import Foundation
import CoreGraphics

/// One raw feature observation in time. Coordinates use normalized image
/// space with a top-left origin (x →, y ↓). Vision can return points outside
/// `[0, 1]`; raw observations preserve those values. Only the legacy model's
/// shared window preprocessing clamps them, with quality warnings at runtime.
///
/// Fields are intentionally optional so a single struct can represent
/// partial observations (Vision may detect a hand but not the record edge,
/// or vice versa). New optional fields may be appended over time; existing
/// call sites are not broken because every new field is defaulted.
public struct ScratchMotionFrame: Sendable, Equatable, Codable {
    public let timestamp: TimeInterval
    public let dominantHand: CGPoint?
    public let recordEdgeAngle: Double?
    public let crossfaderPosition: Double?

    // Vision landmarks in normalized top-left image space. Off-image values
    // remain raw; dominant/secondary are confidence-ranked slots per frame,
    // not persistent hand identity or the performer's handedness.
    public let dominantHandWrist: CGPoint?
    public let dominantHandIndexTip: CGPoint?
    public let dominantHandThumbTip: CGPoint?
    public let dominantHandMiddleTip: CGPoint?
    public let dominantHandConfidence: Float?
    public let secondaryHandWrist: CGPoint?
    public let recordCenter: CGPoint?

    public init(
        timestamp: TimeInterval,
        dominantHand: CGPoint? = nil,
        recordEdgeAngle: Double? = nil,
        crossfaderPosition: Double? = nil,
        dominantHandWrist: CGPoint? = nil,
        dominantHandIndexTip: CGPoint? = nil,
        dominantHandThumbTip: CGPoint? = nil,
        dominantHandMiddleTip: CGPoint? = nil,
        dominantHandConfidence: Float? = nil,
        secondaryHandWrist: CGPoint? = nil,
        recordCenter: CGPoint? = nil
    ) {
        self.timestamp = timestamp
        self.dominantHand = dominantHand
        self.recordEdgeAngle = recordEdgeAngle
        self.crossfaderPosition = crossfaderPosition
        self.dominantHandWrist = dominantHandWrist
        self.dominantHandIndexTip = dominantHandIndexTip
        self.dominantHandThumbTip = dominantHandThumbTip
        self.dominantHandMiddleTip = dominantHandMiddleTip
        self.dominantHandConfidence = dominantHandConfidence
        self.secondaryHandWrist = secondaryHandWrist
        self.recordCenter = recordCenter
    }
}
