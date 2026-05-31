// KidScrubAudioPlayer.swift
// ScratchLab — Kid Mode Validation Prototype (Batch 1, Slice 3).
//
// Self-contained scrub audio player. Proves the one thing Slice 3 must prove:
// finger -> sound. It is the prototype's ONE audio pipeline and is fully
// isolated — it does NOT touch AudioEngine.swift, ScratchPlaybackLabEngine, the
// capture / notation / scoring / export pipeline, or any ML. Delete the
// KidPrototype folder + flag and production is byte-identical.
//
// Approach: an AVAudioSourceNode reads a single bundled sample at a floating
// read head that chases a caller-set normalized position. Because the head is
// driven directly by the user's position, playback pitch and DIRECTION emerge
// from how fast (and which way) the position moves — forward motion plays
// forward, backward motion plays in reverse, and a held finger produces
// silence. This is a real signed scrub, not a one-shot.
//
// HONEST SCOPE NOTE (Risk R1 in the validation plan): this is the minimal
// position-following path. It interpolates linearly and silences when the head
// is still; it does NOT yet apply anti-zipper smoothing across render blocks,
// and motion-to-sound latency on a stock device has not been benchmarked here.
// That smoothing + on-device latency bench is explicitly Slice 4 / next-batch
// work, not Slice 3.

import Foundation
import AVFoundation

final class KidScrubAudioPlayer {

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?

    /// Mono sample data and metadata, loaded once from the bundled sample.
    private var samples: [Float] = []
    private var frameCount: Int = 0
    private var sampleRate: Double = 44_100

    /// Real-time shared state. `targetPosition` is written from the UI thread
    /// and read on the audio render thread under `stateLock`. `readIndex` is
    /// only ever touched on the render thread, so it needs no lock.
    private var stateLock = os_unfair_lock_s()
    private var targetPosition: Double = 0
    private var readIndex: Double = 0

    private var isStarted = false

    /// Below this per-output-frame head movement we treat the record as held
    /// still and emit silence (a stationary groove makes no sound).
    private let silenceRateThreshold: Double = 1e-4

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

    /// Set the normalized platter position (`0.0...1.0`). The render thread
    /// chases this; the resulting pitch/direction follow how it changes.
    func setPosition(_ normalized: Double) {
        let clamped = normalized.isFinite ? min(1.0, max(0.0, normalized)) : 0.5
        os_unfair_lock_lock(&stateLock)
        targetPosition = clamped
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
    }

    private func configureEngine() {
        guard !samples.isEmpty,
              let format = AVAudioFormat(
                standardFormatWithSampleRate: sampleRate,
                channels: 1
              ) else {
            return
        }

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
        let target = targetPosition
        os_unfair_lock_unlock(&stateLock)

        let lastFrame = Double(frameCount - 1)
        let startIndex = readIndex
        let endIndex = target * lastFrame
        let blockFrames = Int(frames)
        let perFrameRate = blockFrames > 0 ? (endIndex - startIndex) / Double(blockFrames) : 0
        let moving = abs(perFrameRate) >= silenceRateThreshold

        for frame in 0..<blockFrames {
            let value: Float
            if moving {
                let idx = startIndex + perFrameRate * Double(frame)
                value = sampleValue(at: idx)
            } else {
                value = 0
            }
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
