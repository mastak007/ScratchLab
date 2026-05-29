import XCTest
@testable import ScratchLab

/// Locks the contract of `ScratchNotationPhrasePolyline.build(...)`:
/// pure, deterministic conversion of a position trace + phrase
/// ranges into one polyline group per active phrase, where each
/// polyline group is a list of **sub-paths**.
///
/// Sub-path rules:
///   - One polyline per active phrase range.
///   - Within a phrase, vertices are ordered by time.
///   - First vertex of the first sub-path = first stroke's
///     `(startTime, startPosition)`.
///   - Each stroke contributes its `(endTime, endPosition)` vertex.
///   - Intra-phrase carry-forward holds emit a flat horizontal
///     vertex at `(nextStroke.startTime, current.endPosition)` in
///     the **same** sub-path.
///   - Non-carry-forward transitions (`next.startPosition !=
///     current.endPosition`) close the current sub-path and open a
///     new one at the next stroke's start vertex. No vertex is
///     emitted in the gap — the renderer paints nothing for the
///     silent platter reset interval.
///   - Inter-phrase silences split into separate polylines.
final class ScratchNotationPhrasePolylineTests: XCTestCase {

    // MARK: - Helpers

    private func trace(
        startTime: TimeInterval,
        endTime: TimeInterval,
        startPosition: Double,
        endPosition: Double,
        direction: ScratchMotionDirection = .forward
    ) -> ScratchNotationPositionTraceSegment {
        ScratchNotationPositionTraceSegment(
            startTime: startTime,
            endTime: endTime,
            startPosition: startPosition,
            endPosition: endPosition,
            direction: direction
        )
    }

    private func phrase(
        _ start: TimeInterval,
        _ end: TimeInterval
    ) -> ScratchNotationPhraseRange {
        ScratchNotationPhraseRange(start: start, end: end)
    }

    private func stroke(
        startTime: TimeInterval,
        endTime: TimeInterval,
        direction: ScratchMotionDirection = .forward,
        startProgress: Double = 0,
        endProgress: Double = 0
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

    private func backwardStroke(
        startTime: TimeInterval,
        endTime: TimeInterval
    ) -> ScratchLabBabyScratchStrokeSegment {
        stroke(
            startTime: startTime,
            endTime: endTime,
            direction: .backward,
            startProgress: 1.0,
            endProgress: 0.0
        )
    }

    private func forwardStroke(
        startTime: TimeInterval,
        endTime: TimeInterval
    ) -> ScratchLabBabyScratchStrokeSegment {
        stroke(
            startTime: startTime,
            endTime: endTime,
            direction: .forward,
            startProgress: 0.0,
            endProgress: 1.0
        )
    }

    // MARK: - 1. Empty input

    func testEmptyTraceProducesNoPolyline() {
        XCTAssertTrue(
            ScratchNotationPhrasePolyline.build(
                from: [], phraseRanges: [phrase(0, 1)]
            ).isEmpty
        )
    }

    func testEmptyPhraseRangesProducesNoPolyline() {
        let result = ScratchNotationPhrasePolyline.build(
            from: [trace(startTime: 0, endTime: 0.5, startPosition: 0.5, endPosition: 0.3)],
            phraseRanges: []
        )
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - 2. Single stroke

    func testSingleStrokeProducesOneSubPathWithTwoVertices() {
        let result = ScratchNotationPhrasePolyline.build(
            from: [trace(startTime: 0, endTime: 0.5, startPosition: 0.5, endPosition: 0.3)],
            phraseRanges: [phrase(0, 0.5)]
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].subPaths.count, 1)
        XCTAssertEqual(result[0].subPaths[0].count, 2)
        XCTAssertEqual(result[0].subPaths[0][0].time, 0.0, accuracy: 1e-9)
        XCTAssertEqual(result[0].subPaths[0][0].position, 0.5, accuracy: 1e-9)
        XCTAssertEqual(result[0].subPaths[0][1].time, 0.5, accuracy: 1e-9)
        XCTAssertEqual(result[0].subPaths[0][1].position, 0.3, accuracy: 1e-9)
    }

    // MARK: - 3. Carry-forward strokes stay in one sub-path

    /// Two carry-forward strokes (back-to-back, shared endpoint)
    /// stay in the same sub-path. The shared vertex is emitted once,
    /// not duplicated.
    func testCarryForwardBackToBackStrokesStayInOneSubPath() {
        let trace = [
            trace(startTime: 0.0, endTime: 0.5, startPosition: 0.5, endPosition: 0.3),
            trace(startTime: 0.5, endTime: 1.0, startPosition: 0.3, endPosition: 0.4),
        ]
        let result = ScratchNotationPhrasePolyline.build(
            from: trace, phraseRanges: [phrase(0, 1.0)]
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].subPaths.count, 1)
        XCTAssertEqual(result[0].subPaths[0].count, 3)
        XCTAssertEqual(result[0].subPaths[0][0].time, 0.0, accuracy: 1e-9)
        XCTAssertEqual(result[0].subPaths[0][1].time, 0.5, accuracy: 1e-9)
        XCTAssertEqual(result[0].subPaths[0][1].position, 0.3, accuracy: 1e-9)
        XCTAssertEqual(result[0].subPaths[0][2].time, 1.0, accuracy: 1e-9)
        XCTAssertEqual(result[0].subPaths[0][2].position, 0.4, accuracy: 1e-9)
    }

