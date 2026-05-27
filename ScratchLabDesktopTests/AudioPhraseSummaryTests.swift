import XCTest
@testable import ScratchLab

final class AudioPhraseSummaryTests: XCTestCase {

    private func event(
        start: Double,
        end: Double,
        kind: String,
        confidence: Double = 0.8
    ) -> CaptureCore.DetectedNotationAudioEvent {
        CaptureCore.DetectedNotationAudioEvent(
            startTime: start,
            endTime: end,
            duration: end - start,
            peakLevel: -12.0,
            rmsLevel: -18.0,
            confidence: confidence,
            eventKind: kind,
            source: "test"
        )
    }

    // 1. empty input returns empty summary
    func test_emptyInput_returnsEmptySummary() {
        let summary = AudioPhraseGrouper.summary(for: [])
        XCTAssertTrue(summary.spans.isEmpty)
        XCTAssertEqual(summary.gapThresholdSeconds, AudioPhraseGrouper.defaultGapThresholdSeconds)
        XCTAssertEqual(summary.highConfidenceThreshold, AudioPhraseGrouper.defaultHighConfidenceThreshold)
        XCTAssertEqual(summary.releaseTailMinSeconds, AudioPhraseGrouper.defaultReleaseTailMinSeconds)
    }

    // 2. all silenceGap input returns empty summary
    func test_allSilenceGap_returnsEmptySummary() {
        let events = [
            event(start: 0.0, end: 1.0, kind: "silenceGap"),
            event(start: 1.0, end: 3.0, kind: "silenceGap"),
            event(start: 3.0, end: 5.0, kind: "silenceGap"),
        ]
        let summary = AudioPhraseGrouper.summary(for: events)
        XCTAssertTrue(summary.spans.isEmpty)
    }

    // 3. single active event returns one phrase
    func test_singleActiveEvent_returnsOnePhrase() {
        let events = [event(start: 0.5, end: 0.9, kind: "scratchBurst")]
        let summary = AudioPhraseGrouper.summary(for: events)
        XCTAssertEqual(summary.spans.count, 1)
        let span = try? XCTUnwrap(summary.spans.first)
        XCTAssertEqual(span?.startTime, 0.5)
        XCTAssertEqual(span?.endTime, 0.9)
        XCTAssertEqual(span?.firstEventIndex, 0)
        XCTAssertEqual(span?.lastEventIndex, 0)
        XCTAssertEqual(span?.activeEventCount, 1)
        XCTAssertEqual(span?.scratchBurstCount, 1)
        XCTAssertEqual(span?.possibleDragCount, 0)
        XCTAssertEqual(span?.possibleCutCount, 0)
        XCTAssertNil(span?.terminalDragDuration)
    }

    // 4. two events within threshold return one phrase
    func test_twoEventsWithinThreshold_returnOnePhrase() {
        let events = [
            event(start: 0.0, end: 0.3, kind: "scratchBurst"),
            event(start: 0.5, end: 0.8, kind: "scratchBurst"),
        ]
        let summary = AudioPhraseGrouper.summary(for: events, gapThresholdSeconds: 1.0)
        XCTAssertEqual(summary.spans.count, 1)
        XCTAssertEqual(summary.spans.first?.activeEventCount, 2)
        XCTAssertEqual(summary.spans.first?.firstEventIndex, 0)
        XCTAssertEqual(summary.spans.first?.lastEventIndex, 1)
    }

    // 5. two events beyond threshold return two phrases
    func test_twoEventsBeyondThreshold_returnTwoPhrases() {
        let events = [
            event(start: 0.0, end: 0.2, kind: "scratchBurst"),
            event(start: 5.0, end: 5.2, kind: "scratchBurst"),
        ]
        let summary = AudioPhraseGrouper.summary(for: events, gapThresholdSeconds: 2.0)
        XCTAssertEqual(summary.spans.count, 2)
        XCTAssertEqual(summary.spans[0].lastEventIndex, 0)
        XCTAssertEqual(summary.spans[1].firstEventIndex, 1)
    }

