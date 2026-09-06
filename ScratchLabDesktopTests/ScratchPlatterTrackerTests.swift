import XCTest
@testable import ScratchLab

/// Platter CC6 ring-counter tracker tests.
/// Verifies wrap detection, dual-deck isolation, direction, idle behaviour.
/// Platter channels: 0 = left, 1 = right (NOT 4/5 — those are pad channels).
final class ScratchPlatterTrackerTests: XCTestCase {

    // MARK: - Signed sample-position projection

    func testSampleProjectionKeepsBackwardTravelBeforeStartWithoutWrapping() {
        let projection = PlatterSamplePositionProjection.resolve(
            framePosition: -4_800,
            contentFrameCount: 48_000,
            sampleRate: 48_000
        )

        XCTAssertEqual(projection.region, .beforeStart)
        XCTAssertEqual(projection.positionSeconds, -0.1, accuracy: 1e-12)
        XCTAssertEqual(projection.progress, 0, accuracy: 1e-12)
    }

    func testSampleProjectionKeepsCueDeadbandAndInRangeRegionsDeterministic() {
        let cue = PlatterSamplePositionProjection.resolve(
            framePosition: -240,
            contentFrameCount: 48_000,
            sampleRate: 48_000
        )
        let start = PlatterSamplePositionProjection.resolve(
            framePosition: 12_000,
            contentFrameCount: 48_000,
            sampleRate: 48_000
        )
        let middle = PlatterSamplePositionProjection.resolve(
            framePosition: 24_000,
            contentFrameCount: 48_000,
            sampleRate: 48_000
        )
        let end = PlatterSamplePositionProjection.resolve(
            framePosition: 40_000,
            contentFrameCount: 48_000,
            sampleRate: 48_000
        )

        XCTAssertEqual(cue.region, .cue)
        XCTAssertEqual(start.region, .start)
        XCTAssertEqual(middle.region, .middle)
        XCTAssertEqual(end.region, .end)
    }

    func testSampleProjectionKeepsPastEndTravelAtRightBoundary() {
        let projection = PlatterSamplePositionProjection.resolve(
            framePosition: 52_800,
            contentFrameCount: 48_000,
            sampleRate: 48_000
        )

        XCTAssertEqual(projection.region, .pastEnd)
        XCTAssertEqual(projection.positionSeconds, 1.1, accuracy: 1e-12)
        XCTAssertEqual(projection.pastEndOvershootSeconds, 0.1, accuracy: 1e-12)
        XCTAssertEqual(projection.progress, 1, accuracy: 1e-12)
    }

    func testSampleProjectionRejectsInvalidMetadataWithoutFabricatingPosition() {
        let projection = PlatterSamplePositionProjection.resolve(
            framePosition: .nan,
            contentFrameCount: 0,
            sampleRate: 0
        )

        XCTAssertEqual(projection.region, .unloaded)
        XCTAssertEqual(projection.positionSeconds, 0)
        XCTAssertEqual(projection.progress, 0)
    }

    // MARK: - Wrap detection

    func testForwardWrap127To0() {
        let tracker = ScratchPlatterTracker()
        _ = tracker.ingest(channel: 0, value: 127)
        let delta = tracker.ingest(channel: 0, value: 0)
        XCTAssertEqual(delta, 1, "127→0 must unwrap to +1")
    }

    func testBackwardWrap0To127() {
        let tracker = ScratchPlatterTracker()
        _ = tracker.ingest(channel: 0, value: 0)
        let delta = tracker.ingest(channel: 0, value: 127)
        XCTAssertEqual(delta, -1, "0→127 must unwrap to -1")
    }

    func testSmallForwardNoWrap() {
        let tracker = ScratchPlatterTracker()
        _ = tracker.ingest(channel: 0, value: 50)
        let delta = tracker.ingest(channel: 0, value: 51)
        XCTAssertEqual(delta, 1, "50→51 is +1, no wrap")
    }

