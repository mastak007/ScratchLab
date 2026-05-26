import XCTest
@testable import ScratchLab

/// Section 2 / Slice 2 — locks the contract of `GridAnnotation` and
/// `GridAnnotationMapper.annotate(primitives:using:)`, the sidecar
/// projection of a primitive stream onto a `TimingGrid`.
///
/// Synthetic, deterministic inputs only. No fixture dependency, no
/// integration with capture or rendering, no algorithm coupling.
final class GridAnnotationTests: XCTestCase {

    // MARK: - Helpers

    private func makeStandardGrid() -> TimingGrid {
        // 120 BPM 4/4 with 16th-note subdivisions, origin at 0.
        // secondsPerBeat = 0.5, secondsPerSubdivision = 0.125,
        // secondsPerBar = 2.0.
        return TimingGrid(beatsPerMinute: 120,
                          beatsPerBar: 4,
                          subdivisionsPerBeat: 4,
                          origin: 0)!
    }

    private func makeForwardSegment(start: TimeInterval, end: TimeInterval) -> NotationPrimitive {
        .directionSegment(DirectionSegment(direction: .forward,
                                            startTime: start,
                                            endTime: end,
                                            startPosition: 0.0,
                                            endPosition: 1.0,
                                            minimumConfidence: 1.0))
    }

