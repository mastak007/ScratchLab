import XCTest
import CoreGraphics
import QuartzCore
@testable import ScratchLab

final class HandDirectionTrackerTests: XCTestCase {

    private var tracker: HandDirectionTracker!

    override func setUp() {
        super.setUp()
        tracker = HandDirectionTracker()
    }

    // MARK: - Forward motion

    func testSteadyForwardMotionClassifiesAsMovingForward() {
        // Simulate 4 frames of rightward hand movement.
        var time: CFTimeInterval = 0
        let dt: CFTimeInterval = 0.12
        var x: CGFloat = 0.30

        var lastDirection: HandDirectionTracker.Direction = .idle
        for _ in 0..<5 {
            x += 0.025          // ~0.21 normalized/sec — above threshold
            time += dt
            lastDirection = tracker.recordObservation(rawPoint: CGPoint(x: x, y: 0.5), at: time)
        }

        XCTAssertEqual(lastDirection, .movingForward, "Steady rightward motion should commit to .movingForward")
    }

    // MARK: - Backward motion

    func testSteadyBackwardMotionClassifiesAsMovingBackward() {
        var time: CFTimeInterval = 0
        let dt: CFTimeInterval = 0.12
        var x: CGFloat = 0.70

        var lastDirection: HandDirectionTracker.Direction = .idle
        for _ in 0..<5 {
            x -= 0.025
            time += dt
            lastDirection = tracker.recordObservation(rawPoint: CGPoint(x: x, y: 0.5), at: time)
        }

        XCTAssertEqual(lastDirection, .movingBackward, "Steady leftward motion should commit to .movingBackward")
    }

    // MARK: - Idle / jitter

    func testJitterAroundIdleDoesNotCommitDirection() {
        // Alternating tiny motions below the displacement threshold.
        var time: CFTimeInterval = 0
        let dt: CFTimeInterval = 0.12
        var x: CGFloat = 0.50
        var sign: CGFloat = 1

        for _ in 0..<8 {
            x += sign * 0.003   // 0.003 < displacementThreshold (0.010)
            sign *= -1
            time += dt
            _ = tracker.recordObservation(rawPoint: CGPoint(x: x, y: 0.5), at: time)
        }

        XCTAssertEqual(tracker.direction, .idle, "Sub-threshold jitter should remain .idle")
    }

    func testAlternatingJitterWithLargeStepsDoesNotCommitDirection() {
        var time: CFTimeInterval = 0
        let positions: [CGFloat] = [0.50, 0.52, 0.50, 0.52, 0.50, 0.52, 0.50, 0.52]

        for x in positions {
            time += 0.12
            _ = tracker.recordObservation(rawPoint: CGPoint(x: x, y: 0.5), at: time)
        }

        XCTAssertEqual(tracker.direction, .idle, "Alternating hand jitter should not become a stroke direction")
    }

    // MARK: - Miss hold

    func testDirectionHeldForFirstFewMissedFrames() {
        // Commit to .movingForward first.
        var time: CFTimeInterval = 0
        let dt: CFTimeInterval = 0.12
        var x: CGFloat = 0.30

        for _ in 0..<5 {
            x += 0.025
            time += dt
            _ = tracker.recordObservation(rawPoint: CGPoint(x: x, y: 0.5), at: time)
        }

        XCTAssertEqual(tracker.direction, .movingForward)

        // Now miss up to holdFrames — direction should be held.
        for missFrame in 1...HandDirectionTracker.holdFrames {
            let held = tracker.recordMiss()
            XCTAssertEqual(held, .movingForward,
                           "Frame \(missFrame): direction should be held during hold window")
        }
    }

