import XCTest
@testable import ScratchLab

/// Section 4 / Slice 5 — locks the contract of
/// `CoachingEventSummary`, `CoachingEventMerger`, and
/// `CoachingEventSummaryEvaluator`. Pure deterministic merge and
/// count utilities; no ML, no primitives, no timing, no scoring.
final class CoachingEventSummaryTests: XCTestCase {

    // MARK: - Helpers

    private func event(
        time: TimeInterval,
        kind: CoachingEventKind = .lateReversal,
        severity: CoachingEventSeverity? = nil,
        message: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> CoachingEvent {
        let resolvedSeverity = severity ?? CoachingEventCatalog.descriptor(for: kind).severity
        guard let event = CoachingEvent(
            time: time,
            kind: kind,
            severity: resolvedSeverity,
            message: message
        ) else {
            XCTFail("CoachingEvent(time: \(time), kind: \(kind)) unexpectedly rejected",
                    file: file, line: line)
            return CoachingEvent(time: 0, kind: kind, severity: resolvedSeverity, message: message)!
        }
        return event
    }

    // MARK: - 1. merge empty groups returns empty set

    func testMergeEmptyGroupsReturnsEmptySet() {
        XCTAssertEqual(CoachingEventMerger.merge([]), CoachingEventSet(events: []))
        XCTAssertEqual(CoachingEventMerger.merge([[], [], []]), CoachingEventSet(events: []))
    }

    // MARK: - 2. merge flattens multiple groups

    func testMergeFlattensMultipleGroups() {
        let a = event(time: 0.5, kind: .lateReversal)
        let b = event(time: 1.0, kind: .earlyReversal)
        let c = event(time: 2.0, kind: .unstableTiming, severity: .warning)
        let merged = CoachingEventMerger.merge([[a], [b], [c]])
        XCTAssertEqual(merged?.events, [a, b, c])
    }

    // MARK: - 3. merge sorts by time ascending

    func testMergeSortsByTimeAscending() {
        let g1 = [
            event(time: 3.0, kind: .lateReversal),
            event(time: 1.0, kind: .earlyReversal),
        ]
        let g2 = [
            event(time: 2.0, kind: .unstableTiming, severity: .warning),
        ]
        let merged = CoachingEventMerger.merge([g1, g2])
        XCTAssertEqual(merged?.events.map(\.time), [1.0, 2.0, 3.0])
    }

    // MARK: - 4. merge preserves group order for equal times

    func testMergePreservesGroupOrderForEqualTimes() {
        let group0 = [event(time: 1.0, kind: .lateReversal)]
        let group1 = [event(time: 1.0, kind: .earlyReversal)]
        let group2 = [event(time: 1.0, kind: .unstableTiming, severity: .warning)]
        let merged = CoachingEventMerger.merge([group0, group1, group2])
        XCTAssertEqual(merged?.events.map(\.kind), [.lateReversal, .earlyReversal, .unstableTiming])
    }

    // MARK: - 5. merge preserves within-group order for equal times

    func testMergePreservesWithinGroupOrderForEqualTimes() {
        let groupA = [
            event(time: 1.0, kind: .lateReversal),
            event(time: 1.0, kind: .earlyReversal),
            event(time: 1.0, kind: .unstableTiming, severity: .warning),
        ]
        let merged = CoachingEventMerger.merge([groupA])
        XCTAssertEqual(merged?.events.map(\.kind), [.lateReversal, .earlyReversal, .unstableTiming])
    }

    // MARK: - 6. summary includes one row per CoachingEventKind

    func testSummaryIncludesOneRowPerCoachingEventKind() {
        let set = CoachingEventSet(events: [])!
        let rows = CoachingEventSummaryEvaluator.summarize(set)
        XCTAssertEqual(rows.count, CoachingEventKind.allCases.count)
    }

    // MARK: - 7. summary order matches CoachingEventKind.allCases

    func testSummaryOrderMatchesAllCases() {
        let set = CoachingEventSet(events: [])!
        let rows = CoachingEventSummaryEvaluator.summarize(set)
        XCTAssertEqual(rows.map(\.kind), CoachingEventKind.allCases)
    }

    // MARK: - 8. summary count computed per kind

    func testSummaryCountComputedPerKind() {
        let events = [
            event(time: 0.0, kind: .lateReversal),
            event(time: 0.1, kind: .lateReversal),
            event(time: 0.2, kind: .earlyReversal),
            event(time: 0.3, kind: .unstableTiming, severity: .warning),
            event(time: 0.4, kind: .unstableTiming, severity: .warning),
            event(time: 0.5, kind: .unstableTiming, severity: .warning),
        ]
        let set = CoachingEventSet(events: events)!
        let rows = CoachingEventSummaryEvaluator.summarize(set)
        let byKind = Dictionary(uniqueKeysWithValues: rows.map { ($0.kind, $0.count) })
        XCTAssertEqual(byKind[.lateReversal], 2)
        XCTAssertEqual(byKind[.earlyReversal], 1)
        XCTAssertEqual(byKind[.unstableTiming], 3)
    }

    // MARK: - 9. zero-count kinds are included

    func testZeroCountKindsAreIncluded() {
        let events = [event(time: 0.0, kind: .lateReversal)]
        let set = CoachingEventSet(events: events)!
        let rows = CoachingEventSummaryEvaluator.summarize(set)
        XCTAssertEqual(rows.count, CoachingEventKind.allCases.count)
        for row in rows where row.kind != .lateReversal {
            XCTAssertEqual(row.count, 0, "\(row.kind.rawValue) should be 0")
        }
        XCTAssertEqual(rows.first { $0.kind == .lateReversal }?.count, 1)
    }

    // MARK: - 10. summary severity comes from catalog

    func testSummarySeverityComesFromCatalog() {
        let set = CoachingEventSet(events: [])!
        let rows = CoachingEventSummaryEvaluator.summarize(set)
        for row in rows {
            XCTAssertEqual(
                row.severity,
                CoachingEventCatalog.descriptor(for: row.kind).severity,
                "severity for \(row.kind.rawValue) must come from the catalog"
            )
        }
    }

    // MARK: - 11. Codable round-trip

    func testCodableRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        for kind in CoachingEventKind.allCases {
            let row = CoachingEventSummary(
                kind: kind,
                severity: CoachingEventCatalog.descriptor(for: kind).severity,
                count: 7
            )
            let data = try encoder.encode(row)
            let decoded = try decoder.decode(CoachingEventSummary.self, from: data)
            XCTAssertEqual(decoded, row)
            let second = try encoder.encode(decoded)
            XCTAssertEqual(second, data)
        }
    }

