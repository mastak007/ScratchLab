// Tests for NotationFeedbackState mapping and NotationFeedbackStyle parameters.
//
// Pure model tests — no SwiftUI, no Canvas, no GraphicsContext.
// Covers feedback-state mapping, boundary conditions,
// reduce-motion style flags, and static-preview safety.

import XCTest
@testable import ScratchLab

final class NotationFeedbackStateTests: XCTestCase {

    // MARK: - Helpers

    private func state(accuracy: Double, isOnBeat: Bool, beatOffset: Double) -> NotationFeedbackState {
        NotationFeedbackState.from(accuracy: accuracy, isOnBeat: isOnBeat, beatOffset: beatOffset)
    }

    // MARK: - 1. Exact timing + high accuracy → correct or excellent

    func testExactTimingOnBeatMapsToExcellentOrCorrect() {
        let s = state(accuracy: 92, isOnBeat: true, beatOffset: 0)
        XCTAssertTrue(s == .excellent || s == .correct,
                      "High-accuracy on-beat must map to excellent or correct, got \(s)")
    }

    // MARK: - 2. Very small timing offset → excellent (accuracy ≥ 90, on-beat)

    func testHighAccuracyOnBeatMapsToExcellent() {
        XCTAssertEqual(state(accuracy: 90, isOnBeat: true, beatOffset: 5), .excellent)
    }

    // MARK: - 3. Acceptable accuracy → correct (accuracy 70–89)

    func testAcceptableAccuracyMapsToCorrect() {
        XCTAssertEqual(state(accuracy: 78, isOnBeat: false, beatOffset: -30), .correct)
    }

    func testAccuracyJustAtCorrectThreshold() {
        XCTAssertEqual(
            state(accuracy: NotationFeedbackState.correctAccuracyThreshold, isOnBeat: false, beatOffset: 0),
            .correct
        )
    }

    // MARK: - 4. Near miss → close (accuracy 50–69)

    func testNearMissAccuracyMapsToClose() {
        XCTAssertEqual(state(accuracy: 58, isOnBeat: false, beatOffset: 10), .close)
    }

    func testAccuracyAtCloseThreshold() {
        XCTAssertEqual(
            state(accuracy: NotationFeedbackState.closeAccuracyThreshold, isOnBeat: false, beatOffset: 0),
            .close
        )
    }

    // MARK: - 5. Early timing → early

    func testEarlyTimingMapsToEarly() {
        XCTAssertEqual(state(accuracy: 35, isOnBeat: false, beatOffset: -80), .early)
    }

    func testEarlyBoundaryThreshold() {
        XCTAssertEqual(
            state(accuracy: 40, isOnBeat: false, beatOffset: NotationFeedbackState.earlyOffsetThresholdMs - 0.1),
            .early
        )
    }

    // MARK: - 6. Late timing → late

    func testLateTimingMapsToLate() {
        XCTAssertEqual(state(accuracy: 28, isOnBeat: false, beatOffset: 120), .late)
    }

    func testLateBoundaryThreshold() {
        XCTAssertEqual(
            state(accuracy: 40, isOnBeat: false, beatOffset: NotationFeedbackState.lateOffsetThresholdMs + 0.1),
            .late
        )
    }

    // MARK: - 7. Wrong direction — never emitted by current mapping (no direction signal)

    func testMappingNeverReturnsWrongDirection() {
        let samples: [(Double, Bool, Double)] = [
            (95, true,  0), (75, true, 20), (55, false, 5),
            (30, false, -100), (20, false, 200), (10, false, 0),
        ]
        for (acc, onBeat, offset) in samples {
            let s = state(accuracy: acc, isOnBeat: onBeat, beatOffset: offset)
            XCTAssertNotEqual(s, .wrongDirection,
                "Current mapping has no direction signal — wrongDirection must never be emitted")
        }
    }

    // MARK: - 8. No live event → neutral is the default lane state

    func testNeutralIsDefaultState() {
        // ScratchMotionLane defaults feedbackState to .neutral so static template
        // preview never shows reward effects without a live detection event.
        XCTAssertEqual(NotationFeedbackState.neutral, .neutral)
        XCTAssertFalse(NotationFeedbackState.neutral.isReward)
    }

    // MARK: - 9. Missed expected stroke → missed (low accuracy, ambiguous timing)

    func testMissedStrokeMapsToMissed() {
        XCTAssertEqual(state(accuracy: 20, isOnBeat: false, beatOffset: 10), .missed)
    }

    func testMissedWhenBeatOffsetInsideThresholds() {
        // beatOffset between earlyThreshold and lateThreshold → .missed
        XCTAssertEqual(
            state(accuracy: 15, isOnBeat: false, beatOffset: NotationFeedbackState.earlyOffsetThresholdMs + 1),
            .missed
        )
    }

    // MARK: - 10. Reduce Motion disables animated spark/pulse

