// ScratchAnalysisNotationComparison — pure, UI-free, diagnostic comparison between the C++
// notation intent (`ScratchNotationIntent`) and the app's existing renderer-neutral notation
// shape (`[LaneStroke]`).
//
// This is a COMPARISON / CAPABILITY report, not a renderer and not a converter. A direct
// lossless mapping is impossible: `LaneStroke` has no travelPercent field, and its
// `faderState` (open/closed) cannot represent an `.unknown` audible state. Rather than force a
// lossy conversion, the report names what could not be compared in `unsupportedFields` and
// only emits mismatches for axes that are genuinely representable on both sides.
//
// Pure value transformation, deterministic, Foundation-only. No SwiftUI, no geometry/rails, no
// rendering, no clock, no I/O. No reference to ScratchPlaybackLabEngine / ScratchPlaybackLabModel.

import Foundation

/// A field of `ScratchNotationIntent` that the `LaneStroke` reference shape cannot represent,
/// so it was reported rather than compared.
enum ScratchNotationUnsupportedField: Equatable, Sendable {
    /// `LaneStroke` has no travel field at all — travelPercent is never comparable.
    case travelPercent
    /// An intent stroke was `.unknown`; `LaneStroke.faderState` is open/closed only, so the
    /// audible axis for that stroke is not comparable (we do not guess open or closed).
    case audibleStateUnknown
}

/// One per-axis disagreement at a given stroke index.
struct ScratchNotationStrokeMismatch: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case direction
        case timing
        case audible
        case count
    }

    let index: Int
    let kind: Kind
}

/// Diagnostic comparison of a `ScratchNotationIntent` against a `[LaneStroke]` reference.
struct ScratchNotationComparisonReport: Equatable, Sendable {
    let intentStrokeCount: Int
    let referenceStrokeCount: Int
    let directionMismatches: [ScratchNotationStrokeMismatch]
    let timingMismatches: [ScratchNotationStrokeMismatch]
    let audibleMismatches: [ScratchNotationStrokeMismatch]
    /// Empty when the counts match; otherwise exactly one `.count` mismatch at the boundary
    /// index `min(intentStrokeCount, referenceStrokeCount)`.
    let countMismatches: [ScratchNotationStrokeMismatch]
    let unsupportedFields: [ScratchNotationUnsupportedField]
    let warnings: [ScratchAnalysisWarning]
}

enum ScratchAnalysisNotationComparison {

    /// Compare an intent against a reference stroke list. Direction and timing are compared on
    /// the overlapping prefix; audible is compared only where representable; travelPercent is
    /// always reported unsupported; a stroke-count difference is surfaced both via the count
    /// fields and as a single `.count` mismatch at the first non-overlapping index.
    static func compare(
        intent: ScratchNotationIntent,
        reference: [LaneStroke],
        timingToleranceSeconds: Double
    ) -> ScratchNotationComparisonReport {
        let intentStrokes = intent.strokes
        let overlap = min(intentStrokes.count, reference.count)

        var directionMismatches: [ScratchNotationStrokeMismatch] = []
        var timingMismatches: [ScratchNotationStrokeMismatch] = []
        var audibleMismatches: [ScratchNotationStrokeMismatch] = []
        var sawUnknownAudible = false

        for i in 0..<overlap {
            let stroke = intentStrokes[i]
            let ref = reference[i]

            // Direction: forward == forward, reverse == backward.
            if expectedReferenceDirection(stroke.direction) != ref.direction {
                directionMismatches.append(.init(index: i, kind: .direction))
            }

            // Timing: both endpoints must be within tolerance.
            if abs(stroke.startTime - ref.startTime) > timingToleranceSeconds
                || abs(stroke.endTime - ref.endTime) > timingToleranceSeconds {
                timingMismatches.append(.init(index: i, kind: .timing))
            }

            // Audible: only where representable. `.unknown` is not comparable.
            switch stroke.audibleState {
            case .unknown:
                sawUnknownAudible = true
            case .audible:
                if ref.faderState != .open {
                    audibleMismatches.append(.init(index: i, kind: .audible))
                }
            case .cut:
                if ref.faderState != .closed {
                    audibleMismatches.append(.init(index: i, kind: .audible))
                }
            }
        }

        // A stroke-count difference is surfaced both via the `intentStrokeCount` /
        // `referenceStrokeCount` fields AND as exactly one `.count` mismatch at the boundary
        // index `overlap = min(intentCount, referenceCount)`. The per-axis arrays stay
        // axis-pure and only cover the overlapping prefix — we never fabricate
        // direction/timing/audible verdicts for indices that exist on only one side.
        let countMismatches: [ScratchNotationStrokeMismatch] =
            intentStrokes.count == reference.count
                ? []
                : [ScratchNotationStrokeMismatch(index: overlap, kind: .count)]

        // travelPercent is never representable in LaneStroke; report it always.
        // audibleStateUnknown only when at least one intent stroke was .unknown.
        var unsupported: [ScratchNotationUnsupportedField] = [.travelPercent]
        if sawUnknownAudible { unsupported.append(.audibleStateUnknown) }

        return ScratchNotationComparisonReport(
            intentStrokeCount: intentStrokes.count,
            referenceStrokeCount: reference.count,
            directionMismatches: directionMismatches,
            timingMismatches: timingMismatches,
            audibleMismatches: audibleMismatches,
            countMismatches: countMismatches,
            unsupportedFields: unsupported,
            warnings: intent.warnings
        )
    }

    // MARK: - Helpers

    private static func expectedReferenceDirection(
        _ direction: ScratchStrokeDirection
    ) -> ScratchNotationDirection {
        switch direction {
        case .forward: return .forward
        case .reverse: return .backward
        }
    }
}
