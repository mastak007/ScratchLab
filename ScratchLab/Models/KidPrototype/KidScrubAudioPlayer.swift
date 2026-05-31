// KidScrubAudioPlayer.swift
// ScratchLab — Kid Mode Validation Prototype (Batch 1).
//
// Self-contained scrub audio player. Proves the one thing the prototype must
// prove: finger -> recognisable "ahh" sound. It is the prototype's ONE audio
// pipeline and is fully isolated — it does NOT touch AudioEngine.swift,
// ScratchPlaybackLabEngine, the capture / notation / scoring / export pipeline,
// or any ML. Delete the KidPrototype folder + flag and production is
// byte-identical.
//
// Batch 1.5, Part C — Anchored micro-scrub model:
// Touch-position 0…1 mapping across the full sample has been replaced. Touch
// deltas now drive the read head within a small (~300 ms) window anchored at
// the cleanest part of the "ahh" sample. The read-head rate is clamped to ±3×
// so fast flicks stay recognisably vocal instead of turning into high-frequency
// buzz. When the finger stops the read head holds and the de-click gain ramp
// fades to silence.
//
// This is NOT a full scratch engine. It is a prototype training-feedback model:
// forward drag  → forward "ahh"
// backward drag → reverse-ish "ahh"
// hold / lift   → silence (de-clicked)
// fast flick    → faster "ahh" (rate-clamped, not buzz)

import Foundation
import AVFoundation

final class KidScrubAudioPlayer {

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?

    /// Mono sample data and metadata, loaded once from the bundled sample.
    private var samples: [Float] = []
    private var frameCount: Int = 0
    private var sampleRate: Double = 44_100

    /// Anchor window within the source sample (frame indices). The read head is
    /// confined to this region so the output always stays inside the vocal
    /// "ahh" — no silence tail, no attack transient.
    private var anchorStart: Double = 0
    private var anchorEnd: Double = 0
    private var windowFrames: Double = 0

    /// Real-time shared state. `targetReadHead` is written from the UI thread
    /// (via `moveReadHead(by:)`) and read on the audio render thread under
    /// `stateLock`.
    private var stateLock = os_unfair_lock_s()
    private var targetReadHead: Double = 0
    private var readIndex: Double = 0

    /// How many audio frames one unit of normalised delta moves the read head.
    /// sensitivity=2.0 means a full pad-width swipe traverses the window twice,
    /// giving roughly 1× playback at comfortable drag speeds.
    private let sensitivity: Double = 2.0

    /// Maximum playback rate multiplier. Clamped so fast flicks stay
    /// recognisably "ahh" instead of turning into high-frequency buzz.
    private let maxRate: Double = 3.0

    /// Per-sample de-click gain envelope (Batch 1.5, Part A). Glides toward 1.0
    /// while the head moves and 0.0 while it is held, so starts/stops/reversals
    /// fade instead of stepping.
    private var gainRamp = KidGainRamp(step: 1.0)

    private var isStarted = false

    /// Below this per-output-frame head movement we treat the record as held
    /// still and emit silence (a stationary groove makes no sound).
    private let silenceRateThreshold: Double = 1e-4

    /// De-click fade length. ~6 ms is click-free yet adds negligible latency.
    private let fadeSeconds: Double = 0.006

    init() {
        loadBundledSample()
        configureEngine()
    }

    deinit {
        stop()
    }

    // MARK: - Public control

    /// Begin rendering. Safe to call repeatedly.
    func start() {
        guard !samples.isEmpty, !isStarted else { return }
        #if canImport(UIKit)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers])
        try? session.setActive(true)
        #endif
        do {
            try engine.start()
            isStarted = true
        } catch {
            isStarted = false
        }
    }

    /// Stop rendering and release the audio session.
    func stop() {
        guard isStarted else { return }
        engine.stop()
        isStarted = false
        #if canImport(UIKit)
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
        #endif
    }

    /// Move the read-head target by `normalizedDelta` within the anchor window.
    /// Positive delta = forward, negative = backward. The render thread chases
    /// this target at ≤ `maxRate`. Called from the UI drag-gesture handler once
    /// per touch event.
    func moveReadHead(by normalizedDelta: Double) {
        let safeDelta = normalizedDelta.isFinite ? normalizedDelta : 0
        let frameDelta = safeDelta * sensitivity * windowFrames
        os_unfair_lock_lock(&stateLock)
        targetReadHead = min(anchorEnd, max(anchorStart, targetReadHead + frameDelta))
        os_unfair_lock_unlock(&stateLock)
    }

    // MARK: - Setup