    private func makeReverseSegment(start: TimeInterval, end: TimeInterval) -> NotationPrimitive {
        .directionSegment(DirectionSegment(direction: .reverse,
                                            startTime: start,
                                            endTime: end,
                                            startPosition: 1.0,
                                            endPosition: 0.0,
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

    // MARK: - Tests

    /// 1. Empty input yields empty output.
    func testEmptyPrimitivesYieldEmptyAnnotations() {
        let grid = makeStandardGrid()
        let annotations = GridAnnotationMapper.annotate(primitives: [], using: grid)
        XCTAssertEqual(annotations.count, 0)
    }

    /// 2. Annotation count equals primitive count.
    func testAnnotationCountEqualsPrimitiveCount() {
        let grid = makeStandardGrid()
        let primitives: [NotationPrimitive] = [
            makeForwardSegment(start: 0.0, end: 0.5),
            makeReversal(time: 0.5),
            makeReverseSegment(start: 0.5, end: 1.0),
            makeIdleHold(start: 1.0, end: 1.5),
            makeForwardSegment(start: 1.5, end: 2.0),
        ]
        let annotations = GridAnnotationMapper.annotate(primitives: primitives, using: grid)
        XCTAssertEqual(annotations.count, primitives.count)
    }

    /// 3. Ordering is preserved: annotations[i].primitiveIndex == i.
    func testOrderingPreservedExactly() {
        let grid = makeStandardGrid()
        let primitives: [NotationPrimitive] = (0..<7).map { i in
            let start = Double(i) * 0.25
            return makeForwardSegment(start: start, end: start + 0.1)
        }
        let annotations = GridAnnotationMapper.annotate(primitives: primitives, using: grid)
        for (i, annotation) in annotations.enumerated() {
            XCTAssertEqual(annotation.primitiveIndex, i,
                           "annotation at array index \(i) has primitiveIndex \(annotation.primitiveIndex)")
        }
    }

    /// 4. Start/end positions map correctly on the standard 120 BPM 4/4
    /// grid for each primitive variant.
    func testStartEndMapsCorrectlyOnStandardGrid() {
        let grid = makeStandardGrid()
        // beat 0 of bar 0 → beat 1 of bar 0: forward segment spanning
        // one full beat (0.0 → 0.5 s).
        let segment = makeForwardSegment(start: 0.0, end: 0.5)
        // Reversal at the bar-1 downbeat (t = 2.0).
        let reversal = makeReversal(time: 2.0)
        // Idle hold spanning one subdivision (0.125 s) starting at the
        // second beat of bar 1.
        let hold = makeIdleHold(start: 2.5, end: 2.625)

        let annotations = GridAnnotationMapper.annotate(
            primitives: [segment, reversal, hold],
            using: grid
        )

        // Segment 0.0–0.5: bar 0 beat 0 sub 0 → bar 0 beat 1 sub 0.
        XCTAssertEqual(annotations[0].start,
                       GridPosition(bar: 0, beat: 0, subdivision: 0, subdivisionPhase: 0))
        XCTAssertEqual(annotations[0].end,
                       GridPosition(bar: 0, beat: 1, subdivision: 0, subdivisionPhase: 0))

        // Reversal at t=2.0: bar 1 beat 0 sub 0, start == end.
        XCTAssertEqual(annotations[1].start,
                       GridPosition(bar: 1, beat: 0, subdivision: 0, subdivisionPhase: 0))
        XCTAssertEqual(annotations[1].start, annotations[1].end,
                       "Reversal annotation must satisfy start == end")

        // Idle hold 2.5–2.625: bar 1 beat 1 sub 0 → bar 1 beat 1 sub 1.
        XCTAssertEqual(annotations[2].start,
                       GridPosition(bar: 1, beat: 1, subdivision: 0, subdivisionPhase: 0))
        XCTAssertEqual(annotations[2].end,
                       GridPosition(bar: 1, beat: 1, subdivision: 1, subdivisionPhase: 0))
    }

    /// 5. Primitives whose times fall before the grid origin produce
    /// negative `bar` indices in the annotation.
    func testPreOriginPrimitivesProduceNegativeBars() {
        // Origin at t=1.0, 120 BPM 4/4 → half a second before origin is
        // the last beat of bar -1.
        let grid = TimingGrid(beatsPerMinute: 120,
                              beatsPerBar: 4,
                              subdivisionsPerBeat: 4,
                              origin: 1.0)!
        // Segment that straddles the origin: starts at 0.5 s (pre-origin),
        // ends at 1.5 s (post-origin).
        let segment = makeForwardSegment(start: 0.5, end: 1.5)
        let annotations = GridAnnotationMapper.annotate(primitives: [segment], using: grid)
        XCTAssertEqual(annotations.count, 1)
        XCTAssertEqual(annotations[0].start,
                       GridPosition(bar: -1, beat: 3, subdivision: 0, subdivisionPhase: 0))
        XCTAssertEqual(annotations[0].end,
                       GridPosition(bar: 0, beat: 1, subdivision: 0, subdivisionPhase: 0))
    }

    /// 6. Mixed primitive durations produce distinct end positions in
    /// the annotation stream — i.e. the mapper does not collapse spans.
    func testMixedDurationsPreserveDistinctEndPositions() {
        let grid = makeStandardGrid()
        let primitives: [NotationPrimitive] = [
            makeForwardSegment(start: 0.0, end: 0.125),  // one sub
            makeForwardSegment(start: 0.0, end: 0.5),    // one beat
            makeForwardSegment(start: 0.0, end: 2.0),    // one bar
        ]
        let annotations = GridAnnotationMapper.annotate(primitives: primitives, using: grid)
        XCTAssertEqual(annotations[0].end,
                       GridPosition(bar: 0, beat: 0, subdivision: 1, subdivisionPhase: 0))
        XCTAssertEqual(annotations[1].end,
                       GridPosition(bar: 0, beat: 1, subdivision: 0, subdivisionPhase: 0))
        XCTAssertEqual(annotations[2].end,
                       GridPosition(bar: 1, beat: 0, subdivision: 0, subdivisionPhase: 0))
        // Sanity: three end positions should be pairwise distinct.
        XCTAssertNotEqual(annotations[0].end, annotations[1].end)
        XCTAssertNotEqual(annotations[1].end, annotations[2].end)
        XCTAssertNotEqual(annotations[0].end, annotations[2].end)
    }

    /// 7. Codable round-trip on a non-trivial annotation array.
    func testCodableRoundTrip() throws {
        let grid = makeStandardGrid()
        let primitives: [NotationPrimitive] = [
            makeForwardSegment(start: 0.0, end: 0.5),
            makeReversal(time: 0.5),
            makeReverseSegment(start: 0.5, end: 1.0),
            makeIdleHold(start: 1.0, end: 1.5),
        ]
        let annotations = GridAnnotationMapper.annotate(primitives: primitives, using: grid)
        XCTAssertFalse(annotations.isEmpty)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()

        let data = try encoder.encode(annotations)
        let decoded = try decoder.decode([GridAnnotation].self, from: data)
        XCTAssertEqual(decoded, annotations)

        // Encode-decode-encode must be byte-identical.
        let second = try encoder.encode(decoded)
        XCTAssertEqual(data, second)
    }

    /// 8. Decoding a `GridAnnotation` with negative `primitiveIndex`
    /// must throw `DecodingError.dataCorrupted`.
    func testCodableRejectsNegativePrimitiveIndex() {
        let decoder = JSONDecoder()
        let invalid = """
        {
          "primitiveIndex": -1,
          "start": {"bar":0,"beat":0,"subdivision":0,"subdivisionPhase":0.0},
          "end":   {"bar":0,"beat":0,"subdivision":0,"subdivisionPhase":0.0}
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(GridAnnotation.self, from: invalid)) { error in
            guard case DecodingError.dataCorrupted = error else {
                XCTFail("expected DecodingError.dataCorrupted, got \(error)")
                return
            }
        }
    }

    /// 9. Mapping is deterministic: two back-to-back calls produce
    /// equal output.
    func testDeterministicAcrossInvocations() {
        let grid = makeStandardGrid()
        let primitives: [NotationPrimitive] = [
            makeForwardSegment(start: 0.0, end: 0.5),
            makeReversal(time: 0.5),
            makeReverseSegment(start: 0.5, end: 1.0),
            makeIdleHold(start: 1.0, end: 1.5),
            makeForwardSegment(start: 1.5, end: 2.0),
        ]
        let first = GridAnnotationMapper.annotate(primitives: primitives, using: grid)
        let second = GridAnnotationMapper.annotate(primitives: primitives, using: grid)
        XCTAssertEqual(first, second)
    }

    /// 10. The mapper does not mutate the primitive stream. The input
    /// array's Equatable identity must survive the call.
    func testAnnotationDoesNotMutatePrimitives() {
        let grid = makeStandardGrid()
        let primitives: [NotationPrimitive] = [
            makeForwardSegment(start: 0.0, end: 0.5),
            makeReversal(time: 0.5),
            makeReverseSegment(start: 0.5, end: 1.0),
        ]
        let snapshot = primitives
        _ = GridAnnotationMapper.annotate(primitives: primitives, using: grid)
        XCTAssertEqual(primitives, snapshot,
                       "annotate(primitives:using:) must not mutate the input stream")
    }

    /// 11. Mapping works correctly on a non-4/4 grid.
    func testNonFourFourGridMapsCorrectly() {
        // 180 BPM, 3/4, 4 subs per beat. secondsPerBeat = 1/3,
        // secondsPerBar = 1.0, secondsPerSubdivision = 1/12.
        let grid = TimingGrid(beatsPerMinute: 180,
                              beatsPerBar: 3,
                              subdivisionsPerBeat: 4,
                              origin: 0)!
        // Forward segment from beat 2 of bar 0 (t = 2/3) to bar 2 beat 0
        // (t = 2.0).
        let segment = makeForwardSegment(start: 2.0 / 3.0, end: 2.0)
        let annotations = GridAnnotationMapper.annotate(primitives: [segment], using: grid)
        XCTAssertEqual(annotations.count, 1)
        let start = annotations[0].start
        let end = annotations[0].end
        XCTAssertEqual(start.bar, 0)
        XCTAssertEqual(start.beat, 2)
        XCTAssertEqual(start.subdivision, 0)
        XCTAssertEqual(start.subdivisionPhase, 0.0, accuracy: 1e-9)
        XCTAssertEqual(end, GridPosition(bar: 2, beat: 0, subdivision: 0, subdivisionPhase: 0))
    }
}
