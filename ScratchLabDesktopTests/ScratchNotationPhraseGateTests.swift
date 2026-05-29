import XCTest
@testable import ScratchLab

/// Locks the contract of `ScratchNotationPhraseGate`: pure, deterministic
/// derivation of "active phrase" ranges from a list of stroke segments,
/// plus a point-in-range lookup used by the macOS Baby Scratch practice
/// guide to suppress trace rendering during inter-phrase silences.
///
/// Tests are written against **synthetic** stroke inputs that mirror
/// the bundled JSON's phrase structure (four phrases with 5+ second
/// silences between them, starting at 0.27 / 11.5 / 23.7 / 35.7 and
/// ending at 6.5 / 18.6 / 30.45 / 42.4). Running against the live
/// `BabyScratchReferenceMotionTimeline.strokeSegments` is gated behind
/// `usesExtractedStrokeResource` because the test bundle does not ship
/// the JSON resource — under XCTest, `.main = test bundle`, the JSON
/// fails to load, and `strokeSegments` falls back to a single-phrase
/// hardcoded stub that would not exercise the multi-phrase code path.
final class ScratchNotationPhraseGateTests: XCTestCase {

    // MARK: - Helpers

    private func segment(
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

    /// Synthetic four-phrase stroke list shaped like the bundled JSON.
    /// Phrase boundaries (start, end): (0.27, 6.5), (11.5, 18.6),
    /// (23.7, 30.45), (35.7, 42.4). Each phrase contains six short
    /// strokes with intra-phrase gaps ≤ 1.0 s (below the 1.5 s
    /// default threshold). Inter-phrase gaps are 5.0 / 5.1 / 5.25
    /// seconds — well above the threshold — so the gate must produce
    /// exactly four ranges.
    private var syntheticFourPhraseSegments: [ScratchLabBabyScratchStrokeSegment] {
        var segments: [ScratchLabBabyScratchStrokeSegment] = []
        for phrase in [(0.27, 6.50), (11.50, 18.60), (23.70, 30.45), (35.70, 42.40)] {
            let (start, end) = phrase
            // Six evenly-spaced 0.4 s strokes spanning the phrase.
            // Adjacent strokes are separated by ~0.85 s gaps for the
            // 6.23 s phrase 1 and proportionally less for the longer
            // phrases — all well below the 1.5 s threshold.
            let span = end - start
            let strokeDuration = 0.4
            for index in 0..<6 {
                let s = start + Double(index) * (span / 6.0)
                let e = min(end, s + strokeDuration)
                segments.append(
                    segment(
                        startTime: s,
                        endTime: e,
                        direction: index.isMultiple(of: 2) ? .forward : .backward
                    )
                )
            }
            // Close the phrase exactly at `end` so the range's `end`
            // matches the expected upper bound to ~1e-9.
            segments.append(
                segment(startTime: end - strokeDuration, endTime: end, direction: .forward)
            )
        }
        return segments
    }

    // MARK: - 1. Empty input produces no ranges

    func testEmptyInputProducesNoRanges() {
        let ranges = ScratchNotationPhraseGate.activePhraseRanges(from: [])
        XCTAssertTrue(ranges.isEmpty)
    }

    // MARK: - 2. Contiguous strokes cluster into a single phrase

    func testSinglePhraseFromContiguousStrokes() {
        let segments: [ScratchLabBabyScratchStrokeSegment] = [
            segment(startTime: 0.10, endTime: 0.30),
            segment(startTime: 0.40, endTime: 0.60),
            segment(startTime: 0.70, endTime: 0.90),
        ]
        let ranges = ScratchNotationPhraseGate.activePhraseRanges(from: segments)
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0].start, 0.10, accuracy: 1e-9)
        XCTAssertEqual(ranges[0].end,   0.90, accuracy: 1e-9)
    }

    // MARK: - 3. Gap above threshold splits into two ranges

    func testGapAboveThresholdSplitsIntoTwoRanges() {
        let segments: [ScratchLabBabyScratchStrokeSegment] = [
            segment(startTime: 0.0, endTime: 0.5),
            segment(startTime: 0.7, endTime: 1.0),
            // Gap of 2.5 s → exceeds default 1.5 s threshold.
            segment(startTime: 3.5, endTime: 4.0),
            segment(startTime: 4.2, endTime: 4.5),
        ]
        let ranges = ScratchNotationPhraseGate.activePhraseRanges(from: segments)
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0].start, 0.0, accuracy: 1e-9)
        XCTAssertEqual(ranges[0].end,   1.0, accuracy: 1e-9)
        XCTAssertEqual(ranges[1].start, 3.5, accuracy: 1e-9)
        XCTAssertEqual(ranges[1].end,   4.5, accuracy: 1e-9)
    }

    // MARK: - 4. Four-phrase silence pattern produces four ranges

    /// Locks the exact ranges expected from a stroke list shaped like
    /// the bundled JSON. This is the algorithmic contract the live
    /// bundled data depends on. The bundled-data round-trip is verified
    /// separately in `testBundledDataIfAvailable` below.
    func testFourPhraseSilencePatternProducesFourRanges() {
        let ranges = ScratchNotationPhraseGate.activePhraseRanges(
            from: syntheticFourPhraseSegments
        )
        XCTAssertEqual(ranges.count, 4)
        XCTAssertEqual(ranges[0].start, 0.27,  accuracy: 1e-9)
        XCTAssertEqual(ranges[0].end,   6.50,  accuracy: 1e-9)
        XCTAssertEqual(ranges[1].start, 11.50, accuracy: 1e-9)
        XCTAssertEqual(ranges[1].end,   18.60, accuracy: 1e-9)
        XCTAssertEqual(ranges[2].start, 23.70, accuracy: 1e-9)
        XCTAssertEqual(ranges[2].end,   30.45, accuracy: 1e-9)
        XCTAssertEqual(ranges[3].start, 35.70, accuracy: 1e-9)
        XCTAssertEqual(ranges[3].end,   42.40, accuracy: 1e-9)
    }

    // MARK: - 5. Known in-stroke times → true

    func testIsInActivePhraseInsideStroke() {
        let ranges = ScratchNotationPhraseGate.activePhraseRanges(
            from: syntheticFourPhraseSegments
        )
        for t: TimeInterval in [0.5, 3.0, 5.0, 12.5, 25.0, 38.0] {
            XCTAssertTrue(
                ScratchNotationPhraseGate.isInActivePhrase(t, ranges: ranges),
                "expected t=\(t) to be inside an active phrase"
            )
        }
    }

    // MARK: - 6. Known silence times → false (locks the forensic bug)

    func testIsInActivePhraseInsideSilence() {
        let ranges = ScratchNotationPhraseGate.activePhraseRanges(
            from: syntheticFourPhraseSegments
        )
        // These are the exact audio times where the forensic on
        // macNotation.mp4 showed false notes during in-playback silence.
        // The gate MUST return false at these moments, otherwise the
        // canvas re-introduces lookahead/trailing strokes during dead
        // air.
        for t: TimeInterval in [9.0, 22.0, 33.0] {
            XCTAssertFalse(
                ScratchNotationPhraseGate.isInActivePhrase(t, ranges: ranges),
                "expected t=\(t) to be inside a silence gap, but gate returned true"
            )
        }
    }

    // MARK: - 7. Boundary edges

    /// Locks the chosen boundary semantics so a future refactor can't
    /// reintroduce a one-frame flicker at phrase start / end. Inclusive
    /// at both ends.
    func testIsInActivePhraseAtBoundaryEdges() {
        let segments: [ScratchLabBabyScratchStrokeSegment] = [
            segment(startTime: 1.0, endTime: 2.0),
            segment(startTime: 5.0, endTime: 6.0),
        ]
        let ranges = ScratchNotationPhraseGate.activePhraseRanges(from: segments)
        XCTAssertTrue(ScratchNotationPhraseGate.isInActivePhrase(1.0, ranges: ranges))
        XCTAssertTrue(ScratchNotationPhraseGate.isInActivePhrase(2.0, ranges: ranges))
        XCTAssertTrue(ScratchNotationPhraseGate.isInActivePhrase(5.0, ranges: ranges))
        XCTAssertTrue(ScratchNotationPhraseGate.isInActivePhrase(6.0, ranges: ranges))
        // Strictly outside both ranges.
        XCTAssertFalse(ScratchNotationPhraseGate.isInActivePhrase(0.5, ranges: ranges))
        XCTAssertFalse(ScratchNotationPhraseGate.isInActivePhrase(3.5, ranges: ranges))
        XCTAssertFalse(ScratchNotationPhraseGate.isInActivePhrase(7.0, ranges: ranges))
    }

    // MARK: - 8. Pre- and post-audio times → false

    /// Covers the paused-pre-Replay and audio-finished states, where
    /// the demo player may still return a time (0 before play, the
    /// final time after end) but no phrase contains it.
    func testIsInActivePhrasePreAndPostAudio() {
        let ranges = ScratchNotationPhraseGate.activePhraseRanges(
            from: syntheticFourPhraseSegments
        )
        XCTAssertFalse(ScratchNotationPhraseGate.isInActivePhrase(-1.0,  ranges: ranges))
        XCTAssertFalse(ScratchNotationPhraseGate.isInActivePhrase(0.0,   ranges: ranges))
        XCTAssertFalse(ScratchNotationPhraseGate.isInActivePhrase(50.0,  ranges: ranges))
        XCTAssertFalse(ScratchNotationPhraseGate.isInActivePhrase(100.0, ranges: ranges))
    }

    // MARK: - 9. Neutral segments are ignored when clustering

    /// Neutral (explicit-hold) segments must not extend a phrase or
    /// bridge two phrases that would otherwise be separated by a long
    /// silence.
    func testNeutralSegmentsIgnored() {
        let segments: [ScratchLabBabyScratchStrokeSegment] = [
            segment(startTime: 0.0, endTime: 0.5),
            // Long neutral straddling the gap. If counted, it would
            // merge the two real phrases into one.
            segment(startTime: 1.0, endTime: 4.0, direction: .neutral),
            segment(startTime: 5.0, endTime: 5.5),
        ]
        let ranges = ScratchNotationPhraseGate.activePhraseRanges(from: segments)
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0].end, 0.5, accuracy: 1e-9)
        XCTAssertEqual(ranges[1].start, 5.0, accuracy: 1e-9)
    }

    // MARK: - 10. Determinism

    func testDeterministicAcrossReruns() {
        let segments = syntheticFourPhraseSegments
        let first = ScratchNotationPhraseGate.activePhraseRanges(from: segments)
        for _ in 0..<99 {
            XCTAssertEqual(
                ScratchNotationPhraseGate.activePhraseRanges(from: segments),
                first
            )
        }
    }

    // MARK: - 11. Bundled-data round-trip (skipped under XCTest)

    /// When the test runs in a host that has loaded the bundled JSON
    /// resource (the app at runtime, or a future test target that
    /// embeds CoachDemoMotion), this asserts the live data still
    /// produces exactly four phrases at the expected times. Under
    /// XCTest the JSON is not in the test bundle, so the live data
    /// falls back to a single short stub — this case is skipped, and
    /// the synthetic test above is the contract.
    func testBundledDataIfAvailable() throws {
        try XCTSkipUnless(
            BabyScratchReferenceMotionTimeline.usesExtractedStrokeResource,
            "Skipping bundled-data round-trip: JSON resource is not loaded in the test bundle."
        )
        let ranges = ScratchNotationPhraseGate.activePhraseRanges(
            from: BabyScratchReferenceMotionTimeline.strokeSegments
        )
        XCTAssertEqual(ranges.count, 4)
        XCTAssertEqual(ranges[0].start, 0.27,  accuracy: 0.01)
        XCTAssertEqual(ranges[0].end,   6.50,  accuracy: 0.01)
        XCTAssertEqual(ranges[3].start, 35.70, accuracy: 0.01)
        XCTAssertEqual(ranges[3].end,   42.40, accuracy: 0.01)
    }
}