    func testSmallBackwardNoWrap() {
        let tracker = ScratchPlatterTracker()
        _ = tracker.ingest(channel: 0, value: 51)
        let delta = tracker.ingest(channel: 0, value: 50)
        XCTAssertEqual(delta, -1, "51→50 is -1, no wrap")
    }

    // MARK: - Accumulation

    func testAccumulatedStepsIncrease() {
        let tracker = ScratchPlatterTracker()
        _ = tracker.ingest(channel: 0, value: 0)
        for v in 1...10 {
            _ = tracker.ingest(channel: 0, value: v)
        }
        XCTAssertEqual(tracker.accumulatedSteps(for: 0), 10)
    }

    func testAccumulatedStepsDecrease() {
        let tracker = ScratchPlatterTracker()
        _ = tracker.ingest(channel: 0, value: 10)
        for v in (0..<10).reversed() {
            _ = tracker.ingest(channel: 0, value: v)
        }
        XCTAssertEqual(tracker.accumulatedSteps(for: 0), -10)
    }

    func testAccumulatedStepsWithWrap() {
        let tracker = ScratchPlatterTracker()
        _ = tracker.ingest(channel: 0, value: 126)
        _ = tracker.ingest(channel: 0, value: 127)
        _ = tracker.ingest(channel: 0, value: 0)   // +1 unwrapped
        _ = tracker.ingest(channel: 0, value: 1)    // +1
        XCTAssertEqual(tracker.accumulatedSteps(for: 0), 3)
    }

    // MARK: - Dual-deck isolation (ch=0 left, ch=1 right)

    func testLeftAndRightDecksAreIndependent() {
        let tracker = ScratchPlatterTracker()
        _ = tracker.ingest(channel: 0, value: 0)
        _ = tracker.ingest(channel: 1, value: 0)

        for _ in 0..<5 { _ = tracker.ingest(channel: 0, value: 5) }
        for _ in 0..<3 { _ = tracker.ingest(channel: 1, value: 3) }

        // After first event, subsequent moves depend on actual deltas.
        // Verify the accumulators are independent.
        let left = tracker.accumulatedSteps(for: 0)
        let right = tracker.accumulatedSteps(for: 1)
        XCTAssertNotEqual(left, right, "Left and right decks must accumulate independently")
    }

    func testLeftDeckDoesNotAffectRightDeck() {
        let tracker = ScratchPlatterTracker()
        _ = tracker.ingest(channel: 1, value: 50)
        _ = tracker.ingest(channel: 1, value: 60)
        let rightBefore = tracker.accumulatedSteps(for: 1)

        // Move left deck.
        _ = tracker.ingest(channel: 0, value: 0)
        for _ in 0..<10 { _ = tracker.ingest(channel: 0, value: 10) }

        let rightAfter = tracker.accumulatedSteps(for: 1)
        XCTAssertEqual(rightBefore, rightAfter, "Left deck events must not affect right deck")
    }

    // MARK: - Non-platter channels ignored

    func testNonPlatterChannelReturnsNil() {
        let tracker = ScratchPlatterTracker()
        // Pad channels 4 and 5 must NOT ingest as platter.
        XCTAssertNil(tracker.ingest(channel: 4, value: 50),
            "ch=4 is a pad channel, not a platter channel")
        XCTAssertNil(tracker.ingest(channel: 5, value: 50),
            "ch=5 is a pad channel, not a platter channel")
        XCTAssertNil(tracker.ingest(channel: 3, value: 50))
        XCTAssertNil(tracker.ingest(channel: 6, value: 50))
        XCTAssertNil(tracker.ingest(channel: 15, value: 50))
    }

    func testPadChannelDoesNotAffectAccumulator() {
        let tracker = ScratchPlatterTracker()
        _ = tracker.ingest(channel: 0, value: 50)
        _ = tracker.ingest(channel: 0, value: 55)
        let before = tracker.accumulatedSteps(for: 0)
        // Feed pad channels — must not affect platter accumulator.
        _ = tracker.ingest(channel: 4, value: 50)
        _ = tracker.ingest(channel: 5, value: 60)
        XCTAssertEqual(tracker.accumulatedSteps(for: 0), before,
            "Pad channel events must not affect platter accumulator")
    }

