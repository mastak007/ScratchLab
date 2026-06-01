#if os(macOS)
import Foundation
import AVFoundation
import os

// Scratch Playback Lab (first slice): isolated macOS sample-playback path.
//
// Scope guardrails (deliberate):
// - Wholly separate from `AudioEngine` and the capture / scoring / export pipeline.
//   It owns its own `AVAudioEngine` and renders ONE bundled sample. It writes no
//   files, no device output (no LEDs/motor), and touches no existing behaviour.
// - The platter integrator (`ScratchPlatterPlayheadMapper`) is the single source of
//   truth for position. This engine's render head *follows* a target position, so
//   the audio you hear and the on-screen playhead are the same number. Following the
//   target by resampling yields forward/reverse "scrub" audio.
// - First slice prioritises a correct playhead and plausible scrub audio over
//   studio-grade scratch fidelity. No crossfader gating, no beat layer yet.

/// Loads a bundled sample into a mono float buffer and renders it with an
/// `AVAudioSourceNode` whose read head slews toward a target sample position.
final class ScratchPlaybackLabEngine {
    /// Loaded sample as mono float frames (channel-averaged).
    private(set) var monoSamples: [Float] = []
    /// Sample rate of the loaded file (frames per second).
    private(set) var sampleRate: Double = 44_100

    /// Sample duration in seconds.
    var duration: TimeInterval {
        sampleRate > 0 ? Double(monoSamples.count) / sampleRate : 0
    }

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private(set) var isRunning = false

    /// Scrub velocity in *sample-seconds of playback per real second* (signed; forward
    /// positive). The render head integrates this continuously, so playback stays smooth
    /// across bursty MIDI delivery — between bursts the head keeps gliding at the last
    /// velocity rather than lurching to a target and going silent. Written by the main
    /// thread, read by the render thread.
    private let velocity = OSAllocatedUnfairLock(initialState: 0.0)
    /// A pending seek (target frame) for reset/jump only; consumed once by the render
    /// thread, which snaps `renderFrame` there and zeroes velocity. nil = no seek.
    private let pendingSeekFrame = OSAllocatedUnfairLock<Double?>(initialState: nil)
    /// Read head the render block last reached (file frames). Audio-thread-owned.
    private var renderFrame: Double = 0
    /// Hysteretic gate: a truly stopped platter (sustained near-zero movement) fades to
    /// silence, but a momentary dip — a direction reversal or mid-stroke MIDI wobble —
    /// glides through instead of cutting the audio into stutter notches. NOT keyed off
    /// target changes, so bursty delivery cannot chop the audio. Audio-thread-owned.
    private var audibilityGate = ScratchPlaybackLabAudibilityGate()
    private var outputSampleRate: Double = 44_100
    private var envelope = ScratchPlaybackLabRenderEnvelope(sampleRate: 44_100)
    /// Whether the read head wraps around the sample (loop) instead of clamping. Written
    /// by the main thread, read by the render thread; guarded like `targetFrame`.
    private let loopsEnabled = OSAllocatedUnfairLock(initialState: false)

    // MARK: - Loading

    /// Loads the bundled `ahhh.wav` (default) into a mono buffer. Returns false if
    /// the resource can't be found or read; the lab then shows an empty waveform.
    @discardableResult
    func loadSample(named name: String = "ahhh", withExtension ext: String = "wav") -> Bool {
        guard let url = Self.locateSample(named: name, withExtension: ext) else { return false }
        return loadSample(at: url)
    }

    @discardableResult
    func loadSample(at url: URL) -> Bool {
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        let format = file.processingFormat
        let frameCapacity = AVAudioFrameCount(file.length)
        guard frameCapacity > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity),
              (try? file.read(into: buffer)) != nil,
              let channelData = buffer.floatChannelData else { return false }

