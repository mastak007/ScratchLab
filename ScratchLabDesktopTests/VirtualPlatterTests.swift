import XCTest
import CoreGraphics
@testable import ScratchLab

/// Tests for the isolated VirtualPlatter prototype model.
///
/// Pure gesture/ground-truth logic only — no capture pipeline, audio, or ML.
final class VirtualPlatterTests: XCTestCase {

    private let center = CGPoint(x: 100, y: 100)
    private let radius: CGFloat = 50

    /// Point on the platter circle at a given screen-space angle (radians).
    private func point(at angle: CGFloat) -> CGPoint {
        CGPoint(x: center.x + radius * cos(angle),
                y: center.y + radius * sin(angle))
    }

    /// Drive the platter through a sweep of `steps` samples, advancing the
    /// angle by `deltaPerStep` radians every `dt` seconds.
    private func sweep(_ platter: VirtualPlatter,
                       startAngle: CGFloat,
                       deltaPerStep: CGFloat,
                       dt: TimeInterval,
                       steps: Int) {
        var angle = startAngle
        var t: TimeInterval = 0
        platter.beginDrag(at: point(at: angle), center: center, timestamp: t)
        for _ in 0..<steps {
            angle += deltaPerStep
            t += dt
            platter.updateDrag(to: point(at: angle), center: center, timestamp: t)
        }
    }

    // MARK: - Geometry helpers

    func testSignedDeltaWrapsAcrossPiSeam() {
        // Crossing +π → -π the short way is a small positive step.
        let forwardSeam = PlatterGeometry.signedDelta(from: 3.0, to: -3.0)
        XCTAssertEqual(forwardSeam, 0.2831, accuracy: 0.001)

        // The reverse is a small negative step, not a ~6 rad jump.
        let backwardSeam = PlatterGeometry.signedDelta(from: -3.0, to: 3.0)
        XCTAssertEqual(backwardSeam, -0.2831, accuracy: 0.001)
    }

    func testAngleAboutCenterIsScreenSpace() {
        // +x is angle 0; +y (downward on screen) is +π/2.
        let right = PlatterGeometry.angle(of: CGPoint(x: 150, y: 100), about: center)
        let down = PlatterGeometry.angle(of: CGPoint(x: 100, y: 150), about: center)
        XCTAssertEqual(right, 0, accuracy: 0.0001)
        XCTAssertEqual(down, .pi / 2, accuracy: 0.0001)
    }

    // MARK: - Sample position mapping

    func testSamplePositionIsSilentBeforeFixedCue() {
        let beforeCue = VirtualPlatterSampleMapper.cuePhase - 0.001
        XCTAssertNil(VirtualPlatterSampleMapper.normalizedSamplePosition(recordPhase: beforeCue))
    }

    func testSamplePositionStartsAtFixedCueAndAdvancesWithRecordPhase() {
        let cue = VirtualPlatterSampleMapper.cuePhase
        let cuePosition = VirtualPlatterSampleMapper.normalizedSamplePosition(recordPhase: cue)
        XCTAssertNotNil(cuePosition)
        XCTAssertEqual(cuePosition ?? -1, 0, accuracy: 0.0001)

        let later = VirtualPlatterSampleMapper.normalizedSamplePosition(recordPhase: cue + 0.25)
        XCTAssertNotNil(later)
        XCTAssertGreaterThan(later ?? 0, 0)

        let farther = VirtualPlatterSampleMapper.normalizedSamplePosition(recordPhase: cue + 0.5)
        XCTAssertNotNil(farther)
        XCTAssertGreaterThan(farther ?? 0, later ?? 0,
                             "Forward record movement must advance sample position")
    }

    func testSamplePositionMovesBackwardWhenRecordPhaseMovesBackward() {
        let cue = VirtualPlatterSampleMapper.cuePhase
        let forwardPosition = VirtualPlatterSampleMapper.normalizedSamplePosition(recordPhase: cue + 0.5)
        let pulledBackPosition = VirtualPlatterSampleMapper.normalizedSamplePosition(recordPhase: cue + 0.2)

        XCTAssertNotNil(forwardPosition)
        XCTAssertNotNil(pulledBackPosition)
        XCTAssertLessThan(pulledBackPosition ?? 1, forwardPosition ?? 0,
                          "Backward record movement must move backward through the sample")
    }

    // MARK: - Direction detection

    func testClockwiseDragIsForward() {
        let platter = VirtualPlatter()
        sweep(platter, startAngle: 0, deltaPerStep: 0.3, dt: 0.1, steps: 5)

        XCTAssertEqual(platter.direction, .forward)
        XCTAssertGreaterThan(platter.angularVelocity, 0,
                             "Forward motion must have a positive angular velocity")
        XCTAssertGreaterThan(platter.angle, 0,
                             "Clockwise sweep must accumulate positive angle")
    }

