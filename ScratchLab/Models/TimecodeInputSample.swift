import Foundation

// MARK: - TimecodeInputSample

/// A single stereo audio sample captured from a potential timecode source.
///
/// Carries both raw sample values and pre-computed per-channel diagnostics
/// (RMS, peak, clipping flag). The diagnostics are computed at ingest time
/// so downstream consumers don't need access to the full sample buffer.
///
/// This type is intentionally platform-neutral — it does not import AVFoundation
/// or any audio framework. Callers are responsible for converting their native
/// buffer types into this representation.
///
/// **Batch 1:** Diagnostics only. No decoding, no position extraction.
public struct TimecodeInputSample: Equatable, Sendable {

    // MARK: - Time

    /// Host-clock timestamp (mach_absolute_time on Darwin, monotonic on other
    /// platforms). Nil when the source cannot provide a host timestamp.
    public let hostTime: UInt64?

    /// Seconds since the tap was started (or since an arbitrary reference if
    /// the source does not provide absolute time). Always non-negative.
    public let relativeTime: TimeInterval

    // MARK: - Format

    /// Sample rate of the source, in Hz (e.g. 44100, 48000).
    public let sampleRate: Double

    /// Number of channels in the original buffer (1 or 2 for timecode).
    public let channelCount: Int

    /// Number of frames in the original buffer.
    public let frameCount: Int

    // MARK: - Per-channel diagnostics

    /// Left channel RMS level, normalised to [0, 1].
    public let leftRMS: Float

    /// Right channel RMS level, normalised to [0, 1]. Nil when `channelCount < 2`.
    public let rightRMS: Float?

    /// Left channel peak absolute value, normalised to [0, 1].
    public let leftPeak: Float

    /// Right channel peak absolute value, normalised to [0, 1]. Nil when `channelCount < 2`.
    public let rightPeak: Float?

    // MARK: - Flags

    /// True when any sample in either channel exceeds 0.999 (i.e. is at or
    /// near digital full scale and may be clipped).
    public let isClipping: Bool

    /// True when both channels (or the only channel) have RMS below the
    /// silence threshold. The threshold is defined by the diagnostics engine.
    public let isSilent: Bool

    /// True when `channelCount >= 2` and one channel has a much lower RMS
    /// than the other (suggesting a mono signal panned hard or a cable fault).
    public let isSingleSided: Bool

    // MARK: - Init

    public init(
        hostTime: UInt64?,
        relativeTime: TimeInterval,
        sampleRate: Double,
        channelCount: Int,
        frameCount: Int,
        leftRMS: Float,
        rightRMS: Float?,
        leftPeak: Float,
        rightPeak: Float?,
        isClipping: Bool,
        isSilent: Bool,
        isSingleSided: Bool
    ) {
        self.hostTime = hostTime
        self.relativeTime = relativeTime
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameCount = frameCount
        self.leftRMS = leftRMS
        self.rightRMS = rightRMS
        self.leftPeak = leftPeak
        self.rightPeak = rightPeak
        self.isClipping = isClipping
        self.isSilent = isSilent
        self.isSingleSided = isSingleSided
    }
}
