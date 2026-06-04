// ScratchNotationLanePreviewModel — a UI-free, LOSSLESS re-projection of `ScratchNotationIntent`
// into a lane-preview shape, staged for a future notation lane WITHOUT fabricating or dropping data.
//
// This is deliberately NOT the existing renderer lane:
// - `LaneStroke` requires a `speed` classification that the intent does not have (it carries
//   `travelPercent`, which is platter distance, not speed) — producing one would fabricate speed.
// - `LaneStroke.faderState` is open/closed only and cannot represent `.unknown`.
// - the existing geometry path draws stroke length as elapsed TIME and has no travelPercent field.
// - the existing lane has nowhere to carry analysis warnings.
//
// So this model preserves direction, start/end time, travelPercent (unclamped), audibleState
// (including `.unknown`), and warnings exactly — leaving the time-vs-travel / speed / fader-display
// decisions to a later, explicit slice. Pure value transformation, deterministic, Foundation-only.
// No SwiftUI, no geometry/rails, no pixel coordinates, no LaneStroke / NotationPresentation usage,
// no I/O.

import Foundation

/// A lane-preview snapshot of a whole take, in stroke order. Carries the notation intent verbatim
/// plus only honestly-derived conveniences.
struct ScratchNotationLanePreviewModel: Equatable, Sendable {
    let strokes: [Stroke]
    let warnings: [ScratchAnalysisWarning]

    struct Stroke: Equatable, Sendable {
        let direction: ScratchStrokeDirection
        let startTime: Double
        let endTime: Double
        let travelPercent: Double          // preserved, UNCLAMPED
        let audibleState: ScratchAudibleState   // preserved, including .unknown

        /// Elapsed time of the stroke, derived only (never stored). Guards against
        /// out-of-order endpoints by flooring at 0.
        var durationSeconds: Double { max(0, endTime - startTime) }
    }
}

/// Pure, deterministic projection of `ScratchNotationIntent` to `ScratchNotationLanePreviewModel`.
/// Lossless: every stroke field and every warning is copied verbatim, in order.
enum ScratchNotationLanePreviewAdapter {
    static func preview(from intent: ScratchNotationIntent) -> ScratchNotationLanePreviewModel {
        let strokes = intent.strokes.map { stroke in
            ScratchNotationLanePreviewModel.Stroke(
                direction: stroke.direction,
                startTime: stroke.startTime,
                endTime: stroke.endTime,
                travelPercent: stroke.travelPercent,
                audibleState: stroke.audibleState
            )
        }
        return ScratchNotationLanePreviewModel(strokes: strokes, warnings: intent.warnings)
    }
}
