import XCTest
@testable import ScratchLab

/// Section 4 / Slice 1 — locks the contract of the coaching-event
/// vocabulary (`CoachingEventKind`, `CoachingEventSeverity`,
/// `CoachingEventDescriptor`, `CoachingEventCatalog`). Pure metadata;
/// no primitive, timing, semantic, ML, capture, or scoring coupling.
final class CoachingEventVocabularyTests: XCTestCase {

    // MARK: - 1. Kind allCases stable order

    func testKindAllCasesContainsExpectedKindsInStableOrder() {
        XCTAssertEqual(CoachingEventKind.allCases, [
            .lateReversal,
            .earlyReversal,
            .unstableTiming,
            .clippedMotion,
            .incompletePhrase,
            .noSignal,
            .unknown,
        ])
    }

    // MARK: - 2. Severity allCases stable order

    func testSeverityAllCasesContainsExpectedSeveritiesInStableOrder() {
        XCTAssertEqual(CoachingEventSeverity.allCases, [
            .info,
            .notice,
            .warning,
        ])
    }

    // MARK: - 3. Kind raw values are stable camelCase identifiers

    func testKindRawValuesAreStableCamelCaseIdentifiers() {
        XCTAssertEqual(CoachingEventKind.lateReversal.rawValue,     "lateReversal")
        XCTAssertEqual(CoachingEventKind.earlyReversal.rawValue,    "earlyReversal")
        XCTAssertEqual(CoachingEventKind.unstableTiming.rawValue,   "unstableTiming")
        XCTAssertEqual(CoachingEventKind.clippedMotion.rawValue,    "clippedMotion")
        XCTAssertEqual(CoachingEventKind.incompletePhrase.rawValue, "incompletePhrase")
        XCTAssertEqual(CoachingEventKind.noSignal.rawValue,         "noSignal")
        XCTAssertEqual(CoachingEventKind.unknown.rawValue,          "unknown")
    }

    // MARK: - 4. Severity raw values are stable lowercase identifiers

    func testSeverityRawValuesAreStableLowercaseIdentifiers() {
        XCTAssertEqual(CoachingEventSeverity.info.rawValue,    "info")
        XCTAssertEqual(CoachingEventSeverity.notice.rawValue,  "notice")
        XCTAssertEqual(CoachingEventSeverity.warning.rawValue, "warning")
    }

    // MARK: - 5. Catalog all count matches CoachingEventKind.allCases count

    func testCatalogAllCountMatchesKindAllCasesCount() {
        XCTAssertEqual(CoachingEventCatalog.all.count, CoachingEventKind.allCases.count)
        XCTAssertEqual(CoachingEventCatalog.all.map(\.kind), CoachingEventKind.allCases)
    }

    // MARK: - 6. descriptor(for:) returns one descriptor per kind

    func testDescriptorForReturnsOneDescriptorPerKind() {
        for kind in CoachingEventKind.allCases {
            let descriptor = CoachingEventCatalog.descriptor(for: kind)
            XCTAssertEqual(descriptor.kind, kind)
        }
    }

    // MARK: - 7. Descriptor display names match spec

    func testDescriptorDisplayNamesMatchSpec() {
        XCTAssertEqual(CoachingEventCatalog.descriptor(for: .lateReversal).displayName,     "Late reversal")
        XCTAssertEqual(CoachingEventCatalog.descriptor(for: .earlyReversal).displayName,    "Early reversal")
        XCTAssertEqual(CoachingEventCatalog.descriptor(for: .unstableTiming).displayName,   "Unstable timing")
        XCTAssertEqual(CoachingEventCatalog.descriptor(for: .clippedMotion).displayName,    "Clipped motion")
        XCTAssertEqual(CoachingEventCatalog.descriptor(for: .incompletePhrase).displayName, "Incomplete phrase")
        XCTAssertEqual(CoachingEventCatalog.descriptor(for: .noSignal).displayName,         "No usable signal")
        XCTAssertEqual(CoachingEventCatalog.descriptor(for: .unknown).displayName,          "Unknown")
    }

