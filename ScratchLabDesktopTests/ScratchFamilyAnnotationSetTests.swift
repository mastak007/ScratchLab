import XCTest
@testable import ScratchLab

/// Section 3 / Slice 3 — locks the contract of
/// `ScratchFamilyAnnotationSet`. Pure validated collection of
/// `ScratchFamilyAttachment` sidecars; no primitive, timing, ML, or
/// capture coupling.
final class ScratchFamilyAnnotationSetTests: XCTestCase {

    // MARK: - Helpers

    private func attachment(lower: Int, upper: Int, family: ScratchFamily) -> ScratchFamilyAttachment {
        let range = PrimitiveIndexRange(lowerBound: lower, upperBound: upper)!
        return ScratchFamilyAttachmentMapper.attach(
            label: ScratchFamilyCatalog.label(for: family),
            to: range
        )
    }

    // MARK: - 1. Empty set is valid

    func testEmptySetIsValid() {
        let set = ScratchFamilyAnnotationSet(attachments: [])
        XCTAssertNotNil(set)
        XCTAssertEqual(set?.attachments.count, 0)
    }

    // MARK: - 2. Sorted non-overlapping is valid

    func testSortedNonOverlappingAttachmentsAreValid() {
        let set = ScratchFamilyAnnotationSet(attachments: [
            attachment(lower: 0,  upper: 3,  family: .baby),
            attachment(lower: 5,  upper: 7,  family: .baby),
            attachment(lower: 10, upper: 12, family: .chirp),
        ])
        XCTAssertNotNil(set)
        XCTAssertEqual(set?.attachments.count, 3)
    }

    // MARK: - 3. Unsorted attachments are rejected

    func testUnsortedAttachmentsAreRejected() {
        let set = ScratchFamilyAnnotationSet(attachments: [
            attachment(lower: 5,  upper: 7,  family: .baby),
            attachment(lower: 0,  upper: 3,  family: .chirp),   // out of order
        ])
        XCTAssertNil(set)
    }

    // MARK: - 4. Overlapping attachments are rejected

    func testOverlappingAttachmentsAreRejected() {
        // Fully overlapping
        XCTAssertNil(ScratchFamilyAnnotationSet(attachments: [
            attachment(lower: 0, upper: 5, family: .baby),
            attachment(lower: 3, upper: 7, family: .baby),
        ]))

        // Single-index overlap at the seam
        XCTAssertNil(ScratchFamilyAnnotationSet(attachments: [
            attachment(lower: 0, upper: 5, family: .baby),
            attachment(lower: 5, upper: 7, family: .baby),
        ]))

        // Containment
        XCTAssertNil(ScratchFamilyAnnotationSet(attachments: [
            attachment(lower: 0, upper: 10, family: .baby),
            attachment(lower: 3, upper: 4,  family: .chirp),
        ]))
    }

    // MARK: - 5. Adjacent ranges are accepted

    func testAdjacentRangesAreAccepted() {
        let set = ScratchFamilyAnnotationSet(attachments: [
            attachment(lower: 0, upper: 3, family: .baby),
            attachment(lower: 4, upper: 6, family: .baby),   // touches, does not overlap
            attachment(lower: 7, upper: 7, family: .chirp),  // single-index, adjacent
        ])
        XCTAssertNotNil(set)
        XCTAssertEqual(set?.attachments.count, 3)
    }

    // MARK: - 6. Duplicate family labels on separate ranges are accepted

    func testDuplicateFamilyLabelsOnSeparateRangesAreAccepted() {
        let set = ScratchFamilyAnnotationSet(attachments: [
            attachment(lower: 0,  upper: 3,  family: .baby),
            attachment(lower: 5,  upper: 7,  family: .baby),
            attachment(lower: 10, upper: 12, family: .baby),
        ])
        XCTAssertNotNil(set)
        XCTAssertEqual(set?.attachments.count, 3)
    }

    // MARK: - 7. attachment(containing:) returns nil for negative index

    func testAttachmentContainingReturnsNilForNegativeIndex() {
        let set = ScratchFamilyAnnotationSet(attachments: [
            attachment(lower: 0, upper: 3, family: .baby),
        ])!
        XCTAssertNil(set.attachment(containing: -1))
        XCTAssertNil(set.attachment(containing: -100))
    }

    // MARK: - 8. attachment(containing:) returns nil when outside any range

    func testAttachmentContainingReturnsNilOutsideAnyRange() {
        let set = ScratchFamilyAnnotationSet(attachments: [
            attachment(lower: 0,  upper: 3,  family: .baby),
            attachment(lower: 10, upper: 12, family: .chirp),
        ])!
        XCTAssertNil(set.attachment(containing: 4))
        XCTAssertNil(set.attachment(containing: 9))
        XCTAssertNil(set.attachment(containing: 13))
        XCTAssertNil(set.attachment(containing: 999))
    }

    // MARK: - 9. attachment(containing:) returns expected attachment

    func testAttachmentContainingReturnsExpectedAttachment() {
        let a0 = attachment(lower: 0,  upper: 3,  family: .baby)
        let a1 = attachment(lower: 5,  upper: 7,  family: .scribble)
        let a2 = attachment(lower: 10, upper: 12, family: .chirp)
        let set = ScratchFamilyAnnotationSet(attachments: [a0, a1, a2])!

        XCTAssertEqual(set.attachment(containing: 0),  a0)
        XCTAssertEqual(set.attachment(containing: 2),  a0)
        XCTAssertEqual(set.attachment(containing: 3),  a0)
        XCTAssertEqual(set.attachment(containing: 5),  a1)
        XCTAssertEqual(set.attachment(containing: 6),  a1)
        XCTAssertEqual(set.attachment(containing: 12), a2)
    }

