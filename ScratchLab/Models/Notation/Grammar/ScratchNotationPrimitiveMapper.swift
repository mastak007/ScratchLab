//  ScratchNotationPrimitiveMapper.swift
//  ScratchLab — pure authored-notation → motion-primitive adapter.
//
//  Maps `ScratchNotation.Stroke` entries to `[NotationPrimitive]` so
//  that authored target notation and captured motion primitives can
//  flow through the same downstream layers (grid annotation, timing
//  evaluation, coaching events) from a single root type.
//
//  This is the model-only seed: it does **not** wire into any live
//  session, coaching surface, or UI. Callers that need the full
//  primitive-annotation-timing-coaching chain must supply their own
//  grid, phrases, and pacing — those layers remain out of scope here.

import Foundation

// MARK: - ScratchNotationPrimitiveMapper

/// Pure, deterministic projection of authored `ScratchNotation.Stroke`
/// entries to motion primitives.
///
/// **What it does:**
///
/// - Each stroke → one `.directionSegment` with the stroke's direction,
///   start/end times, parametric positions matching the forward 0→1 /
///   backward 1→0 progress convention, and `minimumConfidence: 1.0`
///   (sentinel for "authored target notation, not captured").
/// - Consecutive opposite-direction strokes → one `.reversal` at the
///   boundary time, kind `.cusp` (direct flip, no idle gap), at the
///   turnaround extreme.
/// - Consecutive same-direction strokes → **no** reversal.
/// - No `.idleHold` primitives — authored notation does not specify
///   idle holds, and synthesising them from inter-stroke gaps would
///   be inference the data does not support.
///
/// **What it does not do:**
///
/// - No clock, no I/O, no randomness, no ML.
/// - No coaching events, no phrase boundaries, no scoring.
/// - No grid annotation — the caller receives raw primitives.
/// - No UI coupling.
///
/// **Determinism:** same `[ScratchNotation.Stroke]` input → byte-
/// identical `[NotationPrimitive]` output across calls.
enum ScratchNotationPrimitiveMapper {

    /// Derives motion primitives from authored notation strokes.
    /// Strokes are processed in input order.
    ///
    /// - Parameter strokes: the strokes from a `ScratchNotation`
    ///   (typically `notation.strokes`).
    /// - Returns: a `[NotationPrimitive]` with one `.directionSegment`
    ///   per stroke, plus one `.reversal` between each pair of
    ///   consecutive opposite-direction strokes.
    static func derivePrimitives(
        from strokes: [ScratchNotation.Stroke]
    ) -> [NotationPrimitive] {
        guard !strokes.isEmpty else { return [] }

        var output: [NotationPrimitive] = []
        output.reserveCapacity(strokes.count * 2) // upper bound: every pair reversed

        for (index, stroke) in strokes.enumerated() {
            let segment = DirectionSegment(
                direction: mapDirection(stroke.direction),
                startTime: stroke.startTime,
                endTime: stroke.endTime,
                startPosition: startPosition(for: stroke.direction),
                endPosition: endPosition(for: stroke.direction),
                minimumConfidence: Confidence.authored
            )
            output.append(.directionSegment(segment))

            // Reversal between this stroke and the next, only when
            // directions differ.
            let next = nextIndex(in: strokes, after: index)
            guard let next else { continue }
            guard strokes[index].direction != strokes[next].direction else { continue }

            let reversal = Reversal(
                kind: .cusp,
                time: stroke.endTime,
                position: turnaroundPosition(
                    closing: strokes[index].direction,
                    opening: strokes[next].direction
                ),
                minimumConfidence: Confidence.authored
            )
            output.append(.reversal(reversal))
        }

        return output
    }

    // MARK: - Helpers

    private static func nextIndex(
        in strokes: [ScratchNotation.Stroke],
        after index: Int
    ) -> Int? {
        let candidate = index + 1
        return candidate < strokes.count ? candidate : nil
    }

    /// Maps `ScratchNotationDirection` to the motion-level `Direction`.
    /// `.backward` is the authored notation's label for reverse motion;
    /// the motion primitive vocabulary uses `.reverse` for the same.
    private static func mapDirection(
        _ direction: ScratchNotationDirection
    ) -> Direction {
        switch direction {
        case .forward:  return .forward
        case .backward: return .reverse
        }
    }

    /// Parametric start position for a stroke of the given direction.
    /// Forward strokes sweep 0 → 1; backward strokes sweep 1 → 0.
    private static func startPosition(
        for direction: ScratchNotationDirection
    ) -> Double {
        switch direction {
        case .forward:  return 0
        case .backward: return 1
        }
    }

    /// Parametric end position for a stroke of the given direction.
    private static func endPosition(
        for direction: ScratchNotationDirection
    ) -> Double {
        switch direction {
        case .forward:  return 1
        case .backward: return 0
        }
    }

    /// Position at which the reversal between a closing stroke and an
    /// opening stroke sits. Forward→reverse reverses at the high extreme
    /// (1.0); reverse→forward reverses at the low extreme (0.0).
    private static func turnaroundPosition(
        closing: ScratchNotationDirection,
        opening: ScratchNotationDirection
    ) -> Double {
        switch (closing, opening) {
        case (.forward, .backward): return 1.0
        case (.backward, .forward): return 0.0
        // Same-direction pairs are filtered before this call, but
        // if one reaches here the sentinel is 1.0 so it never lies
        // about being at an extreme.
        default:                    return 1.0
        }
    }
}

// MARK: - Confidence sentinel

/// Authored target notation primitives carry this confidence value
/// to distinguish them from captured primitives (which carry the
/// minimum confidence of their contributing platter-position samples).
private enum Confidence {
    static let authored: Double = 1.0
}
