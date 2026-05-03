import Foundation
import QuartzCore

// MARK: - Playback state

struct ScratchNotationPlaybackState: Equatable {
    var loopTime: TimeInterval
    var loopIndex: Int
    var currentStrokeIndex: Int?
    var currentTargetDirection: ScratchNotationDirection?
    var progressThroughStroke: Double
    var isAtStrokeBoundary: Bool
}

// MARK: - Timeline model

final class ScratchNotationTimeline {

    let notation: ScratchNotation

    var loopDuration: TimeInterval {
        notation.phraseEnd ?? notation.timelineDuration
    }

    private(set) var loopTime: TimeInterval = 0
    private(set) var loopIndex: Int = 0
    private(set) var lastFiredStrokeIndices: Set<Int> = []

    init(notation: ScratchNotation) {
        self.notation = notation
    }

    @discardableResult
    func advance(to newLoopTime: TimeInterval, previousLoopTime: TimeInterval) -> ScratchNotationPlaybackState {
        let didWrap = newLoopTime < previousLoopTime

        if didWrap {
            loopIndex += 1
            lastFiredStrokeIndices.removeAll()
        }

        loopTime = newLoopTime

        var boundaryFired = false
        var firedStrokeIndex: Int? = nil

        for (idx, stroke) in notation.strokes.enumerated() {
            guard !lastFiredStrokeIndices.contains(idx) else { continue }

            let startCrossed = didWrap
                ? (stroke.startTime >= previousLoopTime || stroke.startTime <= newLoopTime)
                : (stroke.startTime > previousLoopTime && stroke.startTime <= newLoopTime)

            if startCrossed {
                lastFiredStrokeIndices.insert(idx)
                boundaryFired = true

                if firedStrokeIndex == nil {
                    firedStrokeIndex = idx
                }
            }
        }

        let (currentIdx, direction, progress) = currentStrokeInfo(at: newLoopTime)
        let targetDirection = firedStrokeIndex.map { notation.strokes[$0].direction } ?? direction

        return ScratchNotationPlaybackState(
            loopTime: newLoopTime,
            loopIndex: loopIndex,
            currentStrokeIndex: firedStrokeIndex ?? currentIdx,
            currentTargetDirection: targetDirection,
            progressThroughStroke: progress,
            isAtStrokeBoundary: boundaryFired
        )
    }

    func reset() {
        loopTime = 0
        loopIndex = 0
        lastFiredStrokeIndices.removeAll()
    }

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

    func targetDirection(at time: TimeInterval) -> ScratchNotationDirection? {
        currentStrokeInfo(at: time).1
    }
}
