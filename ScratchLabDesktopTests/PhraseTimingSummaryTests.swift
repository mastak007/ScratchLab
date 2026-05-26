import XCTest
@testable import ScratchLab

/// Section 2 / Slice 6 — locks the contract of
/// `PhraseTimingSummary` and
/// `PhraseTimingSummaryEvaluator.summarize(...)`.
///
/// Synthetic, deterministic inputs only. The evaluator never touches
/// primitives, the grid, or any clock; all assertions are over the
/// statistical outputs produced from hand-constructed drift /
/// annotation / phrase triples.
final class PhraseTimingSummaryTests: XCTestCase {

    // MARK: - Helpers

    private func annotation(index: Int, bar: Int) -> GridAnnotation {
        GridAnnotation(
            primitiveIndex: index,
            start: GridPosition(bar: bar, beat: 0, subdivision: 0, subdivisionPhase: 0),
            end: GridPosition(bar: bar, beat: 0, subdivision: 0, subdivisionPhase: 0)
        )
    }

    private func drift(index: Int,
                        drift value: TimeInterval,
                        within: Bool) -> TimingDrift {
        TimingDrift(primitiveIndex: index,
                     expectedTime: 0,
                     actualTime: value,
                     drift: value,
                     isWithinWindow: within)
    }

    // MARK: - 1. Empty phrases → empty summaries

    func testEmptyPhrasesReturnEmptySummaries() {
        let summaries = PhraseTimingSummaryEvaluator.summarize(
            drifts: [drift(index: 0, drift: 0.01, within: true)],
            annotations: [annotation(index: 0, bar: 0)],
            phrases: []
        )
        XCTAssertTrue(summaries.isEmpty)
    }

    // MARK: - 2. Phrase order preserved

    func testSummariesPreservePhraseOrder() {
        let phrases = [
            Phrase(startBar: 0, barCount: 4)!,
            Phrase(startBar: 4, barCount: 4)!,
            Phrase(startBar: 8, barCount: 4)!,
        ]
        let summaries = PhraseTimingSummaryEvaluator.summarize(
            drifts: [],
            annotations: [],
            phrases: phrases
        )
        XCTAssertEqual(summaries.map(\.phraseIndex), [0, 1, 2])
    }

    // MARK: - 3. Phrase with no drifts → all-zeros summary

    func testPhraseWithNoDriftsReturnsAllZeros() {
        let phrases = [Phrase(startBar: 0, barCount: 4)!]
        let summaries = PhraseTimingSummaryEvaluator.summarize(
            drifts: [],
            annotations: [],
            phrases: phrases
        )
        XCTAssertEqual(summaries.count, 1)
        let s = summaries[0]
        XCTAssertEqual(s.phraseIndex, 0)
        XCTAssertEqual(s.primitiveCount, 0)
        XCTAssertEqual(s.withinWindowCount, 0)
        XCTAssertEqual(s.meanAbsoluteDrift, 0, accuracy: 1e-12)
        XCTAssertEqual(s.maxAbsoluteDrift, 0, accuracy: 1e-12)
    }

    // MARK: - 4. Drifts assigned to phrase by annotation.start

    func testDriftsAssignedByAnnotationStart() {
        // Phrase A covers bars 0..3, phrase B covers bars 4..7.
        let phrases = [
            Phrase(startBar: 0, barCount: 4)!,
            Phrase(startBar: 4, barCount: 4)!,
        ]
        // annotation[0] sits in phrase A (bar 1), [1] in phrase B (bar 5),
        // [2] outside any phrase (bar 9).
        let annotations = [
            annotation(index: 0, bar: 1),
            annotation(index: 1, bar: 5),
            annotation(index: 2, bar: 9),
        ]
        let drifts = [
            drift(index: 0, drift: 0.10, within: true),
            drift(index: 1, drift: 0.05, within: true),
            drift(index: 2, drift: 0.30, within: false),  // outside any phrase
        ]
        let summaries = PhraseTimingSummaryEvaluator.summarize(
            drifts: drifts,
            annotations: annotations,
            phrases: phrases
        )
        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(summaries[0].primitiveCount, 1, "phrase A should contain primitive 0")
        XCTAssertEqual(summaries[1].primitiveCount, 1, "phrase B should contain primitive 1")
        XCTAssertEqual(summaries.reduce(0) { $0 + $1.primitiveCount }, 2,
                       "drift 2 is outside any phrase and must be ignored")
    }

    // MARK: - 5. primitiveCount

    func testPrimitiveCount() {
        let phrases = [Phrase(startBar: 0, barCount: 4)!]
        let annotations = (0..<5).map { annotation(index: $0, bar: $0 % 4) }
        let drifts = (0..<5).map { drift(index: $0, drift: 0.0, within: true) }
        let summaries = PhraseTimingSummaryEvaluator.summarize(
            drifts: drifts, annotations: annotations, phrases: phrases
        )
        XCTAssertEqual(summaries[0].primitiveCount, 5)
    }