    // MARK: - Direction

    func testForwardDirection() {
        let tracker = ScratchPlatterTracker()
        _ = tracker.ingest(channel: 0, value: 50)
        for v in 51...65 { _ = tracker.ingest(channel: 0, value: v) }
        XCTAssertEqual(tracker.recentDirection(for: 0), .forward)
    }

    func testBackwardDirection() {
        let tracker = ScratchPlatterTracker()
        _ = tracker.ingest(channel: 0, value: 65)
        for v in (50..<65).reversed() { _ = tracker.ingest(channel: 0, value: v) }
        XCTAssertEqual(tracker.recentDirection(for: 0), .backward)
    }

    func testDirectionNilForNoEvents() {
        let tracker = ScratchPlatterTracker()
        XCTAssertNil(tracker.recentDirection(for: 0))
    }

    // MARK: - Velocity

    func testRecentVelocityPositiveWhenMoving() {
        let tracker = ScratchPlatterTracker()
        _ = tracker.ingest(channel: 0, value: 50)
        for v in 51...60 { _ = tracker.ingest(channel: 0, value: v) }
        let velocity = tracker.recentVelocity(for: 0)
        XCTAssertGreaterThan(velocity, 0, "Velocity must be positive while moving forward")
    }

    func testRecentVelocityZeroForIdle() {
        let tracker = ScratchPlatterTracker()
        _ = tracker.ingest(channel: 0, value: 50)
        _ = tracker.ingest(channel: 0, value: 50) // same value, delta=0
        // Direction may or may not be nil with all zeros; velocity should be 0
        let velocity = tracker.recentVelocity(for: 0)
        XCTAssertEqual(velocity, 0, "Velocity must be zero when deltas are all zero")
    }

    // MARK: - hasReceivedEvents

    func testHasReceivedEventsFalseInitially() {
        let tracker = ScratchPlatterTracker()
        XCTAssertFalse(tracker.hasReceivedEvents(for: 0))
        XCTAssertFalse(tracker.hasReceivedEvents(for: 1))
    }

    func testHasReceivedEventsTrueAfterIngest() {
        let tracker = ScratchPlatterTracker()
        _ = tracker.ingest(channel: 0, value: 50)
        XCTAssertTrue(tracker.hasReceivedEvents(for: 0))
        XCTAssertFalse(tracker.hasReceivedEvents(for: 1))
    }

    // MARK: - Reset

    func testResetClearsAccumulator() {
        let tracker = ScratchPlatterTracker()
        _ = tracker.ingest(channel: 0, value: 0)
        for _ in 0..<5 { _ = tracker.ingest(channel: 0, value: 5) }
        tracker.reset(channel: 0)
        XCTAssertEqual(tracker.accumulatedSteps(for: 0), 0)
        XCTAssertFalse(tracker.hasReceivedEvents(for: 0))
    }

    func testResetAllClearsBothDecks() {
        let tracker = ScratchPlatterTracker()
        _ = tracker.ingest(channel: 0, value: 0)
        _ = tracker.ingest(channel: 1, value: 0)
        tracker.reset()
        XCTAssertEqual(tracker.accumulatedSteps(for: 0), 0)
        XCTAssertEqual(tracker.accumulatedSteps(for: 1), 0)
    }

    // MARK: - Thread safety (basic smoke)

    func testConcurrentIngestDoesNotCrash() {
        let tracker = ScratchPlatterTracker()
        let group = DispatchGroup()
        for _ in 0..<4 {
            group.enter()
            DispatchQueue.global().async {
                for v in 0..<1000 {
                    _ = tracker.ingest(channel: 0, value: v % 128)
                }
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + 5)
        // Reaching here without crash is the assertion.
        XCTAssertTrue(true, "Concurrent ingest must not crash")
    }
}
