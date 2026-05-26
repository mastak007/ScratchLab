import XCTest
@testable import ScratchLab

/// Section 3 / Slice 4 — locks the contract of `ScratchFamilySummary`
/// and `ScratchFamilySummaryEvaluator`. Pure per-family aggregation
/// over a `ScratchFamilyAnnotationSet`; no primitive, timing, ML, or
/// capture coupling.
final class ScratchFamilySummaryTests: XCTestCase {

    // MARK: - Helpers

    private func attachment(lower: Int, upper: Int, family: ScratchFamily) -> ScratchFamilyAttachment {
        let range = PrimitiveIndexRange(lowerBound: lower, upperBound: upper)!
        return ScratchFamilyAttachmentMapper.attach(
            label: ScratchFamilyCatalog.label(for: family),
            to: range
        )
    }

    private func summaries(for set: ScratchFamilyAnnotationSet) -> [ScratchFamilySummary] {
        ScratchFamilySummaryEvaluator.summarize(annotationSet: set)
    }

    private func summary(for family: ScratchFamily,
                          in summaries: [ScratchFamilySummary]) -> ScratchFamilySummary? {
        summaries.first { $0.family == family }
    }

    // MARK: - 1. Empty set → one zero summary per family

    func testEmptySetReturnsZeroSummaryPerFamily() {
        let set = ScratchFamilyAnnotationSet(attachments: [])!
        let out = summaries(for: set)
        XCTAssertEqual(out.count, ScratchFamily.allCases.count)
        for summary in out {
            XCTAssertEqual(summary.attachmentCount, 0,
                            "\(summary.family.rawValue) should have zero attachments")
            XCTAssertEqual(summary.primitiveCount, 0,
                            "\(summary.family.rawValue) should have zero primitives")
        }
    }

    // MARK: - 2. Summary order matches ScratchFamily.allCases

    func testSummaryOrderMatchesAllCases() {
        let set = ScratchFamilyAnnotationSet(attachments: [
            attachment(lower: 0, upper: 3, family: .baby),
            attachment(lower: 5, upper: 7, family: .chirp),
        ])!
        let out = summaries(for: set)
        XCTAssertEqual(out.map(\.family), ScratchFamily.allCases)
    }

    // MARK: - 3. attachmentCount computed per family

    func testAttachmentCountPerFamily() {
        let set = ScratchFamilyAnnotationSet(attachments: [
            attachment(lower: 0,  upper: 3,  family: .baby),
            attachment(lower: 5,  upper: 7,  family: .baby),
            attachment(lower: 10, upper: 12, family: .chirp),
            attachment(lower: 15, upper: 17, family: .flare),
            attachment(lower: 20, upper: 22, family: .flare),
            attachment(lower: 25, upper: 27, family: .flare),
        ])!
        let out = summaries(for: set)
        XCTAssertEqual(summary(for: .baby,      in: out)?.attachmentCount, 2)
        XCTAssertEqual(summary(for: .chirp,     in: out)?.attachmentCount, 1)
        XCTAssertEqual(summary(for: .flare,     in: out)?.attachmentCount, 3)
        XCTAssertEqual(summary(for: .transform, in: out)?.attachmentCount, 0)
        XCTAssertEqual(summary(for: .unknown,   in: out)?.attachmentCount, 0)
    }

    // MARK: - 4. primitiveCount computed inclusively

    func testPrimitiveCountInclusive() {
        // baby: ranges [0..3] (4 prims) + [5..7] (3 prims) = 7
        // chirp: [10..12] = 3
        let set = ScratchFamilyAnnotationSet(attachments: [
            attachment(lower: 0,  upper: 3,  family: .baby),
            attachment(lower: 5,  upper: 7,  family: .baby),
            attachment(lower: 10, upper: 12, family: .chirp),
        ])!
        let out = summaries(for: set)
        XCTAssertEqual(summary(for: .baby,  in: out)?.primitiveCount, 7)
        XCTAssertEqual(summary(for: .chirp, in: out)?.primitiveCount, 3)
        // Single-index range counts as 1.
        let single = ScratchFamilyAnnotationSet(attachments: [
            attachment(lower: 7, upper: 7, family: .baby),
        ])!
        XCTAssertEqual(summary(for: .baby, in: summaries(for: single))?.primitiveCount, 1)
    }

    // MARK: - 5. Duplicate family labels aggregate counts

