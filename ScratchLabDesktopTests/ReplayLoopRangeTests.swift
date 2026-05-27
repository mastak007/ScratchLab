import XCTest
@testable import ScratchLab

/// Phase D-A1 — locks the contract of `ReplayLoopRange` /
/// `ReplayPlaybackRate`: pure value types, deterministic, no clock,
/// no UI.
final class ReplayLoopRangeTests: XCTestCase {

    // MARK: - Construction invariants

    func testRejectsInvalidRanges() {
        XCTAssertNil(ReplayLoopRange(startTime: 0, endTime: 0))
        XCTAssertNil(ReplayLoopRange(startTime: 1, endTime: 0.5))
        XCTAssertNil(ReplayLoopRange(startTime: .nan, endTime: 1))
        XCTAssertNil(ReplayLoopRange(startTime: 0, endTime: .infinity))
        XCTAssertNil(ReplayLoopRange(startTime: -.infinity, endTime: 0))
    }

    func testAcceptsValidRange() {
        let range = ReplayLoopRange(startTime: 0.5, endTime: 4.5)
        XCTAssertNotNil(range)
        XCTAssertEqual(range?.duration, 4.0)
    }

    // MARK: - Clamp

    func testClampInsideRange() {
        let range = ReplayLoopRange(startTime: 1.0, endTime: 3.0)!
        XCTAssertEqual(range.clamp(2.0), 2.0)
    }

    func testClampBelowRange() {
        let range = ReplayLoopRange(startTime: 1.0, endTime: 3.0)!
        XCTAssertEqual(range.clamp(0.5), 1.0)
    }

    func testClampAboveRange() {
        let range = ReplayLoopRange(startTime: 1.0, endTime: 3.0)!
        XCTAssertEqual(range.clamp(5.0), 3.0)
    }

    func testClampNonFinite() {
        let range = ReplayLoopRange(startTime: 1.0, endTime: 3.0)!
        XCTAssertEqual(range.clamp(.nan), 1.0)
    }

    // MARK: - Advance

    func testAdvanceWithinRange() {
        let range = ReplayLoopRange(startTime: 0, endTime: 4)!
        XCTAssertEqual(range.advance(from: 1, by: 1), 2)
    }

    func testAdvanceWrapsAtBoundary() {
        // Delta lands exactly on endTime → wraps to startTime since
        // endTime is exclusive of the playhead.
        let range = ReplayLoopRange(startTime: 0, endTime: 4)!
        XCTAssertEqual(range.advance(from: 3.5, by: 0.5), 0)
    }

    func testAdvanceWrapsBeyondEnd() {
        let range = ReplayLoopRange(startTime: 0, endTime: 4)!
        // Advancing from 3.5 by 1.0 → would land at 4.5; wraps into 0.5.
        XCTAssertEqual(range.advance(from: 3.5, by: 1.0), 0.5, accuracy: 1e-9)
    }

    func testAdvanceWrapsOverMultipleSpans() {
        let range = ReplayLoopRange(startTime: 0, endTime: 2)!
        // Advancing 5 over a 2-second range → ends at 1.0
        // (5 % 2 = 1).
        XCTAssertEqual(range.advance(from: 0, by: 5), 1.0, accuracy: 1e-9)
    }

    func testAdvanceRejectsNegativeDelta() {
        let range = ReplayLoopRange(startTime: 0, endTime: 4)!
        XCTAssertEqual(range.advance(from: 2, by: -1), 2)
    }

    func testAdvanceRejectsNonFiniteDelta() {
        let range = ReplayLoopRange(startTime: 0, endTime: 4)!
        XCTAssertEqual(range.advance(from: 2, by: .nan), 2)
    }

    func testAdvanceClampsTimeBeforeStart() {
        let range = ReplayLoopRange(startTime: 1, endTime: 3)!
        XCTAssertEqual(range.advance(from: 0.5, by: 0.5), 1.5)
    }

    // MARK: - Determinism

    func testAdvanceDeterministic() {
        let range = ReplayLoopRange(startTime: 0, endTime: 3)!
        let first = range.advance(from: 1.0, by: 0.75)
        for _ in 0..<99 {
            XCTAssertEqual(range.advance(from: 1.0, by: 0.75), first)
        }
    }

    // MARK: - ReplayPlaybackRate

    func testPlaybackRateValues() {
        XCTAssertEqual(ReplayPlaybackRate.quarter.rawValue, 0.25)
        XCTAssertEqual(ReplayPlaybackRate.half.rawValue, 0.5)
        XCTAssertEqual(ReplayPlaybackRate.threeQuarter.rawValue, 0.75)
        XCTAssertEqual(ReplayPlaybackRate.normal.rawValue, 1.0)
    }

    func testPlaybackRateAllCasesOrdered() {
        let all = ReplayPlaybackRate.allCases.map(\.rawValue)
        XCTAssertEqual(all, all.sorted())
    }
}