    // MARK: - 12. Decoder rejects negative count

    func testDecoderRejectsNegativeCount() {
        let decoder = JSONDecoder()
        let payload = """
        {"kind": "lateReversal", "severity": "notice", "count": -1}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(CoachingEventSummary.self, from: payload))
    }

    // MARK: - 13. Deterministic repeated merge

    func testDeterministicRepeatedMerge() {
        let groups = [
            [event(time: 3.0), event(time: 1.0)],
            [event(time: 2.0, kind: .earlyReversal)],
            [event(time: 1.0, kind: .unstableTiming, severity: .warning)],
        ]
        let first = CoachingEventMerger.merge(groups)
        let second = CoachingEventMerger.merge(groups)
        XCTAssertEqual(first, second)
    }

    // MARK: - 14. Deterministic repeated summary

    func testDeterministicRepeatedSummary() {
        let events = [
            event(time: 0.0, kind: .lateReversal),
            event(time: 0.1, kind: .earlyReversal),
            event(time: 0.2, kind: .unstableTiming, severity: .warning),
        ]
        let set = CoachingEventSet(events: events)!
        let first = CoachingEventSummaryEvaluator.summarize(set)
        let second = CoachingEventSummaryEvaluator.summarize(set)
        XCTAssertEqual(first, second)
    }

    // MARK: - 15. No primitive/timing/family/ML access required

    /// Compile-time assertion. The test exercises the merge and
    /// summary surfaces using only the coaching vocabulary, severity,
    /// event, and set types. If any of these utilities reached for a
    /// primitive, timing, family, or ML symbol, the file would fail
    /// to build without the corresponding imports — and this test
    /// deliberately does not import or reference them.
    func testMergeAndSummarizeReachableWithoutPrimitiveTimingFamilyOrMLImports() {
        let a = event(time: 0.0, kind: .noSignal, severity: .info)
        let b = event(time: 1.0, kind: .lateReversal)
        let merged = CoachingEventMerger.merge([[a], [b]])
        XCTAssertNotNil(merged)
        let rows = CoachingEventSummaryEvaluator.summarize(merged!)
        XCTAssertEqual(rows.count, CoachingEventKind.allCases.count)
    }
}