    // MARK: - 6. withinWindowCount

    func testWithinWindowCount() {
        let phrases = [Phrase(startBar: 0, barCount: 4)!]
        let annotations = (0..<4).map { annotation(index: $0, bar: 0) }
        let drifts = [
            drift(index: 0, drift: 0.0, within: true),
            drift(index: 1, drift: 0.1, within: false),
            drift(index: 2, drift: 0.0, within: true),
            drift(index: 3, drift: 0.2, within: false),
        ]
        let summaries = PhraseTimingSummaryEvaluator.summarize(
            drifts: drifts, annotations: annotations, phrases: phrases
        )
        XCTAssertEqual(summaries[0].primitiveCount, 4)
        XCTAssertEqual(summaries[0].withinWindowCount, 2)
    }

    // MARK: - 7. meanAbsoluteDrift

    func testMeanAbsoluteDrift() {
        // Use exactly-representable IEEE 754 values so the mean is bit-exact.
        // |drifts| = {0.25, 0.125, 0.625, 0.0} → mean = 0.25.
        let phrases = [Phrase(startBar: 0, barCount: 4)!]
        let annotations = (0..<4).map { annotation(index: $0, bar: 0) }
        let drifts = [
            drift(index: 0, drift:  0.25,  within: false),
            drift(index: 1, drift: -0.125, within: true),
            drift(index: 2, drift:  0.625, within: false),
            drift(index: 3, drift:  0.0,   within: true),
        ]
        let summaries = PhraseTimingSummaryEvaluator.summarize(
            drifts: drifts, annotations: annotations, phrases: phrases
        )
        XCTAssertEqual(summaries[0].primitiveCount, 4)
        XCTAssertEqual(summaries[0].meanAbsoluteDrift, 0.25, accuracy: 1e-12)
    }

    // MARK: - 8. maxAbsoluteDrift

    func testMaxAbsoluteDrift() {
        let phrases = [Phrase(startBar: 0, barCount: 4)!]
        let annotations = (0..<4).map { annotation(index: $0, bar: 0) }
        let drifts = [
            drift(index: 0, drift:  0.1,   within: true),
            drift(index: 1, drift: -0.625, within: false),  // largest |drift|
            drift(index: 2, drift:  0.5,   within: false),
            drift(index: 3, drift: -0.05,  within: true),
        ]
        let summaries = PhraseTimingSummaryEvaluator.summarize(
            drifts: drifts, annotations: annotations, phrases: phrases
        )
        XCTAssertEqual(summaries[0].maxAbsoluteDrift, 0.625, accuracy: 1e-12)
    }

    // MARK: - 9. Drift with no matching annotation is ignored

    func testDriftWithNoMatchingAnnotationIsIgnored() {
        let phrases = [Phrase(startBar: 0, barCount: 4)!]
        let annotations = [annotation(index: 0, bar: 1)]
        let drifts = [
            drift(index: 0, drift: 0.1, within: true),
            drift(index: 99, drift: 0.5, within: false),  // no annotation for index 99
        ]
        let summaries = PhraseTimingSummaryEvaluator.summarize(
            drifts: drifts, annotations: annotations, phrases: phrases
        )
        XCTAssertEqual(summaries[0].primitiveCount, 1,
                       "drift with no matching annotation must be skipped")
        XCTAssertEqual(summaries[0].maxAbsoluteDrift, 0.1, accuracy: 1e-12)
    }

    // MARK: - 10. Duplicate annotation primitiveIndex: first wins

    func testDuplicateAnnotationPrimitiveIndexUsesFirst() {
        // Two annotations for index 0: first in phrase A (bar 1),
        // second in phrase B (bar 5). Drift must land in phrase A.
        let phrases = [
            Phrase(startBar: 0, barCount: 4)!,
            Phrase(startBar: 4, barCount: 4)!,
        ]
        let annotations = [
            annotation(index: 0, bar: 1),   // first — wins
            annotation(index: 0, bar: 5),   // duplicate — ignored
        ]
        let drifts = [drift(index: 0, drift: 0.1, within: true)]
        let summaries = PhraseTimingSummaryEvaluator.summarize(
            drifts: drifts, annotations: annotations, phrases: phrases
        )
        XCTAssertEqual(summaries[0].primitiveCount, 1, "first annotation lands the drift in phrase A")
        XCTAssertEqual(summaries[1].primitiveCount, 0, "phrase B sees nothing")
    }

    // MARK: - 11. Negative-bar phrases

