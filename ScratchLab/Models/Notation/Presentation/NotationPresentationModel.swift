import Foundation

// MARK: - NotationPresentationStroke

/// A renderer-ready snapshot of a single `NotationPrimitive` plus the
/// sidecar metadata that has been attached to it.
///
/// **Pure value type.** A presentation stroke carries no view, no
/// geometry, no drawing intent — it's the flat data that a future
/// renderer can consume without reaching back into the grammar /
/// timing / semantic / coaching layers.
///
/// - `primitiveIndex` identifies the source primitive in the input
///   `[NotationPrimitive]` array.
/// - `startTime` / `endTime` are taken straight off the primitive
///   (point primitives like `Reversal` carry equal start/end).
/// - `startPosition` / `endPosition` are the `GridAnnotation.start` /
///   `.end` projected for this `primitiveIndex`. Both are `nil` when no
///   annotation exists.
/// - `family` is the `ScratchFamily` of the first
///   `ScratchFamilyAttachment` whose `primitiveRange` contains this
///   index. `nil` when no family annotation set was supplied or no
///   range contains the index.
/// - `coachingKinds` is the ordered list of
///   `CoachingEventKind`s whose corresponding events fall inside the
///   stroke's time range. Non-zero-duration strokes use a `[startTime,
///   endTime)` half-open range; zero-duration strokes include events
///   at exactly `startTime`. Order is the event order from the input
///   `CoachingEventSet`, which is itself sorted ascending by time.
struct NotationPresentationStroke: Equatable, Sendable, Codable {
    let primitiveIndex: Int
    let startTime: TimeInterval
    let endTime: TimeInterval
    let startPosition: GridPosition?
    let endPosition: GridPosition?
    let family: ScratchFamily?
    let coachingKinds: [CoachingEventKind]
}

// MARK: - NotationPresentationModel

/// A presentation snapshot of an entire take, in primitive order.
///
/// The model is the join of `[NotationPrimitive]` plus any
/// combination of `[GridAnnotation]`, `ScratchFamilyAnnotationSet`,
/// and `CoachingEventSet`. Missing sidecars are allowed — strokes
/// keep their corresponding fields `nil` / empty.
struct NotationPresentationModel: Equatable, Sendable, Codable {
    let strokes: [NotationPresentationStroke]
}

// MARK: - NotationPresentationMapper

/// Pure, deterministic projection of `(primitives, annotations,
/// familyAnnotations, coachingEvents)` to a
/// `NotationPresentationModel`.
///
/// **What the mapper does (and only this):**
///
/// - Emits one `NotationPresentationStroke` per input primitive, in
///   input order.
/// - Resolves `startTime` / `endTime` directly from the primitive.
/// - Resolves `startPosition` / `endPosition` from the first
///   `GridAnnotation` whose `primitiveIndex` matches.
/// - Resolves `family` from
///   `familyAnnotations?.attachment(containing: index)?.label.family`.
/// - Resolves `coachingKinds` from `coachingEvents?.events`, filtered
///   by `[startTime, endTime)` for non-zero-duration strokes, and by
///   the single point `[startTime, startTime]` for zero-duration
///   strokes.
///
/// **What the mapper does not do:** no UI / Canvas / renderer call,
/// no ML, no scoring, no clock, no I/O, no mutation of inputs. Inputs
/// are read-only throughout.
enum NotationPresentationMapper {

    static func makeModel(
        primitives: [NotationPrimitive],
        annotations: [GridAnnotation],
        familyAnnotations: ScratchFamilyAnnotationSet?,
        coachingEvents: CoachingEventSet?
    ) -> NotationPresentationModel {
        // First-wins lookup so duplicate annotations on the same
        // primitiveIndex don't change the output non-deterministically.
        var annotationByIndex: [Int: GridAnnotation] = [:]
        annotationByIndex.reserveCapacity(annotations.count)
        for annotation in annotations {
            if annotationByIndex[annotation.primitiveIndex] == nil {
                annotationByIndex[annotation.primitiveIndex] = annotation
            }
        }

        var strokes: [NotationPresentationStroke] = []
        strokes.reserveCapacity(primitives.count)
        for (index, primitive) in primitives.enumerated() {
            let (startTime, endTime) = timeSpan(of: primitive)
            let annotation = annotationByIndex[index]
            let family = familyAnnotations?
                .attachment(containing: index)?
                .label
                .family
            let coachingKinds = coachingKinds(
                in: startTime ... endTime,
                isPoint: startTime == endTime,
                from: coachingEvents
            )
            strokes.append(
                NotationPresentationStroke(
                    primitiveIndex: index,
                    startTime: startTime,
                    endTime: endTime,
                    startPosition: annotation?.start,
                    endPosition: annotation?.end,
                    family: family,
                    coachingKinds: coachingKinds
                )
            )
        }
        return NotationPresentationModel(strokes: strokes)
    }

    // MARK: Helpers

    private static func timeSpan(of primitive: NotationPrimitive) -> (TimeInterval, TimeInterval) {
        switch primitive {
        case .directionSegment(let segment):
            return (segment.startTime, segment.endTime)
        case .reversal(let reversal):
            return (reversal.time, reversal.time)
        case .idleHold(let hold):
            return (hold.startTime, hold.endTime)
        }
    }

    private static func coachingKinds(
        in range: ClosedRange<TimeInterval>,
        isPoint: Bool,
        from coachingEvents: CoachingEventSet?
    ) -> [CoachingEventKind] {
        guard let events = coachingEvents?.events, !events.isEmpty else {
            return []
        }
        let start = range.lowerBound
        let end = range.upperBound
        var output: [CoachingEventKind] = []
        for event in events {
            let included: Bool
            if isPoint {
                included = event.time == start
            } else {
                included = event.time >= start && event.time < end
            }
            if included {
                output.append(event.kind)
            }
        }
        return output
    }
}