    // 6. mixed drag/burst/cut counts are correct
    func test_mixedCounts_areCorrect() {
        let events = [
            event(start: 0.0, end: 0.3, kind: "scratchBurst"),
            event(start: 0.4, end: 0.7, kind: "possibleDrag"),
            event(start: 0.8, end: 0.9, kind: "possibleCut"),
            event(start: 1.0, end: 1.4, kind: "possibleDrag"),
            event(start: 1.5, end: 1.7, kind: "scratchBurst"),
        ]
        let summary = AudioPhraseGrouper.summary(for: events, gapThresholdSeconds: 1.0)
        XCTAssertEqual(summary.spans.count, 1)
        let span = summary.spans.first
        XCTAssertEqual(span?.scratchBurstCount, 2)
        XCTAssertEqual(span?.possibleDragCount, 2)
        XCTAssertEqual(span?.possibleCutCount, 1)
        XCTAssertEqual(span?.activeEventCount, 5)
    }

    // 7. over-threshold gap splits a drag-burst-drag sequence
    func test_overThresholdGap_splitsDragBurstDrag() {
        let events = [
            event(start: 0.0, end: 0.4, kind: "possibleDrag"),
            event(start: 0.5, end: 0.7, kind: "scratchBurst"),
            event(start: 5.0, end: 5.4, kind: "possibleDrag"),
        ]
        let summary = AudioPhraseGrouper.summary(for: events, gapThresholdSeconds: 2.0)
        XCTAssertEqual(summary.spans.count, 2)
        XCTAssertEqual(summary.spans[0].possibleDragCount, 1)
        XCTAssertEqual(summary.spans[0].scratchBurstCount, 1)
        XCTAssertEqual(summary.spans[1].possibleDragCount, 1)
        XCTAssertEqual(summary.spans[1].scratchBurstCount, 0)
    }

    // 8. terminal release tail detected
    func test_terminalReleaseTail_detected() throws {
        let events = [
            event(start: 0.0, end: 0.3, kind: "scratchBurst"),
            event(start: 0.4, end: 0.6, kind: "possibleDrag"),
            event(start: 0.7, end: 2.2, kind: "possibleDrag"),
        ]
        let summary = AudioPhraseGrouper.summary(
            for: events,
            gapThresholdSeconds: 1.0,
            releaseTailMinSeconds: 1.0
        )
        XCTAssertEqual(summary.spans.count, 1)
        let terminal = try XCTUnwrap(summary.spans.first?.terminalDragDuration)
        XCTAssertEqual(terminal, 1.5, accuracy: 1e-9)
    }

    // 9. short / non-dominant terminal drag rejected
    func test_shortTerminalDrag_isRejected() {
        let shortTail = [
            event(start: 0.0, end: 0.3, kind: "possibleDrag"),
            event(start: 0.4, end: 0.7, kind: "possibleDrag"),
        ]
        let shortSummary = AudioPhraseGrouper.summary(
            for: shortTail,
            gapThresholdSeconds: 1.0,
            releaseTailMinSeconds: 1.0
        )
        XCTAssertEqual(shortSummary.spans.count, 1)
        XCTAssertNil(shortSummary.spans.first?.terminalDragDuration,
                     "terminal drag shorter than releaseTailMinSeconds must not register")

        let nonDominant = [
            event(start: 0.0, end: 3.0, kind: "possibleDrag"),
            event(start: 3.1, end: 4.3, kind: "possibleDrag"),
        ]
        let nonDominantSummary = AudioPhraseGrouper.summary(
            for: nonDominant,
            gapThresholdSeconds: 1.0,
            releaseTailMinSeconds: 1.0
        )
        XCTAssertEqual(nonDominantSummary.spans.count, 1)
        XCTAssertNil(nonDominantSummary.spans.first?.terminalDragDuration,
                     "terminal drag shorter than an earlier drag must not register as the release tail")
    }