    // MARK: - 10. attachments(for:) filters by family

    func testAttachmentsForFiltersByFamily() {
        let set = ScratchFamilyAnnotationSet(attachments: [
            attachment(lower: 0,  upper: 3,  family: .baby),
            attachment(lower: 5,  upper: 7,  family: .chirp),
            attachment(lower: 10, upper: 12, family: .baby),
            attachment(lower: 15, upper: 17, family: .flare),
        ])!
        XCTAssertEqual(set.attachments(for: .baby).count, 2)
        XCTAssertEqual(set.attachments(for: .chirp).count, 1)
        XCTAssertEqual(set.attachments(for: .flare).count, 1)
        XCTAssertEqual(set.attachments(for: .transform).count, 0)
        XCTAssertEqual(set.attachments(for: .unknown).count, 0)
    }

    // MARK: - 11. attachments(for:) preserves stored order

    func testAttachmentsForPreservesStoredOrder() {
        let earlyBaby = attachment(lower: 0,  upper: 3,  family: .baby)
        let midBaby   = attachment(lower: 10, upper: 12, family: .baby)
        let lateBaby  = attachment(lower: 20, upper: 22, family: .baby)
        let set = ScratchFamilyAnnotationSet(attachments: [
            earlyBaby,
            attachment(lower: 5, upper: 7, family: .chirp),
            midBaby,
            attachment(lower: 15, upper: 17, family: .flare),
            lateBaby,
        ])!
        XCTAssertEqual(set.attachments(for: .baby), [earlyBaby, midBaby, lateBaby])
    }

    // MARK: - 12. Codable round-trip

    func testCodableRoundTrip() throws {
        let set = ScratchFamilyAnnotationSet(attachments: [
            attachment(lower: 0,  upper: 3,  family: .baby),
            attachment(lower: 5,  upper: 7,  family: .chirp),
            attachment(lower: 10, upper: 12, family: .baby),
        ])!
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        let data = try encoder.encode(set)
        XCTAssertEqual(try decoder.decode(ScratchFamilyAnnotationSet.self, from: data), set)
        let second = try encoder.encode(try decoder.decode(ScratchFamilyAnnotationSet.self, from: data))
        XCTAssertEqual(data, second)

        // Empty set round-trips cleanly.
        let emptySet = ScratchFamilyAnnotationSet(attachments: [])!
        let emptyData = try encoder.encode(emptySet)
        XCTAssertEqual(
            try decoder.decode(ScratchFamilyAnnotationSet.self, from: emptyData),
            emptySet
        )
    }

    // MARK: - 13. Decoder rejects overlapping ranges

    func testCodableRejectsOverlappingRanges() {
        let decoder = JSONDecoder()
        let invalid = """
        {
          "attachments": [
            {
              "primitiveRange": {"lowerBound":0,"upperBound":5},
              "label": {"family":"baby","displayName":"Baby Scratch","isResearchOnly":false}
            },
            {
              "primitiveRange": {"lowerBound":3,"upperBound":7},
              "label": {"family":"baby","displayName":"Baby Scratch","isResearchOnly":false}
            }
          ]
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(ScratchFamilyAnnotationSet.self, from: invalid))
    }

    // MARK: - 14. Decoder rejects unsorted ranges

    func testCodableRejectsUnsortedRanges() {
        let decoder = JSONDecoder()
        let invalid = """
        {
          "attachments": [
            {
              "primitiveRange": {"lowerBound":10,"upperBound":12},
              "label": {"family":"baby","displayName":"Baby Scratch","isResearchOnly":false}
            },
            {
              "primitiveRange": {"lowerBound":0,"upperBound":3},
              "label": {"family":"chirp","displayName":"Chirp","isResearchOnly":true}
            }
          ]
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(ScratchFamilyAnnotationSet.self, from: invalid))
    }

    // MARK: - 15. Deterministic repeated lookup

    func testDeterministicLookups() {
        let set = ScratchFamilyAnnotationSet(attachments: [
            attachment(lower: 0,  upper: 3,  family: .baby),
            attachment(lower: 5,  upper: 7,  family: .chirp),
        ])!
        for index in -2...10 {
            XCTAssertEqual(set.attachment(containing: index),
                            set.attachment(containing: index))
        }
        XCTAssertEqual(set.attachments(for: .baby), set.attachments(for: .baby))
    }

    // MARK: - 16. No primitive / timing access required

    /// Demonstrates that the entire `ScratchFamilyAnnotationSet`
    /// surface is exercised here without constructing any
    /// `NotationPrimitive`, `TimingGrid`, `PlatterPositionTimeline`,
    /// or other capture / timing artifact in scope. The compiler
    /// catches any future regression where the API requires primitive
    /// or timing context.
    func testNoPrimitiveOrTimingAccessRequired() {
        let set = ScratchFamilyAnnotationSet(attachments: [
            attachment(lower: 0,  upper: 3,  family: .baby),
            attachment(lower: 5,  upper: 7,  family: .chirp),
        ])!
        _ = set.attachment(containing: 2)
        _ = set.attachments(for: .baby)
        XCTAssertEqual(set.attachments.count, 2)
    }
}
