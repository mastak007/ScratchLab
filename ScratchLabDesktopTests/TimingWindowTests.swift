import XCTest
@testable import ScratchLab

/// Section 2 / Slice 3 — locks the contract of `TimingWindow`,
/// `TimingDrift`, and `TimingWindowEvaluator.evaluate(...)`. Pure
/// timing-evaluation math with no grid, capture, replay, scoring, or
/// UI coupling.
///
/// Synthetic, deterministic inputs only. The fixture-backed suite is
/// not touched in this slice — the evaluator works on absolute seconds
/// independent of musical metadata.
final class TimingWindowTests: XCTestCase {

    // MARK: - Primitive helpers

    private func makeForwardSegment(start: TimeInterval, end: TimeInterval) -> NotationPrimitive {
        .directionSegment(DirectionSegment(direction: .forward,
                                            startTime: start,
                                            endTime: end,
                                            startPosition: 0.0,
                                            endPosition: 1.0,
                                            minimumConfidence: 1.0))
    }

    private func makeReversal(time: TimeInterval) -> NotationPrimitive {
        .reversal(Reversal(kind: .cusp,
                            time: time,
                            position: 0.5,
                            minimumConfidence: 1.0))
    }

    private func makeIdleHold(start: TimeInterval, end: TimeInterval) -> NotationPrimitive {
        .idleHold(IdleHold(startTime: start,
                            endTime: end,
                            positionLow: 0.4,
                            positionHigh: 0.5,
                            minimumConfidence: 1.0))
    }

    // MARK: - 1. TimingWindow constructor rejects invalid tolerances

    func testTimingWindowConstructorRejectsInvalidTolerances() {
        XCTAssertNil(TimingWindow(earlyTolerance: -0.01, lateTolerance: 0.05))
        XCTAssertNil(TimingWindow(earlyTolerance: 0.05, lateTolerance: -0.01))
        XCTAssertNil(TimingWindow(earlyTolerance: .nan, lateTolerance: 0.05))
        XCTAssertNil(TimingWindow(earlyTolerance: 0.05, lateTolerance: .nan))
        XCTAssertNil(TimingWindow(earlyTolerance: .infinity, lateTolerance: 0.05))
        XCTAssertNil(TimingWindow(earlyTolerance: 0.05, lateTolerance: .infinity))
        XCTAssertNotNil(TimingWindow(earlyTolerance: 0, lateTolerance: 0))
        XCTAssertNotNil(TimingWindow(earlyTolerance: 0.05, lateTolerance: 0.05))
    }

    // MARK: - 2. Symmetric window contains zero and both boundaries

    func testSymmetricWindowContainsZeroAndBoundaries() {
        let window = TimingWindow(earlyTolerance: 0.05, lateTolerance: 0.05)!
        XCTAssertTrue(window.contains(drift: 0))
        XCTAssertTrue(window.contains(drift: -0.05))
        XCTAssertTrue(window.contains(drift: 0.05))
    }

    // MARK: - 3. Symmetric window rejects just outside boundaries

    func testSymmetricWindowRejectsJustOutsideBoundaries() {
        let window = TimingWindow(earlyTolerance: 0.05, lateTolerance: 0.05)!
        XCTAssertFalse(window.contains(drift: -0.050001))
        XCTAssertFalse(window.contains(drift: 0.050001))
        XCTAssertFalse(window.contains(drift: -1.0))
        XCTAssertFalse(window.contains(drift: 1.0))
    }

    // MARK: - 4. Asymmetric window behaves correctly

    func testAsymmetricWindow() {
        // tight on the early side, loose on the late side
        let window = TimingWindow(earlyTolerance: 0.01, lateTolerance: 0.10)!
        XCTAssertTrue(window.contains(drift: 0))
        XCTAssertTrue(window.contains(drift: -0.01))    // early boundary
        XCTAssertFalse(window.contains(drift: -0.011))  // just past early
        XCTAssertTrue(window.contains(drift: 0.10))     // late boundary
        XCTAssertFalse(window.contains(drift: 0.101))   // just past late
        XCTAssertTrue(window.contains(drift: 0.05))     // well inside late
    }

    // MARK: - 5. Evaluator returns empty for empty annotations

    func testEvaluatorReturnsEmptyForEmptyAnnotations() {
        let window = TimingWindow(earlyTolerance: 0.05, lateTolerance: 0.05)!
        let drifts = TimingWindowEvaluator.evaluate(
            annotations: [],
            primitives: [makeForwardSegment(start: 0, end: 1)],
            expectedStartTimes: [0: 0.0],
            window: window
        )
        XCTAssertEqual(drifts.count, 0)
    }

    // MARK: - 6. Evaluator preserves annotation order