        let channels = Int(format.channelCount)
        let frames = Int(buffer.frameLength)
        var mono = [Float](repeating: 0, count: frames)
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels {
                sum += channelData[channel][frame]
            }
            mono[frame] = sum / Float(max(channels, 1))
        }

        monoSamples = mono
        sampleRate = format.sampleRate
        renderFrame = 0
        velocity.withLock { $0 = 0 }
        pendingSeekFrame.withLock { $0 = nil }
        envelope.reset()
        audibilityGate.reset()
        return true
    }

    /// Locates the bundled sample, tolerating both a flat bundle and the
    /// `VirtualPlatter` subdirectory it ships in.
    private static func locateSample(named name: String, withExtension ext: String) -> URL? {
        let bundle = Bundle.main
        return bundle.url(forResource: name, withExtension: ext, subdirectory: "VirtualPlatter")
            ?? bundle.url(forResource: name, withExtension: ext)
    }

    // MARK: - Position

    /// Sets the scrub velocity in sample-seconds of playback per real second (signed).
    /// The render head integrates this continuously; the platter model refreshes it from
    /// the smoothed CC6 step rate. Set 0 to glide to a stop (the envelope fades out).
    func setVelocity(_ sampleSecondsPerSecond: Double) {
        velocity.withLock { $0 = sampleSecondsPerSecond }
    }

    /// Seeks the read head to `seconds` (reset/jump only) and zeroes velocity. The render
    /// thread applies it once, snapping `renderFrame` — it does NOT slew there.
    func setTargetPosition(seconds: TimeInterval) {
        let frames = max(0, min(seconds, duration)) * sampleRate
        pendingSeekFrame.withLock { $0 = frames }
    }

    /// Enables loop playback: the read head wraps around the sample and follows the
    /// shorter path across the boundary so continuous rotation cycles cleanly instead of
    /// sweeping backward through the whole sample at the seam.
    func setLoops(_ on: Bool) {
        loopsEnabled.withLock { $0 = on }
    }

    /// Output gain `0...1` for the whole lab (used optionally to gate sample volume by
    /// crossfader position). Applied on the main mixer — isolated to this engine.
    func setOutputGain(_ gain: Float) {
        engine.mainMixerNode.outputVolume = Swift.min(Swift.max(gain, 0), 1)
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning, !monoSamples.isEmpty else { return }
        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        outputSampleRate = outputFormat.sampleRate > 0 ? outputFormat.sampleRate : sampleRate
        envelope = ScratchPlaybackLabRenderEnvelope(sampleRate: outputSampleRate)
        audibilityGate.reset()
        let node = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList in
            guard let self else { return noErr }
            return self.render(frameCount: frameCount, audioBufferList: audioBufferList)
        }
        sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: outputFormat)
        do {
            try engine.start()
            isRunning = true
        } catch {
            engine.detach(node)
            sourceNode = nil
            isRunning = false
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.stop()
        if let node = sourceNode {
            engine.detach(node)
        }
        sourceNode = nil
        isRunning = false
    }

    // MARK: - Render

    /// Integrates the scrub `velocity` across the quantum: the read head advances by a
    /// constant per-frame rate, linear-interpolating the mono buffer (wrapping in loop
    /// mode, clamping otherwise). Because motion comes from velocity — not a target
    /// position — the head keeps gliding between MIDI bursts and only fades to silence
    /// when velocity reaches ~0. A pending seek snaps the head and zeroes velocity.
    private func render(frameCount: AVAudioFrameCount, audioBufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let frames = Int(frameCount)
        let total = monoSamples.count

        guard total > 0, frames > 0 else {
            for buffer in buffers { memset(buffer.mData, 0, Int(buffer.mDataByteSize)) }
            return noErr
        }

        // Apply a pending seek (reset/jump): snap the head, drop velocity.
        let seekRequest: Double? = pendingSeekFrame.withLock { state in
            let s = state
            state = nil
            return s
        }
        if let seek = seekRequest {
            renderFrame = Self.clampFrame(seek, total: Double(total))
            velocity.withLock { $0 = 0 }
        }

        let v = velocity.withLock { $0 }
        let loops = loopsEnabled.withLock { $0 }
        let ring = Double(total)
        let start = renderFrame
        let perFrame = Self.framesPerOutputFrame(velocity: v, sampleRate: sampleRate, outputSampleRate: outputSampleRate)
        let bufferSeconds = outputSampleRate > 0 ? Double(frames) / outputSampleRate : 0
        let audible = audibilityGate.update(movementFrames: perFrame * Double(frames), bufferSeconds: bufferSeconds)

        monoSamples.withUnsafeBufferPointer { samples in
            for frameIndex in 0..<frames {
                let sourceValue: Float
                if audible {
                    let position = start + perFrame * Double(frameIndex)
                    sourceValue = Self.sampleSpan(samples, from: position, to: position + perFrame,
                                                  total: ring, loops: loops)
                } else {
                    sourceValue = 0
                }
                let value = envelope.process(sourceValue, audible: audible)
                for buffer in buffers {
                    guard let data = buffer.mData else { continue }
                    data.assumingMemoryBound(to: Float.self)[frameIndex] = value
                }
            }
        }

        let rawEnd = start + perFrame * Double(frames)
        renderFrame = audible ? (loops ? Self.wrapFrame(rawEnd, total: ring) : Self.clampFrame(rawEnd, total: ring)) : start
        return noErr
    }

    /// File frames the head advances per OUTPUT frame for a scrub `velocity`
    /// (sample-seconds/sec). rate 1.0 ⇒ normal speed regardless of output rate.
    static func framesPerOutputFrame(velocity: Double, sampleRate: Double, outputSampleRate: Double) -> Double {
        guard outputSampleRate > 0 else { return 0 }
        return velocity * sampleRate / outputSampleRate
    }

    /// The read head, advanced one quantum from `start` at `velocity`, wrapped (loop) or
    /// clamped. Pure so the velocity integration is unit-testable without AVAudioEngine.
    static func advancedFrame(from start: Double, velocity: Double, sampleRate: Double,
                              outputSampleRate: Double, frames: Int, total: Double, loops: Bool) -> Double {
        guard total > 0, frames > 0 else { return start }
        let perFrame = framesPerOutputFrame(velocity: velocity, sampleRate: sampleRate, outputSampleRate: outputSampleRate)
        let raw = start + perFrame * Double(frames)
        return loops ? wrapFrame(raw, total: total) : clampFrame(raw, total: total)
    }

    /// Whether the head moves enough this quantum to be audible (i.e. velocity ≉ 0).
    static func isAudible(perFrame: Double, frames: Int, minDeltaFrames: Double) -> Bool {
        abs(perFrame * Double(frames)) >= minDeltaFrames
    }

    /// Wraps a frame index into `0 ..< total` (loop reads); 0 for non-positive total.
    static func wrapFrame(_ frame: Double, total: Double) -> Double {
        guard total > 0 else { return 0 }
        let m = frame.truncatingRemainder(dividingBy: total)
        return m < 0 ? m + total : m
    }

    /// Clamps a frame index into `0 ... total-1` (clamp mode); 0 for non-positive total.
    static func clampFrame(_ frame: Double, total: Double) -> Double {
        guard total > 0 else { return 0 }
        return Swift.min(Swift.max(frame, 0), total - 1)
    }

    /// Reads the source for one output frame whose read head crosses the span `from…to`
    /// (one quantum-step apart, so the span width is `|perFrame|` source frames).
    ///
    /// At ≤1× the span is sub-sample, so this is a single linear-interpolated point read at
    /// `from` — byte-identical to plain interpolation. Above 1× the head skips source frames;
    /// point-sampling would fold those skipped high frequencies back as harsh aliasing. So
    /// the source is **box-averaged** across the span (band-limiting it to the new rate),
    /// using `ceil(width)` midpoint sub-taps capped at 64. The span is `min…max`, so reverse
    /// (`to < from`) averages the identical span — direction-symmetric. Each tap wraps/clamps
    /// independently, so a span across the loop seam (or a clamped end) reads safely.
    static func sampleSpan(_ samples: UnsafeBufferPointer<Float>, from: Double, to: Double,
                           total: Double, loops: Bool) -> Float {
        let width = abs(to - from)
        let read: (Double) -> Float = { pos in
            let p = loops ? wrapFrame(pos, total: total) : clampFrame(pos, total: total)
            return interpolate(samples, at: p)
        }
        if width <= 1 { return read(from) }   // ≤1× — preserve plain interpolation at the head

        let taps = Swift.min(64, Swift.max(2, Int(width.rounded(.up))))
        let lo = Swift.min(from, to)
        let step = width / Double(taps)
        var sum: Float = 0
        for k in 0..<taps {
            sum += read(lo + (Double(k) + 0.5) * step)   // midpoint of each sub-interval
        }
        return sum / Float(taps)
    }

    /// Linear-interpolated read of a float buffer at a fractional index, clamped to
    /// the buffer bounds.
    private static func interpolate(_ samples: UnsafeBufferPointer<Float>, at index: Double) -> Float {
        let maxIndex = samples.count - 1
        if maxIndex < 0 { return 0 }
        let clamped = Swift.min(Swift.max(index, 0), Double(maxIndex))
        let lower = Int(clamped)
        if lower >= maxIndex { return samples[maxIndex] }
        let fraction = Float(clamped - Double(lower))
        return samples[lower] * (1 - fraction) + samples[lower + 1] * fraction
    }
}

