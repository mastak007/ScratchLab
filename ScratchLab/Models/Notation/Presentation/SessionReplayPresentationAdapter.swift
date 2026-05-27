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
/// - Populates `coachingKinds` with drift coaching events whose time
///   falls inside a stroke's `[startTime, endTime]` window when
///   `FeatureFlags.coachingEventsPipelineEnabled` is on AND a caller
///   passes `coachingEvents`. Only `.lateReversal` and `.earlyReversal`
///   propagate — phrase coaching events stay dry until Phase B2 ships
///   phrase visibility (Phase C2's hard prerequisite). When the flag
///   is off OR the caller passes no events, `coachingKinds` stays `[]`
///   exactly as before.
///
/// **What the adapter does not do:** no UI / Canvas / renderer call,
/// no ML, no scoring, no clock, no I/O, no export-schema touch, no
/// re-derivation from the source `DetectedNotationSnapshot`, no
/// mutation of inputs. Inputs are read-only throughout.
enum SessionReplayPresentationAdapter {

    static func makeModel(
        from timeline: SessionReplayTimeline,
        coachingEvents: [CoachingEvent] = []
    ) -> NotationPresentationModel {
        let attachedKinds: [[CoachingEventKind]] = FeatureFlags.coachingEventsPipelineEnabled
            ? attachDriftKinds(coachingEvents, to: timeline.events)
            : Array(repeating: [], count: timeline.events.count)
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
                    coachingKinds: attachedKinds[index]
                )
            )
        }
        return NotationPresentationModel(strokes: strokes)
    }

    /// Pure helper: maps a `[CoachingEvent]` list onto a parallel
    /// `[[CoachingEventKind]]` aligned with `strokes`. Drift events only
    /// — phrase / unstable-timing / clipped-motion kinds are silently
    /// dropped so the surface never surfaces coaching states that the
    /// user cannot visually verify yet. Exposed `internal` (not
    /// `private`) so the DEBUG-only test target can lock the mapping.
    static func attachDriftKinds(
        _ events: [CoachingEvent],
        to strokes: [SessionReplayEvent]
    ) -> [[CoachingEventKind]] {
        var result: [[CoachingEventKind]] = Array(repeating: [], count: strokes.count)
        guard !strokes.isEmpty else { return result }
        for event in events {
            guard event.kind == .lateReversal || event.kind == .earlyReversal else { continue }
            guard event.time.isFinite else { continue }
            if let index = Self.strokeIndex(for: event.time, in: strokes) {
                result[index].append(event.kind)
            }
        }
        return result
    }

    private static func strokeIndex(
        for time: TimeInterval,
        in strokes: [SessionReplayEvent]
    ) -> Int? {
        for (index, event) in strokes.enumerated() {
            let start = event.startTime
            let end = event.endTime ?? event.startTime
            let lo = min(start, end)
            let hi = max(start, end)
            if time >= lo && time <= hi {
                return index
            }
        }
        return nil
    }
}
