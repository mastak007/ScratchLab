import XCTest
@testable import ScratchLab

/// Locks the contract of `ScratchNotationAttackMarkers.build(...)`:
/// pure, deterministic emission of one onset marker per audible
/// scratch stroke inside the active phrase ranges. The markers are an
/// additive rhythm-row layer for the Mac Baby Scratch guide — they do
/// not touch the motion trace geometry.
///
/// The helper carries no clock and no UI dependencies; it takes only
/// stroke segments + phrase ranges and returns ordered markers.
final class ScratchNotationAttackMarkersTests: XCTestCase {

    // MARK: - Fixtures

    private func segment(
        _ start: TimeInterval,
        _ end: TimeInterval,
        _ direction: ScratchMotionDirection
    ) -> ScratchLabBabyScratchStrokeSegment {
        // startProgress / endProgress are irrelevant to onset markers;
        // give them honest baby-scratch sweep values so the fixtures
        // read like real data.
        let (startProgress, endProgress): (Double, Double)
        switch direction {
        case .forward: (startProgress, endProgress) = (0.0, 1.0)
        case .backward: (startProgress, endProgress) = (1.0, 0.0)
        case .neutral: (startProgress, endProgress) = (0.0, 0.0)
        }
        return ScratchLabBabyScratchStrokeSegment(
            startTime: start,
            endTime: end,
            direction: direction,
            holdAfter: 0,
            startProgress: startProgress,
            endProgress: endProgress
        )
    }

    /// The 11 audible strokes of the bundled Baby Scratch demo's first
    /// phrase (`baby_scratch_strokes.json`, strokes 1–11). Times taken
    /// verbatim from the JSON.
    private func phraseOneSegments() -> [ScratchLabBabyScratchStrokeSegment] {
        [
            segment(0.27, 0.778, .backward),
            segment(1.07, 1.378, .backward),
            segment(1.46, 1.763, .backward),
            segment(1.84, 2.368, .backward),
            segment(2.605, 2.913, .backward),
            segment(2.99, 3.278, .forward),
            segment(3.36, 3.928, .backward),
            segment(4.13, 4.453, .forward),
            segment(4.52, 4.803, .forward),
            segment(4.895, 5.743, .backward),
            segment(5.743, 6.5, .forward),
        ]
    }

    // MARK: - 1. Empty input gives empty markers

    func testEmptyInputsGiveEmptyMarkers() {
        let segments = phraseOneSegments()
        let ranges = ScratchNotationPhraseGate.activePhraseRanges(from: segments)
        XCTAssertTrue(ScratchNotationAttackMarkers.build(from: [], phraseRanges: ranges).isEmpty)
        XCTAssertTrue(ScratchNotationAttackMarkers.build(from: segments, phraseRanges: []).isEmpty)
        XCTAssertTrue(ScratchNotationAttackMarkers.build(from: [], phraseRanges: []).isEmpty)
    }

    // MARK: - 2. One stroke gives one marker at startTime

