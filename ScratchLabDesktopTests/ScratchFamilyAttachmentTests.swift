import XCTest
@testable import ScratchLab

/// Section 3 / Slice 2 — locks the contract of `PrimitiveIndexRange`,
/// `ScratchFamilyAttachment`, and `ScratchFamilyAttachmentMapper`.
///
/// Sidecar-only: no notation primitive, no timing grid, no classifier
/// access. All tests construct attachments from hand-built index
/// ranges and catalog-supplied labels.
final class ScratchFamilyAttachmentTests: XCTestCase {

    // MARK: - 1. Range rejects negative lowerBound

    func testRangeRejectsNegativeLowerBound() {
        XCTAssertNil(PrimitiveIndexRange(lowerBound: -1, upperBound: 0))
        XCTAssertNil(PrimitiveIndexRange(lowerBound: -10, upperBound: -5))
    }

    // MARK: - 2. Range rejects upperBound below lowerBound

    func testRangeRejectsUpperBoundBelowLowerBound() {
        XCTAssertNil(PrimitiveIndexRange(lowerBound: 5, upperBound: 4))
        XCTAssertNil(PrimitiveIndexRange(lowerBound: 100, upperBound: 0))
    }

    // MARK: - 3. Range accepts single-index range

    func testRangeAcceptsSingleIndexRange() {
        let range = PrimitiveIndexRange(lowerBound: 7, upperBound: 7)
        XCTAssertNotNil(range)
        XCTAssertEqual(range?.lowerBound, 7)
        XCTAssertEqual(range?.upperBound, 7)
        XCTAssertEqual(range?.count, 1)
    }

    // MARK: - 4. Range accepts multi-index range

    func testRangeAcceptsMultiIndexRange() {
        let range = PrimitiveIndexRange(lowerBound: 0, upperBound: 9)
        XCTAssertNotNil(range)
        XCTAssertEqual(range?.count, 10)
    }

    // MARK: - 5. count is inclusive

    func testCountIsInclusive() {
        XCTAssertEqual(PrimitiveIndexRange(lowerBound: 0, upperBound: 0)!.count, 1)
        XCTAssertEqual(PrimitiveIndexRange(lowerBound: 0, upperBound: 4)!.count, 5)
        XCTAssertEqual(PrimitiveIndexRange(lowerBound: 10, upperBound: 19)!.count, 10)
    }

    // MARK: - 6. contains includes lower and upper bounds

    func testContainsIncludesLowerAndUpperBounds() {
        let range = PrimitiveIndexRange(lowerBound: 3, upperBound: 7)!
        XCTAssertTrue(range.contains(3),  "lower bound must be contained")
        XCTAssertTrue(range.contains(5),  "interior index must be contained")
        XCTAssertTrue(range.contains(7),  "upper bound must be contained")
    }

    // MARK: - 7. contains excludes outside bounds

    func testContainsExcludesOutsideBounds() {
        let range = PrimitiveIndexRange(lowerBound: 3, upperBound: 7)!
        XCTAssertFalse(range.contains(2))
        XCTAssertFalse(range.contains(8))
        XCTAssertFalse(range.contains(-1))
        XCTAssertFalse(range.contains(100))
    }

    // MARK: - 8. Attachment preserves range

    func testAttachmentPreservesRange() {
        let range = PrimitiveIndexRange(lowerBound: 4, upperBound: 12)!
        let attachment = ScratchFamilyAttachmentMapper.attach(
            label: ScratchFamilyCatalog.label(for: .baby),
            to: range
        )
        XCTAssertEqual(attachment.primitiveRange, range)
    }

    // MARK: - 9. Attachment preserves label

    func testAttachmentPreservesLabel() {
        let range = PrimitiveIndexRange(lowerBound: 0, upperBound: 3)!
        let label = ScratchFamilyCatalog.label(for: .baby)
        let attachment = ScratchFamilyAttachmentMapper.attach(label: label, to: range)
        XCTAssertEqual(attachment.label, label)
        XCTAssertEqual(attachment.label.family, .baby)
        XCTAssertEqual(attachment.label.displayName, "Baby Scratch")
        XCTAssertFalse(attachment.label.isResearchOnly)
    }

    // MARK: - 10. Mapper is deterministic

