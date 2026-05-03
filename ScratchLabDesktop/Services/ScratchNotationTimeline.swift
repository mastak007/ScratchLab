import Foundation
import QuartzCore

// MARK: - Playback state

struct ScratchNotationPlaybackState: Equatable {
    var loopTime: TimeInterval
    var loopIndex: Int
    var currentStrokeIndex: Int?        // nil = in a gap/hold between strokes
    var currentTargetDirection: ScratchNotationDirection?
    var progressThroughStroke: Double   // 0…1 within the current stroke
    var isAtStrokeBoundary: Bool        // true on the tick that first crosses startTime
}

// MARK: - Timeline model

/// Pure Swift, no Vision or UI dependencies.
/// Wraps a `ScratchNotation` and provides stroke-boundary detection,
/// loop-time tracking, and duplicate-event suppression.
final class ScratchNotationTimeline {

    let notation: ScratchNotation

    /// Returns the loop duration derived from the notation phrase.
    var loopDuration: TimeInterval { notation.phraseEnd ?? notation.timelineDuration }

    // MARK: - State

    private(set) var loopTime: TimeInterval = 0
    private(set) var loopIndex: Int = 0
    private(set) var lastFiredStrokeIndices: Set<Int> = []

    // MARK: - Init

    init(notation: ScratchNotation) {
        self.notation = notation
    }

    // MARK: - Advance

    /// Advance the timeline to `newLoopTime` (already modulo `loopDuration`).
    /// Returns a playback state describing what happened at `newLoopTime`.
    /// Call this once per render tick with the current playback clock value.
    @discardableResult
    func advance(to newLoopTime: TimeInterval, previousLoopTime: TimeInterval) -> ScratchNotationPlaybackState {
        let didWrap = newLoopTime < previousLoopTime
        if didWrap {
            loopIndex += 1
            lastFiredStrokeIndices = []
        }
        loopTime = newLoopTime

        var boundaryFired = false
        let (strokeIdx, direction, progress) = currentStrokeInfo(at: newLoopTime)

        if let idx = strokeIdx, !lastFiredStrokeIndices.contains(idx) {
            let stroke = notation.strokes[idx]
            let startCrossed = didWrap
                ? (stroke.startTime >= previousLoopTime || stroke.startTime <= newLoopTime)
                : (stroke.startTime >= previousLoopTime && stroke.startTime <= newLoopTime)
            if startCrossed {
                lastFiredStrokeIndices.insert(idx)
                boundaryFired = true
            }
        }

        return ScratchNotationPlaybackState(
            loopTime: newLoopTime,
            loopIndex: loopIndex,
            currentStrokeIndex: strokeIdx,
            currentTargetDirection: direction,
            progressThroughStroke: progress,
            isAtStrokeBoundary: boundaryFired
        )
    }

    /// Reset timeline to zero, clearing all fired-stroke tracking.
    func reset() {
        loopTime = 0
        loopIndex = 0
        lastFiredStrokeIndices = []
    }

    // MARK: - Stroke lookup

    /// Returns (strokeIndex, direction, progress) for `time` within the loop.
    /// Returns (nil, nil, 0) when `time` falls in a gap between strokes.
    func currentStrokeInfo(at time: TimeInterval) -> (Int?, ScratchNotationDirection?, Double) {
        for (i, stroke) in notation.strokes.enumerated() {
            guard time >= stroke.startTime, time <= stroke.endTime else { continue }
            let progress = stroke.duration > 0
                ? (time - stroke.startTime) / stroke.duration
                : 0
            return (i, stroke.direction, min(1, max(0, progress)))
        }
        return (nil, nil, 0)
    }

    /// Convenience: current target direction at `time` (nil in gaps).
    func targetDirection(at time: TimeInterval) -> ScratchNotationDirection? {
        currentStrokeInfo(at: time).1
    }
}

