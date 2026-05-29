import XCTest
@testable import ScratchLab

/// Locks the contract of `ScratchNotationPhrasePolyline.build(...)`:
/// pure, deterministic conversion of a position trace + phrase
/// ranges into one continuous polyline per active phrase. Replaces
/// the prior tokenized-stroke renderer model (stroke segments + hold
/// connectors + endpoint dots) with the SXRATCH-style continuous
/// sample-position polyline.
///
/// Composition rules:
///   - One polyline per active phrase range.
///   - Vertices are ordered in time.
///   - First vertex = first stroke's `(startTime, startPosition)`.
///   - Each subsequent stroke contributes its end vertex
///     `(endTime, endPosition)`.
///   - Intra-phrase holds (gaps `> 0`, `≤ silenceThreshold`) inject
///     a flat horizontal vertex `(nextStroke.startTime, current.
///     endPosition)` between strokes so the path stays geometrically
///     continuous through holds.
///   - Inter-phrase silences (gaps `> silenceThreshold`) split into
///     separate polylines — never bridged.
///   - No loop tiling: every vertex sits in `[trace.first.startTime,
///     trace.last.endTime]`. The audio is single-shot.
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
        direction: ScratchMotionDirection = .forward
    ) -> ScratchLabBabyScratchStrokeSegment {
        ScratchLabBabyScratchStrokeSegment(
            startTime: startTime,
            endTime: endTime,
            direction: direction,
            holdAfter: 0,
            startProgress: 0,
            endProgress: 0
        )
    }

    // MARK: - 1. Empty input

    func testEmptyTraceProducesNoPolyline() {
        let result = ScratchNotationPhrasePolyline.build(
            from: [], phraseRanges: [phrase(0, 1)]
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testEmptyPhraseRangesProducesNoPolyline() {
        let result = ScratchNotationPhrasePolyline.build(
            from: [trace(startTime: 0, endTime: 0.5, startPosition: 0.5, endPosition: 0.3)],
            phraseRanges: []
        )
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - 2. Single stroke

    func testSingleStrokeProducesTwoVertices() {
        let result = ScratchNotationPhrasePolyline.build(
            from: [trace(startTime: 0, endTime: 0.5, startPosition: 0.5, endPosition: 0.3)],
            phraseRanges: [phrase(0, 0.5)]
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].vertices.count, 2)
        XCTAssertEqual(result[0].vertices[0].time, 0.0, accuracy: 1e-9)
        XCTAssertEqual(result[0].vertices[0].position, 0.5, accuracy: 1e-9)
        XCTAssertEqual(result[0].vertices[1].time, 0.5, accuracy: 1e-9)
        XCTAssertEqual(result[0].vertices[1].position, 0.3, accuracy: 1e-9)
    }

    // MARK: - 3. Consecutive strokes share vertex chain

    /// Two strokes with no hold gap (back-to-back) produce three
    /// vertices total — the second stroke's start vertex is the same
    /// (time, position) as the first stroke's end, so it is not
    /// emitted twice.
    func testConsecutiveStrokesShareVertexChain() {
        let trace = [
            trace(startTime: 0.0, endTime: 0.5, startPosition: 0.5, endPosition: 0.3),
            trace(startTime: 0.5, endTime: 1.0, startPosition: 0.3, endPosition: 0.4),
        ]
        let result = ScratchNotationPhrasePolyline.build(
            from: trace, phraseRanges: [phrase(0, 1.0)]
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].vertices.count, 3)
        XCTAssertEqual(result[0].vertices[0].time, 0.0, accuracy: 1e-9)
        XCTAssertEqual(result[0].vertices[1].time, 0.5, accuracy: 1e-9)
        XCTAssertEqual(result[0].vertices[1].position, 0.3, accuracy: 1e-9)
        XCTAssertEqual(result[0].vertices[2].time, 1.0, accuracy: 1e-9)
        XCTAssertEqual(result[0].vertices[2].position, 0.4, accuracy: 1e-9)
    }

    // MARK: - 4. Intra-phrase hold injects flat vertex

    /// Two strokes separated by a 0.3 s hold (sub-threshold) produce
    /// four vertices: stroke 1 start, stroke 1 end, flat hold vertex
    /// at `(stroke2.startTime, stroke1.endPosition)`, stroke 2 end.
    /// The two middle vertices share Y so the polyline draws a flat
    /// horizontal hold segment between them.
    func testIntraPhraseHoldAddsFlatHorizontalVertex() {
        let trace = [
            trace(startTime: 0.0, endTime: 0.5, startPosition: 0.5, endPosition: 0.3),
            trace(startTime: 0.8, endTime: 1.2, startPosition: 0.3, endPosition: 0.4),
        ]
        let result = ScratchNotationPhrasePolyline.build(
            from: trace, phraseRanges: [phrase(0, 1.2)]
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].vertices.count, 4)
        // Stroke 1 end → flat hold vertex must share Y.
        XCTAssertEqual(
            result[0].vertices[1].position,
            result[0].vertices[2].position,
            accuracy: 1e-9
        )
        XCTAssertEqual(result[0].vertices[2].time, 0.8, accuracy: 1e-9)
        XCTAssertEqual(result[0].vertices[3].time, 1.2, accuracy: 1e-9)
        XCTAssertEqual(result[0].vertices[3].position, 0.4, accuracy: 1e-9)
    }

    // MARK: - 5. Inter-phrase silence splits into separate polylines

    /// A 5 s gap above the 1.5 s threshold must produce two
    /// independent polylines — never one bridged polyline. This is
    /// the rule that keeps phrase boundaries honest.
    func testInterPhraseSilenceSplitsPolylines() {
        let trace = [
            trace(startTime: 0.0, endTime: 0.5, startPosition: 0.5, endPosition: 0.3),
            trace(startTime: 5.5, endTime: 6.0, startPosition: 0.3, endPosition: 0.4),
        ]
        let result = ScratchNotationPhrasePolyline.build(
            from: trace,
            phraseRanges: [phrase(0, 0.5), phrase(5.5, 6.0)]
        )
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].vertices.last?.time, 0.5)
        XCTAssertEqual(result[1].vertices.first?.time, 5.5)
        // Critically: the two polylines must not share or chain
        // their vertex streams. The last vertex of polyline 0 sits
        // at t=0.5; the first vertex of polyline 1 sits at t=5.5.
        // No vertex exists in between.
        for polyline in result {
            for vertex in polyline.vertices {
                let inFirst = vertex.time >= 0.0 && vertex.time <= 0.5
                let inSecond = vertex.time >= 5.5 && vertex.time <= 6.0
                XCTAssertTrue(
                    inFirst || inSecond,
                    "vertex at t=\(vertex.time) leaks across the inter-phrase silence"
                )
            }
        }
    }

    // MARK: - 6. No vertex outside the audio range (no loop tiling)

    /// Locks the no-tiling rule: every vertex must sit inside the
    /// audio time range. The prior renderer tiled at
    /// `[-loopDuration, 0, loopDuration]` which injected phantom
    /// strokes at audio_t < ~1.2 s (from the −loopDuration tile of
    /// the trace's last stroke) and audio_t > ~39.6 s (from the
    /// +loopDuration tile of the trace's first stroke). The polyline
    /// builder is the single source of vertex truth — anything
    /// outside the audio range is forbidden by construction.
    func testNoVerticesOutsideAudioRange() {
        // Synthetic four-phrase shape mirroring the bundled JSON.
        var traceSegments: [ScratchNotationPositionTraceSegment] = []
        var phraseRanges: [ScratchNotationPhraseRange] = []
        for (start, end) in [(0.27, 6.50), (11.50, 18.60), (23.70, 30.45), (35.70, 42.40)] {
            phraseRanges.append(phrase(start, end))
            // Three strokes per phrase, all intra-phrase gaps ≤ 1 s.
            let span = end - start
            let durations = [0.4, 0.5, 0.6]
            var t = start
            for (i, d) in durations.enumerated() {
                traceSegments.append(
                    trace(
                        startTime: t,
                        endTime: min(end, t + d),
                        startPosition: Double(i) * 0.2,
                        endPosition: Double(i) * 0.2 + 0.1
                    )
                )
                t += d + 0.2
                if t > end { break }
            }
        }
        // Close phrase 4 cleanly at end = 42.4.
        traceSegments.append(
            trace(startTime: 41.9, endTime: 42.4, startPosition: 0.4, endPosition: 0.5)
        )
        let result = ScratchNotationPhrasePolyline.build(
            from: traceSegments, phraseRanges: phraseRanges
        )
        XCTAssertGreaterThan(result.count, 0)
        for polyline in result {
            for vertex in polyline.vertices {
                XCTAssertGreaterThanOrEqual(vertex.time, 0.0 - 1e-9)
                XCTAssertLessThanOrEqual(vertex.time, 42.4 + 1e-9)
            }
        }
    }

    // MARK: - 7. Vertices are strictly ordered in time

    func testVerticesAreOrderedInTime() {
        let trace = [
            trace(startTime: 0.0, endTime: 0.5, startPosition: 0.5, endPosition: 0.3),
            trace(startTime: 0.8, endTime: 1.2, startPosition: 0.3, endPosition: 0.4),
            trace(startTime: 1.4, endTime: 1.8, startPosition: 0.4, endPosition: 0.5),
        ]
        let result = ScratchNotationPhrasePolyline.build(
            from: trace, phraseRanges: [phrase(0, 1.8)]
        )
        XCTAssertEqual(result.count, 1)
        let times = result[0].vertices.map(\.time)
        let sorted = times.sorted()
        XCTAssertEqual(times, sorted, "vertices must be ordered in time")
    }

    // MARK: - 8. Determinism

    func testDeterministicAcrossReruns() {
        let trace = [
            trace(startTime: 0.0, endTime: 0.5, startPosition: 0.5, endPosition: 0.3),
            trace(startTime: 0.8, endTime: 1.2, startPosition: 0.3, endPosition: 0.4),
            trace(startTime: 5.5, endTime: 6.0, startPosition: 0.4, endPosition: 0.5),
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

    // MARK: - 9. Non-carry-forward strokes emit hold-then-jump

    /// Two consecutive backward strokes (each 1 → 0) with an
    /// intra-phrase gap must produce the vertex sequence
    /// `(s1.start, 1) → (s1.end, 0) → (s2.start, 0) →
    /// (s2.start, 1) → (s2.end, 0)`. The hold-flat vertex at
    /// `(s2.startTime, 0)` followed by the jump vertex at
    /// `(s2.startTime, 1)` produces a vertical line at `s2.startTime`
    /// — the silent platter-reset moment.
    func testNonCarryForwardStrokesEmitHoldThenJumpVertices() {
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
        XCTAssertEqual(result[0].vertices.count, 5)
        XCTAssertEqual(result[0].vertices[0].time, 0.0, accuracy: 1e-9)
        XCTAssertEqual(result[0].vertices[0].position, 1.0, accuracy: 1e-9)
        XCTAssertEqual(result[0].vertices[1].time, 0.5, accuracy: 1e-9)
        XCTAssertEqual(result[0].vertices[1].position, 0.0, accuracy: 1e-9)
        // Flat hold at the previous endPosition (0) — runs until
        // the next stroke's startTime.
        XCTAssertEqual(result[0].vertices[2].time, 0.8, accuracy: 1e-9)
        XCTAssertEqual(result[0].vertices[2].position, 0.0, accuracy: 1e-9)
        // Jump at the same X to the next stroke's startPosition (1).
        XCTAssertEqual(result[0].vertices[3].time, 0.8, accuracy: 1e-9)
        XCTAssertEqual(result[0].vertices[3].position, 1.0, accuracy: 1e-9)
        // Stroke 2 end.
        XCTAssertEqual(result[0].vertices[4].time, 1.2, accuracy: 1e-9)
        XCTAssertEqual(result[0].vertices[4].position, 0.0, accuracy: 1e-9)
    }

    // MARK: - 10. Carry-forward strokes skip the jump

    /// When `next.startPosition == current.endPosition`, the polyline
    /// stays smooth and emits no extra jump vertex. Verified for
    /// both gap > 0 (one flat-hold vertex only) and gap == 0
    /// (back-to-back, no flat-hold vertex either).
    func testCarryForwardStrokesDoNotEmitJump() {
        let withHold = [
            trace(startTime: 0.0, endTime: 0.5,
                  startPosition: 0.5, endPosition: 0.3),
            trace(startTime: 0.8, endTime: 1.2,
                  startPosition: 0.3, endPosition: 0.4),
        ]
        let resultWithHold = ScratchNotationPhrasePolyline.build(
            from: withHold, phraseRanges: [phrase(0, 1.2)]
        )
        XCTAssertEqual(resultWithHold[0].vertices.count, 4)

        let backToBack = [
            trace(startTime: 0.0, endTime: 0.5,
                  startPosition: 0.5, endPosition: 0.3),
            trace(startTime: 0.5, endTime: 1.0,
                  startPosition: 0.3, endPosition: 0.4),
        ]
        let resultBackToBack = ScratchNotationPhrasePolyline.build(
            from: backToBack, phraseRanges: [phrase(0, 1.0)]
        )
        XCTAssertEqual(resultBackToBack[0].vertices.count, 3)
    }

    // MARK: - 11. Back-to-back non-carry-forward emits jump without hold

    /// gap == 0 with non-equal positions: emit just the jump vertex,
    /// no flat-hold vertex (the hold would have zero duration).
    func testBackToBackNonCarryForwardEmitsJumpOnly() {
        let trace = [
            trace(startTime: 0.0, endTime: 0.5,
                  startPosition: 1.0, endPosition: 0.0, direction: .backward),
            trace(startTime: 0.5, endTime: 1.0,
                  startPosition: 1.0, endPosition: 0.0, direction: .backward),
        ]
        let result = ScratchNotationPhrasePolyline.build(
            from: trace, phraseRanges: [phrase(0, 1.0)]
        )
        XCTAssertEqual(result[0].vertices.count, 4)
        // Stroke 1 end, then jump vertex at same X, then stroke 2 end.
        XCTAssertEqual(result[0].vertices[1].time, 0.5, accuracy: 1e-9)
        XCTAssertEqual(result[0].vertices[1].position, 0.0, accuracy: 1e-9)
        XCTAssertEqual(result[0].vertices[2].time, 0.5, accuracy: 1e-9)
        XCTAssertEqual(result[0].vertices[2].position, 1.0, accuracy: 1e-9)
        XCTAssertEqual(result[0].vertices[3].time, 1.0, accuracy: 1e-9)
        XCTAssertEqual(result[0].vertices[3].position, 0.0, accuracy: 1e-9)
    }

    // MARK: - 12. Phrase boundary does not connect across silence

    /// When trace segments are split across two phrases by an
    /// inter-phrase silence, the polylines remain independent. No
    /// jump or hold vertex appears across the silence gap.
    func testPhraseBoundaryDoesNotConnectAcrossSilence() {
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
        XCTAssertEqual(result[0].vertices.count, 2)
        XCTAssertEqual(result[1].vertices.count, 2)
        // Critically: no vertex at time 0.5–5.5.
        for polyline in result {
            for vertex in polyline.vertices {
                XCTAssertFalse(
                    vertex.time > 0.5 && vertex.time < 5.5,
                    "vertex at t=\(vertex.time) leaks across the inter-phrase silence"
                )
            }
        }
    }

    // MARK: - 13. Bundled-shaped phrase 1 reaches both lane boundaries

    /// With raw progress (post-corrective), the bundled phrase 1
    /// polyline must contain at least one vertex at position 0 and
    /// at least one at position 1. The duration-proxy lost this; the
    /// raw trace restores it.
    func testBundledShapedPhrase1ReachesBothLaneBoundaries() {
        let rawStrokes: [ScratchLabBabyScratchStrokeSegment] = [
            stroke(startTime: 0.27,  endTime: 0.778, direction: .backward),
            stroke(startTime: 1.07,  endTime: 1.378, direction: .backward),
            stroke(startTime: 2.99,  endTime: 3.278, direction: .forward),
            stroke(startTime: 5.743, endTime: 6.5,   direction: .forward),
        ]
        // Manually set raw progress to JSON shape (1↔0 / 0↔1).
        let rawProgress: [(Double, Double)] = [
            (1.0, 0.0), (1.0, 0.0), (0.0, 1.0), (0.0, 1.0)
        ]
        let withRawProgress: [ScratchLabBabyScratchStrokeSegment] =
            zip(rawStrokes, rawProgress).map { strokeAndProgress in
                let (s, progress) = strokeAndProgress
                return ScratchLabBabyScratchStrokeSegment(
                    startTime: s.startTime,
                    endTime: s.endTime,
                    direction: s.direction,
                    holdAfter: s.holdAfter,
                    startProgress: progress.0,
                    endProgress: progress.1
                )
            }
        let traceForPhrase = ScratchNotationRawTrace.build(from: withRawProgress)
        let result = ScratchNotationPhrasePolyline.build(
            from: traceForPhrase, phraseRanges: [phrase(0.27, 6.5)]
        )
        XCTAssertEqual(result.count, 1)
        let positions = result[0].vertices.map(\.position)
        XCTAssertTrue(positions.contains(0.0))
        XCTAssertTrue(positions.contains(1.0))
    }
}
