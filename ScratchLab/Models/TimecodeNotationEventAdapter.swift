import Foundation

/// Pure adapter converting a finalized DVS `PlatterPositionTimeline`
/// (typically `TimecodeNotationTimelineAccumulator.finalizedTimeline()`)
/// into `CaptureCore.DetectedNotationRecordMovementEvent`s via the existing
/// `derivePrimitives(from:)` grammar — the same deterministic primitive
/// derivation captured notation already uses elsewhere, so DVS-sourced
/// notation reads with the same forward/backward/idle vocabulary as
/// camera-detected notation.
///
/// Only `.directionSegment` primitives become movement events. `.idleHold`
/// is the honest gap/no-motion representation described in
/// `TimecodeNotationTimelineAccumulator` and is intentionally not emitted
/// as a movement event. `.reversal` is not emitted as its own event either
/// — `DetectedNotationRecordMovementEvent` has no reversal-specific case,
/// and a reversal is already implied by the direction change between two
/// adjacent emitted segments.
enum TimecodeNotationEventAdapter {
    /// Provenance tag applied to every event this adapter produces —
    /// distinguishes DVS-sourced notation from camera-detected (`"detected"`)
    /// or authored (`"target_notation"`) events elsewhere in the codebase.
    static let sourceLabel = "timecode_live"

    /// Converts `timeline` into movement events via `derivePrimitives`.
    /// Deterministic: identical `timeline`/`parameters` always produce
    /// identical output.
    static func makeMovementEvents(
        from timeline: PlatterPositionTimeline,
        parameters: GrammarParameters = .standard
    ) -> [CaptureCore.DetectedNotationRecordMovementEvent] {
        derivePrimitives(from: timeline, parameters: parameters).compactMap { primitive in
            guard case .directionSegment(let segment) = primitive else { return nil }
            return CaptureCore.DetectedNotationRecordMovementEvent(
                startTime: segment.startTime,
                endTime: segment.endTime,
                startPosition: segment.startPosition,
                endPosition: segment.endPosition,
                direction: segment.direction == .forward ? "forward" : "backward",
                movementKind: .hold,
                speed: speed(for: segment),
                confidence: segment.minimumConfidence,
                source: sourceLabel
            )
        }
    }

    /// Average unsigned platter-axis speed over the segment's span.
    /// `derivePrimitives` reports magnitude only through this and the
    /// segment's own position/time span; a future slice may classify
    /// push/pull kind from it, but this slice keeps every DVS-sourced
    /// event's `movementKind` as `.hold` (unclassified), matching the
    /// existing camera-detected movement events' convention for the same
    /// "detected, not further speed-classified" case.
    private static func speed(for segment: DirectionSegment) -> Double {
        let duration = segment.endTime - segment.startTime
        guard duration > 0 else { return 0 }
        return abs(segment.endPosition - segment.startPosition) / duration
    }
}
