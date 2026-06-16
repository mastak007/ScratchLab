import Foundation

// MARK: - TimecodeMotionSample

/// A single timecode-derived motion event, carrying decoded movement and a
/// source label.
///
/// This is the intermediate type between the decoder output and the platter
/// timeline adapter. It carries enough information for the adapter to
/// filter, clamp, and integrate into `PlatterPositionSample` values.
///
/// **Batch 2:** Prototype only. Used by `TimecodePlatterAdapter`.
public struct TimecodeMotionSample: Equatable, Sendable {

    /// Host-clock timestamp, if available.
    public let hostTime: UInt64?

    /// Seconds since the start of the decode session.
    public let relativeTime: TimeInterval

    /// Position delta for this sample relative to the previous sample.
    /// Positive = forward, negative = backward.
    public let deltaPosition: Double

    /// Estimated velocity in position-units per second.
    public let velocity: Double

    /// Decoded direction.
    public let direction: TimecodeDirection

    /// Confidence in [0, 1].
    public let confidence: Double

    /// Label identifying the source of this motion sample
    /// (e.g. `"timecode_fixture"`, `"timecode_live"`).
    public let sourceLabel: String

    // MARK: - Init

    public init(
        hostTime: UInt64?,
        relativeTime: TimeInterval,
        deltaPosition: Double,
        velocity: Double,
        direction: TimecodeDirection,
        confidence: Double,
        sourceLabel: String
    ) {
        self.hostTime = hostTime
        self.relativeTime = relativeTime
        self.deltaPosition = deltaPosition
        self.velocity = velocity
        self.direction = direction
        self.confidence = confidence
        self.sourceLabel = sourceLabel
    }
}