    func testCounterClockwiseDragIsBackward() {
        let platter = VirtualPlatter()
        sweep(platter, startAngle: 0, deltaPerStep: -0.3, dt: 0.1, steps: 5)

        XCTAssertEqual(platter.direction, .backward)
        XCTAssertLessThan(platter.angularVelocity, 0,
                          "Backward motion must have a negative angular velocity")
        XCTAssertLessThan(platter.angle, 0,
                          "Counter-clockwise sweep must accumulate negative angle")
    }

    func testVelocitySignMatchesDirection() {
        let forward = VirtualPlatter()
        sweep(forward, startAngle: 0, deltaPerStep: 0.25, dt: 0.1, steps: 4)
        XCTAssertEqual(forward.direction.sign, 1)
        XCTAssertEqual(forward.angularVelocity > 0 ? 1 : -1, forward.direction.sign)

        let backward = VirtualPlatter()
        sweep(backward, startAngle: 0, deltaPerStep: -0.25, dt: 0.1, steps: 4)
        XCTAssertEqual(backward.direction.sign, -1)
        XCTAssertEqual(backward.angularVelocity > 0 ? 1 : -1, backward.direction.sign)
    }

    func testTinyJitterStaysIdle() {
        let platter = VirtualPlatter() // idleAngularSpeed default 0.25 rad/s
        // 0.01 rad over 0.1s ≈ 0.1 rad/s — below the idle threshold.
        sweep(platter, startAngle: 0, deltaPerStep: 0.01, dt: 0.1, steps: 5)
        XCTAssertEqual(platter.direction, .idle)
    }

    func testFullClockwiseLoopAccumulatesTwoPi() {
        let platter = VirtualPlatter()
        // 36 steps of 0.2 rad ≈ 7.2 rad (> one full turn).
        sweep(platter, startAngle: 0, deltaPerStep: 0.2, dt: 0.05, steps: 36)
        XCTAssertEqual(platter.angle, 7.2, accuracy: 0.05,
                       "Accumulated angle must track total spin, not wrap")
    }

    // MARK: - Normalized speed

    func testNormalizedSpeedIsClampedAndMonotonic() {
        let slow = VirtualPlatter()
        sweep(slow, startAngle: 0, deltaPerStep: 0.1, dt: 0.1, steps: 4)

        let fast = VirtualPlatter()
        sweep(fast, startAngle: 0, deltaPerStep: 0.6, dt: 0.1, steps: 4)

        XCTAssertGreaterThanOrEqual(slow.normalizedSpeed, 0)
        XCTAssertLessThanOrEqual(fast.normalizedSpeed, 1)
        XCTAssertGreaterThan(fast.normalizedSpeed, slow.normalizedSpeed,
                             "Faster spin must yield a higher normalized speed")
    }

    func testNormalizedSpeedNeverExceedsOne() {
        let platter = VirtualPlatter()
        // Huge per-step delta to try to overflow the normalized speed.
        sweep(platter, startAngle: 0, deltaPerStep: 2.5, dt: 0.01, steps: 6)
        XCTAssertLessThanOrEqual(platter.normalizedSpeed, 1.0)
        XCTAssertGreaterThan(platter.normalizedSpeed, 0.0)
    }

    // MARK: - Drag lifecycle

    func testEndDragReturnsToIdleAndZeroVelocity() {
        let platter = VirtualPlatter()
        sweep(platter, startAngle: 0, deltaPerStep: 0.4, dt: 0.1, steps: 4)
        XCTAssertEqual(platter.direction, .forward)

        platter.endDrag()

        XCTAssertEqual(platter.direction, .idle)
        XCTAssertEqual(platter.angularVelocity, 0)
        XCTAssertEqual(platter.normalizedSpeed, 0)
        XCTAssertFalse(platter.isDragging)
    }

    func testResetClearsAccumulatedAngle() {
        let platter = VirtualPlatter()
        sweep(platter, startAngle: 0, deltaPerStep: 0.4, dt: 0.1, steps: 4)
        platter.reset()
        XCTAssertEqual(platter.angle, 0)
        XCTAssertEqual(platter.direction, .idle)
    }

    // MARK: - Exact ground-truth lock evaluator

    private func driveEvaluator(_ evaluator: inout ScratchLockEvaluator,
                                direction: PlatterDirection,
                                speed: Double,
                                from start: TimeInterval,
                                to end: TimeInterval,
                                step: TimeInterval) -> LockAssessment {
        var t = start
        var last = LockAssessment(phase: .waiting, progress: 0)
        while t <= end + 1e-9 {
            last = evaluator.evaluate(direction: direction,
                                      normalizedSpeed: speed,
                                      at: t)
            t += step
        }
        return last
    }

    func testWaitingBeforeWindow() {
        let stroke = ScratchTargetStroke(direction: .forward, start: 1.0, end: 3.0)
        var evaluator = ScratchLockEvaluator(stroke: stroke, requiredCoverage: 0.6)
        let assessment = evaluator.evaluate(direction: .forward,
                                            normalizedSpeed: 0.9,
                                            at: 0.5)
        XCTAssertEqual(assessment.phase, .waiting)
        XCTAssertEqual(assessment.progress, 0)
        XCTAssertFalse(assessment.isSuccess)
    }

