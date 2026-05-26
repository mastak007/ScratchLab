import XCTest
@testable import ScratchLab

/// Section 4 / Slice 3 — locks the contract of
/// `DriftCoachingRule` and `DriftCoachingEvaluator`. Pure
/// deterministic threshold mapping; no ML, no primitives, no
/// scoring, no UI/export coupling.
final class DriftCoachingEvaluatorTests: XCTestCase {

    // MARK: - Helpers

    private func drift(
        primitiveIndex: Int = 0,
        expectedTime: TimeInterval = 0,
        actualTime: TimeInterval,
        drift: TimeInterval,
        isWithinWindow: Bool = false
    ) -> TimingDrift {
        TimingDrift(
            primitiveIndex: primitiveIndex,
            expectedTime: expectedTime,
            actualTime: actualTime,
            drift: drift,
            isWithinWindow: isWithinWindow
        )
    }

    private func rule(late: TimeInterval, early: TimeInterval,
                      file: StaticString = #filePath, line: UInt = #line) -> DriftCoachingRule {
        guard let rule = DriftCoachingRule(lateThreshold: late, earlyThreshold: early) else {
            XCTFail("DriftCoachingRule(late: \(late), early: \(early)) unexpectedly rejected", file: file, line: line)
            return DriftCoachingRule(lateThreshold: 0, earlyThreshold: 0)!
        }
        return rule
    }

    // MARK: - 1. rule rejects negative thresholds

    func testRuleRejectsNegativeThresholds() {
        XCTAssertNil(DriftCoachingRule(lateThreshold: -0.001, earlyThreshold: 0.0))
        XCTAssertNil(DriftCoachingRule(lateThreshold: 0.0, earlyThreshold: -0.001))
        XCTAssertNil(DriftCoachingRule(lateThreshold: -1.0, earlyThreshold: -1.0))
    }

    // MARK: - 2. rule rejects NaN/infinity thresholds

    func testRuleRejectsNonFiniteThresholds() {
        XCTAssertNil(DriftCoachingRule(lateThreshold: .nan, earlyThreshold: 0))
        XCTAssertNil(DriftCoachingRule(lateThreshold: 0, earlyThreshold: .nan))
        XCTAssertNil(DriftCoachingRule(lateThreshold: .infinity, earlyThreshold: 0))
        XCTAssertNil(DriftCoachingRule(lateThreshold: 0, earlyThreshold: .infinity))
        XCTAssertNil(DriftCoachingRule(lateThreshold: -.infinity, earlyThreshold: 0))
    }

    // MARK: - 3. rule accepts zero thresholds

