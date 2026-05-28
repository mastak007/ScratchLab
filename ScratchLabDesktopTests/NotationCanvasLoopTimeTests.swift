import XCTest
@testable import ScratchLab

/// Phase-A polish bugfix — locks the contract of
/// `BabyScratchDemoPlaybackCoordinator.notationCanvasLoopTime(for:cycleDuration:)`,
/// the pure helper that maps full demo-audio time onto the notation
/// canvas's own phrase loop so a single-phrase notation tiles across
/// every Baby Scratch repetition.
final class NotationCanvasLoopTimeTests: XCTestCase {

    // MARK: - First phrase / repetition

    func testMapsTimeInsideFirstPhrase() {
        // 0.27 s (first stroke start in baby_scratch.json) lands inside
        // the first phrase and maps to itself.
        let result = BabyScratchDemoPlaybackCoordinator.notationCanvasLoopTime(
            for: 0.27,
            cycleDuration: 5.0687
        )
        XCTAssertEqual(result, 0.27, accuracy: 1e-9)
    }

    func testMapsTimeAtCycleStart() {
        let result = BabyScratchDemoPlaybackCoordinator.notationCanvasLoopTime(
            for: 0,
            cycleDuration: 5.0687
        )
        XCTAssertEqual(result, 0, accuracy: 1e-9)
    }

    func testMapsTimeJustBeforeCycleBoundary() {
        let cycle: TimeInterval = 5.0687
        let result = BabyScratchDemoPlaybackCoordinator.notationCanvasLoopTime(
            for: cycle - 0.001,
            cycleDuration: cycle
        )
        XCTAssertEqual(result, cycle - 0.001, accuracy: 1e-9)
    }

    // MARK: - Later phrase / later repetition

    func testMapsTimeInsideSecondPhrase() {
        // Audio time 6.0 s with a 5.0687 s cycle → 6.0 - 5.0687 = 0.9313.
        let cycle: TimeInterval = 5.0687
        let result = BabyScratchDemoPlaybackCoordinator.notationCanvasLoopTime(
            for: 6.0,
            cycleDuration: cycle
        )
        XCTAssertEqual(result, 6.0 - cycle, accuracy: 1e-9)
    }

    func testMapsTimeInsideMuchLaterRepetition() {
        // Audio time 40.0 s with a 5.0687 s cycle → 7 full cycles
        // consumed (35.4809 s), remainder 4.5191 s.
        let cycle: TimeInterval = 5.0687
        let result = BabyScratchDemoPlaybackCoordinator.notationCanvasLoopTime(
            for: 40.0,
            cycleDuration: cycle
        )
        let expected = 40.0 - cycle * 7
        XCTAssertEqual(result, expected, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(result, 0)
        XCTAssertLessThan(result, cycle)
    }

    func testMapsTimeAtIntegerCycleMultipleWrapsToZero() {
        // Exactly 3 × cycle → wrap remainder is zero.
        let cycle: TimeInterval = 5.0687
        let result = BabyScratchDemoPlaybackCoordinator.notationCanvasLoopTime(
            for: cycle * 3,
            cycleDuration: cycle
        )
        XCTAssertEqual(result, 0, accuracy: 1e-9)
    }

    // MARK: - Wrap correctness across the full audio

    func testWrapStaysInsideCycleAcrossFullDemoDuration() {
        let cycle: TimeInterval = 5.0687
        // Sample every 0.25 s across the bundled audio span. Result must
        // always live inside `[0, cycle)` — never freeze, never go
        // negative, never exceed the cycle.
        var t: TimeInterval = 0
        while t < BabyScratchReferenceMotionTimeline.sourceDuration {
            let mapped = BabyScratchDemoPlaybackCoordinator.notationCanvasLoopTime(
                for: t,
                cycleDuration: cycle
            )
            XCTAssertGreaterThanOrEqual(mapped, 0)
            XCTAssertLessThan(mapped, cycle)
            t += 0.25
        }
    }

    // MARK: - Defensive parameter validation

    func testNonPositiveCycleDurationFallsBackToSafeTime() {
        XCTAssertEqual(
            BabyScratchDemoPlaybackCoordinator.notationCanvasLoopTime(
                for: 1.5, cycleDuration: 0
            ),
            1.5,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            BabyScratchDemoPlaybackCoordinator.notationCanvasLoopTime(
                for: 1.5, cycleDuration: -1
            ),
            1.5,
            accuracy: 1e-9
        )
    }

    func testNonFiniteCycleDurationFallsBackToSafeTime() {
        XCTAssertEqual(
            BabyScratchDemoPlaybackCoordinator.notationCanvasLoopTime(
                for: 1.5, cycleDuration: .nan
            ),
            1.5,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            BabyScratchDemoPlaybackCoordinator.notationCanvasLoopTime(
                for: 1.5, cycleDuration: .infinity
            ),
            1.5,
            accuracy: 1e-9
        )
    }

    func testNonFiniteAudioTimeFallsBackToZero() {
        XCTAssertEqual(
            BabyScratchDemoPlaybackCoordinator.notationCanvasLoopTime(
                for: .nan, cycleDuration: 5.0687
            ),
            0,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            BabyScratchDemoPlaybackCoordinator.notationCanvasLoopTime(
                for: -.infinity, cycleDuration: 5.0687
            ),
            0,
            accuracy: 1e-9
        )
    }

    func testNegativeAudioTimeClampsToZero() {
        XCTAssertEqual(
            BabyScratchDemoPlaybackCoordinator.notationCanvasLoopTime(
                for: -0.5, cycleDuration: 5.0687
            ),
            0,
            accuracy: 1e-9
        )
    }

    // MARK: - Determinism

    func testDeterministicAcrossReruns() {
        let cycle: TimeInterval = 5.0687
        let first = BabyScratchDemoPlaybackCoordinator.notationCanvasLoopTime(
            for: 17.3, cycleDuration: cycle
        )
        for _ in 0..<99 {
            XCTAssertEqual(
                BabyScratchDemoPlaybackCoordinator.notationCanvasLoopTime(
                    for: 17.3, cycleDuration: cycle
                ),
                first
            )
        }
    }
}
