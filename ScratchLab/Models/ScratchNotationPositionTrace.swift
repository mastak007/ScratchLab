//  ScratchNotationPositionTrace.swift
//  ScratchLab — derived continuous-position trace for notation surfaces.
//
//  Pure, deterministic helper that turns a list of direction-encoded
//  stroke segments (forward / backward + duration) into a continuous
//  cursor trace in `[0, 1]`. The cursor carries forward across
//  direction reversals — a backward stroke does not reset to the
//  baseline, it just moves the cursor down from wherever it currently
//  sits. The amount moved is proportional to segment duration, clamped
//  to the unit interval.
//
//  Use this when the source notation data carries only direction +
//  duration (no real platter / sample position). Renderers that
//  consume real positions should pass them through directly rather
//  than running this derivation.

import Foundation

// MARK: - ScratchNotationPositionTraceSegment

/// One renderable stroke on a continuous-position trace. `startPosition`
/// and `endPosition` are both in `[0, 1]`. `direction` is the same
/// direction the source segment carried — preserved so callers can
/// colour-code or accent slope direction independently of cursor
/// arithmetic.
struct ScratchNotationPositionTraceSegment: Equatable, Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let startPosition: Double
    let endPosition: Double
    let direction: ScratchMotionDirection
}

// MARK: - ScratchNotationPositionTrace

/// Pure mapper from a list of stroke segments to a continuous-position
/// trace. Same input → byte-identical output across calls. No clock,
/// no I/O, no UI, no fake position data — when real position is
/// unavailable the cursor is derived purely from duration + direction,
/// and the helper documents that derivation explicitly so callers can
/// reason about it.
enum ScratchNotationPositionTrace {

    /// Starting cursor value used by `derive(...)`. Mid-lane so a
    /// single forward or backward stroke produces a visible move
    /// without slamming against the clamp boundary on the very first
    /// segment.
    static let initialPosition: Double = 0.5

    /// Cursor change per second of stroke duration. Calibrated so a
    /// typical Baby Scratch stroke (~0.18 s) moves the cursor by ~0.18
    /// — visible but small, leaving the cursor near the middle for
    /// repeated short strokes. Long strokes still cover more ground;
    /// the clamp keeps the cursor honest at the boundaries.
    static let movementRatePerSecond: Double = 1.0

    /// Builds the derived trace. Skips segments with `.neutral`
    /// direction (explicit holds) so the cursor only moves on real
    /// strokes. Non-finite durations collapse to zero movement so a
    /// bad input never produces NaN / Infinity.
    static func derive(
        from segments: [ScratchLabBabyScratchStrokeSegment],
        initialPosition: Double = ScratchNotationPositionTrace.initialPosition,
        movementRatePerSecond: Double = ScratchNotationPositionTrace.movementRatePerSecond
    ) -> [ScratchNotationPositionTraceSegment] {
        let safeInitial = clamp(initialPosition)
        let safeRate = movementRatePerSecond.isFinite
            ? max(0, movementRatePerSecond)
            : 0
        let sorted = segments.sorted { $0.startTime < $1.startTime }
        var cursor = safeInitial
        var trace: [ScratchNotationPositionTraceSegment] = []
        trace.reserveCapacity(sorted.count)
        for segment in sorted {
            guard segment.direction != .neutral else { continue }
            let duration = segment.duration
            let safeDuration: Double
            if duration.isFinite, duration > 0 {
                safeDuration = duration
            } else {
                safeDuration = 0
            }
            let delta = safeDuration * safeRate
            let nextCursor: Double
            switch segment.direction {
            case .forward:
                nextCursor = clamp(cursor + delta)
            case .backward:
                nextCursor = clamp(cursor - delta)
            case .neutral:
                nextCursor = cursor
            }
            trace.append(
                ScratchNotationPositionTraceSegment(
                    startTime: segment.startTime,
                    endTime: segment.endTime,
                    startPosition: cursor,
                    endPosition: nextCursor,
                    direction: segment.direction
                )
            )
            cursor = nextCursor
        }
        return trace
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}