/// Hysteretic audibility gate for the playback lab render head.
///
/// A bare per-buffer threshold ("mute the moment head movement drops below N frames")
/// chops scratching into stutter notches: the head crosses zero at every direction
/// reversal and wobbles below the threshold mid-stroke when MIDI arrives in bursts, so
/// the source is muted and re-faded many times a second. This gate fixes that with:
///   - **hysteresis** — once open it stays open until movement falls below a lower
///     `closeDeltaFrames`, so velocity hovering near one level can't chatter the gate; and
///   - **a hold** — movement must stay below `closeDeltaFrames` for `holdSeconds` of real
///     time (buffer-size independent) before muting, so a brief reversal dip glides
///     through. A genuinely stopped platter (sustained near-zero movement) still mutes.
///
/// Pure and audio-thread-owned, so the gating policy is unit-testable without AVAudioEngine.
struct ScratchPlaybackLabAudibilityGate {
    let openDeltaFrames: Double   // movement ≥ this re-opens the gate immediately
    let closeDeltaFrames: Double  // movement < this counts toward muting
    let holdSeconds: TimeInterval // sustained sub-close time required before muting
    private(set) var isOpen = false
    private var quietSeconds: TimeInterval = 0

    init(openDeltaFrames: Double = 8.0, closeDeltaFrames: Double = 2.0, holdSeconds: TimeInterval = 0.08) {
        self.openDeltaFrames = max(openDeltaFrames, 0)
        self.closeDeltaFrames = max(min(closeDeltaFrames, openDeltaFrames), 0)
        self.holdSeconds = max(holdSeconds, 0)
    }

