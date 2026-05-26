import Foundation

// MARK: - SessionReplayPresentationAdapter

/// Pure, deterministic projection of a `SessionReplayTimeline` to a
/// `NotationPresentationModel`.
///
/// `SessionReplayTimeline` is the in-memory deterministic event
/// stream built from a `DetectedNotationSnapshot` (audio onsets,
/// record movements, fader, mixer MIDI), already pre-sorted by
/// `(startTime, lane priority, sourceIndex)`. This adapter is the
/// additive, read-only bridge that lets a renderer-side consumer feed
/// the same stream into `NotationLaneGeometryMapper` without
/// re-deriving from the source snapshot.
///
/// **What the adapter does (and only this):**
///
/// - Emits one `NotationPresentationStroke` per `SessionReplayEvent`,
///   in `timeline.events` order.
/// - Sets `primitiveIndex` to the event's position in
///   `timeline.events` (`0 ..< timeline.events.count`). This is the
///   stable per-timeline identity for the renderer — not the lane
///   `sourceIndex`, which is a within-lane tie-breaker on the source
///   side.
/// - Copies `startTime` directly from the event.
/// - Sets `endTime` to `event.endTime ?? event.startTime`. Mixer MIDI
///   and other point-in-time lanes carry `endTime == nil`; they map
///   to a zero-duration stroke at `startTime`.
/// - Leaves `startPosition`, `endPosition`, and `family` as `nil` —
///   `SessionReplayTimeline` carries no `GridAnnotation` or
///   `ScratchFamilyAnnotationSet` sidecar.
/// - Leaves `coachingKinds` as `[]` — `SessionReplayTimeline` carries
///   no `CoachingEventSet` sidecar.
///
/// **What the adapter does not do:** no UI / Canvas / renderer call,
/// no ML, no scoring, no clock, no I/O, no export-schema touch, no
/// re-derivation from the source `DetectedNotationSnapshot`, no
/// mutation of inputs. Inputs are read-only throughout.
enum SessionReplayPresentationAdapter {

    static func makeModel(from timeline: SessionReplayTimeline) -> NotationPresentationModel {
        var strokes: [NotationPresentationStroke] = []
        strokes.reserveCapacity(timeline.events.count)
        for (index, event) in timeline.events.enumerated() {
            strokes.append(
                NotationPresentationStroke(
                    primitiveIndex: index,
                    startTime: event.startTime,
                    endTime: event.endTime ?? event.startTime,
                    startPosition: nil,
                    endPosition: nil,
                    family: nil,
                    coachingKinds: []
                )
            )
        }
        return NotationPresentationModel(strokes: strokes)
    }
}