    func testDirectionDropsToIdleAfterHoldWindow() {
        // Commit to .movingForward.
        var time: CFTimeInterval = 0
        var x: CGFloat = 0.30

        for _ in 0..<5 {
            x += 0.025
            time += 0.12
            _ = tracker.recordObservation(rawPoint: CGPoint(x: x, y: 0.5), at: time)
        }

        // Consume the hold window.
        for _ in 0..<HandDirectionTracker.holdFrames {
            _ = tracker.recordMiss()
        }

        // One more miss puts us past holdFrames.
        let afterHold = tracker.recordMiss()
        XCTAssertEqual(afterHold, .idle, "Direction should drop to .idle after the hold window expires")
        XCTAssertEqual(tracker.confidence, 0, accuracy: 0.001, "Idle after a miss window should not keep direction confidence")
    }

    // MARK: - Reset after extended misses

    func testExtendedMissesResetToSearching() {
        // Commit to .movingBackward.
        var time: CFTimeInterval = 0
        var x: CGFloat = 0.70

        for _ in 0..<5 {
            x -= 0.025
            time += 0.12
            _ = tracker.recordObservation(rawPoint: CGPoint(x: x, y: 0.5), at: time)
        }

        // Drain all frames up to and including resetFrames.
        var lastResult: HandDirectionTracker.Direction = .movingBackward
        for _ in 0..<HandDirectionTracker.resetFrames {
            lastResult = tracker.recordMiss()
        }

        XCTAssertEqual(lastResult, .searching, "After resetFrames misses the tracker should signal .searching")
        XCTAssertEqual(tracker.direction, .searching)
    }

    // MARK: - Direction reversal

    func testDirectionReversalIsDetected() {
        var time: CFTimeInterval = 0
        var x: CGFloat = 0.30

        // Phase 1: move forward.
        for _ in 0..<5 {
            x += 0.025
            time += 0.12
            _ = tracker.recordObservation(rawPoint: CGPoint(x: x, y: 0.5), at: time)
        }
        XCTAssertEqual(tracker.direction, .movingForward)

        // Phase 2: brief pause to flush history naturally (idle frames).
        for _ in 0..<3 {
            time += 0.12
            _ = tracker.recordObservation(rawPoint: CGPoint(x: x, y: 0.5), at: time)
        }

        // Phase 3: move backward.
        for _ in 0..<5 {
            x -= 0.025
            time += 0.12
            _ = tracker.recordObservation(rawPoint: CGPoint(x: x, y: 0.5), at: time)
        }

        XCTAssertEqual(tracker.direction, .movingBackward, "After reversal through idle, direction should be .movingBackward")
    }

    // MARK: - Hysteresis

    func testFirstObservationAloneIsIdle() {
        // With only 1 sample in history, no velocity pair exists.
        let result = tracker.recordObservation(rawPoint: CGPoint(x: 0.30, y: 0.5), at: 0)
        XCTAssertEqual(result, .idle, "First observation with no prior history should be .idle")
    }

    func testDirectionRequiresCommitFramesBeforeCommitting() {
        // commitFrames = 2: need 2 agreeing frames before the direction commits.
        var time: CFTimeInterval = 0

        // Baseline sample.
        _ = tracker.recordObservation(rawPoint: CGPoint(x: 0.30, y: 0.5), at: time)
        time += 0.12

        // One forward frame — 1 agreeing frame, should still be .idle.
        let afterOneFrame = tracker.recordObservation(rawPoint: CGPoint(x: 0.36, y: 0.5), at: time)
        XCTAssertEqual(afterOneFrame, .idle,
                       "Direction should not commit after only 1 agreeing frame (commitFrames=\(HandDirectionTracker.commitFrames))")
        time += 0.12

        // Second forward frame — 2 agreeing frames, should commit.
        let afterTwoFrames = tracker.recordObservation(rawPoint: CGPoint(x: 0.42, y: 0.5), at: time)
        XCTAssertEqual(afterTwoFrames, .movingForward,
                       "Direction should commit after \(HandDirectionTracker.commitFrames) agreeing frames")
    }

    // MARK: - Threshold behaviour

