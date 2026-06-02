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

    // MARK: - 17. ActionableCoaching copy strings are non-empty

    func testActionableCoachingCopyStringsAreNonEmpty() {
        XCTAssertFalse(CoachCopy.ActionableCoaching.header.isEmpty)
        XCTAssertFalse(CoachCopy.ActionableCoaching.lowConfidenceDisclaimer.isEmpty)
        XCTAssertFalse(CoachCopy.ActionableCoaching.lateReversalAction.isEmpty)
        XCTAssertFalse(CoachCopy.ActionableCoaching.earlyReversalAction.isEmpty)
    }

    // MARK: - 18. ActionableCoaching copy is PROFILE.md-compliant

    func testActionableCoachingCopyUsesNoBannedVocabulary() {
        let banned: [String] = [
            "AI detects",
            "deep learning",
            "real-time AI coach",
            "perfectly detects",
        ]
        let strings: [String] = [
            CoachCopy.ActionableCoaching.header,
            CoachCopy.ActionableCoaching.lowConfidenceDisclaimer,
            CoachCopy.ActionableCoaching.lateReversalAction,
            CoachCopy.ActionableCoaching.earlyReversalAction,
        ]
        for string in strings {
            let lower = string.lowercased()
            for phrase in banned {
                XCTAssertFalse(
                    lower.contains(phrase.lowercased()),
                    "ActionableCoaching string \"\(string.prefix(40))...\" contains banned phrase \"\(phrase)\""
                )
            }
        }
    }

    // MARK: - 19. ActionableCoaching late/early reversal copy is distinct

    func testActionableCoachingLateAndEarlyReversalCopyAreDistinct() {
        XCTAssertNotEqual(
            CoachCopy.ActionableCoaching.lateReversalAction,
            CoachCopy.ActionableCoaching.earlyReversalAction,
            "Late and early reversal actionable copy must be distinct"
        )
    }

    // MARK: - 20. ActionableCoaching fallbackAction returns catalog body

    func testActionableCoachingFallbackActionReturnsCatalogBody() {
        for kind in CoachingEventKind.allCases {
            let fallback = CoachCopy.ActionableCoaching.fallbackAction(for: kind)
            let expected = CoachingEventCatalog.descriptor(for: kind).body
            XCTAssertEqual(fallback, expected,
                           "fallbackAction(for: .\(kind.rawValue)) must return the catalog descriptor body")
        }
    }

    // MARK: - 21. CoachCopy vocabulary compliance (PROFILE.md / App Store safety)

    /// PROFILE.md / CoachCopy header banned vocabulary: ScratchLab must never imply an AI
    /// detector, deep learning, a real-time AI coach, or perfect detection. Matched
    /// phrase-level and case-insensitive — bare "AI"/"ai" is intentionally NOT banned (it
    /// would false-positive "available", "again", "fail"); only the documented
    /// marketing-risk phrases are.
    private static let bannedPhrases = [
        "AI detects", "AI detect", "AI coach", "real-time AI coach",
        "deep learning", "neural", "perfectly detects", "perfectly detect",
    ]

    func testCoachCopyAggregatorIsNonEmptyAndStringsAreNonEmpty() {
        XCTAssertFalse(CoachCopy.allUserFacingStrings.isEmpty,
                       "the audit aggregator must list the user-facing strings")
        for s in CoachCopy.allUserFacingStrings {
            XCTAssertFalse(s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "no user-facing string should be empty")
        }
    }

    func testCoachCopyContainsNoBannedVocabulary() {
        for s in CoachCopy.allUserFacingStrings {
            let lower = s.lowercased()
            for phrase in Self.bannedPhrases {
                XCTAssertFalse(lower.contains(phrase.lowercased()),
                               "CoachCopy string contains banned phrase \"\(phrase)\": \"\(s)\"")
            }
        }
    }

    /// The practice-timing preview surface must keep its PROFILE.md-required disclaimer
    /// conventions: a "(preview)" suffix token and the not-saved/exported/scored disclaimer
    /// stating metrics come from on-device audio onsets.
    func testTimingPreviewKeepsRequiredDisclaimerVocabulary() {
        XCTAssertEqual(CoachCopy.TimingPreview.previewSuffix, "(preview)")
        let disclaimer = CoachCopy.TimingPreview.disclaimer.lowercased()
        XCTAssertTrue(disclaimer.contains("on-device audio onsets"),
                      "disclaimer must state metrics come from on-device audio onsets")
        XCTAssertTrue(disclaimer.contains("aren't saved, exported, or scored"),
                      "disclaimer must keep the not-saved/exported/scored language")
    }
}