    func testMatchingDirectionInWindowLocks() {
        let stroke = ScratchTargetStroke(direction: .forward,
                                         start: 1.0,
                                         end: 3.0,
                                         minimumNormalizedSpeed: 0.1)
        var evaluator = ScratchLockEvaluator(stroke: stroke, requiredCoverage: 0.6)
        let final = driveEvaluator(&evaluator,
                                   direction: .forward,
                                   speed: 0.5,
                                   from: 1.0,
                                   to: 3.0,
                                   step: 0.05)
        XCTAssertEqual(final.phase, .locked)
        XCTAssertTrue(final.isSuccess)
        XCTAssertEqual(final.progress, 1.0, accuracy: 0.0001)
    }

    func testWrongDirectionNeverLocksAndMisses() {
        let stroke = ScratchTargetStroke(direction: .forward,
                                         start: 1.0,
                                         end: 3.0,
                                         minimumNormalizedSpeed: 0.1)
        var evaluator = ScratchLockEvaluator(stroke: stroke, requiredCoverage: 0.6)
        let final = driveEvaluator(&evaluator,
                                   direction: .backward,
                                   speed: 0.9,
                                   from: 1.0,
                                   to: 3.6,
                                   step: 0.05)
        XCTAssertEqual(final.phase, .missed)
        XCTAssertFalse(final.isSuccess)
        XCTAssertEqual(evaluator.matchedDuration, 0, accuracy: 0.0001)
    }

    func testTooSlowDoesNotLock() {
        let stroke = ScratchTargetStroke(direction: .forward,
                                         start: 1.0,
                                         end: 3.0,
                                         minimumNormalizedSpeed: 0.4)
        var evaluator = ScratchLockEvaluator(stroke: stroke, requiredCoverage: 0.6)
        let final = driveEvaluator(&evaluator,
                                   direction: .forward,
                                   speed: 0.2, // below the 0.4 minimum
                                   from: 1.0,
                                   to: 3.6,
                                   step: 0.05)
        XCTAssertEqual(final.phase, .missed)
        XCTAssertFalse(final.isSuccess)
    }

    // MARK: - Feel tuning: settle + hysteresis

    /// Finger held still on the record (no new samples) must decay to
    /// "Still" instead of holding a stale speed like a slider thumb —
    /// while the finger is still down and the track position is preserved.
    func testHeldStillSettlesToIdle() {
        let platter = VirtualPlatter()
        sweep(platter, startAngle: 0, deltaPerStep: 0.3, dt: 0.1, steps: 5)
        XCTAssertEqual(platter.direction, .forward)
        let frozenAngle = platter.angle

        // Last input was at t = 0.5 (5 * 0.1). Tick settle past it.
        var t: TimeInterval = 0.5
        for _ in 0..<10 {
            t += 0.05
            platter.settle(at: t)
        }

        XCTAssertEqual(platter.direction, .idle)
        XCTAssertEqual(platter.angularVelocity, 0, accuracy: 0.05)
        XCTAssertEqual(platter.normalizedSpeed, 0, accuracy: 0.01)
        XCTAssertTrue(platter.isDragging, "Finger is still down — only the speed settled")
        XCTAssertEqual(platter.angle, frozenAngle, accuracy: 0.0001,
                       "Settling must not move the record")
    }

    /// Speed parked between the idle and wake thresholds must NOT wake from
    /// idle (anti-chatter), but once moving it keeps its direction down
    /// through that same band until it drops below the idle threshold.
    func testDirectionHysteresisAcrossThresholdBand() {
        let platter = VirtualPlatter() // idle 0.7, wake 1.1 rad/s
        var angle: CGFloat = 0
        var t: TimeInterval = 0
        platter.beginDrag(at: point(at: angle), center: center, timestamp: t)

        // ~0.9 rad/s sits inside the (0.7, 1.1) band. From idle it must stay
        // idle — a single 0.7 threshold would have flipped to forward.
        for _ in 0..<8 {
            angle += 0.09
            t += 0.1
            platter.updateDrag(to: point(at: angle), center: center, timestamp: t)
        }
        XCTAssertEqual(platter.direction, .idle,
                       "Speed in the hysteresis band must not wake from idle")

        // Push clearly above the wake threshold → now moving.
        for _ in 0..<6 {
            angle += 0.5
            t += 0.1
            platter.updateDrag(to: point(at: angle), center: center, timestamp: t)
        }
        XCTAssertEqual(platter.direction, .forward)

        // Ease back into the same band (~0.9 rad/s). Still moving: it holds
        // direction instead of chattering back to idle.
        for _ in 0..<6 {
            angle += 0.09
            t += 0.1
            platter.updateDrag(to: point(at: angle), center: center, timestamp: t)
        }
        XCTAssertEqual(platter.direction, .forward,
                       "Once moving, direction holds through the band")
    }
}