    func testMotionJustAboveThresholdCommits() {
        var time: CFTimeInterval = 0
        // Per frame move slightly above displacementThreshold over 4 frames.
        // window = 4 frames × 0.014 normalized each = 0.056 total in ~0.48 sec → ~0.12 n/s, ≥ velocityThreshold
        let dx: CGFloat = 0.014
        var x: CGFloat = 0.30

        for _ in 0..<(HandDirectionTracker.historyCapacity + HandDirectionTracker.commitFrames) {
            x += dx
            time += 0.12
            _ = tracker.recordObservation(rawPoint: CGPoint(x: x, y: 0.5), at: time)
        }

        XCTAssertEqual(tracker.direction, .movingForward, "Motion just above thresholds should commit .movingForward")
    }

    func testMotionBelowDisplacementThresholdStaysIdle() {
        var time: CFTimeInterval = 0
        // Move each frame but stay below displacementThreshold over the window.
        // dx per frame = 0.001, window total ≈ 0.004, which is < 0.010 threshold.
        var x: CGFloat = 0.30

        for _ in 0..<8 {
            x += 0.001
            time += 0.05   // faster frames but tiny displacement
            _ = tracker.recordObservation(rawPoint: CGPoint(x: x, y: 0.5), at: time)
        }

        XCTAssertEqual(tracker.direction, .idle, "Motion below displacement threshold should not commit")
    }

    // MARK: - Confidence

    func testConfidenceIsZeroBeforeCommit() {
        // One agreeing frame — pendingCount=1, commitFrames=2, so not yet committed.
        var time: CFTimeInterval = 0
        _ = tracker.recordObservation(rawPoint: CGPoint(x: 0.30, y: 0.5), at: time)
        time += 0.12
        _ = tracker.recordObservation(rawPoint: CGPoint(x: 0.36, y: 0.5), at: time)

        // direction is still .idle (not committed), so confidence must be 0.
        XCTAssertEqual(tracker.confidence, 0, accuracy: 0.001,
                       "Confidence should be 0 when no active direction is committed")
    }

    func testConfidenceReachesOneAfterCommit() {
        var time: CFTimeInterval = 0
        var x: CGFloat = 0.30

        for _ in 0..<5 {
            x += 0.025
            time += 0.12
            _ = tracker.recordObservation(rawPoint: CGPoint(x: x, y: 0.5), at: time)
        }

        XCTAssertEqual(tracker.direction, .movingForward)
        XCTAssertEqual(tracker.confidence, 1.0, accuracy: 0.001,
                       "Confidence should be 1.0 once well past commitFrames")
    }

    func testConfidenceDropsToZeroOnIdle() {
        // Commit forward, then add an idle (stationary) frame to trigger .idle commit.
        var time: CFTimeInterval = 0
        var x: CGFloat = 0.30

        for _ in 0..<5 {
            x += 0.025
            time += 0.12
            _ = tracker.recordObservation(rawPoint: CGPoint(x: x, y: 0.5), at: time)
        }
        XCTAssertEqual(tracker.confidence, 1.0, accuracy: 0.001)

        // Stationary frames → computeRawDirection returns .idle → committed = .idle immediately.
        for _ in 0..<3 {
            time += 0.12
            _ = tracker.recordObservation(rawPoint: CGPoint(x: x, y: 0.5), at: time)
        }

        XCTAssertEqual(tracker.direction, .idle)
        XCTAssertEqual(tracker.confidence, 0, accuracy: 0.001,
                       "Confidence should be 0 once direction commits to .idle")
    }

    // MARK: - Reset

    func testResetClearsAllState() {
        var time: CFTimeInterval = 0
        var x: CGFloat = 0.30

        for _ in 0..<6 {
            x += 0.025
            time += 0.12
            _ = tracker.recordObservation(rawPoint: CGPoint(x: x, y: 0.5), at: time)
        }

        tracker.reset()

        XCTAssertEqual(tracker.direction, .idle)
        XCTAssertEqual(tracker.missedCount, 0)
        XCTAssertEqual(tracker.confidence, 0)
    }
}
