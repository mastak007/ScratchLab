import XCTest
@testable import ScratchLab

/// Section 3 / Slice 1 — locks the contract of the scratch-family
/// vocabulary (`ScratchFamily`, `ScratchFamilyLabel`,
/// `ScratchFamilyCatalog`). Pure metadata; no primitive, timing, ML,
/// or capture coupling.
final class ScratchFamilyTests: XCTestCase {

    // MARK: - 1. allCases contains the expected families in stable order

    func testAllCasesContainsExpectedFamiliesInStableOrder() {
        XCTAssertEqual(ScratchFamily.allCases, [
            .baby,
            .scribble,
            .chirp,
            .flare,
            .transform,
            .tear,
            .orbit,
            .crab,
            .unknown,
        ])
    }

    // MARK: - 2. Raw values are stable lowercase identifiers

    func testRawValuesAreStableLowercaseIdentifiers() {
        XCTAssertEqual(ScratchFamily.baby.rawValue,      "baby")
        XCTAssertEqual(ScratchFamily.scribble.rawValue,  "scribble")
        XCTAssertEqual(ScratchFamily.chirp.rawValue,     "chirp")
        XCTAssertEqual(ScratchFamily.flare.rawValue,     "flare")
        XCTAssertEqual(ScratchFamily.transform.rawValue, "transform")
        XCTAssertEqual(ScratchFamily.tear.rawValue,      "tear")
        XCTAssertEqual(ScratchFamily.orbit.rawValue,     "orbit")
        XCTAssertEqual(ScratchFamily.crab.rawValue,      "crab")
        XCTAssertEqual(ScratchFamily.unknown.rawValue,   "unknown")
    }

    // MARK: - 3. Display names match the specified product-safe names

    func testDisplayNamesMatchSpec() {
        XCTAssertEqual(ScratchFamilyCatalog.label(for: .baby).displayName,      "Baby Scratch")
        XCTAssertEqual(ScratchFamilyCatalog.label(for: .scribble).displayName,  "Scribble")
        XCTAssertEqual(ScratchFamilyCatalog.label(for: .chirp).displayName,     "Chirp")
        XCTAssertEqual(ScratchFamilyCatalog.label(for: .flare).displayName,     "Flare")
        XCTAssertEqual(ScratchFamilyCatalog.label(for: .transform).displayName, "Transform")
        XCTAssertEqual(ScratchFamilyCatalog.label(for: .tear).displayName,      "Tear")
        XCTAssertEqual(ScratchFamilyCatalog.label(for: .orbit).displayName,     "Orbit")
        XCTAssertEqual(ScratchFamilyCatalog.label(for: .crab).displayName,      "Crab")
        XCTAssertEqual(ScratchFamilyCatalog.label(for: .unknown).displayName,   "Unknown")
    }

    // MARK: - 4. Baby label is not research-only

    func testBabyLabelIsNotResearchOnly() {
        XCTAssertFalse(ScratchFamilyCatalog.label(for: .baby).isResearchOnly)
    }

    // MARK: - 5. Unknown label is not research-only

    func testUnknownLabelIsNotResearchOnly() {
        XCTAssertFalse(ScratchFamilyCatalog.label(for: .unknown).isResearchOnly)
    }

    // MARK: - 6. All non-baby known technique labels are research-only

    func testAllNonBabyKnownTechniquesAreResearchOnly() {
        let researchOnlyFamilies: [ScratchFamily] = [
            .scribble, .chirp, .flare, .transform, .tear, .orbit, .crab,
        ]
        for family in researchOnlyFamilies {
            XCTAssertTrue(
                ScratchFamilyCatalog.label(for: family).isResearchOnly,
                "\(family.rawValue) must be research-only at this stage"
            )
        }
    }

    // MARK: - 7. Catalog all count matches ScratchFamily.allCases count

    func testCatalogAllCountMatchesAllCasesCount() {
        XCTAssertEqual(ScratchFamilyCatalog.all.count, ScratchFamily.allCases.count)
        // Same order as allCases.
        XCTAssertEqual(ScratchFamilyCatalog.all.map(\.family), ScratchFamily.allCases)
    }

    // MARK: - 8. label(for:) returns a label for every family

    func testLabelForReturnsLabelForEveryFamily() {
        for family in ScratchFamily.allCases {
            let label = ScratchFamilyCatalog.label(for: family)
            XCTAssertEqual(label.family, family)
            XCTAssertFalse(label.displayName.isEmpty,
                           "\(family.rawValue) must have a non-empty displayName")
        }
    }

    // MARK: - 9. Codable round-trip for ScratchFamily

    func testCodableRoundTripForScratchFamily() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for family in ScratchFamily.allCases {
            let data = try encoder.encode(family)
            let decoded = try decoder.decode(ScratchFamily.self, from: data)
            XCTAssertEqual(decoded, family)
        }
    }

    // MARK: - 10. Codable rejects unknown raw value

    func testCodableRejectsUnknownRawValue() {
        let decoder = JSONDecoder()
        let unknownRaw = """
        "telepathy"
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(ScratchFamily.self, from: unknownRaw),
                             "decoder must reject unknown raw values, not silently map to .unknown")

        let emptyRaw = """
        ""
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(ScratchFamily.self, from: emptyRaw))
    }

    // MARK: - 11. Codable round-trip for ScratchFamilyLabel

    func testCodableRoundTripForScratchFamilyLabel() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        for family in ScratchFamily.allCases {
            let label = ScratchFamilyCatalog.label(for: family)
            let data = try encoder.encode(label)
            let decoded = try decoder.decode(ScratchFamilyLabel.self, from: data)
            XCTAssertEqual(decoded, label)
            let secondData = try encoder.encode(decoded)
            XCTAssertEqual(secondData, data,
                           "byte-stable re-encode for \(family.rawValue)")
        }
    }

    // MARK: - 12. Deterministic repeated catalog lookups

    func testDeterministicCatalogLookups() {
        for family in ScratchFamily.allCases {
            XCTAssertEqual(
                ScratchFamilyCatalog.label(for: family),
                ScratchFamilyCatalog.label(for: family)
            )
        }
        XCTAssertEqual(ScratchFamilyCatalog.all, ScratchFamilyCatalog.all)
    }
}
