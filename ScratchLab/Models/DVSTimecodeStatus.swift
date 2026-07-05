import Foundation

/// Diagnostics-first snapshot of one DVS control-vinyl analysis cycle.
///
/// Pure value type. No platform dependencies; does not reach into playback,
/// scoring, export, or any Serato product API.
public struct DVSTimecodeStatus: Equatable, Sendable {

    /// Decoded platter motion direction.
    public enum Direction: String, Equatable, Sendable {
        case forward
        case backward
        case stopped
        case unknown
    }

    /// True when a signal above the noise floor is present on both channels.
    public let hasSignal: Bool

    /// Aggregate RMS of the left channel in the analysis window (linear 0–1).
    public let rms: Float

    /// Peak amplitude of the left channel in the analysis window (linear 0–1).
    public let peak: Float

    /// ZCR-derived carrier frequency estimate (Hz). nil when silent or unknown.
    public let estimatedFrequencyHz: Float?

    /// Phase delta from the most recently decoded frame. nil when no frame was
    /// decoded (e.g. silent, clipped, or below the confidence threshold).
    public let phaseDelta: Float?

    /// Decoded platter motion direction.
    public let direction: Direction

    /// Platter speed relative to nominal (1.0 ≈ 33 rpm). 0.0 = stopped.
    public let relativeRate: Float

    /// Decode confidence in [0, 1]. 1.0 = ideal signal; 0.0 = no confidence.
    public let confidence: Float

    /// Human-readable reason the last buffer was dropped. nil when no drops.
    public let droppedReason: String?

    public init(
        hasSignal: Bool,
        rms: Float,
        peak: Float,
        estimatedFrequencyHz: Float?,
        phaseDelta: Float?,
        direction: Direction,
        relativeRate: Float,
        confidence: Float,
        droppedReason: String?
    ) {
        self.hasSignal = hasSignal
        self.rms = rms
        self.peak = peak
        self.estimatedFrequencyHz = estimatedFrequencyHz
        self.phaseDelta = phaseDelta
        self.direction = direction
        self.relativeRate = relativeRate
        self.confidence = confidence
        self.droppedReason = droppedReason
    }
}