    func testEvaluatorPreservesAnnotationOrder() {
        let window = TimingWindow(earlyTolerance: 0.05, lateTolerance: 0.05)!
        let grid = TimingGrid(beatsPerMinute: 120,
                              beatsPerBar: 4,
                              subdivisionsPerBeat: 4,
                              origin: 0)!
        let primitives: [NotationPrimitive] = [
            makeForwardSegment(start: 0.0, end: 0.5),
            makeForwardSegment(start: 0.5, end: 1.0),
            makeForwardSegment(start: 1.0, end: 1.5),
            makeForwardSegment(start: 1.5, end: 2.0),
        ]
        let annotations = GridAnnotationMapper.annotate(primitives: primitives, using: grid)
        let expected: [Int: TimeInterval] = [0: 0.0, 1: 0.5, 2: 1.0, 3: 1.5]
        let drifts = TimingWindowEvaluator.evaluate(
            annotations: annotations,
            primitives: primitives,
            expectedStartTimes: expected,
            window: window
        )
        XCTAssertEqual(drifts.count, 4)
        XCTAssertEqual(drifts.map(\.primitiveIndex), [0, 1, 2, 3])
    }

    // MARK: - 7. Evaluator computes positive and negative drift correctly

    func testEvaluatorComputesPositiveAndNegativeDrift() {
        let window = TimingWindow(earlyTolerance: 1.0, lateTolerance: 1.0)!
        // primitive[0]: actual = 0.10, expected = 0.00 → drift = +0.10 (late)
        // primitive[1]: actual = 0.45, expected = 0.50 → drift = -0.05 (early)
        // primitive[2]: actual = 1.00, expected = 1.00 → drift =  0    (on)
        let primitives: [NotationPrimitive] = [
            makeForwardSegment(start: 0.10, end: 0.20),
            makeForwardSegment(start: 0.45, end: 0.55),
            makeForwardSegment(start: 1.00, end: 1.10),
        ]
        let annotations: [GridAnnotation] = [
            GridAnnotation(primitiveIndex: 0,
                            start: GridPosition(bar: 0, beat: 0, subdivision: 0, subdivisionPhase: 0),
                            end:   GridPosition(bar: 0, beat: 0, subdivision: 0, subdivisionPhase: 0)),
            GridAnnotation(primitiveIndex: 1,
                            start: GridPosition(bar: 0, beat: 0, subdivision: 0, subdivisionPhase: 0),
                            end:   GridPosition(bar: 0, beat: 0, subdivision: 0, subdivisionPhase: 0)),
            GridAnnotation(primitiveIndex: 2,
                            start: GridPosition(bar: 0, beat: 0, subdivision: 0, subdivisionPhase: 0),
                            end:   GridPosition(bar: 0, beat: 0, subdivision: 0, subdivisionPhase: 0)),
        ]
        let drifts = TimingWindowEvaluator.evaluate(
            annotations: annotations,
            primitives: primitives,
            expectedStartTimes: [0: 0.0, 1: 0.5, 2: 1.0],
            window: window
        )
        XCTAssertEqual(drifts.count, 3)
        XCTAssertEqual(drifts[0].drift,  0.10, accuracy: 1e-12)
        XCTAssertEqual(drifts[1].drift, -0.05, accuracy: 1e-12)
        XCTAssertEqual(drifts[2].drift,  0.00, accuracy: 1e-12)
        // Field consistency
        for d in drifts {
            XCTAssertEqual(d.drift, d.actualTime - d.expectedTime, accuracy: 1e-12)
        }
    }

    // MARK: - 8. Evaluator marks within/outside window correctly

    func testEvaluatorMarksWithinAndOutsideWindow() {
        // tolerance = 1/8 exactly. Drift values chosen as
        // exactly-representable IEEE 754 fractions so the boundary
        // case (drift == lateTolerance) is exact, not off-by-ULP.
        let window = TimingWindow(earlyTolerance: 0.125, lateTolerance: 0.125)!
        // drifts: +0.25 (outside late), -0.0625 (inside), 0 (inside),
        //         +0.125 (boundary, inside)
        let primitives: [NotationPrimitive] = [
            makeForwardSegment(start: 0.25,    end: 0.5),
            makeForwardSegment(start: 0.9375,  end: 1.0),
            makeForwardSegment(start: 2.0,     end: 2.5),
            makeForwardSegment(start: 3.125,   end: 3.5),
        ]
        let annotations: [GridAnnotation] = (0..<4).map { idx in
            GridAnnotation(primitiveIndex: idx,
                            start: GridPosition(bar: 0, beat: 0, subdivision: 0, subdivisionPhase: 0),
                            end:   GridPosition(bar: 0, beat: 0, subdivision: 0, subdivisionPhase: 0))
        }
        let drifts = TimingWindowEvaluator.evaluate(
            annotations: annotations,
            primitives: primitives,
            expectedStartTimes: [0: 0.0, 1: 1.0, 2: 2.0, 3: 3.0],
            window: window
        )
        XCTAssertEqual(drifts.count, 4)
        XCTAssertEqual(drifts[0].drift,  0.25,   accuracy: 1e-12)
        XCTAssertEqual(drifts[1].drift, -0.0625, accuracy: 1e-12)
        XCTAssertEqual(drifts[2].drift,  0.0,    accuracy: 1e-12)
        XCTAssertEqual(drifts[3].drift,  0.125,  accuracy: 1e-12)
        XCTAssertEqual(drifts.map(\.isWithinWindow), [false, true, true, true])
    }