    // MARK: - 4. Intra-phrase carry-forward hold adds a flat vertex

    /// Two carry-forward strokes separated by an intra-phrase hold
    /// gap (sub-threshold) produce ONE sub-path with a flat
    /// horizontal vertex at `(nextStroke.startTime,
    /// current.endPosition)`.
    func testIntraPhraseHoldKeepsCarryForwardStrokesInOneSubPath() {
        let trace = [
            trace(startTime: 0.0, endTime: 0.5, startPosition: 0.5, endPosition: 0.3),
            trace(startTime: 0.8, endTime: 1.2, startPosition: 0.3, endPosition: 0.4),
        ]
        let result = ScratchNotationPhrasePolyline.build(
            from: trace, phraseRanges: [phrase(0, 1.2)]
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].subPaths.count, 1)
        XCTAssertEqual(result[0].subPaths[0].count, 4)
        // Stroke 1 start → end.
        XCTAssertEqual(result[0].subPaths[0][0].position, 0.5, accuracy: 1e-9)
        XCTAssertEqual(result[0].subPaths[0][1].position, 0.3, accuracy: 1e-9)
        // Flat hold vertex at the next stroke's startTime, same Y.
        XCTAssertEqual(result[0].subPaths[0][2].time, 0.8, accuracy: 1e-9)
        XCTAssertEqual(result[0].subPaths[0][2].position, 0.3, accuracy: 1e-9)
        // Stroke 2 end.
        XCTAssertEqual(result[0].subPaths[0][3].time, 1.2, accuracy: 1e-9)
        XCTAssertEqual(result[0].subPaths[0][3].position, 0.4, accuracy: 1e-9)
    }

    // MARK: - 5. Non-carry-forward transition breaks the sub-path

    /// Two consecutive backward strokes (each 1 → 0) with an
    /// intra-phrase gap produce **two sub-paths**, each containing
    /// 2 vertices. No vertex is emitted in the gap — neither a flat
    /// hold nor a vertical jump. The renderer paints nothing there.
    func testNonCarryForwardTransitionBreaksSubPath() {
        let trace = [
            trace(startTime: 0.0, endTime: 0.5,
                  startPosition: 1.0, endPosition: 0.0, direction: .backward),
            trace(startTime: 0.8, endTime: 1.2,
                  startPosition: 1.0, endPosition: 0.0, direction: .backward),
        ]
        let result = ScratchNotationPhrasePolyline.build(
            from: trace, phraseRanges: [phrase(0, 1.2)]
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].subPaths.count, 2)
        XCTAssertEqual(result[0].subPaths[0].count, 2)
        XCTAssertEqual(result[0].subPaths[1].count, 2)
        XCTAssertEqual(result[0].subPaths[0][0].position, 1.0, accuracy: 1e-9)
        XCTAssertEqual(result[0].subPaths[0][1].position, 0.0, accuracy: 1e-9)
        XCTAssertEqual(result[0].subPaths[1][0].time, 0.8, accuracy: 1e-9)
        XCTAssertEqual(result[0].subPaths[1][0].position, 1.0, accuracy: 1e-9)
        XCTAssertEqual(result[0].subPaths[1][1].time, 1.2, accuracy: 1e-9)
        XCTAssertEqual(result[0].subPaths[1][1].position, 0.0, accuracy: 1e-9)
        // Critically: no vertex anywhere between 0.5 and 0.8.
        for sub in result[0].subPaths {
            for vertex in sub {
                XCTAssertFalse(
                    vertex.time > 0.5 && vertex.time < 0.8,
                    "vertex at t=\(vertex.time) sits inside the silent reset interval"
                )
            }
        }
    }

    // MARK: - 6. Back-to-back non-carry-forward also breaks

    /// gap == 0 with non-equal positions still breaks the sub-path.
    /// The two strokes share a `time` but not a `position`; the
    /// renderer must not connect them with a vertical line.
    func testBackToBackNonCarryForwardBreaksSubPath() {
        let trace = [
            trace(startTime: 0.0, endTime: 0.5,
                  startPosition: 1.0, endPosition: 0.0, direction: .backward),
            trace(startTime: 0.5, endTime: 1.0,
                  startPosition: 1.0, endPosition: 0.0, direction: .backward),
        ]
        let result = ScratchNotationPhrasePolyline.build(
            from: trace, phraseRanges: [phrase(0, 1.0)]
        )
        XCTAssertEqual(result[0].subPaths.count, 2)
        XCTAssertEqual(result[0].subPaths[0].count, 2)
        XCTAssertEqual(result[0].subPaths[1].count, 2)
        // Both sub-paths share the boundary time 0.5 but at
        // different positions. They do not share a vertex.
        XCTAssertEqual(result[0].subPaths[0][1].time, 0.5, accuracy: 1e-9)
        XCTAssertEqual(result[0].subPaths[0][1].position, 0.0, accuracy: 1e-9)
        XCTAssertEqual(result[0].subPaths[1][0].time, 0.5, accuracy: 1e-9)
        XCTAssertEqual(result[0].subPaths[1][0].position, 1.0, accuracy: 1e-9)
    }

    // MARK: - 7. Inter-phrase silence still produces independent polylines

    func testInterPhraseSilenceSplitsIntoSeparatePolylines() {
        let trace = [
            trace(startTime: 0.0, endTime: 0.5,
                  startPosition: 1.0, endPosition: 0.0, direction: .backward),
            // 5 s inter-phrase silence
            trace(startTime: 5.5, endTime: 6.0,
                  startPosition: 1.0, endPosition: 0.0, direction: .backward),
        ]
        let result = ScratchNotationPhrasePolyline.build(
            from: trace,
            phraseRanges: [phrase(0, 0.5), phrase(5.5, 6.0)]
        )
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].subPaths.count, 1)
        XCTAssertEqual(result[1].subPaths.count, 1)
        XCTAssertEqual(result[0].subPaths[0].last?.time, 0.5)
        XCTAssertEqual(result[1].subPaths[0].first?.time, 5.5)
    }

    // MARK: - 8. Bundled phrase 1 produces six sub-paths

    /// Locks the exact sub-path count for the bundled phrase-1
    /// shape: four isolated backwards (strokes 1-4) + one connected
    /// run (5, 6, 7, 8) + one connected run (9, 10, 11). The four
    /// isolated backwards each form their own sub-path because each
    /// backward stroke ends at 0 and the next backward stroke starts
    /// at 1 — non-carry-forward.
    func testBundledPhrase1ProducesSixSubPaths() {
        let rawStrokes: [ScratchLabBabyScratchStrokeSegment] = [
            backwardStroke(startTime: 0.27,  endTime: 0.778),
            backwardStroke(startTime: 1.07,  endTime: 1.378),
            backwardStroke(startTime: 1.46,  endTime: 1.763),
            backwardStroke(startTime: 1.84,  endTime: 2.368),
            backwardStroke(startTime: 2.605, endTime: 2.913),
            forwardStroke(startTime: 2.99,  endTime: 3.278),
            backwardStroke(startTime: 3.36,  endTime: 3.928),
            forwardStroke(startTime: 4.13,  endTime: 4.453),
            forwardStroke(startTime: 4.52,  endTime: 4.803),
            backwardStroke(startTime: 4.895, endTime: 5.743),
            forwardStroke(startTime: 5.743, endTime: 6.5),
        ]
        let trace = ScratchNotationRawTrace.build(from: rawStrokes)
        let result = ScratchNotationPhrasePolyline.build(
            from: trace, phraseRanges: [phrase(0.27, 6.5)]
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(
            result[0].subPaths.count, 6,
            "expected 4 isolated backwards + run(5-8) + run(9-11) = 6 sub-paths"
        )
        // The first four sub-paths are each one backward stroke
        // (2 vertices each).
        for index in 0..<4 {
            XCTAssertEqual(
                result[0].subPaths[index].count, 2,
                "sub-path \(index) should be a single 1→0 backward stroke"
            )
        }
        // Sub-path 4 covers strokes 5-8: 5 stroke endpoints + 3
        // intra-phrase hold vertices = 8 vertices.
        XCTAssertEqual(result[0].subPaths[4].count, 8)
        // Sub-path 5 covers strokes 9-11: 4 stroke endpoints + 1
        // intra-phrase hold vertex between 9 and 10 (gap 0.092 s) +
        // 0 between 10 and 11 (back-to-back gap 0) = 5 vertices.
        XCTAssertEqual(result[0].subPaths[5].count, 5)
    }

    // MARK: - 9. Bundled phrases 2-4 produce one sub-path each

    /// Every transition in phrases 2-4 is carry-forward (B-F-B-F-…
    /// alternates with shared endpoints 0 or 1), so each phrase
    /// should produce exactly one sub-path.
    func testBundledPhrase2ProducesOneSubPath() {
        // Compact representative of phrase 2's BFBFBF alternation.
        let rawStrokes: [ScratchLabBabyScratchStrokeSegment] = [
            backwardStroke(startTime: 11.50, endTime: 12.00),
            forwardStroke(startTime: 12.37, endTime: 12.878),
            backwardStroke(startTime: 13.17, endTime: 13.478),
            forwardStroke(startTime: 13.56, endTime: 13.863),
            backwardStroke(startTime: 13.94, endTime: 14.468),
        ]
        let trace = ScratchNotationRawTrace.build(from: rawStrokes)
        let result = ScratchNotationPhrasePolyline.build(
            from: trace, phraseRanges: [phrase(11.50, 14.468)]
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].subPaths.count, 1)
        XCTAssertGreaterThanOrEqual(result[0].subPaths[0].count, 5)
    }

    // MARK: - 10. Bundled phrase 1 still reaches both lane boundaries

    /// Amplitude rule preserved across sub-paths: phrase 1's
    /// concatenated sub-path vertices must include at least one
    /// position == 0 and at least one position == 1.
    func testBundledPhrase1ReachesBothLaneBoundariesAcrossSubPaths() {
        let rawStrokes: [ScratchLabBabyScratchStrokeSegment] = [
            backwardStroke(startTime: 0.27, endTime: 0.778),
            forwardStroke(startTime: 1.0, endTime: 1.5),
        ]
        let trace = ScratchNotationRawTrace.build(from: rawStrokes)
        let result = ScratchNotationPhrasePolyline.build(
            from: trace, phraseRanges: [phrase(0.27, 1.5)]
        )
        XCTAssertEqual(result.count, 1)
        let allPositions = result[0].subPaths.flatMap { $0 }.map(\.position)
        XCTAssertTrue(allPositions.contains(0.0))
        XCTAssertTrue(allPositions.contains(1.0))
    }

    // MARK: - 11. No vertex outside phrase / audio range

    func testNoVerticesOutsidePhraseRange() {
        let trace = [
            trace(startTime: 0.0, endTime: 0.5,
                  startPosition: 1.0, endPosition: 0.0, direction: .backward),
            trace(startTime: 0.8, endTime: 1.2,
                  startPosition: 1.0, endPosition: 0.0, direction: .backward),
        ]
        let result = ScratchNotationPhrasePolyline.build(
            from: trace, phraseRanges: [phrase(0, 1.2)]
        )
        for polyline in result {
            for sub in polyline.subPaths {
                for vertex in sub {
                    XCTAssertGreaterThanOrEqual(vertex.time, 0.0 - 1e-9)
                    XCTAssertLessThanOrEqual(vertex.time, 1.2 + 1e-9)
                }
            }
        }
    }

    // MARK: - 12. Determinism

    func testDeterministicAcrossReruns() {
        let trace = [
            trace(startTime: 0.0, endTime: 0.5,
                  startPosition: 1.0, endPosition: 0.0, direction: .backward),
            trace(startTime: 0.8, endTime: 1.2,
                  startPosition: 1.0, endPosition: 0.0, direction: .backward),
            trace(startTime: 5.5, endTime: 6.0,
                  startPosition: 1.0, endPosition: 0.0, direction: .backward),
        ]
        let ranges = [phrase(0, 1.2), phrase(5.5, 6.0)]
        let first = ScratchNotationPhrasePolyline.build(
            from: trace, phraseRanges: ranges
        )
        for _ in 0..<99 {
            XCTAssertEqual(
                ScratchNotationPhrasePolyline.build(from: trace, phraseRanges: ranges),
                first
            )
        }
    }
}