    func testRuleAcceptsZeroThresholds() {
        let r = DriftCoachingRule(lateThreshold: 0, earlyThreshold: 0)
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.lateThreshold, 0)
        XCTAssertEqual(r?.earlyThreshold, 0)
    }

    // MARK: - 4. late drift over threshold emits lateReversal

    func testLateDriftOverThresholdEmitsLateReversal() {
        let r = rule(late: 0.05, early: 0.05)
        let drifts = [drift(actualTime: 1.0, drift: 0.06)]
        let events = DriftCoachingEvaluator.events(from: drifts, using: r)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .lateReversal)
    }

    // MARK: - 5. late drift at threshold emits no event

    func testLateDriftAtThresholdEmitsNoEvent() {
        let r = rule(late: 0.05, early: 0.05)
        let drifts = [drift(actualTime: 1.0, drift: 0.05)]
        XCTAssertEqual(DriftCoachingEvaluator.events(from: drifts, using: r), [])
    }

    // MARK: - 6. early drift over threshold emits earlyReversal

    func testEarlyDriftOverThresholdEmitsEarlyReversal() {
        let r = rule(late: 0.05, early: 0.05)
        let drifts = [drift(actualTime: 1.0, drift: -0.06)]
        let events = DriftCoachingEvaluator.events(from: drifts, using: r)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .earlyReversal)
    }

    // MARK: - 7. early drift at threshold emits no event

    func testEarlyDriftAtThresholdEmitsNoEvent() {
        let r = rule(late: 0.05, early: 0.05)
        let drifts = [drift(actualTime: 1.0, drift: -0.05)]
        XCTAssertEqual(DriftCoachingEvaluator.events(from: drifts, using: r), [])
    }

    // MARK: - 8. in-window drift emits no event

    func testInWindowDriftEmitsNoEvent() {
        let r = rule(late: 0.05, early: 0.05)
        let drifts = [
            drift(actualTime: 1.0, drift: 0.0),
            drift(actualTime: 1.1, drift: 0.02),
            drift(actualTime: 1.2, drift: -0.03),
            drift(actualTime: 1.3, drift: 0.049),
            drift(actualTime: 1.4, drift: -0.049),
        ]
        XCTAssertEqual(DriftCoachingEvaluator.events(from: drifts, using: r), [])
    }

    // MARK: - 9. emitted event time uses actualTime

    func testEmittedEventTimeUsesActualTime() {
        let r = rule(late: 0.05, early: 0.05)
        let drifts = [
            drift(actualTime: 7.25, drift: 0.10),
            drift(actualTime: 9.75, drift: -0.20),
        ]
        let events = DriftCoachingEvaluator.events(from: drifts, using: r)
        XCTAssertEqual(events.map(\.time), [7.25, 9.75])
    }

    // MARK: - 10. emitted severity comes from catalog

    func testEmittedSeverityComesFromCatalog() {
        let r = rule(late: 0.05, early: 0.05)
        let drifts = [
            drift(actualTime: 1.0, drift: 0.10),
            drift(actualTime: 2.0, drift: -0.10),
        ]
        let events = DriftCoachingEvaluator.events(from: drifts, using: r)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].severity, CoachingEventCatalog.descriptor(for: .lateReversal).severity)
        XCTAssertEqual(events[1].severity, CoachingEventCatalog.descriptor(for: .earlyReversal).severity)
    }

    // MARK: - 11. emitted message is nil

    func testEmittedMessageIsNil() {
        let r = rule(late: 0.05, early: 0.05)
        let drifts = [
            drift(actualTime: 1.0, drift: 0.10),
            drift(actualTime: 2.0, drift: -0.10),
        ]
        for event in DriftCoachingEvaluator.events(from: drifts, using: r) {
            XCTAssertNil(event.message)
        }
    }

    // MARK: - 12. preserves emitted order

    func testPreservesEmittedOrder() {
        let r = rule(late: 0.05, early: 0.05)
        let drifts = [
            drift(actualTime: 1.0, drift: 0.10),  // late
            drift(actualTime: 1.5, drift: 0.02),  // skipped
            drift(actualTime: 2.0, drift: -0.10), // early
            drift(actualTime: 2.5, drift: -0.03), // skipped
            drift(actualTime: 3.0, drift: 0.20),  // late
        ]
        let events = DriftCoachingEvaluator.events(from: drifts, using: r)
        XCTAssertEqual(events.map(\.time), [1.0, 2.0, 3.0])
        XCTAssertEqual(events.map(\.kind), [.lateReversal, .earlyReversal, .lateReversal])
    }

    // MARK: - 13. empty drifts return empty events

    func testEmptyDriftsReturnEmptyEvents() {
        let r = rule(late: 0.05, early: 0.05)
        XCTAssertEqual(DriftCoachingEvaluator.events(from: [], using: r), [])
    }

    // MARK: - 14. Codable round-trip

    func testRuleCodableRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        let cases: [DriftCoachingRule] = [
            rule(late: 0, early: 0),
            rule(late: 0.05, early: 0.05),
            rule(late: 0.10, early: 0.25),
        ]
        for r in cases {
            let data = try encoder.encode(r)
            let decoded = try decoder.decode(DriftCoachingRule.self, from: data)
            XCTAssertEqual(decoded, r)
            let second = try encoder.encode(decoded)
            XCTAssertEqual(second, data)
        }
    }

    // MARK: - 15. Codable rejects invalid rule

    func testCodableRejectsInvalidRule() {
        let decoder = JSONDecoder()
        let negativeLate = """
        {"lateThreshold": -0.001, "earlyThreshold": 0.05}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(DriftCoachingRule.self, from: negativeLate))

        let negativeEarly = """
        {"lateThreshold": 0.05, "earlyThreshold": -0.001}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(DriftCoachingRule.self, from: negativeEarly))

        let nonFinite = """
        {"lateThreshold": 1e1000, "earlyThreshold": 0.05}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(DriftCoachingRule.self, from: nonFinite))
    }

    // MARK: - 16. Deterministic repeated evaluation

    func testDeterministicRepeatedEvaluation() {
        let r = rule(late: 0.05, early: 0.05)
        let drifts = [
            drift(actualTime: 1.0, drift: 0.10),
            drift(actualTime: 1.5, drift: 0.02),
            drift(actualTime: 2.0, drift: -0.10),
            drift(actualTime: 2.5, drift: -0.03),
            drift(actualTime: 3.0, drift: 0.20),
        ]
        let first = DriftCoachingEvaluator.events(from: drifts, using: r)
        let second = DriftCoachingEvaluator.events(from: drifts, using: r)
        XCTAssertEqual(first, second)
    }
}
