// Tests for PracticeGameplayCoordinator — the WATCH → COPY → RESULT state
// machine. Evidence fixtures are synthetic `CaptureCore.DetectedNotation*`
// values built directly (no real capture/DVS/MIDI involved); the target
// side is always `ScratchNotation.babyScratchCycle` at 100 BPM with a
// 0-beat count-in, so 1 beat = 0.6 s and beat 0 sits at take-relative 0.

import Foundation
import Testing
@testable import ScratchLab

// MARK: - Fixtures

private let fixtureBPM = 100.0
private let fixtureCountInBeats = 0
private let fixturePattern = ScratchNotation.babyScratchCycle

private func movementEvent(
    start: Double,
    end: Double,
    direction: String,
    kind: ScratchMovementKind = .normalPush
) -> CaptureCore.DetectedNotationRecordMovementEvent {
    .init(startTime: start, endTime: end, startPosition: 0, endPosition: 1,
          direction: direction, movementKind: kind, speed: 1,
          confidence: 0.9, source: "timecode_live")
}

private func snapshot(
    movementEvents: [CaptureCore.DetectedNotationRecordMovementEvent],
    mixerEvents: [CaptureCore.RawMixerMIDIEvent] = []
) -> CaptureCore.DetectedNotationSnapshot {
    .init(notationSource: "detected", notationConfidence: nil, detectedLabel: nil,
          labelSource: "", labelConfidence: nil, detectionSources: ["test"],
          recordMovementEvents: movementEvents, audioEvents: [], faderEvents: [],
          mixerMidiEvents: mixerEvents, capturedAt: Date())
}

/// Cycle 0 played exactly on target (forward 0–0.3s, backward 0.3–0.6s).
private func perfectSnapshot() -> CaptureCore.DetectedNotationSnapshot {
    snapshot(movementEvents: [
        movementEvent(start: 0.0, end: 0.3, direction: "forward"),
        movementEvent(start: 0.3, end: 0.6, direction: "backward")
    ])
}

/// Cycle 0 perfect, PLUS a stroke that belongs to cycle 1 (starts at
/// take-relative 0.65s = beat 1.0833, past the [0,1.0) beat window).
private func perfectSnapshotWithNextCycleLeakage() -> CaptureCore.DetectedNotationSnapshot {
    snapshot(movementEvents: [
        movementEvent(start: 0.0, end: 0.3, direction: "forward"),
        movementEvent(start: 0.3, end: 0.6, direction: "backward"),
        movementEvent(start: 0.65, end: 0.9, direction: "forward")
    ])
}

private func missingBackwardStrokeSnapshot() -> CaptureCore.DetectedNotationSnapshot {
    snapshot(movementEvents: [
        movementEvent(start: 0.0, end: 0.3, direction: "forward")
    ])
}

/// Non-empty `recordMovementEvents` (so the snapshot-level guard passes)
/// but the one event is a `.hold`, not a stroke kind — every axis should
/// end up unassessable, not zero.
private func holdOnlySnapshot() -> CaptureCore.DetectedNotationSnapshot {
    snapshot(movementEvents: [
        movementEvent(start: 0.0, end: 0.1, direction: "forward", kind: .hold)
    ])
}

@MainActor
private func beginBaby(_ coordinator: PracticeGameplayCoordinator) {
    coordinator.beginAttempt(pattern: fixturePattern, bpm: fixtureBPM, countInBeats: fixtureCountInBeats)
}

// MARK: - Tests

@Suite("PracticeGameplayCoordinator state machine")
@MainActor
struct PracticeGameplayCoordinatorTests {

    @Test("idle transitions to watching")
    func idleToWatch() {
        let coordinator = PracticeGameplayCoordinator()
        #expect(coordinator.state == .idle)
        coordinator.beginWatch()
        #expect(coordinator.state == .watching)
    }

    @Test("watching transitions to ready, and ready can start a copy attempt")
    func watchToReadyToCopy() {
        let coordinator = PracticeGameplayCoordinator()
        coordinator.beginWatch()
        coordinator.finishWatching()
        #expect(coordinator.state == .ready)
        beginBaby(coordinator)
        guard case .copying = coordinator.state else {
            Issue.record("expected .copying after beginAttempt from .ready"); return
        }
    }

    @Test("Copy closes at exactly one canonical cycle: only in-window evidence is compared")
    func copyClosesAtOneCycle() {
        let coordinator = PracticeGameplayCoordinator()
        beginBaby(coordinator)
        let result = coordinator.completeAttempt(snapshot: perfectSnapshot())
        let attempt = try! #require(result)
        #expect(attempt.comparison.matchedStrokes.count == 2)
        #expect(attempt.window.startBeat == 0)
        #expect(attempt.window.endBeat == 1.0)
    }

    @Test("Exactly one PracticeAttemptResult is emitted per attempt")
    func exactlyOneResultEmitted() {
        let coordinator = PracticeGameplayCoordinator()
        beginBaby(coordinator)
        let first = coordinator.completeAttempt(snapshot: perfectSnapshot())
        #expect(first != nil)
        // Already `.result` — a second completion signal must not emit or
        // overwrite anything.
        let second = coordinator.completeAttempt(snapshot: missingBackwardStrokeSnapshot())
        #expect(second == nil)
        #expect(coordinator.currentResult == first)
    }

