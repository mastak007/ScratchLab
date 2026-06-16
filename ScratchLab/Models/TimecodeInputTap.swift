import Foundation
import Combine
#if os(macOS) || os(iOS)
import Accelerate
#endif

// MARK: - TimecodeInputTap

/// A lightweight audio buffer observer for timecode-like stereo sources.
///
/// Accepts raw audio sample buffers, computes per-sample diagnostics (RMS,
/// peak, clipping, silence, channel balance), and accumulates them into a
/// `TimecodeAudioBuffer` for aggregate diagnosis.
///
/// **Batch 1:** Model + diagnostics only. Does NOT connect to `AVCaptureSession`,
/// `AVAudioEngine`, or any live audio hardware. Callers push buffers
/// manually (e.g. from a test harness, or from a DEBUG-gated live tap).
///
/// The tap is a `class` (reference type) so it can be shared between a
/// producer (audio callback) and consumer (diagnostics display) without
/// copying buffers.
public final class TimecodeInputTap: ObservableObject, @unchecked Sendable {

    // MARK: - Configuration

    /// Expected sample rate of the timecode source, in Hz.
    public let sampleRate: Double

    /// Expected channel count (typically 2 for stereo timecode).
    public let channelCount: Int

    /// Reference date for `relativeTime` computation. Defaults to the
    /// instant the tap is created.
    public let startDate: Date

    // MARK: - Accumulated state

    /// The most recently accumulated buffer of diagnostics-ready samples.
    /// Replaced on each call to `drain()`.
    @Published public private(set) var latestBuffer: TimecodeAudioBuffer

    /// The running host-time of the most recently pushed sample, if any.
    @Published public private(set) var latestHostTime: UInt64?

    /// Total number of sample buffers received since creation.
    @Published public private(set) var bufferCount: Int = 0

    /// Total number of audio frames received since creation.
    @Published public private(set) var totalFrameCount: Int = 0

    /// The most recent individual sample (for live level display).
    @Published public private(set) var latestSample: TimecodeInputSample?

    // MARK: - Internal state

    private let lock = NSLock()
    private var pendingSamples: [TimecodeInputSample] = []

    // MARK: - Init

    public init(sampleRate: Double = 44100, channelCount: Int = 2) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.startDate = Date()
        self.latestBuffer = .empty(sampleRate: sampleRate, channelCount: channelCount)
    }

    // MARK: - Buffer ingestion

    /// Push a raw stereo audio buffer into the tap.
    ///
    /// The tap computes per-sample RMS, peak, clipping, silence, and
    /// channel-balance diagnostics and appends the result to the internal
    /// accumulator.
    ///
    /// Floating-point samples are expected to be normalised to [-1, +1].
    ///
    /// - Parameters:
    ///   - samplesLeft: Left-channel samples, normalised to [-1, +1].
    ///   - samplesRight: Right-channel samples, normalised to [-1, +1].
    ///   - hostTime: Optional host-clock timestamp.
    ///   - frameCount: Number of frames (derived from array count if 0).
    public func push(
        samplesLeft: [Float],
        samplesRight: [Float],
        hostTime: UInt64? = nil,
        frameCount: Int = 0
    ) {
        let frames = frameCount > 0 ? frameCount : max(samplesLeft.count, samplesRight.count)
        let now = Date()
        let relativeTime = now.timeIntervalSince(startDate)

        // Compute per-channel diagnostics using Accelerate when available.
        let leftRMS = rms(samplesLeft)
        let rightRMS = rms(samplesRight)
        let leftPeak = peak(samplesLeft)
        let rightPeak = peak(samplesRight)

        // Clipping: any sample at or above 0.999 absolute.
        let isClipping = samplesLeft.contains(where: { abs($0) >= 0.999 })
                       || samplesRight.contains(where: { abs($0) >= 0.999 })

        // Per-sample silence: both channels below 0.001 RMS.
        let isSilent = leftRMS < 0.001 && rightRMS < 0.001

        // Single-sided: one channel substantially lower than the other.
        let maxRMS = max(leftRMS, rightRMS)
        let minRMS = min(leftRMS, rightRMS)
        let isSingleSided = maxRMS > 0.001 && (minRMS / max(maxRMS, 0.0001)) < 0.1

        let sample = TimecodeInputSample(
            hostTime: hostTime,
            relativeTime: relativeTime,
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameCount: frames,
            leftRMS: leftRMS,
            rightRMS: channelCount >= 2 ? rightRMS : nil,
            leftPeak: leftPeak,
            rightPeak: channelCount >= 2 ? rightPeak : nil,
            isClipping: isClipping,
            isSilent: isSilent,
            isSingleSided: isSingleSided
        )

        lock.lock()
        pendingSamples.append(sample)
        bufferCount += 1
        totalFrameCount += frames
        latestHostTime = hostTime
        latestSample = sample
        lock.unlock()
    }

    /// Push a mono audio buffer into the tap (convenience for mono sources).
    public func pushMono(
        samples: [Float],
        hostTime: UInt64? = nil,
        frameCount: Int = 0
    ) {
        push(
            samplesLeft: samples,
            samplesRight: [],
            hostTime: hostTime,
            frameCount: frameCount
        )
    }

    // MARK: - Draining

    /// Drain all pending samples into a `TimecodeAudioBuffer` and reset the
    /// internal accumulator.
    ///
    /// The returned buffer is also stored in `latestBuffer`.
    ///
    /// - Returns: The accumulated buffer, or an empty buffer if none were pending.
    @discardableResult
    public func drain() -> TimecodeAudioBuffer {
        lock.lock()
        let samples = pendingSamples
        pendingSamples.removeAll(keepingCapacity: true)
        lock.unlock()

        let buffer = TimecodeAudioBuffer(samples: samples)
        latestBuffer = buffer
        return buffer
    }

    /// Reset all accumulated state.
    public func reset() {
        lock.lock()
        pendingSamples.removeAll(keepingCapacity: true)
        bufferCount = 0
        totalFrameCount = 0
        latestHostTime = nil
        latestSample = nil
        latestBuffer = .empty(sampleRate: sampleRate, channelCount: channelCount)
        lock.unlock()
    }

    // MARK: - Diagnostics convenience

    /// Run diagnostics on the current latest buffer.
    public func diagnose(with diagnostics: TimecodeSignalDiagnostics = TimecodeSignalDiagnostics()) -> TimecodeSignalDiagnostics.Diagnosis {
        return diagnostics.diagnose(latestBuffer)
    }

    /// Drain and diagnose in a single call.
    public func drainAndDiagnose(with diagnostics: TimecodeSignalDiagnostics = TimecodeSignalDiagnostics()) -> TimecodeSignalDiagnostics.Diagnosis {
        drain()
        return diagnose(with: diagnostics)
    }

    // MARK: - DSP helpers

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
#if os(macOS) || os(iOS)
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        return rms
#else
        let meanSquare = samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)
        return sqrt(meanSquare)
#endif
    }

    private func peak(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
#if os(macOS) || os(iOS)
        var maxAbs: Float = 0
        var src = samples
        vDSP_maxmgv(&src, 1, &maxAbs, vDSP_Length(samples.count))
        return maxAbs
#else
        return samples.map { abs($0) }.max() ?? 0
#endif
    }
}
