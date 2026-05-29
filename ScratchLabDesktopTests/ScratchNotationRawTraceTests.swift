import XCTest
@testable import ScratchLab

/// Locks the contract of `ScratchNotationRawTrace.build(...)`: pure,
/// deterministic mapping from a list of bundled stroke segments to
/// `ScratchNotationPositionTraceSegment` values that pass the JSON's
/// `startProgress` / `endProgress` through untouched.
///
/// Replaces the duration-proxy `ScratchNotationPositionTrace.derive`
/// path for Baby Scratch. Baby's bundled JSON already encodes every
/// stroke as a full-sample sweep (1 → 0 backward, 0 → 1 forward), so
/// the truthful trace is the raw progress values — not a cursor
/// walked through a calibrated movement rate.
final class ScratchNotationRawTraceTests: XCTestCase {

    // MARK: - Helpers

    private func stroke(
        startTime: TimeInterval,
        endTime: TimeInterval,
        direction: ScratchMotionDirection,
        startProgress: Double,
        endProgress: Double
    ) -> ScratchLabBabyScratchStrokeSegment {
        ScratchLabBabyScratchStrokeSegment(
            startTime: startTime,
            endTime: endTime,
            direction: direction,
            holdAfter: 0,
            startProgress: startProgress,
            endProgress: endProgress
        )
    }

    // MARK: - 1. Raw trace uses JSON start/end progress exactly

    func testRawTraceUsesJsonStartAndEndProgress() {
        let input = [
            stroke(
                startTime: 0.27, endTime: 0.778,
                direction: .backward,
                startProgress: 1.0, endProgress: 0.0
            )
        ]
        let trace = ScratchNotationRawTrace.build(from: input)
        XCTAssertEqual(trace.count, 1)
        XCTAssertEqual(trace[0].startTime, 0.27, accuracy: 1e-9)
        XCTAssertEqual(trace[0].endTime, 0.778, accuracy: 1e-9)
        XCTAssertEqual(trace[0].startPosition, 1.0, accuracy: 1e-9)
        XCTAssertEqual(trace[0].endPosition, 0.0, accuracy: 1e-9)
        XCTAssertEqual(trace[0].direction, .backward)
    }

    // MARK: - 2. Backward 1 → 0 stays 1 → 0

    func testBackwardStrokeStaysAtFullRange() {
        let input = [
            stroke(
                startTime: 0, endTime: 1,
                direction: .backward,
                startProgress: 1.0, endProgress: 0.0
            )
        ]
        let trace = ScratchNotationRawTrace.build(from: input)
        XCTAssertEqual(trace[0].startPosition, 1.0)
        XCTAssertEqual(trace[0].endPosition, 0.0)
    }

    // MARK: - 3. Forward 0 → 1 stays 0 → 1

    func testForwardStrokeStaysAtFullRange() {
        let input = [
            stroke(
                startTime: 0, endTime: 1,
                direction: .forward,
                startProgress: 0.0, endProgress: 1.0
            )
        ]
        let trace = ScratchNotationRawTrace.build(from: input)
        XCTAssertEqual(trace[0].startPosition, 0.0)
        XCTAssertEqual(trace[0].endPosition, 1.0)
    }

    // MARK: - 4. Partial-progress strokes are passed through

    /// Future scratches (or future Baby data) may encode partial
    /// travel. The helper must NOT inject its own rate or clamp the
    /// values — it is a literal pass-through.
    func testPartialProgressIsPassedThrough() {
        let input = [
            stroke(
                startTime: 0, endTime: 0.5,
                direction: .forward,
                startProgress: 0.2, endProgress: 0.7
            )
        ]
        let trace = ScratchNotationRawTrace.build(from: input)
        XCTAssertEqual(trace[0].startPosition, 0.2, accuracy: 1e-9)
        XCTAssertEqual(trace[0].endPosition, 0.7, accuracy: 1e-9)
    }

    // MARK: - 5. Neutral segments are skipped

    func testNeutralSegmentsAreSkipped() {
        let input = [
            stroke(
                startTime: 0, endTime: 0.5,
                direction: .forward,
                startProgress: 0.0, endProgress: 1.0
            ),
            stroke(
                startTime: 0.6, endTime: 1.0,
                direction: .neutral,
                startProgress: 1.0, endProgress: 1.0
            ),
            stroke(
                startTime: 1.1, endTime: 1.6,
                direction: .backward,
                startProgress: 1.0, endProgress: 0.0
            ),
        ]
        let trace = ScratchNotationRawTrace.build(from: input)
        XCTAssertEqual(trace.count, 2)
        XCTAssertEqual(trace[0].direction, .forward)
        XCTAssertEqual(trace[1].direction, .backward)
    }

    // MARK: - 6. Bundled phrase-1 shape reaches both lane boundaries

    /// Locks the win condition: applying the helper to a stroke list
    /// shaped like phrase 1 of `baby_scratch_strokes.json` (every
    /// stroke a full sweep) produces a trace whose positions include
    /// both 0 and 1. That's the property the duration-proxy lost.
    func testBundledShapedPhrase1ReachesBothBoundaries() {
        // Five backward + one forward, the head of bundled phrase 1.
        let input: [ScratchLabBabyScratchStrokeSegment] = [
            stroke(startTime: 0.27, endTime: 0.778, direction: .backward,
                   startProgress: 1.0, endProgress: 0.0),
            stroke(startTime: 1.07, endTime: 1.378, direction: .backward,
                   startProgress: 1.0, endProgress: 0.0),
            stroke(startTime: 2.99, endTime: 3.278, direction: .forward,
                   startProgress: 0.0, endProgress: 1.0),
        ]
        let trace = ScratchNotationRawTrace.build(from: input)
        let positions = trace.flatMap { [$0.startPosition, $0.endPosition] }
        XCTAssertTrue(positions.contains(0.0), "expected at least one vertex at lane bottom")
        XCTAssertTrue(positions.contains(1.0), "expected at least one vertex at lane top")
    }

    // MARK: - 7. Determinism

    func testDeterministicAcrossReruns() {
        let input = [
            stroke(startTime: 0, endTime: 0.5, direction: .backward,
                   startProgress: 1.0, endProgress: 0.0),
            stroke(startTime: 0.6, endTime: 0.9, direction: .forward,
                   startProgress: 0.0, endProgress: 1.0),
        ]
        let first = ScratchNotationRawTrace.build(from: input)
        for _ in 0..<99 {
            XCTAssertEqual(ScratchNotationRawTrace.build(from: input), first)
        }
    }

    // MARK: - 8. Empty input

    func testEmptyInputProducesEmptyTrace() {
        XCTAssertTrue(ScratchNotationRawTrace.build(from: []).isEmpty)
    }
}
