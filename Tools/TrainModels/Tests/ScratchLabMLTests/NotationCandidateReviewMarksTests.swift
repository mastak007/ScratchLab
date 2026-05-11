//
//  NotationCandidateReviewMarksTests.swift
//  ScratchLabMLTests — Slice R1
//
//  Tests for `NotationCandidateAccumulator.currentReviewMarks` — the
//  accessor that feeds the Review preview's visual timing-mark strip.
//
//  Behavioural coverage required by the slice spec:
//    * marks count matches the review summary's timingCandidateCount
//      (i.e. the strip uses the filtered Review pass, not raw Advanced)
//    * an empty accumulator returns no marks
//    * dense input is capped at the same 80 budget as the Review summary
//    * marks are returned in ascending timestamp order
//    * silence-gap candidates never appear in the marks stream
//    * raw `currentSummary()` reports more candidates than
//      `currentReviewMarks()` on dense input (so the strip cannot be
//      using raw diagnostics)
//    * reset clears the marks
//    * calling currentReviewMarks does not mutate accumulator state that
//      currentSummary depends on (preview-only invariant)
//

import XCTest
@testable import ScratchLabML

final class NotationCandidateReviewMarksTests: XCTestCase {

    private let sampleRate: Double = 44_100

    // MARK: Helpers

    private func makeImpulseSignal(
        durationSeconds: Double,
        impulseTimes: [Double],
        impulsePeak: Float = 0.7
    ) -> [Float] {
        let count = Int(durationSeconds * sampleRate)
        var s = [Float](repeating: 0, count: count)
        for t in impulseTimes {
            let centre = Int(t * sampleRate)
            for offset in -32...32 {
                let i = centre + offset
                if i >= 0 && i < count {
                    s[i] += impulsePeak * Float(exp(-(Double(offset * offset)) / 80.0))
                }
            }
        }
        return s
    }

    // MARK: Empty inputs

    func testEmptyAccumulatorReturnsNoMarks() {
        let acc = NotationCandidateAccumulator()
        XCTAssertEqual(acc.currentReviewMarks(), [])
    }

    func testQuietInputProducesNoMarks() {
        let acc = NotationCandidateAccumulator()
        // Below the review preset's −40 dB floor.
        let count = Int(1.0 * sampleRate)
        let s = [Float](repeating: 0.0001, count: count)
        acc.pushSamples(s, sampleRate: sampleRate)
        XCTAssertEqual(acc.currentReviewMarks(), [])
    }

    // MARK: Marks track the filtered Review summary (not raw)

    func testMarksCountMatchesReviewSummaryTimingCandidateCount() {
        let acc = NotationCandidateAccumulator()
        let times = [0.30, 0.90, 1.60, 2.20, 2.80]
        let signal = makeImpulseSignal(
            durationSeconds: 3.2, impulseTimes: times, impulsePeak: 0.85
        )
        acc.pushSamples(signal, sampleRate: sampleRate)

        let summary = acc.currentReviewSummary()
        let marks = acc.currentReviewMarks()

        // Review timingCandidateCount excludes silence gaps; marks
        // should equal that count exactly.
        let timing = summary.onsetCount + summary.strokeCount
            + summary.uncertainCount + summary.cutCount
        XCTAssertEqual(marks.count, timing,
                       "marks count must equal the Review summary's timing-candidate count")
        XCTAssertEqual(marks.count, times.count,
                       "strong well-separated impulses should all surface as marks")
    }

    func testMarksAreFilteredNotRawForDenseInput() {
        let acc = NotationCandidateAccumulator()
        // 30 impulses at 80 ms spacing — tighter than the review
        // preset's 200 ms min spacing, so the review pass must drop
        // most of them.
        let times = (0..<30).map { Double($0) * 0.08 + 0.20 }
        let signal = makeImpulseSignal(durationSeconds: 3.0, impulseTimes: times)
        acc.pushSamples(signal, sampleRate: sampleRate)

        let raw = acc.currentSummary()
        let marks = acc.currentReviewMarks()
        let rawTimingCount = raw.onsetCount + raw.strokeCount
            + raw.uncertainCount + raw.cutCount

        XCTAssertGreaterThan(rawTimingCount, marks.count,
                             "raw / Advanced diagnostics must report more candidates than the Review marks on dense input")
        XCTAssertLessThanOrEqual(marks.count, 15,
                                 "200 ms spacing on a 3 s span: at most ~15 marks")
    }

    // MARK: Cap budget

