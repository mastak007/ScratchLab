import Foundation

// MARK: - TimecodeAudioBuffer

/// An aggregate of multiple `TimecodeInputSample` values representing one
/// diagnostic window (e.g. 100 ms of audio).
///
/// Carries aggregate format metadata alongside the per-sample array so
/// consumers can reason about the buffer as a whole without re-deriving
/// sample rate, channel count, or duration from individual samples.
///
/// **Batch 1:** Diagnostics only. No decoding, no position extraction.
public struct TimecodeAudioBuffer: Equatable, Sendable {

    /// The samples in this buffer, in time order.
    public let samples: [TimecodeInputSample]

    /// Sample rate shared by all samples in this buffer.
    public let sampleRate: Double

    /// Channel count shared by all samples in this buffer.
    public let channelCount: Int

    /// Total number of frames across all samples in this buffer.
    public let totalFrameCount: Int

    /// Duration of this buffer in seconds, derived from `totalFrameCount / sampleRate`.
    public var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return TimeInterval(totalFrameCount) / sampleRate
    }

    /// The host time of the earliest sample, if any sample carries a host time.
    public var earliestHostTime: UInt64? {
        samples.compactMap(\.hostTime).min()
    }

    /// The host time of the latest sample, if any sample carries a host time.
    public var latestHostTime: UInt64? {
        samples.compactMap(\.hostTime).max()
    }

    // MARK: - Init

    public init(samples: [TimecodeInputSample]) {
        self.samples = samples
        self.sampleRate = samples.first?.sampleRate ?? 0
        self.channelCount = samples.first?.channelCount ?? 0
        self.totalFrameCount = samples.reduce(0) { $0 + $1.frameCount }
    }

    /// Create a buffer with explicit format metadata. Use this when the
    /// format is known but samples may be empty (e.g. initial state).
    public init(samples: [TimecodeInputSample], sampleRate: Double, channelCount: Int) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.totalFrameCount = samples.reduce(0) { $0 + $1.frameCount }
    }

    /// Create an empty buffer with the given format parameters.
    public static func empty(sampleRate: Double, channelCount: Int) -> TimecodeAudioBuffer {
        TimecodeAudioBuffer(samples: [], sampleRate: sampleRate, channelCount: channelCount)
    }
}
