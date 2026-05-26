import XCTest
@testable import ScratchLab

/// Section 4 / Slice 4 — locks the contract of
/// `PhraseCoachingRule` and `PhraseCoachingEvaluator`. Pure
/// deterministic threshold mapping over `PhraseTimingSummary`; no
/// ML, no primitives, no scoring, no UI/export coupling.
final class PhraseCoachingEvaluatorTests: XCTestCase {

    // MARK: - Helpers

    private func rule(
        mean: TimeInterval = 0.05,
        max: TimeInterval = 0.10,
        minCount: Int = 4,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> PhraseCoachingRule {
        guard let rule = PhraseCoachingRule(
            unstableMeanAbsoluteDriftThreshold: mean,
            unstableMaxAbsoluteDriftThreshold: max,
            incompleteMinimumPrimitiveCount: minCount
        ) else {
            XCTFail("PhraseCoachingRule(mean: \(mean), max: \(max), minCount: \(minCount)) unexpectedly rejected",
                    file: file, line: line)
            return PhraseCoachingRule(
                unstableMeanAbsoluteDriftThreshold: 0,
                unstableMaxAbsoluteDriftThreshold: 0,
                incompleteMinimumPrimitiveCount: 0
            )!
        }
        return rule
    }

    private func summary(
        phraseIndex: Int,
        primitiveCount: Int = 8,
        meanAbsoluteDrift: TimeInterval = 0,
        maxAbsoluteDrift: TimeInterval = 0,
        withinWindowCount: Int? = nil
    ) -> PhraseTimingSummary {
        let within = withinWindowCount ?? primitiveCount
        return PhraseTimingSummary(
            phraseIndex: phraseIndex,
            primitiveCount: primitiveCount,
            withinWindowCount: within,
            meanAbsoluteDrift: meanAbsoluteDrift,
            maxAbsoluteDrift: maxAbsoluteDrift
        )
    }

    // MARK: - 1. rule rejects negative thresholds

    func testRuleRejectsNegativeThresholds() {
        XCTAssertNil(PhraseCoachingRule(
            unstableMeanAbsoluteDriftThreshold: -0.001,
            unstableMaxAbsoluteDriftThreshold: 0,
            incompleteMinimumPrimitiveCount: 0
        ))
        XCTAssertNil(PhraseCoachingRule(
            unstableMeanAbsoluteDriftThreshold: 0,
            unstableMaxAbsoluteDriftThreshold: -0.001,
            incompleteMinimumPrimitiveCount: 0
        ))
    }

    // MARK: - 2. rule rejects NaN/infinity thresholds

    func testRuleRejectsNonFiniteThresholds() {
        XCTAssertNil(PhraseCoachingRule(
            unstableMeanAbsoluteDriftThreshold: .nan,
            unstableMaxAbsoluteDriftThreshold: 0,
            incompleteMinimumPrimitiveCount: 0
        ))
        XCTAssertNil(PhraseCoachingRule(
            unstableMeanAbsoluteDriftThreshold: 0,
            unstableMaxAbsoluteDriftThreshold: .infinity,
            incompleteMinimumPrimitiveCount: 0
        ))
        XCTAssertNil(PhraseCoachingRule(
            unstableMeanAbsoluteDriftThreshold: -.infinity,
            unstableMaxAbsoluteDriftThreshold: 0,
            incompleteMinimumPrimitiveCount: 0
        ))
    }

    // MARK: - 3. rule rejects negative incompleteMinimumPrimitiveCount

    func testRuleRejectsNegativeIncompleteMinimumPrimitiveCount() {
        XCTAssertNil(PhraseCoachingRule(
            unstableMeanAbsoluteDriftThreshold: 0,
            unstableMaxAbsoluteDriftThreshold: 0,
            incompleteMinimumPrimitiveCount: -1
        ))
    }

    // MARK: - 4. rule accepts zero thresholds and zero minimum count

    func testRuleAcceptsZeroThresholdsAndZeroMinimumCount() {
        let r = PhraseCoachingRule(
            unstableMeanAbsoluteDriftThreshold: 0,
            unstableMaxAbsoluteDriftThreshold: 0,
            incompleteMinimumPrimitiveCount: 0
        )
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.unstableMeanAbsoluteDriftThreshold, 0)
        XCTAssertEqual(r?.unstableMaxAbsoluteDriftThreshold, 0)
        XCTAssertEqual(r?.incompleteMinimumPrimitiveCount, 0)
    }

    // MARK: - 5. incomplete primitive count emits incompletePhrase

