// ScratchAnalysisNotationAdapter — pure, UI-free projection of the C++ analysis output into a
// stable notation-intent model that existing notation/rendering code can consume later.
//
// This is the first hand-off OUT of the offline C++ analysis island (ScratchAnalysisOutput) into
// an app-facing value type. It is a LOSSLESS, 1:1 mirror of the analysis strokes — no geometry,
// no rails, no rendering, no clock, no I/O, no ML, no scoring. It does not reach into the
// grammar / presentation / coaching pipeline.
//
// Deliberately narrow (Slice 7):
// - Reuses the existing enums from ScratchAnalysis.swift (ScratchStrokeDirection,
//   ScratchAudibleState, ScratchAnalysisWarning) — no duplicate enums.
// - travelPercent is passed through UNCLAMPED (the C++ core never caps it; UI may cap later).
// - .unknown audibility stays .unknown — never promoted to audible.
// - No Codable in this slice (adding it would force the shared enums to adopt Codable).
// - No pitch bend, no audio position, no playback fields — none of those exist in the input.

import Foundation

/// A renderer-agnostic notation-intent snapshot of a whole take, in stroke order.
///
/// **Pure value type.** Carries the notation *intent* (what was played, audibly or not) without
/// any drawing geometry. A future renderer/adapter can consume this without depending on the
/// analysis bridge, the C++ core, or any audio/MIDI layer.
struct ScratchNotationIntent: Equatable, Sendable {
    let strokes: [ScratchNotationIntentStroke]
    let warnings: [ScratchAnalysisWarning]
}

/// One notation-intent stroke. A faithful mirror of `ScratchAnalyzedStroke` decoupled from the
/// analysis-bridge naming.
struct ScratchNotationIntentStroke: Equatable, Sendable {
    /// Platter rotation direction for the stroke.
    let direction: ScratchStrokeDirection
    /// Stroke start time, in the analysis input's time base (seconds), passed through verbatim.
    let startTime: Double
    /// Stroke end time, same time base as `startTime`, passed through verbatim.
    let endTime: Double
    /// Travel as a percentage of one platter revolution. Passed through UNCLAMPED — may exceed 100.
    let travelPercent: Double
    /// Whether the stroke was heard through the crossfader, cut, or has no telemetry to decide.
    let audibleState: ScratchAudibleState
}

/// Pure, deterministic projection of `ScratchAnalysisOutput` to `ScratchNotationIntent`.
///
/// **What it does (and only this):** emits one intent stroke per analyzed stroke, in input order,
/// copying every field verbatim, and passes warnings through in order.
enum ScratchAnalysisNotationAdapter {
    static func notationIntent(from output: ScratchAnalysisOutput) -> ScratchNotationIntent {
        let strokes = output.strokes.map { stroke in
            ScratchNotationIntentStroke(
                direction: stroke.direction,
                startTime: stroke.startTime,
                endTime: stroke.endTime,
                travelPercent: stroke.travelPercent,
                audibleState: stroke.audibleState
            )
        }
        return ScratchNotationIntent(strokes: strokes, warnings: output.warnings)
    }
}