    func testMapperDeterministicAcrossInvocations() {
        let range = PrimitiveIndexRange(lowerBound: 2, upperBound: 8)!
        let label = ScratchFamilyCatalog.label(for: .baby)
        let first = ScratchFamilyAttachmentMapper.attach(label: label, to: range)
        let second = ScratchFamilyAttachmentMapper.attach(label: label, to: range)
        XCTAssertEqual(first, second)
    }

    // MARK: - 11. PrimitiveIndexRange Codable round-trip

    func testPrimitiveIndexRangeCodableRoundTrip() throws {
        let range = PrimitiveIndexRange(lowerBound: 5, upperBound: 13)!
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        let data = try encoder.encode(range)
        XCTAssertEqual(try decoder.decode(PrimitiveIndexRange.self, from: data), range)
        let second = try encoder.encode(try decoder.decode(PrimitiveIndexRange.self, from: data))
        XCTAssertEqual(data, second)
    }

    // MARK: - 12. ScratchFamilyAttachment Codable round-trip

    func testScratchFamilyAttachmentCodableRoundTrip() throws {
        let range = PrimitiveIndexRange(lowerBound: 0, upperBound: 5)!
        let attachment = ScratchFamilyAttachmentMapper.attach(
            label: ScratchFamilyCatalog.label(for: .baby),
            to: range
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        let data = try encoder.encode(attachment)
        XCTAssertEqual(try decoder.decode(ScratchFamilyAttachment.self, from: data), attachment)
        let second = try encoder.encode(try decoder.decode(ScratchFamilyAttachment.self, from: data))
        XCTAssertEqual(data, second)
    }

    // MARK: - 13. Decoder rejects invalid range

    func testCodableRejectsInvalidRange() {
        let decoder = JSONDecoder()
        let negativeLower = """
        {"lowerBound":-1,"upperBound":3}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(PrimitiveIndexRange.self, from: negativeLower))

        let upperBelowLower = """
        {"lowerBound":5,"upperBound":4}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(PrimitiveIndexRange.self, from: upperBelowLower))

        // Nested via ScratchFamilyAttachment also rejects.
        let attachmentWithBadRange = """
        {
          "primitiveRange": {"lowerBound":-1,"upperBound":3},
          "label": {"family":"baby","displayName":"Baby Scratch","isResearchOnly":false}
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(ScratchFamilyAttachment.self,
                                                  from: attachmentWithBadRange))
    }

    // MARK: - 14. Attachment does not access or mutate primitives

    /// The whole `ScratchFamilyAttachment` surface is pure metadata —
    /// it has no `NotationPrimitive` field and no API that takes one.
    /// Constructing an attachment requires nothing but indices and a
    /// label, demonstrably independent of any primitive collection.
    func testAttachmentDoesNotRequireOrTouchPrimitives() {
        // Build an attachment in a context where no NotationPrimitive
        // value exists in scope at all. If the API were primitive-aware
        // this call site would not compile.
        let range = PrimitiveIndexRange(lowerBound: 42, upperBound: 99)!
        let attachment = ScratchFamilyAttachmentMapper.attach(
            label: ScratchFamilyCatalog.label(for: .baby),
            to: range
        )
        XCTAssertEqual(attachment.primitiveRange.lowerBound, 42)
        XCTAssertEqual(attachment.primitiveRange.upperBound, 99)
        XCTAssertEqual(attachment.primitiveRange.count, 58)
    }

    // MARK: - 15. Research-only label can be attached as metadata

    func testResearchOnlyLabelCanBeAttachedAsMetadata() {
        // .chirp is research-only per Slice 1's catalog. The sidecar
        // still accepts it — consumers gate visibility on
        // `label.isResearchOnly`, not the attachment layer.
        let chirpLabel = ScratchFamilyCatalog.label(for: .chirp)
        XCTAssertTrue(chirpLabel.isResearchOnly, "test precondition")
        let range = PrimitiveIndexRange(lowerBound: 0, upperBound: 2)!
        let attachment = ScratchFamilyAttachmentMapper.attach(label: chirpLabel, to: range)
        XCTAssertEqual(attachment.label, chirpLabel)
        XCTAssertTrue(attachment.label.isResearchOnly,
                      "the research-only flag must survive attachment unchanged")
    }
}
