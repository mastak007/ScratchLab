import XCTest
@testable import ScratchLab

/// Phase B1 production-wiring slice — locks the contract of
/// `LaneJudgment.from(beatOffsetMilliseconds:isOnBeat:)`: pure,
/// deterministic, presentation-only. No coaching semantics, no
/// scoring effect.
final class LaneJudgmentTests: XCTestCase {

    // MARK: - isOnBeat short-circuit

    func testOnBeatWinsRegardlessOfOffset() {
        // Upstream `isOnBeat == true` means the audio pipeline has
        // already accepted this hit as inside the window. The
        // presentation layer mirrors that verdict even when the
        // numeric offset would otherwise be marginal.
        XCTAssertEqual(
            LaneJudgment.from(beatOffsetMilliseconds: 0, isOnBeat: true),
            .onBeat
        )
        XCTAssertEqual(
            LaneJudgment.from(beatOffsetMilliseconds: 150, isOnBeat: true),
            .onBeat
        )
        XCTAssertEqual(
            LaneJudgment.from(beatOffsetMilliseconds: -150, isOnBeat: true),
            .onBeat
        )
    }

    // MARK: - Numeric thresholds

    func testInsideWindowMapsToOnBeat() {
        XCTAssertEqual(
            LaneJudgment.from(beatOffsetMilliseconds: 50, isOnBeat: false),
            .onBeat
        )
        XCTAssertEqual(
            LaneJudgment.from(beatOffsetMilliseconds: -50, isOnBeat: false),
            .onBeat
        )
    }

    func testAtBoundaryStillCountsAsOnBeat() {
        // Boundary is strict less-than threshold — exactly 80 ms in
        // either direction is still inside the window.
        XCTAssertEqual(
            LaneJudgment.from(beatOffsetMilliseconds: 80, isOnBeat: false),
            .onBeat
        )
        XCTAssertEqual(
            LaneJudgment.from(beatOffsetMilliseconds: -80, isOnBeat: false),
            .onBeat
        )
    }

    func testJustBeyondLateBoundaryMapsToLate() {
        XCTAssertEqual(
            LaneJudgment.from(beatOffsetMilliseconds: 80.1, isOnBeat: false),
            .late
        )
    }

    func testJustBeyondEarlyBoundaryMapsToEarly() {
        XCTAssertEqual(
            LaneJudgment.from(beatOffsetMilliseconds: -80.1, isOnBeat: false),
            .early
        )
    }

    func testVeryLateMapsToLate() {
        XCTAssertEqual(
            LaneJudgment.from(beatOffsetMilliseconds: 250, isOnBeat: false),
            .late
        )
    }

    func testVeryEarlyMapsToEarly() {
        XCTAssertEqual(
            LaneJudgment.from(beatOffsetMilliseconds: -250, isOnBeat: false),
            .early
        )
    }

    // MARK: - Defensive parameter validation

    func testNonFiniteOffsetMapsToNeutral() {
        XCTAssertEqual(
            LaneJudgment.from(beatOffsetMilliseconds: .nan, isOnBeat: false),
            .neutral
        )
        XCTAssertEqual(
            LaneJudgment.from(beatOffsetMilliseconds: .infinity, isOnBeat: false),
            .neutral
        )
        XCTAssertEqual(
            LaneJudgment.from(beatOffsetMilliseconds: -.infinity, isOnBeat: false),
            .neutral
        )
    }

    func testNonFiniteOffsetMapsToNeutralEvenWhenIsOnBeat() {
        // Upstream guarantee: a non-finite offset shouldn't reach the
        // lane in the first place. If it does, the presentation layer
        // refuses to assert anything — neutral wins even over
        // isOnBeat.
        XCTAssertEqual(
            LaneJudgment.from(beatOffsetMilliseconds: .nan, isOnBeat: true),
            .neutral
        )
    }

    // MARK: - Determinism

    func testDeterministicAcrossReruns() {
        let first = LaneJudgment.from(beatOffsetMilliseconds: 142.5, isOnBeat: false)
        for _ in 0..<99 {
            XCTAssertEqual(
                LaneJudgment.from(beatOffsetMilliseconds: 142.5, isOnBeat: false),
                first
            )
        }
    }
}
