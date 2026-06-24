import XCTest
@testable import ScratchLab

/// Platter CC6 ring-counter tracker tests.
/// Verifies wrap detection, dual-deck isolation, direction, idle behaviour.
final class ScratchPlatterTrackerTests: XCTestCase {

    // MARK: - Wrap detection

    func testForwardWrap127To0() {
        let tracker = ScratchPlatterTracker()
        _ = tracker.ingest(channel: 4, value: 127)
        let delta = tracker.ingest(channel: 4, value: 0)
        XCTAssertEqual(delta, 1, "127→0 must unwrap to +1")
    }

    func testBackwardWrap0To127() {
        let tracker = ScratchPlatterTracker()
        _ = tracker.ingest(channel: 4, value: 0)
        let delta = tracker.ingest(channel: 4, value: 127)
        XCTAssertEqual(delta, -1, "0→127 must unwrap to -1")
    }

    func testSmallForwardNoWrap() {
        let tracker = ScratchPlatterTracker()
        _ = tracker.ingest(channel: 4, value: 50)
        let delta = tracker.ingest(channel: 4, value: 51)
        XCTAssertEqual(delta, 1, "50→51 is +1, no wrap")
    }

    func testSmallBackwardNoWrap() {
        let tracker = ScratchPlatterTracker()
        _ = tracker.ingest(channel: 4, value: 51)
        let delta = tracker.ingest(channel: 4, value: 50)
        XCTAssertEqual(delta, -1, "51→50 is -1, no wrap")
    }

    // MARK: - Accumulation

    func testAccumulatedStepsIncrease() {
        let tracker = ScratchPlatterTracker()
        _ = tracker.ingest(channel: 4, value: 0)
        for v in 1...10 {
            _ = tracker.ingest(channel: 4, value: v)
        }
        XCTAssertEqual(tracker.accumulatedSteps(for: 4), 10)
    }

    func testAccumulatedStepsDecrease() {
        let tracker = ScratchPlatterTracker()
        _ = tracker.ingest(channel: 4, value: 10)
        for v in (0..<10).reversed() {
            _ = tracker.ingest(channel: 4, value: v)
        }
        XCTAssertEqual(tracker.accumulatedSteps(for: 4), -10)
    }

    func testAccumulatedStepsWithWrap() {
        let tracker = ScratchPlatterTracker()
        _ = tracker.ingest(channel: 4, value: 126)
        _ = tracker.ingest(channel: 4, value: 127)
        _ = tracker.ingest(channel: 4, value: 0)   // +1 unwrapped
        _ = tracker.ingest(channel: 4, value: 1)    // +1
        XCTAssertEqual(tracker.accumulatedSteps(for: 4), 3)
    }

    // MARK: - Dual-deck isolation

    func testLeftAndRightDecksAreIndependent() {
        let tracker = ScratchPlatterTracker()
        _ = tracker.ingest(channel: 4, value: 0)
        _ = tracker.ingest(channel: 5, value: 0)

        for _ in 0..<5 { _ = tracker.ingest(channel: 4, value: 5) }
        for _ in 0..<3 { _ = tracker.ingest(channel: 5, value: 3) }

        // After first event, subsequent moves depend on actual deltas.
        // Verify the accumulators are independent.
        let left = tracker.accumulatedSteps(for: 4)
        let right = tracker.accumulatedSteps(for: 5)
        XCTAssertNotEqual(left, right, "Left and right decks must accumulate independently")
    }

    func testLeftDeckDoesNotAffectRightDeck() {
        let tracker = ScratchPlatterTracker()
        _ = tracker.ingest(channel: 5, value: 50)
        _ = tracker.ingest(channel: 5, value: 60)
        let rightBefore = tracker.accumulatedSteps(for: 5)

        // Move left deck.
        _ = tracker.ingest(channel: 4, value: 0)
        for _ in 0..<10 { _ = tracker.ingest(channel: 4, value: 10) }

        let rightAfter = tracker.accumulatedSteps(for: 5)
        XCTAssertEqual(rightBefore, rightAfter, "Left deck events must not affect right deck")
    }

    // MARK: - Non-platter channels ignored

    func testNonPlatterChannelReturnsNil() {
        let tracker = ScratchPlatterTracker()
        XCTAssertNil(tracker.ingest(channel: 0, value: 50))
        XCTAssertNil(tracker.ingest(channel: 1, value: 50))
        XCTAssertNil(tracker.ingest(channel: 3, value: 50))
        XCTAssertNil(tracker.ingest(channel: 6, value: 50))
        XCTAssertNil(tracker.ingest(channel: 15, value: 50))
    }