    func testReduceMotionDisablesSparkAndPulse() {
        let excellent = NotationFeedbackStyle.style(for: .excellent, reduceMotion: true)
        XCTAssertFalse(excellent.hasSpark, "Spark must be disabled under Reduce Motion")
        XCTAssertFalse(excellent.hasPulse, "Pulse must be disabled under Reduce Motion")

        let correct = NotationFeedbackStyle.style(for: .correct, reduceMotion: true)
        XCTAssertFalse(correct.hasPulse, "Pulse must be disabled under Reduce Motion")
        XCTAssertFalse(correct.hasSpark)
    }

    func testMotionEnabledHasSparkAndPulseForExcellent() {
        let excellent = NotationFeedbackStyle.style(for: .excellent, reduceMotion: false)
        XCTAssertTrue(excellent.hasSpark, "Excellent with motion enabled must have spark")
        XCTAssertTrue(excellent.hasPulse, "Excellent with motion enabled must have pulse")
    }

    func testMotionEnabledHasPulseForCorrect() {
        let correct = NotationFeedbackStyle.style(for: .correct, reduceMotion: false)
        XCTAssertTrue(correct.hasPulse, "Correct with motion enabled must have pulse")
        XCTAssertFalse(correct.hasSpark, "Correct must not have spark (reserved for excellent)")
    }

    // MARK: - 11. Static template preview does not show reward effects by default

    func testNeutralStateHasNoGlowOrEffects() {
        let neutral = NotationFeedbackStyle.style(for: .neutral, reduceMotion: false)
        XCTAssertNil(neutral.glowColor, "Neutral must carry no glow color")
        XCTAssertEqual(neutral.glowOpacity, 0, "Neutral glow opacity must be zero")
        XCTAssertFalse(neutral.hasSpark)
        XCTAssertFalse(neutral.hasPulse)
        XCTAssertNil(neutral.timingMarkerColor)
    }

    // MARK: - Correction states carry no reward spark/pulse

    func testEarlyAndLateHaveNoRewardEffects() {
        for reduceMotion in [false, true] {
            let early = NotationFeedbackStyle.style(for: .early, reduceMotion: reduceMotion)
            XCTAssertFalse(early.hasSpark, "Early must not have spark (reduceMotion: \(reduceMotion))")
            XCTAssertFalse(early.hasPulse, "Early must not have pulse (reduceMotion: \(reduceMotion))")
            XCTAssertNotNil(early.timingMarkerColor, "Early must have a timing marker color")

            let late = NotationFeedbackStyle.style(for: .late, reduceMotion: reduceMotion)
            XCTAssertFalse(late.hasSpark, "Late must not have spark (reduceMotion: \(reduceMotion))")
            XCTAssertFalse(late.hasPulse, "Late must not have pulse (reduceMotion: \(reduceMotion))")
            XCTAssertNotNil(late.timingMarkerColor, "Late must have a timing marker color")
        }
    }

    // MARK: - isReward and isTimingCorrection properties

    func testIsRewardTrueOnlyForCorrectAndExcellent() {
        XCTAssertTrue(NotationFeedbackState.correct.isReward)
        XCTAssertTrue(NotationFeedbackState.excellent.isReward)
        XCTAssertFalse(NotationFeedbackState.close.isReward)
        XCTAssertFalse(NotationFeedbackState.early.isReward)
        XCTAssertFalse(NotationFeedbackState.late.isReward)
        XCTAssertFalse(NotationFeedbackState.missed.isReward)
        XCTAssertFalse(NotationFeedbackState.neutral.isReward)
        XCTAssertFalse(NotationFeedbackState.wrongDirection.isReward)
    }

    func testIsTimingCorrectionTrueForEarlyAndLate() {
        XCTAssertTrue(NotationFeedbackState.early.isTimingCorrection)
        XCTAssertTrue(NotationFeedbackState.late.isTimingCorrection)
        XCTAssertFalse(NotationFeedbackState.correct.isTimingCorrection)
        XCTAssertFalse(NotationFeedbackState.excellent.isTimingCorrection)
        XCTAssertFalse(NotationFeedbackState.neutral.isTimingCorrection)
    }

    // MARK: - Boundary: just below excellent threshold goes to correct (on-beat)

    func testJustBelowExcellentThresholdOnBeatMapsToCorrect() {
        XCTAssertEqual(
            state(accuracy: NotationFeedbackState.excellentAccuracyThreshold - 0.1,
                  isOnBeat: true, beatOffset: 0),
            .correct,
            "Just below 90 but on-beat should be correct, not excellent"
        )
    }

    // MARK: - Decay duration available without style computation

    func testDecayDurationIsAvailableOnState() {
        XCTAssertEqual(NotationFeedbackState.neutral.decayDuration, 0)
        XCTAssertGreaterThan(NotationFeedbackState.correct.decayDuration, 0)
        XCTAssertGreaterThan(NotationFeedbackState.excellent.decayDuration, 0)
        XCTAssertGreaterThan(NotationFeedbackState.early.decayDuration, 0)
    }
}