    func testDuplicateFamilyLabelsAggregateCounts() {
        let set = ScratchFamilyAnnotationSet(attachments: [
            attachment(lower: 0,  upper: 4,  family: .baby),   // 5 prims
            attachment(lower: 10, upper: 14, family: .baby),   // 5 prims
            attachment(lower: 20, upper: 24, family: .baby),   // 5 prims
        ])!
        let out = summaries(for: set)
        let babySummary = summary(for: .baby, in: out)
        XCTAssertEqual(babySummary?.attachmentCount, 3)
        XCTAssertEqual(babySummary?.primitiveCount, 15)
    }

    // MARK: - 6. unknown family is included

    func testUnknownFamilyIncluded() {
        let set = ScratchFamilyAnnotationSet(attachments: [
            attachment(lower: 0, upper: 3, family: .unknown),
            attachment(lower: 5, upper: 7, family: .unknown),
        ])!
        let out = summaries(for: set)
        let unknownSummary = summary(for: .unknown, in: out)
        XCTAssertEqual(unknownSummary?.attachmentCount, 2)
        XCTAssertEqual(unknownSummary?.primitiveCount, 7)  // 4 + 3
        // unknown sits in the catalogue order (last) and is reported alongside the rest.
        XCTAssertEqual(out.last?.family, .unknown)
    }

    // MARK: - 7. Families with no attachments remain zero

    func testFamiliesWithNoAttachmentsRemainZero() {
        let set = ScratchFamilyAnnotationSet(attachments: [
            attachment(lower: 0, upper: 3, family: .baby),
        ])!
        let out = summaries(for: set)
        let zeroFamilies: [ScratchFamily] = [
            .scribble, .chirp, .flare, .transform, .tear, .orbit, .crab, .unknown,
        ]
        for family in zeroFamilies {
            let s = summary(for: family, in: out)
            XCTAssertEqual(s?.attachmentCount, 0,
                            "\(family.rawValue) expected 0 attachments")
            XCTAssertEqual(s?.primitiveCount, 0,
                            "\(family.rawValue) expected 0 primitives")
        }
    }

    // MARK: - 8. Codable round-trip

    func testCodableRoundTrip() throws {
        let value = ScratchFamilySummary(family: .baby,
                                          attachmentCount: 3,
                                          primitiveCount: 12)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        let data = try encoder.encode(value)
        XCTAssertEqual(try decoder.decode(ScratchFamilySummary.self, from: data), value)
        let second = try encoder.encode(try decoder.decode(ScratchFamilySummary.self, from: data))
        XCTAssertEqual(data, second)
    }

    // MARK: - 9. Decoder rejects negative attachmentCount

    func testCodableRejectsNegativeAttachmentCount() {
        let decoder = JSONDecoder()
        let invalid = """
        {"family":"baby","attachmentCount":-1,"primitiveCount":0}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(ScratchFamilySummary.self, from: invalid)) { error in
            guard case DecodingError.dataCorrupted = error else {
                XCTFail("expected DecodingError.dataCorrupted, got \(error)")
                return
            }
        }
    }

    // MARK: - 10. Decoder rejects negative primitiveCount

    func testCodableRejectsNegativePrimitiveCount() {
        let decoder = JSONDecoder()
        let invalid = """
        {"family":"baby","attachmentCount":1,"primitiveCount":-5}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(ScratchFamilySummary.self, from: invalid))
    }

    // MARK: - 11. Deterministic repeated summary

    func testDeterministicAcrossInvocations() {
        let set = ScratchFamilyAnnotationSet(attachments: [
            attachment(lower: 0,  upper: 3,  family: .baby),
            attachment(lower: 5,  upper: 7,  family: .chirp),
            attachment(lower: 10, upper: 12, family: .baby),
        ])!
        let first = summaries(for: set)
        let second = summaries(for: set)
        XCTAssertEqual(first, second)
    }

    // MARK: - 12. No primitive / timing access required

    /// The evaluator's only input is a `ScratchFamilyAnnotationSet`,
    /// which itself carries no primitive or timing data. This test
    /// constructs a set and gets a summary without naming any
    /// `NotationPrimitive` or `TimingGrid` symbol; any future
    /// regression that pulls one of those types into the surface would
    /// break the compile here.
    func testNoPrimitiveOrTimingAccessRequired() {
        let set = ScratchFamilyAnnotationSet(attachments: [
            attachment(lower: 0, upper: 3, family: .baby),
        ])!
        let out = ScratchFamilySummaryEvaluator.summarize(annotationSet: set)
        XCTAssertEqual(out.count, ScratchFamily.allCases.count)
        XCTAssertEqual(summary(for: .baby, in: out)?.primitiveCount, 4)
    }
}