    // 10. high-confidence drag count respects threshold
    func test_highConfidenceDragCount_respectsThreshold() {
        let events = [
            event(start: 0.0, end: 0.3, kind: "possibleDrag", confidence: 0.49),
            event(start: 0.4, end: 0.7, kind: "possibleDrag", confidence: 0.50),
            event(start: 0.8, end: 1.1, kind: "possibleDrag", confidence: 0.92),
            event(start: 1.2, end: 1.4, kind: "scratchBurst", confidence: 0.99),
        ]
        let summary = AudioPhraseGrouper.summary(
            for: events,
            gapThresholdSeconds: 1.0,
            highConfidenceThreshold: 0.5
        )
        XCTAssertEqual(summary.spans.count, 1)
        XCTAssertEqual(summary.spans.first?.possibleDragCount, 3)
        XCTAssertEqual(summary.spans.first?.highConfidenceDragCount, 2,
                       "only drags with confidence >= threshold count toward highConfidenceDragCount")
    }

    // 11. repeated grouping is deterministic
    func test_repeatedGrouping_isDeterministic() {
        let events = [
            event(start: 0.0, end: 0.3, kind: "scratchBurst"),
            event(start: 0.4, end: 0.7, kind: "possibleDrag"),
            event(start: 3.0, end: 3.5, kind: "silenceGap"),
            event(start: 4.0, end: 4.4, kind: "possibleCut"),
        ]
        let first = AudioPhraseGrouper.summary(for: events)
        let second = AudioPhraseGrouper.summary(for: events)
        let third = AudioPhraseGrouper.summary(for: events)
        XCTAssertEqual(first, second)
        XCTAssertEqual(second, third)
    }

    // 12. threshold override re-splits a fixture
    func test_thresholdOverride_reSplitsFixture() {
        let events = [
            event(start: 0.0, end: 0.3, kind: "scratchBurst"),
            event(start: 1.5, end: 1.8, kind: "scratchBurst"),
        ]
        let coarse = AudioPhraseGrouper.summary(for: events, gapThresholdSeconds: 2.0)
        let fine = AudioPhraseGrouper.summary(for: events, gapThresholdSeconds: 0.5)
        XCTAssertEqual(coarse.spans.count, 1)
        XCTAssertEqual(fine.spans.count, 2)
    }

    // 13. no technique/family/coaching/scoring fields exist in the new model
    func test_modelShape_hasNoTechniqueFamilyCoachingScoringFields() {
        let span = AudioPhraseSpan(
            startTime: 0.0,
            endTime: 1.0,
            firstEventIndex: 0,
            lastEventIndex: 0,
            activeEventCount: 1,
            possibleDragCount: 0,
            scratchBurstCount: 1,
            possibleCutCount: 0,
            highConfidenceDragCount: 0,
            terminalDragDuration: nil
        )
        let summary = AudioPhraseSummary(
            spans: [span],
            gapThresholdSeconds: 2.0,
            highConfidenceThreshold: 0.5,
            releaseTailMinSeconds: 1.0
        )

        let forbiddenSubstrings = ["technique", "family", "coaching", "score"]
        let forbiddenExactNames: Set<String> = [
            "confidence", "phraseconfidence", "label", "kind", "spankind", "phrasekind"
        ]

        let spanLabels = Mirror(reflecting: span).children.compactMap { $0.label?.lowercased() }
        for label in spanLabels {
            for token in forbiddenSubstrings {
                XCTAssertFalse(label.contains(token),
                               "AudioPhraseSpan field \"\(label)\" includes forbidden token \"\(token)\"")
            }
            XCTAssertFalse(forbiddenExactNames.contains(label),
                           "AudioPhraseSpan must not declare \"\(label)\"")
        }

        let summaryLabels = Mirror(reflecting: summary).children.compactMap { $0.label?.lowercased() }
        for label in summaryLabels {
            for token in forbiddenSubstrings {
                XCTAssertFalse(label.contains(token),
                               "AudioPhraseSummary field \"\(label)\" includes forbidden token \"\(token)\"")
            }
            XCTAssertFalse(forbiddenExactNames.contains(label),
                           "AudioPhraseSummary must not declare \"\(label)\"")
        }
    }
}
