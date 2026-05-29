import XCTest
@testable import ScratchLab

/// Locks the contract of `ScratchNotationHoldConnector`: pure,
/// deterministic emission of horizontal hold segments between
/// consecutive trace segments that belong to the same active phrase,
/// suppressed across inter-phrase silence gaps.
///
/// Together with `ScratchNotationPositionTrace` (which carries the
/// cursor forward across reversals) and `ScratchNotationPhraseGate`
/// (which suppresses all drawing during silences), these three pure
/// helpers describe the full Baby Scratch trace geometry:
///
///   - position trace draws sloped lines during each stroke,
///   - hold connectors draw flat lines between strokes inside a phrase,
///   - phrase gate makes the canvas empty when the audio is silent.
///
/// The renderer composes the three; no other Y-position logic should
/// exist in the view itself.
final class ScratchNotationHoldConnectorTests: XCTestCase {

    // MARK: - Helpers

    private func traceSegment(
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

    private func strokeSegment(
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

    // MARK: - 1. Empty input → no connectors

    func testEmptyInputProducesNoConnectors() {
        let connectors = ScratchNotationHoldConnector.connectors(from: [])
        XCTAssertTrue(connectors.isEmpty)
    }

    // MARK: - 2. Single segment → no connectors

    func testSingleSegmentProducesNoConnectors() {
        let trace = [
            traceSegment(startTime: 0, endTime: 0.5, startPosition: 0.5, endPosition: 0.3)
        ]
        let connectors = ScratchNotationHoldConnector.connectors(from: trace)
        XCTAssertTrue(connectors.isEmpty)
    }

    // MARK: - 3. Intra-phrase gap is bridged

    /// Two consecutive trace segments separated by a 0.3 s hold (well
    /// below the 1.5 s default threshold) must produce exactly one
    /// connector running from the first segment's endTime / endPosition
    /// to the second segment's startTime / startPosition.
    func testIntraPhraseGapProducesConnector() {
        let trace = [
            traceSegment(startTime: 0.0, endTime: 0.5, startPosition: 0.5, endPosition: 0.3),
            traceSegment(startTime: 0.8, endTime: 1.2, startPosition: 0.3, endPosition: 0.4),
        ]
        let connectors = ScratchNotationHoldConnector.connectors(from: trace)
        XCTAssertEqual(connectors.count, 1)
        XCTAssertEqual(connectors[0].startTime, 0.5, accuracy: 1e-9)
        XCTAssertEqual(connectors[0].endTime,   0.8, accuracy: 1e-9)
        XCTAssertEqual(connectors[0].position,  0.3, accuracy: 1e-9)
    }

    // MARK: - 4. Inter-phrase silence is NOT bridged

    /// A 5 s gap between two trace segments is well above the 1.5 s
    /// default threshold and must NOT produce a connector. This is the
    /// rule that keeps inter-phrase silences honest — even though the
    /// position trace's carry-forward semantic would happily continue
    /// the cursor, the connector list suppresses any visible line
    /// across the silence.
    func testInterPhraseSilenceProducesNoConnector() {
        let trace = [
            traceSegment(startTime: 0.0, endTime: 0.5, startPosition: 0.5, endPosition: 0.3),
            traceSegment(startTime: 5.5, endTime: 6.0, startPosition: 0.3, endPosition: 0.4),
        ]
        let connectors = ScratchNotationHoldConnector.connectors(from: trace)
        XCTAssertTrue(connectors.isEmpty)
    }

    // MARK: - 5. Mixed: only intra-phrase gaps bridge

    func testMixedGapsOnlyBridgeIntraPhrase() {
        let trace = [
            // Phrase 1: two strokes with a 0.3 s hold
            traceSegment(startTime: 0.0, endTime: 0.5, startPosition: 0.5, endPosition: 0.3),
            traceSegment(startTime: 0.8, endTime: 1.2, startPosition: 0.3, endPosition: 0.4),
            // 5 s silence
            // Phrase 2: two strokes with a 0.2 s hold
            traceSegment(startTime: 6.2, endTime: 6.7, startPosition: 0.4, endPosition: 0.6),
            traceSegment(startTime: 6.9, endTime: 7.4, startPosition: 0.6, endPosition: 0.5),
        ]
        let connectors = ScratchNotationHoldConnector.connectors(from: trace)
        XCTAssertEqual(connectors.count, 2)
        XCTAssertEqual(connectors[0].startTime, 0.5, accuracy: 1e-9)
        XCTAssertEqual(connectors[0].endTime,   0.8, accuracy: 1e-9)
        XCTAssertEqual(connectors[0].position,  0.3, accuracy: 1e-9)
        XCTAssertEqual(connectors[1].startTime, 6.7, accuracy: 1e-9)
        XCTAssertEqual(connectors[1].endTime,   6.9, accuracy: 1e-9)
        XCTAssertEqual(connectors[1].position,  0.6, accuracy: 1e-9)
    }

    // MARK: - 6. Threshold boundary is respected

    func testThresholdBoundaryIsRespected() {
        // Gap exactly at threshold (1.5 s) is treated as intra-phrase
        // — connector emitted. Just above threshold → suppressed.
        let intra = [
            traceSegment(startTime: 0.0, endTime: 0.5, startPosition: 0.5, endPosition: 0.3),
            traceSegment(startTime: 2.0, endTime: 2.5, startPosition: 0.3, endPosition: 0.4),
        ]
        let inter = [
            traceSegment(startTime: 0.0, endTime: 0.5, startPosition: 0.5, endPosition: 0.3),
            traceSegment(startTime: 2.01, endTime: 2.5, startPosition: 0.3, endPosition: 0.4),
        ]
        XCTAssertEqual(
            ScratchNotationHoldConnector.connectors(from: intra).count,
            1,
            "gap of exactly 1.5 s should be treated as intra-phrase"
        )
        XCTAssertEqual(
            ScratchNotationHoldConnector.connectors(from: inter).count,
            0,
            "gap of 1.51 s should be treated as inter-phrase"
        )
    }

    // MARK: - 7. Zero-length gap (back-to-back) → no connector needed

    /// When two trace segments share a timestamp (the bundled JSON has
    /// these: stroke 11 ends exactly where stroke 12 starts), the
    /// connector would have zero duration and is omitted to avoid
    /// emitting an invisible artefact.
    func testZeroLengthGapProducesNoConnector() {
        let trace = [
            traceSegment(startTime: 0.0, endTime: 0.5, startPosition: 0.5, endPosition: 0.3),
            traceSegment(startTime: 0.5, endTime: 1.0, startPosition: 0.3, endPosition: 0.4),
        ]
        let connectors = ScratchNotationHoldConnector.connectors(from: trace)
        XCTAssertTrue(connectors.isEmpty)
    }

    // MARK: - 8. Determinism

    func testDeterministicAcrossReruns() {
        let trace = [
            traceSegment(startTime: 0.0, endTime: 0.5, startPosition: 0.5, endPosition: 0.3),
            traceSegment(startTime: 0.8, endTime: 1.2, startPosition: 0.3, endPosition: 0.4),
            traceSegment(startTime: 6.0, endTime: 6.5, startPosition: 0.4, endPosition: 0.5),
        ]
        let first = ScratchNotationHoldConnector.connectors(from: trace)
        for _ in 0..<99 {
            XCTAssertEqual(
                ScratchNotationHoldConnector.connectors(from: trace),
                first
            )
        }
    }

    // MARK: - 9. Rate calibration: 0.25 walks the bundled phrase 1

    /// Locks the calibrated movement rate the Mac view passes to
    /// `ScratchNotationPositionTrace.derive(...)`. With rate 0.25 the
    /// cursor walks visibly through phrase 1's eleven strokes from
    /// start cursor 0.5 without slamming to a boundary on the very
    /// first stroke. Without recalibration (rate 1.0), the first
    /// backward stroke (0.508 s) alone moves the cursor by 0.508 and
    /// the first three strokes pin it at 0 — defeating any visible
    /// dynamic range.
    func testCalibratedBabyRateProducesVisibleDynamicRange() {
        // Bundled phrase-1 stroke durations & directions.
        let phrase1: [ScratchLabBabyScratchStrokeSegment] = [
            strokeSegment(startTime: 0.27,  endTime: 0.778, direction: .backward),
            strokeSegment(startTime: 1.07,  endTime: 1.378, direction: .backward),
            strokeSegment(startTime: 1.46,  endTime: 1.763, direction: .backward),
            strokeSegment(startTime: 1.84,  endTime: 2.368, direction: .backward),
            strokeSegment(startTime: 2.605, endTime: 2.913, direction: .backward),
            strokeSegment(startTime: 2.99,  endTime: 3.278, direction: .forward),
            strokeSegment(startTime: 3.36,  endTime: 3.928, direction: .backward),
            strokeSegment(startTime: 4.13,  endTime: 4.453, direction: .forward),
            strokeSegment(startTime: 4.52,  endTime: 4.803, direction: .forward),
            strokeSegment(startTime: 4.895, endTime: 5.743, direction: .backward),
            strokeSegment(startTime: 5.743, endTime: 6.5,   direction: .forward),
        ]
        let traceCalibrated = ScratchNotationPositionTrace.derive(
            from: phrase1,
            movementRatePerSecond: MacBabyScratchPracticeGuideRate.calibratedBabyRate
        )
        // At rate 0.25 the first stroke should NOT slam the cursor to
        // a boundary — its endPosition stays strictly between 0 and 1.
        XCTAssertGreaterThan(traceCalibrated[0].endPosition, 0)
        XCTAssertLessThan(traceCalibrated[0].endPosition, 1)
        // The first three same-direction strokes should each show
        // distinct endPositions — no saturation cliff.
        XCTAssertNotEqual(traceCalibrated[0].endPosition, traceCalibrated[1].endPosition)
        XCTAssertNotEqual(traceCalibrated[1].endPosition, traceCalibrated[2].endPosition)
        // The whole phrase should produce at least 0.3 of dynamic
        // range — enough to read visibly on a 156-pt lane.
        let positions = traceCalibrated.flatMap { [$0.startPosition, $0.endPosition] }
        let range = (positions.max() ?? 0) - (positions.min() ?? 0)
        XCTAssertGreaterThan(range, 0.3)
    }

    // MARK: - 10. Long deliberate strokes can still saturate

    /// Calibration must not be so low that *no* stroke can reach the
    /// lane boundary. A deliberate ~2 s stroke at rate 0.25 walks the
    /// cursor by 0.5 — half the lane — proving the lane top remains
    /// reachable for committed motion.
    func testLongStrokeStillReachesBoundary() {
        let long: [ScratchLabBabyScratchStrokeSegment] = [
            strokeSegment(startTime: 0, endTime: 4.0, direction: .forward),
        ]
        let trace = ScratchNotationPositionTrace.derive(
            from: long,
            movementRatePerSecond: MacBabyScratchPracticeGuideRate.calibratedBabyRate
        )
        XCTAssertEqual(trace.count, 1)
        XCTAssertEqual(trace[0].endPosition, 1.0, accuracy: 1e-9)
    }
}
