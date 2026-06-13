// ScratchNotationLaneDisplayModel — a UI-free travel-DISPLAY projection of
// `ScratchNotationLanePreviewModel`.
//
// It answers one question for a future notation lane: given a preserved raw `travelPercent`, how
// much visual stroke excursion should the lane use? It adds a `normalizedTravel` (0...1, display
// scaling only) computed against a caller-supplied `fullScaleTravelPercent` — there is NO default
// "rail" scale, because what travel counts as full excursion is a product decision the caller owns.
//
// The raw `travelPercent` is preserved unclamped; only `normalizedTravel` is clamped, and only for
// display. This intentionally does NOT scale stroke length by time (x stays time elsewhere) and
// does NOT bucket by speed — it is the data a travel-scaled renderer would consume instead of the
// current speed-bucket amplitude.
//
// Pure value transformation, deterministic, Foundation-only. No SwiftUI, no geometry/pixels, no
// LaneStroke / ScratchStrokeGeometry / NotationPresentation usage, no I/O, no shared-enum changes.

import Foundation

/// DEBUG stats summary of a display model's stroke distribution — read-only, lossless, no mutation.
/// Travel/duration sanity buckets use neutral measurement terms only; this is NOT scratch
/// technique classification.
struct ScratchNotationLaneDisplayStats: Equatable, Sendable {
    let totalStrokes: Int
    let railHitStrokes: Int        // normalizedTravel >= 1.0
    let maxNormalizedTravel: Double
    let maxTravelPercent: Double
    /// Strokes with zero duration — instantaneous direction reversals; undefined speed.
    let zeroDurationStrokes: Int
    /// Strokes with travelPercent < 1.0 and non-zero duration — sub-revolution movement.
    let microTravelStrokes: Int
    /// Strokes with travelPercent >= 1.0 and non-zero duration — meaningful platter movement.
    let meaningfulTravelStrokes: Int
}

/// A display-ready snapshot for a future notation lane, in stroke order. Carries the preview
/// model verbatim plus a display-only `normalizedTravel` and the scale used to compute it.
struct ScratchNotationLaneDisplayModel: Equatable, Sendable {
    let strokes: [Stroke]
    let warnings: [ScratchAnalysisWarning]
    /// The caller-supplied full-excursion scale, echoed back exactly (incl. invalid values).
    let fullScaleTravelPercent: Double
    /// True only when `fullScaleTravelPercent` is finite and > 0; otherwise no scaling is possible.
    let scaleIsUsable: Bool

    struct Stroke: Equatable, Sendable {
        let direction: ScratchStrokeDirection
        let startTime: Double
        let endTime: Double
        let travelPercent: Double        // raw, UNCLAMPED, preserved
        let normalizedTravel: Double     // display-only: travelPercent / fullScale, clamped 0...1
        let audibleState: ScratchAudibleState   // preserved, including .unknown

        var durationSeconds: Double { max(0, endTime - startTime) }

        /// Derived platter speed in travel-percent per second. nil when duration is
        /// zero (instantaneous direction reversal). DEBUG read-only; not persisted.
        var speedPercentPerSecond: Double? {
            let dur = durationSeconds
            guard dur > 0 else { return nil }
            return travelPercent / dur
        }
    }
}

/// Pure, deterministic projection of `ScratchNotationLanePreviewModel` to a display model. The
/// `fullScaleTravelPercent` is REQUIRED from the caller — no magic default.
enum ScratchNotationLaneDisplayAdapter {
    static func displayModel(
        from preview: ScratchNotationLanePreviewModel,
        fullScaleTravelPercent: Double
    ) -> ScratchNotationLaneDisplayModel {
        let usable = fullScaleTravelPercent.isFinite && fullScaleTravelPercent > 0

        let strokes = preview.strokes.map { stroke -> ScratchNotationLaneDisplayModel.Stroke in
            let normalized: Double
            if usable {
                normalized = min(1.0, max(0.0, stroke.travelPercent / fullScaleTravelPercent))
            } else {
                normalized = 0.0
            }
            return ScratchNotationLaneDisplayModel.Stroke(
                direction: stroke.direction,
                startTime: stroke.startTime,
                endTime: stroke.endTime,
                travelPercent: stroke.travelPercent,   // raw, untouched
                normalizedTravel: normalized,
                audibleState: stroke.audibleState
            )
        }

        return ScratchNotationLaneDisplayModel(
            strokes: strokes,
            warnings: preview.warnings,
            fullScaleTravelPercent: fullScaleTravelPercent,
            scaleIsUsable: usable
        )
    }
}

extension ScratchNotationLaneDisplayModel {
    /// Read-only stats summary of the stroke distribution — lossless, no mutation.
    /// Travel/duration buckets use neutral measurement terms only (NOT technique labels).
    var stats: ScratchNotationLaneDisplayStats {
        let zeroDur = strokes.filter { $0.durationSeconds == 0 }.count
        let nonZero = strokes.filter { $0.durationSeconds > 0 }
        let micro = nonZero.filter { $0.travelPercent < 1.0 }.count
        let meaningful = nonZero.filter { $0.travelPercent >= 1.0 }.count
        return ScratchNotationLaneDisplayStats(
            totalStrokes: strokes.count,
            railHitStrokes: strokes.filter { $0.normalizedTravel >= 1.0 }.count,
            maxNormalizedTravel: strokes.map(\.normalizedTravel).max() ?? 0,
            maxTravelPercent: strokes.map(\.travelPercent).max() ?? 0,
            zeroDurationStrokes: zeroDur,
            microTravelStrokes: micro,
            meaningfulTravelStrokes: meaningful
        )
    }
}
