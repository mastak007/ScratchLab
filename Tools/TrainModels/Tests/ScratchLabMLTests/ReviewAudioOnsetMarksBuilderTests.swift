//
//  ReviewAudioOnsetMarksBuilderTests.swift
//  ScratchLabMLTests — Slice S
//
//  Tests for the take-scoped marks/summary builder. Mirrors the
//  expectations the live `currentReviewMarks` covers:
//    * empty input → empty
//    * input.count ≤ cap → all events kept, returned in ascending
//      timestamp order
//    * input.count > cap → strongest events kept (by peakLevel), then
//      re-sorted by timestamp ascending
//    * summary mirrors the cap so the card never disagrees with itself
//    * cap can be lowered for tests, default is 80 (matches live)
//

import XCTest
@testable import ScratchLabML

final class ReviewAudioOnsetMarksBuilderTests: XCTestCase {

    // MARK: Empty / degenerate inputs

    func testEmptyInputProducesEmptyMarksAndZeroSummary() {
        let marks = ReviewAudioOnsetMarksBuilder.buildFromTakeEvents([])
        XCTAssertEqual(marks, [])

        let s = ReviewAudioOnsetMarksBuilder.summarizeTakeEvents([])
        XCTAssertEqual(s.timingCandidateCount, 0)
        XCTAssertEqual(s.rawEventCount, 0)
        XCTAssertNil(s.firstTimestamp)
        XCTAssertNil(s.lastTimestamp)
    }

    func testZeroOrNegativeCapProducesEmptyMarks() {
        let events = [
            ReviewAudioOnsetTakeEvent(startTime: 0.1, peakLevel: 0.5),
            ReviewAudioOnsetTakeEvent(startTime: 0.2, peakLevel: 0.6),
        ]
        XCTAssertEqual(
            ReviewAudioOnsetMarksBuilder.buildFromTakeEvents(events, maxMarks: 0),
            []
        )
        XCTAssertEqual(
            ReviewAudioOnsetMarksBuilder.buildFromTakeEvents(events, maxMarks: -3),
            []
        )
    }

    // MARK: Under-cap path

    func testEventsUnderCapAreReturnedAllInTimestampOrder() {
        let events = [
            ReviewAudioOnsetTakeEvent(startTime: 2.20, peakLevel: 0.3),
            ReviewAudioOnsetTakeEvent(startTime: 0.30, peakLevel: 0.9),
            ReviewAudioOnsetTakeEvent(startTime: 1.10, peakLevel: 0.5),
        ]
        let marks = ReviewAudioOnsetMarksBuilder.buildFromTakeEvents(events)
        XCTAssertEqual(marks, [0.30, 1.10, 2.20])
    }

    // MARK: Over-cap path

    func testEventsOverCapKeepStrongestThenSortByTimestamp() {
        // Cap 3; the strongest are at indices 0, 2, 4 (peak 0.9, 0.8, 0.85).
        // After cap by peakLevel desc → [0, 4, 2] (peaks 0.9, 0.85, 0.8).
        // Re-sorted by timestamp → [0 (0.10), 2 (0.30), 4 (0.50)].
        let events = [
            ReviewAudioOnsetTakeEvent(startTime: 0.10, peakLevel: 0.90),
            ReviewAudioOnsetTakeEvent(startTime: 0.20, peakLevel: 0.40),
            ReviewAudioOnsetTakeEvent(startTime: 0.30, peakLevel: 0.80),
            ReviewAudioOnsetTakeEvent(startTime: 0.40, peakLevel: 0.30),
            ReviewAudioOnsetTakeEvent(startTime: 0.50, peakLevel: 0.85),
            ReviewAudioOnsetTakeEvent(startTime: 0.60, peakLevel: 0.20),
        ]
        let marks = ReviewAudioOnsetMarksBuilder.buildFromTakeEvents(events, maxMarks: 3)
        XCTAssertEqual(marks.count, 3)
        XCTAssertEqual(marks, [0.10, 0.30, 0.50])
    }

    func testDefaultCapMatchesLivePipeline() {
        XCTAssertEqual(
            ReviewAudioOnsetMarksBuilder.defaultMaxMarks, 80,
            "default cap must match NotationCandidateAccumulator.currentReviewMarks's 80 so live + take previews agree on the budget"
        )
    }

    func testOver80EventsAreCappedAt80ByDefault() {
        var events: [ReviewAudioOnsetTakeEvent] = []
        for i in 0..<120 {
            // Stagger peakLevel so the cap has a deterministic ranking.
            events.append(
                ReviewAudioOnsetTakeEvent(
                    startTime: 0.25 * Double(i),
                    peakLevel: Double(i) / 200.0
                )
            )
        }
        let marks = ReviewAudioOnsetMarksBuilder.buildFromTakeEvents(events)
        XCTAssertEqual(marks.count, 80)
        // Sorted ascending.
        XCTAssertEqual(marks, marks.sorted())
    }

    // MARK: Summary mirrors the cap

    func testSummaryReportsCappedTimingAndRawCount() {
        let events = (0..<10).map { i in
            ReviewAudioOnsetTakeEvent(
                startTime: 0.10 * Double(i + 1),
                peakLevel: 0.10 * Double(i + 1)
            )
        }
        let s = ReviewAudioOnsetMarksBuilder.summarizeTakeEvents(events, maxMarks: 4)
        XCTAssertEqual(s.timingCandidateCount, 4)
        XCTAssertEqual(s.rawEventCount, 10)
        XCTAssertNotNil(s.firstTimestamp)
        XCTAssertNotNil(s.lastTimestamp)
        // First/last must be drawn from the capped + time-sorted set.
        if let first = s.firstTimestamp, let last = s.lastTimestamp {
            XCTAssertLessThanOrEqual(first, last)
        }
    }

    func testSummaryUnderCapHasMatchingTimingAndRawCount() {
        let events = [
            ReviewAudioOnsetTakeEvent(startTime: 0.1, peakLevel: 0.5),
            ReviewAudioOnsetTakeEvent(startTime: 0.2, peakLevel: 0.6),
        ]
        let s = ReviewAudioOnsetMarksBuilder.summarizeTakeEvents(events)
        XCTAssertEqual(s.timingCandidateCount, 2)
        XCTAssertEqual(s.rawEventCount, 2)
        XCTAssertEqual(s.firstTimestamp, 0.1)
        XCTAssertEqual(s.lastTimestamp, 0.2)
    }

    // MARK: Builder does not mutate inputs

    func testBuilderDoesNotMutateInputArray() {
        let events = [
            ReviewAudioOnsetTakeEvent(startTime: 0.10, peakLevel: 0.90),
            ReviewAudioOnsetTakeEvent(startTime: 0.20, peakLevel: 0.40),
            ReviewAudioOnsetTakeEvent(startTime: 0.30, peakLevel: 0.80),
        ]
        let snapshot = events
        _ = ReviewAudioOnsetMarksBuilder.buildFromTakeEvents(events, maxMarks: 1)
        _ = ReviewAudioOnsetMarksBuilder.summarizeTakeEvents(events, maxMarks: 1)
        XCTAssertEqual(events, snapshot, "builder must treat input as read-only")
    }
}