    func testSingleStrokeGivesOneMarkerAtStartTime() {
        let segments = [segment(0.27, 0.778, .backward)]
        let ranges = ScratchNotationPhraseGate.activePhraseRanges(from: segments)
        let markers = ScratchNotationAttackMarkers.build(
            from: segments, phraseRanges: ranges
        )
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers.first?.time ?? -1, 0.27, accuracy: 1e-9)
        XCTAssertEqual(markers.first?.direction, .backward)
        XCTAssertEqual(markers.first?.phraseIndex, 0)
    }

    // MARK: - 3. Neutral strokes skipped

    func testNeutralStrokesSkipped() {
        let segments = [
            segment(0.27, 0.778, .backward),
            segment(0.9, 1.2, .neutral),
            segment(1.46, 1.763, .forward),
        ]
        let ranges = ScratchNotationPhraseGate.activePhraseRanges(from: segments)
        let markers = ScratchNotationAttackMarkers.build(
            from: segments, phraseRanges: ranges
        )
        XCTAssertEqual(markers.map(\.time), [0.27, 1.46])
    }

    // MARK: - 4. Markers only inside phrase ranges

    /// A stroke whose onset sits outside every supplied range is
    /// dropped. Here a single-phrase range covers only the first
    /// cluster; a stroke past the range end is excluded.
    func testMarkersOnlyInsidePhraseRanges() {
        let segments = [
            segment(0.27, 0.778, .backward),
            segment(1.07, 1.378, .backward),
            // far-away stroke, outside the restricted range below
            segment(20.0, 20.4, .forward),
        ]
        let restricted = [ScratchNotationPhraseRange(start: 0.27, end: 1.378)]
        let markers = ScratchNotationAttackMarkers.build(
            from: segments, phraseRanges: restricted
        )
        XCTAssertEqual(markers.map(\.time), [0.27, 1.07])
    }

    // MARK: - 5. Phrase 1 marker times equal the 11 expected stroke starts

    func testPhraseOneMarkerTimesMatchExpected() {
        let segments = phraseOneSegments()
        let ranges = ScratchNotationPhraseGate.activePhraseRanges(from: segments)
        // All 11 strokes fall in a single phrase (max intra gap < 1.5 s).
        XCTAssertEqual(ranges.count, 1)
        let markers = ScratchNotationAttackMarkers.build(
            from: segments, phraseRanges: ranges
        )
        let expected: [TimeInterval] = [
            0.27, 1.07, 1.46, 1.84, 2.605, 2.99, 3.36, 4.13, 4.52, 4.895, 5.743,
        ]
        XCTAssertEqual(markers.count, expected.count)
        for (marker, time) in zip(markers, expected) {
            XCTAssertEqual(marker.time, time, accuracy: 1e-9)
            XCTAssertEqual(marker.phraseIndex, 0)
        }
    }

    // MARK: - 6. Output is sorted by time

    func testMarkersSortedByTime() {
        // Feed strokes out of order; output must still be time-sorted.
        let segments = [
            segment(4.13, 4.453, .forward),
            segment(0.27, 0.778, .backward),
            segment(2.605, 2.913, .backward),
        ]
        let ranges = ScratchNotationPhraseGate.activePhraseRanges(from: segments)
        let markers = ScratchNotationAttackMarkers.build(
            from: segments, phraseRanges: ranges
        )
        let times = markers.map(\.time)
        XCTAssertEqual(times, times.sorted())
        XCTAssertEqual(times, [0.27, 2.605, 4.13])
    }

    // MARK: - 7. phraseIndex tracks the containing range across phrases

    func testPhraseIndexAcrossMultiplePhrases() {
        let segments = [
            segment(0.27, 0.778, .backward),
            segment(1.07, 1.378, .forward),
            // 5+ s gap → second phrase
            segment(12.0, 12.5, .backward),
            segment(12.7, 13.0, .forward),
        ]
        let ranges = ScratchNotationPhraseGate.activePhraseRanges(from: segments)
        XCTAssertEqual(ranges.count, 2)
        let markers = ScratchNotationAttackMarkers.build(
            from: segments, phraseRanges: ranges
        )
        XCTAssertEqual(markers.map(\.phraseIndex), [0, 0, 1, 1])
        XCTAssertEqual(markers.map(\.time), [0.27, 1.07, 12.0, 12.7])
    }

    // MARK: - 8. Determinism

    func testDeterministicAcrossReruns() {
        let segments = phraseOneSegments()
        let ranges = ScratchNotationPhraseGate.activePhraseRanges(from: segments)
        let first = ScratchNotationAttackMarkers.build(
            from: segments, phraseRanges: ranges
        )
        for _ in 0..<99 {
            XCTAssertEqual(
                ScratchNotationAttackMarkers.build(
                    from: segments, phraseRanges: ranges
                ),
                first
            )
        }
    }
}
