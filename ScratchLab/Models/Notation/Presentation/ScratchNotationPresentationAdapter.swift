import Foundation

// MARK: - ScratchNotationPresentationAdapter

/// Pure, deterministic projection of a `ScratchNotation` reference
/// notation to a `NotationPresentationModel`.
///
/// `ScratchNotation` is the JSON-backed reference notation loaded from
/// the bundled `baby_scratch.json` (and its detected-preview siblings).
/// `NotationPresentationModel` is the renderer-ready snapshot consumed
/// by `NotationLaneGeometryMapper`. This adapter is the additive,
/// read-only bridge between the two — it does not own, mutate, or
/// observe either side.
///
/// **What the adapter does (and only this):**
///
/// - Emits one `NotationPresentationStroke` per `ScratchNotation.Stroke`,
///   in source order.
/// - Sets `primitiveIndex` to the stroke's position in
///   `notation.strokes` (`0 ..< notation.strokes.count`).
/// - Copies `startTime` / `endTime` directly from the stroke.
/// - Leaves `startPosition`, `endPosition`, and `family` as `nil` —
///   `ScratchNotation` carries no `GridAnnotation` or
///   `ScratchFamilyAnnotationSet` sidecar.
/// - Leaves `coachingKinds` as `[]` — `ScratchNotation` carries no
///   `CoachingEventSet` sidecar.
///
/// **What the adapter does not do:** no UI / Canvas / renderer call,
/// no ML, no scoring, no clock, no I/O, no export-schema touch, no
/// mutation of inputs. Inputs are read-only throughout.
enum ScratchNotationPresentationAdapter {

    static func makeModel(from notation: ScratchNotation) -> NotationPresentationModel {
        var strokes: [NotationPresentationStroke] = []
        strokes.reserveCapacity(notation.strokes.count)
        for (index, stroke) in notation.strokes.enumerated() {
            strokes.append(
                NotationPresentationStroke(
                    primitiveIndex: index,
                    startTime: stroke.startTime,
                    endTime: stroke.endTime,
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