    func testIncompletePrimitiveCountEmitsIncompletePhrase() {
        let r = rule(mean: 1.0, max: 1.0, minCount: 4)
        let s = summary(phraseIndex: 0, primitiveCount: 3)
        let events = PhraseCoachingEvaluator.events(
            from: [s],
            phraseStartTimes: [0: 1.0],
            using: r
        )
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .incompletePhrase)
    }

    // MARK: - 6. primitive count at minimum emits no incompletePhrase

    func testPrimitiveCountAtMinimumEmitsNoIncompletePhrase() {
        let r = rule(mean: 1.0, max: 1.0, minCount: 4)
        let s = summary(phraseIndex: 0, primitiveCount: 4)
        let events = PhraseCoachingEvaluator.events(
            from: [s],
            phraseStartTimes: [0: 1.0],
            using: r
        )
        XCTAssertEqual(events, [])
    }

    // MARK: - 7. mean drift over threshold emits unstableTiming

    func testMeanDriftOverThresholdEmitsUnstableTiming() {
        let r = rule(mean: 0.05, max: 10.0, minCount: 0)
        let s = summary(phraseIndex: 0, primitiveCount: 8, meanAbsoluteDrift: 0.06, maxAbsoluteDrift: 0)
        let events = PhraseCoachingEvaluator.events(
            from: [s],
            phraseStartTimes: [0: 1.0],
            using: r
        )
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .unstableTiming)
    }

    // MARK: - 8. mean drift at threshold emits no unstableTiming

    func testMeanDriftAtThresholdEmitsNoUnstableTiming() {
        let r = rule(mean: 0.05, max: 10.0, minCount: 0)
        let s = summary(phraseIndex: 0, primitiveCount: 8, meanAbsoluteDrift: 0.05, maxAbsoluteDrift: 0)
        let events = PhraseCoachingEvaluator.events(
            from: [s],
            phraseStartTimes: [0: 1.0],
            using: r
        )
        XCTAssertEqual(events, [])
    }

    // MARK: - 9. max drift over threshold emits unstableTiming

    func testMaxDriftOverThresholdEmitsUnstableTiming() {
        let r = rule(mean: 10.0, max: 0.10, minCount: 0)
        let s = summary(phraseIndex: 0, primitiveCount: 8, meanAbsoluteDrift: 0, maxAbsoluteDrift: 0.11)
        let events = PhraseCoachingEvaluator.events(
            from: [s],
            phraseStartTimes: [0: 1.0],
            using: r
        )
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .unstableTiming)
    }

    // MARK: - 10. max drift at threshold emits no unstableTiming

    func testMaxDriftAtThresholdEmitsNoUnstableTiming() {
        let r = rule(mean: 10.0, max: 0.10, minCount: 0)
        let s = summary(phraseIndex: 0, primitiveCount: 8, meanAbsoluteDrift: 0, maxAbsoluteDrift: 0.10)
        let events = PhraseCoachingEvaluator.events(
            from: [s],
            phraseStartTimes: [0: 1.0],
            using: r
        )
        XCTAssertEqual(events, [])
    }

    // MARK: - 11. phrase can emit incompletePhrase then unstableTiming

    func testPhraseCanEmitIncompleteThenUnstable() {
        let r = rule(mean: 0.05, max: 10.0, minCount: 4)
        let s = summary(phraseIndex: 0, primitiveCount: 2, meanAbsoluteDrift: 0.10, maxAbsoluteDrift: 0)
        let events = PhraseCoachingEvaluator.events(
            from: [s],
            phraseStartTimes: [0: 1.5],
            using: r
        )
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.map(\.kind), [.incompletePhrase, .unstableTiming])
        XCTAssertEqual(events.map(\.time), [1.5, 1.5])
    }

    // MARK: - 12. event time uses phraseStartTimes by phraseIndex

    func testEventTimeUsesPhraseStartTimesByPhraseIndex() {
        let r = rule(mean: 0.05, max: 10.0, minCount: 4)
        let summaries = [
            summary(phraseIndex: 0, primitiveCount: 1),
            summary(phraseIndex: 7, primitiveCount: 1),
        ]
        let events = PhraseCoachingEvaluator.events(
            from: summaries,
            phraseStartTimes: [0: 2.0, 7: 9.25],
            using: r
        )
        XCTAssertEqual(events.map(\.time), [2.0, 9.25])
    }

    // MARK: - 13. missing phraseStartTimes entry skips summary

    func testMissingPhraseStartTimesEntrySkipsSummary() {
        let r = rule(mean: 0.05, max: 10.0, minCount: 4)
        let summaries = [
            summary(phraseIndex: 0, primitiveCount: 1, meanAbsoluteDrift: 0.10),
            summary(phraseIndex: 1, primitiveCount: 1, meanAbsoluteDrift: 0.10),
        ]
        let events = PhraseCoachingEvaluator.events(
            from: summaries,
            phraseStartTimes: [1: 4.0],
            using: r
        )
        XCTAssertEqual(events.map(\.time), [4.0, 4.0])
        XCTAssertEqual(events.map(\.kind), [.incompletePhrase, .unstableTiming])
    }

    // MARK: - 14. emitted severity comes from catalog

    func testEmittedSeverityComesFromCatalog() {
        let r = rule(mean: 0.05, max: 10.0, minCount: 4)
        let s = summary(phraseIndex: 0, primitiveCount: 1, meanAbsoluteDrift: 0.10)
        let events = PhraseCoachingEvaluator.events(
            from: [s],
            phraseStartTimes: [0: 1.0],
            using: r
        )
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].severity, CoachingEventCatalog.descriptor(for: .incompletePhrase).severity)
        XCTAssertEqual(events[1].severity, CoachingEventCatalog.descriptor(for: .unstableTiming).severity)
    }

    // MARK: - 15. emitted message is nil

    func testEmittedMessageIsNil() {
        let r = rule(mean: 0.05, max: 10.0, minCount: 4)
        let s = summary(phraseIndex: 0, primitiveCount: 1, meanAbsoluteDrift: 0.10)
        for event in PhraseCoachingEvaluator.events(
            from: [s],
            phraseStartTimes: [0: 1.0],
            using: r
        ) {
            XCTAssertNil(event.message)
        }
    }

    // MARK: - 16. preserves emitted order across phrases

    func testPreservesEmittedOrderAcrossPhrases() {
        let r = rule(mean: 0.05, max: 10.0, minCount: 4)
        let summaries = [
            summary(phraseIndex: 0, primitiveCount: 8, meanAbsoluteDrift: 0.10),  // unstable only
            summary(phraseIndex: 1, primitiveCount: 2, meanAbsoluteDrift: 0),     // incomplete only
            summary(phraseIndex: 2, primitiveCount: 2, meanAbsoluteDrift: 0.10),  // incomplete then unstable
            summary(phraseIndex: 3, primitiveCount: 8, meanAbsoluteDrift: 0),     // no events
        ]
        let events = PhraseCoachingEvaluator.events(
            from: summaries,
            phraseStartTimes: [0: 1.0, 1: 2.0, 2: 3.0, 3: 4.0],
            using: r
        )
        XCTAssertEqual(events.map(\.kind), [
            .unstableTiming,
            .incompletePhrase,
            .incompletePhrase,
            .unstableTiming,
        ])
        XCTAssertEqual(events.map(\.time), [1.0, 2.0, 3.0, 3.0])
    }

    // MARK: - 17. empty summaries return empty events

    func testEmptySummariesReturnEmptyEvents() {
        let r = rule()
        XCTAssertEqual(
            PhraseCoachingEvaluator.events(from: [], phraseStartTimes: [:], using: r),
            []
        )
    }

    // MARK: - 18. Codable round-trip

    func testRuleCodableRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        let cases: [PhraseCoachingRule] = [
            rule(mean: 0, max: 0, minCount: 0),
            rule(mean: 0.05, max: 0.10, minCount: 4),
            rule(mean: 0.20, max: 0.50, minCount: 12),
        ]
        for r in cases {
            let data = try encoder.encode(r)
            let decoded = try decoder.decode(PhraseCoachingRule.self, from: data)
            XCTAssertEqual(decoded, r)
            let second = try encoder.encode(decoded)
            XCTAssertEqual(second, data)
        }
    }

    // MARK: - 19. Codable rejects invalid rule

    func testCodableRejectsInvalidRule() {
        let decoder = JSONDecoder()
        let negMean = """
        {"unstableMeanAbsoluteDriftThreshold": -0.001, "unstableMaxAbsoluteDriftThreshold": 0.1, "incompleteMinimumPrimitiveCount": 4}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(PhraseCoachingRule.self, from: negMean))

        let negMax = """
        {"unstableMeanAbsoluteDriftThreshold": 0.05, "unstableMaxAbsoluteDriftThreshold": -0.001, "incompleteMinimumPrimitiveCount": 4}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(PhraseCoachingRule.self, from: negMax))

        let nonFinite = """
        {"unstableMeanAbsoluteDriftThreshold": 1e1000, "unstableMaxAbsoluteDriftThreshold": 0.1, "incompleteMinimumPrimitiveCount": 4}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(PhraseCoachingRule.self, from: nonFinite))

        let negCount = """
        {"unstableMeanAbsoluteDriftThreshold": 0.05, "unstableMaxAbsoluteDriftThreshold": 0.10, "incompleteMinimumPrimitiveCount": -1}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(PhraseCoachingRule.self, from: negCount))
    }

    // MARK: - 20. Deterministic repeated evaluation

    func testDeterministicRepeatedEvaluation() {
        let r = rule(mean: 0.05, max: 0.10, minCount: 4)
        let summaries = [
            summary(phraseIndex: 0, primitiveCount: 8, meanAbsoluteDrift: 0.10),
            summary(phraseIndex: 1, primitiveCount: 2, meanAbsoluteDrift: 0),
            summary(phraseIndex: 2, primitiveCount: 2, meanAbsoluteDrift: 0.10),
        ]
        let starts: [Int: TimeInterval] = [0: 1.0, 1: 2.0, 2: 3.0]
        let first = PhraseCoachingEvaluator.events(from: summaries, phraseStartTimes: starts, using: r)
        let second = PhraseCoachingEvaluator.events(from: summaries, phraseStartTimes: starts, using: r)
        XCTAssertEqual(first, second)
    }
}