    // MARK: - 9. Evaluator skips annotations with no expectedStartTimes entry

    func testEvaluatorSkipsMissingExpectedStartTimes() {
        let window = TimingWindow(earlyTolerance: 0.05, lateTolerance: 0.05)!
        let primitives: [NotationPrimitive] = [
            makeForwardSegment(start: 0.0, end: 0.5),
            makeForwardSegment(start: 0.5, end: 1.0),
            makeForwardSegment(start: 1.0, end: 1.5),
        ]
        let annotations: [GridAnnotation] = (0..<3).map { idx in
            GridAnnotation(primitiveIndex: idx,
                            start: GridPosition(bar: 0, beat: 0, subdivision: 0, subdivisionPhase: 0),
                            end:   GridPosition(bar: 0, beat: 0, subdivision: 0, subdivisionPhase: 0))
        }
        // Only entries for primitives 0 and 2 — primitive 1 must be skipped.
        let drifts = TimingWindowEvaluator.evaluate(
            annotations: annotations,
            primitives: primitives,
            expectedStartTimes: [0: 0.0, 2: 1.0],
            window: window
        )
        XCTAssertEqual(drifts.count, 2)
        XCTAssertEqual(drifts.map(\.primitiveIndex), [0, 2])
    }

    // MARK: - 10. Evaluator skips out-of-bounds primitive indices

    func testEvaluatorSkipsOutOfBoundsPrimitiveIndices() {
        let window = TimingWindow(earlyTolerance: 0.05, lateTolerance: 0.05)!
        let primitives: [NotationPrimitive] = [
            makeForwardSegment(start: 0.0, end: 0.5),
        ]
        // Three annotations: one valid index, two stale references.
        let annotations: [GridAnnotation] = [
            GridAnnotation(primitiveIndex: 0,
                            start: GridPosition(bar: 0, beat: 0, subdivision: 0, subdivisionPhase: 0),
                            end:   GridPosition(bar: 0, beat: 0, subdivision: 0, subdivisionPhase: 0)),
            GridAnnotation(primitiveIndex: 99,
                            start: GridPosition(bar: 0, beat: 0, subdivision: 0, subdivisionPhase: 0),
                            end:   GridPosition(bar: 0, beat: 0, subdivision: 0, subdivisionPhase: 0)),
            GridAnnotation(primitiveIndex: 7,
                            start: GridPosition(bar: 0, beat: 0, subdivision: 0, subdivisionPhase: 0),
                            end:   GridPosition(bar: 0, beat: 0, subdivision: 0, subdivisionPhase: 0)),
        ]
        let drifts = TimingWindowEvaluator.evaluate(
            annotations: annotations,
            primitives: primitives,
            expectedStartTimes: [0: 0.0, 7: 0.5, 99: 1.0],
            window: window
        )
        XCTAssertEqual(drifts.count, 1)
        XCTAssertEqual(drifts[0].primitiveIndex, 0)
    }

    // MARK: - 11. Codable round-trip