    // MARK: - 8. Descriptor body strings are non-empty

    func testDescriptorBodyStringsAreNonEmpty() {
        for kind in CoachingEventKind.allCases {
            let descriptor = CoachingEventCatalog.descriptor(for: kind)
            XCTAssertFalse(descriptor.body.isEmpty,
                           "\(kind.rawValue) must have a non-empty body")
        }
    }

    // MARK: - 9. clippedMotion is research-only

    func testClippedMotionIsResearchOnly() {
        XCTAssertTrue(CoachingEventCatalog.descriptor(for: .clippedMotion).isResearchOnly)
    }

    // MARK: - 10. All other descriptors are not research-only

    func testAllOtherDescriptorsAreNotResearchOnly() {
        let nonResearchKinds: [CoachingEventKind] = [
            .lateReversal,
            .earlyReversal,
            .unstableTiming,
            .incompletePhrase,
            .noSignal,
            .unknown,
        ]
        for kind in nonResearchKinds {
            XCTAssertFalse(
                CoachingEventCatalog.descriptor(for: kind).isResearchOnly,
                "\(kind.rawValue) must not be research-only at this stage"
            )
        }
    }

    // MARK: - 11. Codable round-trip for CoachingEventKind

    func testCodableRoundTripForCoachingEventKind() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for kind in CoachingEventKind.allCases {
            let data = try encoder.encode(kind)
            let decoded = try decoder.decode(CoachingEventKind.self, from: data)
            XCTAssertEqual(decoded, kind)
        }
    }

    // MARK: - 12. Codable rejects unknown kind raw value

    func testCodableRejectsUnknownKindRawValue() {
        let decoder = JSONDecoder()
        let unknownRaw = """
        "telepathy"
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(CoachingEventKind.self, from: unknownRaw),
                             "decoder must reject unknown raw values, not silently map to .unknown")

        let emptyRaw = """
        ""
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(CoachingEventKind.self, from: emptyRaw))
    }

    // MARK: - 13. Codable round-trip for CoachingEventSeverity

    func testCodableRoundTripForCoachingEventSeverity() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for severity in CoachingEventSeverity.allCases {
            let data = try encoder.encode(severity)
            let decoded = try decoder.decode(CoachingEventSeverity.self, from: data)
            XCTAssertEqual(decoded, severity)
        }
    }

    // MARK: - 14. Codable rejects unknown severity raw value

    func testCodableRejectsUnknownSeverityRawValue() {
        let decoder = JSONDecoder()
        let unknownRaw = """
        "catastrophic"
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(CoachingEventSeverity.self, from: unknownRaw))

        let emptyRaw = """
        ""
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(CoachingEventSeverity.self, from: emptyRaw))
    }

    // MARK: - 15. Codable round-trip for CoachingEventDescriptor

    func testCodableRoundTripForCoachingEventDescriptor() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        for kind in CoachingEventKind.allCases {
            let descriptor = CoachingEventCatalog.descriptor(for: kind)
            let data = try encoder.encode(descriptor)
            let decoded = try decoder.decode(CoachingEventDescriptor.self, from: data)
            XCTAssertEqual(decoded, descriptor)
            let secondData = try encoder.encode(decoded)
            XCTAssertEqual(secondData, data,
                           "byte-stable re-encode for \(kind.rawValue)")
        }
    }

    // MARK: - 16. Deterministic repeated catalog lookups

    func testDeterministicCatalogLookups() {
        for kind in CoachingEventKind.allCases {
            XCTAssertEqual(
                CoachingEventCatalog.descriptor(for: kind),
                CoachingEventCatalog.descriptor(for: kind)
            )
        }
        XCTAssertEqual(CoachingEventCatalog.all, CoachingEventCatalog.all)
    }
}