    func testMarksAreCappedAtTheSame80Budget() {
        // Build > 80 well-separated impulses so the review preset
        // accepts them all, then verify the cap kicks in.
        let acc = NotationCandidateAccumulator()
        // 100 impulses, 0.25 s apart (> 200 ms min spacing), strong.
        let times = (0..<100).map { 0.30 + Double($0) * 0.25 }
        let duration = times.last! + 0.30
        let signal = makeImpulseSignal(
            durationSeconds: duration, impulseTimes: times, impulsePeak: 0.85
        )
        acc.pushSamples(signal, sampleRate: sampleRate)

        let marks = acc.currentReviewMarks()
        XCTAssertLessThanOrEqual(marks.count, 80,
                                 "marks must respect the 80-candidate cap")
        XCTAssertGreaterThan(marks.count, 0)
    }

    // MARK: Ordering

    func testMarksAreInAscendingTimestampOrder() {
        let acc = NotationCandidateAccumulator()
        let times = [0.30, 0.90, 1.60, 2.20, 2.80]
        let signal = makeImpulseSignal(
            durationSeconds: 3.2, impulseTimes: times, impulsePeak: 0.85
        )
        acc.pushSamples(signal, sampleRate: sampleRate)

        let marks = acc.currentReviewMarks()
        let sorted = marks.sorted()
        XCTAssertEqual(marks, sorted, "marks must already be in ascending order")
    }

    // MARK: Silence-gap exclusion

    func testMarksNeverIncludeSilenceGaps() {
        // Loud impulse, then silence, then loud impulse — would produce
        // a silence-gap row under the default detector; review preset
        // turns gap detection off, but the marks accessor also defends
        // by filtering silenceGap kinds out.
        let acc = NotationCandidateAccumulator()
        var signal = makeImpulseSignal(
            durationSeconds: 2.0, impulseTimes: [0.20, 1.60]
        )
        for i in Int(0.30 * sampleRate)..<Int(1.50 * sampleRate) {
            signal[i] = 0
        }
        acc.pushSamples(signal, sampleRate: sampleRate)

        let raw = acc.currentSummary()
        let marks = acc.currentReviewMarks()
        let review = acc.currentReviewSummary()

        XCTAssertGreaterThan(raw.silenceGapCount, 0,
                             "sanity: default detector still flags silence gaps")
        XCTAssertEqual(review.silenceGapCount, 0,
                       "review preset disables silence-gap detection")
        // marks count must equal stroke-like count, not stroke-like + gaps.
        let strokeLike = review.onsetCount + review.strokeCount
            + review.uncertainCount + review.cutCount
        XCTAssertEqual(marks.count, strokeLike,
                       "marks count must exclude silence gaps")
    }

    // MARK: Reset

    func testMarksAreEmptyAfterReset() {
        let acc = NotationCandidateAccumulator()
        let signal = makeImpulseSignal(
            durationSeconds: 0.6, impulseTimes: [0.30], impulsePeak: 0.85
        )
        acc.pushSamples(signal, sampleRate: sampleRate)
        XCTAssertFalse(acc.currentReviewMarks().isEmpty)

        acc.reset()
        XCTAssertEqual(acc.currentReviewMarks(), [],
                       "reset must clear marks")
    }

    // MARK: Read-only invariant — marks accessor never mutates state

    func testCallingMarksDoesNotChangeSubsequentSummaries() {
        let acc = NotationCandidateAccumulator()
        let times = [0.30, 0.90, 1.60, 2.20, 2.80]
        let signal = makeImpulseSignal(
            durationSeconds: 3.2, impulseTimes: times, impulsePeak: 0.85
        )
        acc.pushSamples(signal, sampleRate: sampleRate)

        let summaryBefore = acc.currentSummary()
        let reviewBefore = acc.currentReviewSummary()
        _ = acc.currentReviewMarks()
        _ = acc.currentReviewMarks()
        let summaryAfter = acc.currentSummary()
        let reviewAfter = acc.currentReviewSummary()

        XCTAssertEqual(summaryBefore, summaryAfter,
                       "currentReviewMarks must not perturb currentSummary")
        XCTAssertEqual(reviewBefore, reviewAfter,
                       "currentReviewMarks must not perturb currentReviewSummary")
    }

    // MARK: First / last bounds align with summary

    func testMarksRangeFallsWithinSummaryFirstLast() {
        let acc = NotationCandidateAccumulator()
        let times = [0.30, 0.90, 1.60, 2.20, 2.80]
        let signal = makeImpulseSignal(
            durationSeconds: 3.2, impulseTimes: times, impulsePeak: 0.85
        )
        acc.pushSamples(signal, sampleRate: sampleRate)

        let review = acc.currentReviewSummary()
        let marks = acc.currentReviewMarks()
        guard let first = review.firstTimestamp,
              let last = review.lastTimestamp,
              let firstMark = marks.first,
              let lastMark = marks.last else {
            return XCTFail("expected non-empty marks and timestamps")
        }
        XCTAssertEqual(firstMark, first, accuracy: 1e-9,
                       "first mark must equal Review summary's firstTimestamp")
        XCTAssertEqual(lastMark, last, accuracy: 1e-9,
                       "last mark must equal Review summary's lastTimestamp")
    }
}