    @Test("A stroke belonging to the next cycle is excluded from this attempt")
    func nextCycleEventsExcluded() {
        let coordinator = PracticeGameplayCoordinator()
        beginBaby(coordinator)
        let result = coordinator.completeAttempt(snapshot: perfectSnapshotWithNextCycleLeakage())
        let attempt = try! #require(result)
        #expect(attempt.comparison.matchedStrokes.count == 2)
        #expect(attempt.comparison.extraPerformedStrokeIndices.isEmpty)
    }

    @Test("A missing stroke still completes the attempt with a real (low) score")
    func missingStrokeStillCompletes() {
        let coordinator = PracticeGameplayCoordinator()
        beginBaby(coordinator)
        let result = coordinator.completeAttempt(snapshot: missingBackwardStrokeSnapshot())
        let attempt = try! #require(result)
        #expect(attempt.comparison.missingTargetStrokeIndices == [1])
        #expect(attempt.completionScore != nil)
        guard case .result = coordinator.state else {
            Issue.record("expected .result even with a missing stroke"); return
        }
    }

    @Test("Retry starts a fresh attempt with the same technique and tempo")
    func retryCreatesNewAttempt() {
        var tick = 0
        let coordinator = PracticeGameplayCoordinator(now: {
            tick += 1
            return Date(timeIntervalSince1970: Double(tick))
        })
        beginBaby(coordinator)
        _ = coordinator.completeAttempt(snapshot: missingBackwardStrokeSnapshot())
        let firstSession = coordinator.lastSession
        coordinator.retry()
        guard case .copying(let secondSession) = coordinator.state else {
            Issue.record("expected .copying after retry"); return
        }
        #expect(secondSession.pattern == firstSession?.pattern)
        #expect(secondSession.bpm == firstSession?.bpm)
        #expect(secondSession.startedAt != firstSession?.startedAt)

        let secondResult = coordinator.completeAttempt(snapshot: perfectSnapshot())
        let attempt = try! #require(secondResult)
        #expect(attempt.comparison.missingTargetStrokeIndices.isEmpty) // genuinely a new, different attempt
    }

    @Test("The prior result is unchanged while a retry is being prepared")
    func priorResultDoesNotMutateDuringRetry() {
        let coordinator = PracticeGameplayCoordinator()
        beginBaby(coordinator)
        let firstResult = try! #require(coordinator.completeAttempt(snapshot: perfectSnapshot()))
        coordinator.retry()
        // The state moved off .result, but the captured value is untouched.
        #expect(firstResult.comparison.matchedStrokes.count == 2)
        #expect(coordinator.currentResult == nil)
    }

    @Test("Unassessable axes stay unavailable, never a fabricated zero")
    func unassessableAxesStayUnavailable() {
        let coordinator = PracticeGameplayCoordinator()
        beginBaby(coordinator)
        let result = coordinator.completeAttempt(snapshot: holdOnlySnapshot())
        let attempt = try! #require(result)
        #expect(attempt.timingScore == nil)
        #expect(attempt.directionScore == nil)
        #expect(attempt.faderScore == nil)
        #expect(attempt.completionScore != nil) // a real, assessed 0% — not "no data"
    }

    @Test("WATCH never produces a score")
    func watchNeverScores() {
        let coordinator = PracticeGameplayCoordinator()
        coordinator.beginWatch()
        coordinator.finishWatching()
        #expect(coordinator.currentResult == nil)
        // Completion is meaningless outside .copying — it must be a no-op.
        let result = coordinator.completeAttempt(snapshot: perfectSnapshot())
        #expect(result == nil)
        #expect(coordinator.state == .ready)
    }

    @Test("Repeated start commands do not create overlapping attempts")
    func repeatedStartDoesNotOverlap() {
        var tick = 0
        let coordinator = PracticeGameplayCoordinator(now: {
            tick += 1
            return Date(timeIntervalSince1970: Double(tick))
        })
        beginBaby(coordinator)
        guard case .copying(let firstSession) = coordinator.state else {
            Issue.record("expected .copying"); return
        }
        // A second start command with different parameters while already
        // copying must be ignored — no second window opens.
        let otherPattern = ScratchNotation.BeatPattern(
            version: 1, scratchID: "other", timingBasis: "beat_canonical_cycle_v1",
            beatsPerBar: nil,
            strokes: [.init(startBeat: 0, endBeat: 2, direction: .forward,
                            speedClassification: .medium, faderState: .open)]
        )
        coordinator.beginAttempt(pattern: otherPattern, bpm: 140, countInBeats: 4)
        guard case .copying(let stillFirstSession) = coordinator.state else {
            Issue.record("expected still .copying"); return
        }
        #expect(stillFirstSession == firstSession)
    }

    @Test("Same evidence produces the same result, deterministically")
    func deterministicSameEvidence() {
        let fixedDate = Date(timeIntervalSince1970: 1000)
        let coordinatorA = PracticeGameplayCoordinator(now: { fixedDate })
        let coordinatorB = PracticeGameplayCoordinator(now: { fixedDate })
        beginBaby(coordinatorA)
        beginBaby(coordinatorB)
        let resultA = coordinatorA.completeAttempt(snapshot: perfectSnapshot())
        let resultB = coordinatorB.completeAttempt(snapshot: perfectSnapshot())
        #expect(resultA != nil)
        #expect(resultA == resultB)
    }
}