    mutating func reset() {
        isOpen = false
        quietSeconds = 0
    }

    /// Updates the gate for one render buffer spanning `bufferSeconds` of output, during
    /// which the head moved `movementFrames`. Returns whether the source is audible now.
    mutating func update(movementFrames: Double, bufferSeconds: TimeInterval) -> Bool {
        let magnitude = abs(movementFrames)
        if magnitude >= openDeltaFrames {
            quietSeconds = 0
            isOpen = true
        } else if magnitude < closeDeltaFrames {
            quietSeconds += max(bufferSeconds, 0)
            if quietSeconds >= holdSeconds {
                isOpen = false
            }
        } else {
            // In the hysteresis band: hold the current state, don't accumulate toward mute.
            quietSeconds = 0
        }
        return isOpen
    }
}

/// Small render-thread envelope for the playback lab source node.
///
/// The source switches between silence and arbitrary positions inside `ahhh.wav`.
/// Without a ramp, the first/last emitted frame can jump between `0` and a non-zero
/// sample value, which is heard as a click/static tick when pressing play/stop or
/// when platter MIDI jitters around rest.
struct ScratchPlaybackLabRenderEnvelope {
    private let rampStep: Float
    private(set) var gain: Float = 0
    private(set) var lastAudibleSample: Float = 0

    init(sampleRate: Double, rampDuration: TimeInterval = 0.004) {
        let frames = max(1, Int(sampleRate * max(rampDuration, 0.0005)))
        self.rampStep = 1.0 / Float(frames)
    }

    mutating func reset() {
        gain = 0
        lastAudibleSample = 0
    }

    mutating func process(_ sample: Float, audible: Bool) -> Float {
        let targetGain: Float = audible ? 1 : 0
        if gain < targetGain {
            gain = min(targetGain, gain + rampStep)
        } else if gain > targetGain {
            gain = max(targetGain, gain - rampStep)
        }

        let source = audible ? sample : lastAudibleSample
        let output = source * gain
        if audible {
            lastAudibleSample = sample
        } else if gain == 0 {
            lastAudibleSample = 0
        }
        return output
    }
}

/// Smooths a signed scrub velocity (sample-seconds of playback per real second) from
/// per-event platter movement timestamped on the real (CoreMIDI) clock.
///
/// Pure and clock-agnostic: it's a time-based EMA, so it's robust to bursty, irregular
/// MIDI delivery — each event contributes in proportion to the real time it spans. A
/// gap longer than `idleTimeout` between two events zeroes the velocity (platter
/// stopped). The host also calls `reset()` when it detects the stream has gone idle.
struct ScratchScrubVelocityEstimator: Equatable {
    let smoothing: TimeInterval     // EMA time-constant (~0.04 s)
    let idleTimeout: TimeInterval   // inter-event gap treated as "stopped" (~0.18 s)
    private(set) var velocity: Double = 0
    private var lastTime: TimeInterval?

    init(smoothing: TimeInterval = 0.04, idleTimeout: TimeInterval = 0.18) {
        self.smoothing = max(0.001, smoothing)
        self.idleTimeout = max(0.001, idleTimeout)
    }

    /// Feeds a playhead movement of `sampleSeconds` that occurred at real time `time`.
    /// The first call only seeds the clock (no velocity). Returns the updated velocity.
    @discardableResult
    mutating func ingest(sampleSeconds: Double, at time: TimeInterval) -> Double {
        defer { lastTime = time }
        guard let last = lastTime else { return velocity }   // seed only
        let dt = time - last
        guard dt > 0 else { return velocity }
        if dt > idleTimeout { velocity = 0; return velocity } // long gap → stopped
        let instantaneous = sampleSeconds / dt                // sample-sec per real-sec
        let alpha = Swift.min(1.0, dt / smoothing)
        velocity += (instantaneous - velocity) * alpha
        return velocity
    }

    /// Clears velocity and the clock (host calls this when the platter stream goes idle).
    mutating func reset() {
        velocity = 0
        lastTime = nil
    }
}
#endif