    func testNonPlatterChannelDoesNotAffectAccumulator() {
        let tracker = ScratchPlatterTracker()
        _ = tracker.ingest(channel: 4, value: 50)
        _ = tracker.ingest(channel: 4, value: 55)
        let before = tracker.accumulatedSteps(for: 4)
        _ = tracker.ingest(channel: 0, value: 50)
        XCTAssertEqual(tracker.accumulatedSteps(for: 4), before)
    }

    // MARK: - Direction

    func testForwardDirection() {
        let tracker = ScratchPlatterTracker()
        _ = tracker.ingest(channel: 4, value: 50)
        for v in 51...65 { _ = tracker.ingest(channel: 4, value: v) }
        XCTAssertEqual(tracker.recentDirection(for: 4), .forward)
    }

    func testBackwardDirection() {
        let tracker = ScratchPlatterTracker()
        _ = tracker.ingest(channel: 4, value: 65)
        for v in (50..<65).reversed() { _ = tracker.ingest(channel: 4, value: v) }
        XCTAssertEqual(tracker.recentDirection(for: 4), .backward)
    }

    func testDirectionNilForNoEvents() {
        let tracker = ScratchPlatterTracker()
        XCTAssertNil(tracker.recentDirection(for: 4))
    }

    // MARK: - Velocity

    func testRecentVelocityPositiveWhenMoving() {
        let tracker = ScratchPlatterTracker()
        _ = tracker.ingest(channel: 4, value: 50)
        for v in 51...60 { _ = tracker.ingest(channel: 4, value: v) }
        let velocity = tracker.recentVelocity(for: 4)
        XCTAssertGreaterThan(velocity, 0, "Velocity must be positive while moving forward")
    }

    func testRecentVelocityZeroForIdle() {
        let tracker = ScratchPlatterTracker()
        _ = tracker.ingest(channel: 4, value: 50)
        _ = tracker.ingest(channel: 4, value: 50) // same value, delta=0
        // Direction may or may not be nil with all zeros; velocity should be 0
        let velocity = tracker.recentVelocity(for: 4)
        XCTAssertEqual(velocity, 0, "Velocity must be zero when deltas are all zero")
    }

    // MARK: - hasReceivedEvents

    func testHasReceivedEventsFalseInitially() {
        let tracker = ScratchPlatterTracker()
        XCTAssertFalse(tracker.hasReceivedEvents(for: 4))
        XCTAssertFalse(tracker.hasReceivedEvents(for: 5))
    }

    func testHasReceivedEventsTrueAfterIngest() {
        let tracker = ScratchPlatterTracker()
        _ = tracker.ingest(channel: 4, value: 50)
        XCTAssertTrue(tracker.hasReceivedEvents(for: 4))
        XCTAssertFalse(tracker.hasReceivedEvents(for: 5))
    }

    // MARK: - Reset

    func testResetClearsAccumulator() {
        let tracker = ScratchPlatterTracker()
        _ = tracker.ingest(channel: 4, value: 0)
        for _ in 0..<5 { _ = tracker.ingest(channel: 4, value: 5) }
        tracker.reset(channel: 4)
        XCTAssertEqual(tracker.accumulatedSteps(for: 4), 0)
        XCTAssertFalse(tracker.hasReceivedEvents(for: 4))
    }

    func testResetAllClearsBothDecks() {
        let tracker = ScratchPlatterTracker()
        _ = tracker.ingest(channel: 4, value: 0)
        _ = tracker.ingest(channel: 5, value: 0)
        tracker.reset()
        XCTAssertEqual(tracker.accumulatedSteps(for: 4), 0)
        XCTAssertEqual(tracker.accumulatedSteps(for: 5), 0)
    }

    // MARK: - Thread safety (basic smoke)

    func testConcurrentIngestDoesNotCrash() {
        let tracker = ScratchPlatterTracker()
        let group = DispatchGroup()
        for _ in 0..<4 {
            group.enter()
            DispatchQueue.global().async {
                for v in 0..<1000 {
                    _ = tracker.ingest(channel: 4, value: v % 128)
                }
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + 5)
        // Reaching here without crash is the assertion.
        XCTAssertTrue(true, "Concurrent ingest must not crash")
    }
}
