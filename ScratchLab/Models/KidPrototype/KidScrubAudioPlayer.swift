// KidScrubAudioPlayer.swift
// ScratchLab — Kid Mode Validation Prototype (Batch 1).
//
// Self-contained scrub audio player. This is the prototype's ONE audio
// pipeline. Delete the KidPrototype folder + flag and production is
// byte-identical.
//
// Batch 1.5, Part E — Auto-play render model:
// When the user is not grabbing, the render thread self-advances at exactly
// 1× record speed through a 0.9 s anchor window (12→6 arc at 33⅓ RPM).
// When the user grabs, the render thread chases the touch-driven target.
// Release returns to auto-play. The audio thread drives itself — no timer
// stepping. Gain ramps on state changes for click-free transitions.

import Foundation
import AVFoundation

final class KidScrubAudioPlayer {

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?

    private var samples: [Float] = []
    private var frameCount: Int = 0
    private var sampleRate: Double = 44_100

    /// Anchor window within the source sample.
    private var anchorStart: Double = 0
    private var anchorEnd: Double = 0
    private var windowFrames: Double = 0

    /// Shared state guarded by `stateLock`.
    private var stateLock = os_unfair_lock_s()

    /// When true, the user is touching — render chases `targetReadHead`.
    /// When false, render self-advances at 1× through the window.
    private var isGrabbing = false

    /// Touch-driven target (only used when isGrabbing).
    private var targetReadHead: Double = 0

    /// Render-thread-only read head position. Initialised to window centre.
    private var readIndex: Double = 0

    /// 1× playback rate: audio frames per output sample.
    private var oneXRate: Double = 0

    private let maxTouchRate: Double = 5.0
    private var gainRamp = KidGainRamp(step: 1.0)
    private var isStarted = false
    private let silenceRateThreshold: Double = 1e-4
    private let fadeSeconds: Double = 0.006

    init() {
        loadBundledSample()
        configureEngine()
    }

    deinit { stop() }

    // MARK: - Public control

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

    func stop() {
        guard isStarted else { return }
        engine.stop()
        isStarted = false
        #if canImport(UIKit)
        try? AVAudioSession.sharedInstance().setActive(
            false, options: [.notifyOthersOnDeactivation])
        #endif
    }

    /// Move the read-head target. Positive = forward, negative = reverse.
    /// Full-height swipe = ±1.0 = full window traversal.
    func moveReadHead(by normalizedDelta: Double) {
        let safeDelta = normalizedDelta.isFinite ? normalizedDelta : 0
        let fd = safeDelta * windowFrames
        os_unfair_lock_lock(&stateLock)
        targetReadHead = min(anchorEnd, max(anchorStart, targetReadHead + fd))
        os_unfair_lock_unlock(&stateLock)
    }

    /// Snap the read head / target to an absolute position t ∈ [0, 1].
    func jumpTo(t: Double) {
        let ct = min(1.0, max(0.0, t.isFinite ? t : 0.5))
        let frame = anchorStart + ct * windowFrames
        os_unfair_lock_lock(&stateLock)
        targetReadHead = frame
        readIndex = frame
        os_unfair_lock_unlock(&stateLock)
    }

    /// Called on touch-down: switch from auto-play to touch-chase mode.
    func beginGrab() {
        os_unfair_lock_lock(&stateLock)
        isGrabbing = true
        // Lock target to current read position so we don't chase a stale target.
        targetReadHead = readIndex
        os_unfair_lock_unlock(&stateLock)
    }

    /// Called on touch-up: switch back to auto-play mode.
    func endGrab() {
        os_unfair_lock_lock(&stateLock)
        isGrabbing = false
        os_unfair_lock_unlock(&stateLock)
    }

    // MARK: - Setup