    func testNegativeBarPhrasesWork() {
        let phrases = [Phrase(startBar: -4, barCount: 4)!]  // bars -4..-1
        let annotations = [
            annotation(index: 0, bar: -4),
            annotation(index: 1, bar: -1),
            annotation(index: 2, bar: 0),   // outside (endBarExclusive is 0)
        ]
        let drifts = [
            drift(index: 0, drift: 0.1, within: true),
            drift(index: 1, drift: 0.2, within: false),
            drift(index: 2, drift: 0.3, within: true),
        ]
        let summaries = PhraseTimingSummaryEvaluator.summarize(
            drifts: drifts, annotations: annotations, phrases: phrases
        )
        XCTAssertEqual(summaries[0].primitiveCount, 2)
        XCTAssertEqual(summaries[0].withinWindowCount, 1)
        XCTAssertEqual(summaries[0].maxAbsoluteDrift, 0.2, accuracy: 1e-12)
    }

    // MARK: - 12. Codable round-trip

    func testCodableRoundTrip() throws {
        let summary = PhraseTimingSummary(
            phraseIndex: 2,
            primitiveCount: 4,
            withinWindowCount: 3,
            meanAbsoluteDrift: 0.125,
            maxAbsoluteDrift: 0.25
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        let data = try encoder.encode(summary)
        XCTAssertEqual(try decoder.decode(PhraseTimingSummary.self, from: data), summary)
        let second = try encoder.encode(try decoder.decode(PhraseTimingSummary.self, from: data))
        XCTAssertEqual(data, second)
    }

    // MARK: - 13. Decoder rejects negative phraseIndex

    func testCodableRejectsNegativePhraseIndex() {
        let decoder = JSONDecoder()
        let invalid = """
        {"phraseIndex":-1,"primitiveCount":0,"withinWindowCount":0,
         "meanAbsoluteDrift":0.0,"maxAbsoluteDrift":0.0}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(PhraseTimingSummary.self, from: invalid))
    }

    // MARK: - 14. Decoder rejects invalid counts

    func testCodableRejectsInvalidCounts() {
        let decoder = JSONDecoder()
        let negativePrimitive = """
        {"phraseIndex":0,"primitiveCount":-1,"withinWindowCount":0,
         "meanAbsoluteDrift":0.0,"maxAbsoluteDrift":0.0}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(PhraseTimingSummary.self, from: negativePrimitive))

        let negativeWithin = """
        {"phraseIndex":0,"primitiveCount":2,"withinWindowCount":-1,
         "meanAbsoluteDrift":0.0,"maxAbsoluteDrift":0.0}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(PhraseTimingSummary.self, from: negativeWithin))

        let withinExceedsPrimitive = """
        {"phraseIndex":0,"primitiveCount":2,"withinWindowCount":3,
         "meanAbsoluteDrift":0.0,"maxAbsoluteDrift":0.0}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(PhraseTimingSummary.self, from: withinExceedsPrimitive))
    }

    // MARK: - 15. Decoder rejects non-finite summary drift values

    func testCodableRejectsNonFiniteDriftValues() {
        let decoder = JSONDecoder()
        let meanNaN = """
        {"phraseIndex":0,"primitiveCount":1,"withinWindowCount":0,
         "meanAbsoluteDrift":"NaN","maxAbsoluteDrift":0.0}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(PhraseTimingSummary.self, from: meanNaN))

        let maxInfinity = """
        {"phraseIndex":0,"primitiveCount":1,"withinWindowCount":0,
         "meanAbsoluteDrift":0.0,"maxAbsoluteDrift":"Infinity"}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(PhraseTimingSummary.self, from: maxInfinity))

        let negativeMean = """
        {"phraseIndex":0,"primitiveCount":1,"withinWindowCount":0,
         "meanAbsoluteDrift":-0.1,"maxAbsoluteDrift":0.0}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(PhraseTimingSummary.self, from: negativeMean))
    }

    // MARK: - 16. Deterministic

    func testDeterministicAcrossInvocations() {
        let phrases = [
            Phrase(startBar: 0, barCount: 4)!,
            Phrase(startBar: 4, barCount: 4)!,
        ]
        let annotations = [
            annotation(index: 0, bar: 1),
            annotation(index: 1, bar: 5),
        ]
        let drifts = [
            drift(index: 0, drift:  0.1,  within: true),
            drift(index: 1, drift: -0.25, within: false),
        ]
        let first = PhraseTimingSummaryEvaluator.summarize(
            drifts: drifts, annotations: annotations, phrases: phrases
        )
        let second = PhraseTimingSummaryEvaluator.summarize(
            drifts: drifts, annotations: annotations, phrases: phrases
        )
        XCTAssertEqual(first, second)
    }
}