    func testCodableRoundTrip() throws {
        let window = TimingWindow(earlyTolerance: 0.04, lateTolerance: 0.11)!
        let drift = TimingDrift(primitiveIndex: 3,
                                 expectedTime: 1.5,
                                 actualTime: 1.45,
                                 drift: -0.05,
                                 isWithinWindow: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()

        let windowData = try encoder.encode(window)
        XCTAssertEqual(try decoder.decode(TimingWindow.self, from: windowData), window)

        let driftData = try encoder.encode(drift)
        XCTAssertEqual(try decoder.decode(TimingDrift.self, from: driftData), drift)

        // Byte-stable re-encode.
        let windowDataAgain = try encoder.encode(try decoder.decode(TimingWindow.self, from: windowData))
        XCTAssertEqual(windowData, windowDataAgain)
        let driftDataAgain = try encoder.encode(try decoder.decode(TimingDrift.self, from: driftData))
        XCTAssertEqual(driftData, driftDataAgain)
    }

    // MARK: - 12. Codable rejects invalid TimingWindow

    func testCodableRejectsInvalidTimingWindow() {
        let decoder = JSONDecoder()
        let negativeEarly = """
        {"earlyTolerance":-0.01,"lateTolerance":0.05}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(TimingWindow.self, from: negativeEarly))

        let negativeLate = """
        {"earlyTolerance":0.05,"lateTolerance":-0.01}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(TimingWindow.self, from: negativeLate))

        // JSON has no NaN/Infinity literal; serialised non-finite values
        // typically come back as strings. The decoder rejects them
        // either at the type-mismatch layer or via the finite guard.
        let earlyNaN = """
        {"earlyTolerance":"NaN","lateTolerance":0.05}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(TimingWindow.self, from: earlyNaN))
    }

    // MARK: - 13. Codable rejects invalid TimingDrift

    func testCodableRejectsInvalidTimingDrift() {
        let decoder = JSONDecoder()
        let negativeIndex = """
        {"primitiveIndex":-1,"expectedTime":0.0,"actualTime":0.0,"drift":0.0,"isWithinWindow":true}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(TimingDrift.self, from: negativeIndex))

        let expectedNaN = """
        {"primitiveIndex":0,"expectedTime":"NaN","actualTime":0.0,"drift":0.0,"isWithinWindow":true}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(TimingDrift.self, from: expectedNaN))

        let actualNaN = """
        {"primitiveIndex":0,"expectedTime":0.0,"actualTime":"NaN","drift":0.0,"isWithinWindow":true}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(TimingDrift.self, from: actualNaN))

        let driftNaN = """
        {"primitiveIndex":0,"expectedTime":0.0,"actualTime":0.0,"drift":"NaN","isWithinWindow":true}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(TimingDrift.self, from: driftNaN))
    }

    // MARK: - 14. Evaluator does not mutate primitives or annotations

    func testEvaluatorDoesNotMutatePrimitivesOrAnnotations() {
        let window = TimingWindow(earlyTolerance: 0.05, lateTolerance: 0.05)!
        let primitives: [NotationPrimitive] = [
            makeForwardSegment(start: 0.0, end: 0.5),
            makeReversal(time: 0.5),
            makeIdleHold(start: 0.5, end: 1.0),
        ]
        let annotations: [GridAnnotation] = (0..<3).map { idx in
            GridAnnotation(primitiveIndex: idx,
                            start: GridPosition(bar: 0, beat: 0, subdivision: 0, subdivisionPhase: 0),
                            end:   GridPosition(bar: 0, beat: 0, subdivision: 0, subdivisionPhase: 0))
        }
        let primitivesSnapshot = primitives
        let annotationsSnapshot = annotations
        _ = TimingWindowEvaluator.evaluate(
            annotations: annotations,
            primitives: primitives,
            expectedStartTimes: [0: 0.0, 1: 0.5, 2: 0.5],
            window: window
        )
        XCTAssertEqual(primitives, primitivesSnapshot)
        XCTAssertEqual(annotations, annotationsSnapshot)
    }

    // MARK: - 15. Non-4/4 grid annotations still evaluate

    /// The evaluator operates on absolute seconds. A non-4/4 grid
    /// produces a different `GridPosition` shape, but the drift maths
    /// is unaffected — the test confirms the evaluator never inspects
    /// musical metadata.
    func testNonFourFourGridAnnotationsEvaluate() {
        let window = TimingWindow(earlyTolerance: 0.05, lateTolerance: 0.05)!
        let grid = TimingGrid(beatsPerMinute: 180,
                              beatsPerBar: 3,
                              subdivisionsPerBeat: 4,
                              origin: 0)!
        let primitives: [NotationPrimitive] = [
            makeForwardSegment(start: 0.0, end: 1.0 / 6.0),
            makeForwardSegment(start: 1.0 / 6.0, end: 1.0 / 3.0),
        ]
        let annotations = GridAnnotationMapper.annotate(primitives: primitives, using: grid)
        // Expected start times: exact triplet-subdivision boundaries.
        let expected: [Int: TimeInterval] = [0: 0.0, 1: 1.0 / 6.0]
        let drifts = TimingWindowEvaluator.evaluate(
            annotations: annotations,
            primitives: primitives,
            expectedStartTimes: expected,
            window: window
        )
        XCTAssertEqual(drifts.count, 2)
        XCTAssertEqual(drifts.map(\.isWithinWindow), [true, true])
        XCTAssertEqual(drifts[0].drift, 0, accuracy: 1e-12)
        XCTAssertEqual(drifts[1].drift, 0, accuracy: 1e-12)
    }
}
