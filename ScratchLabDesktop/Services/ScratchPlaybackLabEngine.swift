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

    /// Target read position in *file frames*, written by the main thread and read by
    /// the audio render thread. Guarded by an unfair lock — a single `Double`, with
    /// negligible contention for a developer tool. (Not strictly real-time-safe, but
    /// acceptable for this slice; revisit with a lock-free atomic if promoted.)
    private let targetFrame = OSAllocatedUnfairLock(initialState: 0.0)
    /// Read head the render block last reached (file frames). Audio-thread-owned.
    private var renderFrame: Double = 0
    /// Tiny pitch-bend jitter from play/stop should not become audible as short
    /// static bursts. Wait until the target is meaningfully away from the render
    /// head before opening the audio envelope.
    private let minimumAudibleDeltaFrames = 8.0
    private var outputSampleRate: Double = 44_100
    private var envelope = ScratchPlaybackLabRenderEnvelope(sampleRate: 44_100)

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
        targetFrame.withLock { $0 = 0 }
        envelope.reset()
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

    /// Sets the target playhead position in seconds (clamped to the loaded sample).
    func setTargetPosition(seconds: TimeInterval) {
        let frames = max(0, min(seconds, duration)) * sampleRate
        targetFrame.withLock { $0 = frames }
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

    /// Slews `renderFrame` from its current value to the target over the quantum,
    /// linear-interpolating the mono buffer. Reverse when target < current; silence
    /// when effectively stopped.
    private func render(frameCount: AVAudioFrameCount, audioBufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let frames = Int(frameCount)
        let total = monoSamples.count

        guard total > 0, frames > 0 else {
            for buffer in buffers { memset(buffer.mData, 0, Int(buffer.mDataByteSize)) }
            return noErr
        }

        let target = targetFrame.withLock { $0 }
        let start = renderFrame
        let step = (target - start) / Double(frames)
        let audible = abs(target - start) >= minimumAudibleDeltaFrames

        monoSamples.withUnsafeBufferPointer { samples in
            for frameIndex in 0..<frames {
                let sourceValue: Float
                if audible {
                    let position = start + step * Double(frameIndex)
                    sourceValue = Self.interpolate(samples, at: position)
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

        renderFrame = audible ? target : start
        return noErr
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
#endif