    private func loadBundledSample() {
        // Reuse an existing bundled sample (no new resource added). Prefer the
        // long "ahhh" vocal — good headroom for scrubbing — falling back to the
        // VirtualPlatter copy, then "fresh".
        let candidates: [(name: String, ext: String, subdir: String?)] = [
            ("ahhh", "wav", nil),
            ("ahhh", "wav", "VirtualPlatter"),
            ("fresh", "wav", nil)
        ]

        var fileURL: URL?
        for candidate in candidates {
            if let url = Bundle.main.url(
                forResource: candidate.name,
                withExtension: candidate.ext,
                subdirectory: candidate.subdir
            ) {
                fileURL = url
                break
            }
        }

        guard let url = fileURL,
              let file = try? AVAudioFile(forReading: url) else {
            return
        }

        let format = file.processingFormat
        let length = AVAudioFrameCount(file.length)
        guard length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: length),
              (try? file.read(into: buffer)) != nil,
              let channelData = buffer.floatChannelData else {
            return
        }

        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        // Collapse to mono (average channels) for a single read head.
        let channelCount = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: frames)
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += channelData[channel][frame]
            }
            mono[frame] = sum / Float(max(channelCount, 1))
        }

        samples = mono
        frameCount = frames
        sampleRate = format.sampleRate

        // Anchor the scrub window at the loudest, most recognisable part of the
        // "ahh". The sample envelope peaks from ~50 ms to ~420 ms; a 300 ms
        // window starting at 100 ms keeps the read head inside the strong vocal
        // formant region.
        let windowDuration: Double = 0.300     // 300 ms
        let windowStartSecond: Double = 0.100  // start 100 ms in
        anchorStart = windowStartSecond * sampleRate
        anchorEnd = min(Double(frameCount - 1), anchorStart + windowDuration * sampleRate)
        windowFrames = anchorEnd - anchorStart

        // Park the read head at the centre of the window so the user hears the
        // strongest "ahh" on first touch without any movement.
        let centre = anchorStart + windowFrames / 2.0
        readIndex = centre
        targetReadHead = centre
    }

    private func configureEngine() {
        guard !samples.isEmpty,
              let format = AVAudioFormat(
                standardFormatWithSampleRate: sampleRate,
                channels: 1
              ) else {
            return
        }

        // Now that the real sample rate is known, build the de-click ramp.
        gainRamp = KidGainRamp(fadeSeconds: fadeSeconds, sampleRate: sampleRate)

        let node = AVAudioSourceNode { [weak self] _, _, frameCountToFill, audioBufferList -> OSStatus in
            guard let self else { return noErr }
            return self.render(frameCount: frameCountToFill, into: audioBufferList)
        }

        sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
    }

    // MARK: - Render (audio thread)

    private func render(frameCount frames: AVAudioFrameCount, into audioBufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let bufferList = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard sampleCountIsValid else {
            silence(bufferList, frames: frames)
            return noErr
        }

        os_unfair_lock_lock(&stateLock)
        let target = targetReadHead
        os_unfair_lock_unlock(&stateLock)

        let blockFrames = Int(frames)
        let startIndex = readIndex

        // Chase the target at no more than ±maxRate (audio frames per output
        // sample). A rate of 1.0 = normal speed, 3.0 = 3× speed.
        let rawRate = blockFrames > 0 ? (target - startIndex) / Double(blockFrames) : 0
        let clampedRate = min(max(rawRate, -maxRate), maxRate)
        let endIndex = startIndex + clampedRate * Double(blockFrames)

        // Target the de-click envelope: full level while the head moves, silence
        // while it is held. The ramp turns the on/off edges into short fades.
        let gainTarget: Double = abs(clampedRate) >= silenceRateThreshold ? 1.0 : 0.0

        for frame in 0..<blockFrames {
            let idx = startIndex + clampedRate * Double(frame)
            let gain = Float(gainRamp.advance(toward: gainTarget))
            let value = sampleValue(at: idx) * gain
            for buffer in bufferList {
                let out = buffer.mData!.assumingMemoryBound(to: Float.self)
                out[frame] = value
            }
        }

        readIndex = endIndex
        return noErr
    }

    private var sampleCountIsValid: Bool {
        frameCount > 1 && samples.count == frameCount
    }

    /// Linearly interpolated, bounds-clamped sample read.
    private func sampleValue(at index: Double) -> Float {
        let clamped = min(Double(frameCount - 1), max(0, index))
        let lower = Int(clamped.rounded(.down))
        let upper = min(lower + 1, frameCount - 1)
        let fraction = Float(clamped - Double(lower))
        return samples[lower] + (samples[upper] - samples[lower]) * fraction
    }

    private func silence(_ bufferList: UnsafeMutableAudioBufferListPointer, frames: AVAudioFrameCount) {
        for buffer in bufferList {
            memset(buffer.mData, 0, Int(buffer.mDataByteSize))
        }
    }
}