    private func loadBundledSample() {
        let candidates: [(name: String, ext: String, subdir: String?)] = [
            ("ahhh", "wav", nil),
            ("ahhh", "wav", "VirtualPlatter"),
            ("fresh", "wav", nil),
        ]
        var fileURL: URL?
        for c in candidates {
            if let u = Bundle.main.url(forResource: c.name, withExtension: c.ext, subdirectory: c.subdir) {
                fileURL = u; break
            }
        }
        guard let url = fileURL,
              let file = try? AVAudioFile(forReading: url) else { return }
        let fmt = file.processingFormat
        let len = AVAudioFrameCount(file.length)
        guard len > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: len),
              (try? file.read(into: buf)) != nil,
              let ch = buf.floatChannelData else { return }
        let frames = Int(buf.frameLength)
        guard frames > 0 else { return }
        let nCh = Int(fmt.channelCount)
        var mono = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
            var sum: Float = 0
            for c in 0..<nCh { sum += ch[c][f] }
            mono[f] = sum / Float(max(nCh, 1))
        }
        samples = mono
        frameCount = frames
        sampleRate = fmt.sampleRate

        // 12→6 arc: 180° at 33⅓ RPM = 0.9 s, inside ahhh.wav (1.047 s).
        let wDur: Double = 0.900
        let wStart: Double = 0.050
        anchorStart = wStart * sampleRate
        anchorEnd = min(Double(frameCount - 1), anchorStart + wDur * sampleRate)
        windowFrames = anchorEnd - anchorStart
        oneXRate = windowFrames / 0.9 / sampleRate

        let centre = anchorStart + windowFrames / 2.0
        readIndex = centre
        targetReadHead = centre
    }

    private func configureEngine() {
        guard !samples.isEmpty,
              let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        else { return }
        gainRamp = KidGainRamp(fadeSeconds: fadeSeconds, sampleRate: sampleRate)
        let node = AVAudioSourceNode { [weak self] _, _, n, buf in
            guard let s = self else { return noErr }
            return s.render(frameCount: n, into: buf)
        }
        sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
        engine.prepare()
    }

    // MARK: - Render (audio thread)

    private func render(
        frameCount frames: AVAudioFrameCount,
        into audioBufferList: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        let bufs = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard sampleCountIsValid else { silence(bufs, frames: frames); return noErr }

        os_unfair_lock_lock(&stateLock)
        let grabbing = isGrabbing
        let target = targetReadHead
        os_unfair_lock_unlock(&stateLock)

        let n = Int(frames)
        let start = readIndex
        let rate: Double
        let gainTarget: Double

        if grabbing {
            let raw = n > 0 ? (target - start) / Double(n) : 0
            rate = min(max(raw, -maxTouchRate), maxTouchRate)
            gainTarget = abs(rate) >= silenceRateThreshold ? 1.0 : 0.0
        } else {
            // No auto-play audio.  Hold position, fade to silence.
            rate = 0
            gainTarget = 0.0
        }

        let end = start + rate * Double(n)

        for f in 0..<n {
            let idx = start + rate * Double(f)
            let g = Float(gainRamp.advance(toward: gainTarget))
            let v = sampleValue(at: idx) * g
            for b in bufs {
                b.mData!.assumingMemoryBound(to: Float.self)[f] = v
            }
        }

        // Wrap readIndex within [anchorStart, anchorEnd] for continuous looping.
        var ri = end
        while ri > anchorEnd { ri -= windowFrames }
        while ri < anchorStart { ri += windowFrames }
        readIndex = ri
        return noErr
    }

    private var sampleCountIsValid: Bool {
        frameCount > 1 && samples.count == frameCount
    }

    private func sampleValue(at index: Double) -> Float {
        let c = min(Double(frameCount - 1), max(0, index))
        let lo = Int(c.rounded(.down))
        let hi = min(lo + 1, frameCount - 1)
        let frac = Float(c - Double(lo))
        return samples[lo] + (samples[hi] - samples[lo]) * frac
    }

    private func silence(
        _ bufs: UnsafeMutableAudioBufferListPointer,
        frames: AVAudioFrameCount
    ) {
        for b in bufs { memset(b.mData, 0, Int(b.mDataByteSize)) }
    }
}
