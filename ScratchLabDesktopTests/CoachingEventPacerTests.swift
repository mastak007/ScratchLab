import XCTest
@testable import ScratchLab

/// Phase C0b — locks the contract of `CoachingEventPacer` /
/// `CoachingEventPacingRule`: pure throttle / suppressor, no UI, no
/// ML, no clock, deterministic across runs.
final class CoachingEventPacerTests: XCTestCase {

    // MARK: - Helpers

    private func makeEvent(
        time: TimeInterval,
        kind: CoachingEventKind = .lateReversal,
        severity: CoachingEventSeverity = .notice
    ) -> CoachingEvent {
        guard let event = CoachingEvent(time: time, kind: kind, severity: severity, message: nil) else {
            XCTFail("CoachingEvent(time: \(time)) unexpectedly rejected")
            return CoachingEvent(time: 0, kind: kind, severity: severity, message: nil)!
        }
        return event
    }

    private func makeSet(_ events: [CoachingEvent]) -> CoachingEventSet {
        guard let set = CoachingEventSet(events: events) else {
            XCTFail("CoachingEventSet(events:) unexpectedly rejected")
            return CoachingEventSet(events: [])!
        }
        return set
    }

    private func makeRule(global: TimeInterval, perKind: TimeInterval) -> CoachingEventPacingRule {
        guard let rule = CoachingEventPacingRule(
            minimumInterEventSpacing: global,
            sameKindSuppressionWindow: perKind
        ) else {
            XCTFail("CoachingEventPacingRule unexpectedly rejected (\(global), \(perKind))")
            return CoachingEventPacingRule(minimumInterEventSpacing: 0, sameKindSuppressionWindow: 0)!
        }
        return rule
    }

    // MARK: - Construction invariants

    func testPacingRuleRejectsInvalidValues() {
        XCTAssertNil(CoachingEventPacingRule(minimumInterEventSpacing: -0.1, sameKindSuppressionWindow: 0))
        XCTAssertNil(CoachingEventPacingRule(minimumInterEventSpacing: 0, sameKindSuppressionWindow: -0.1))
        XCTAssertNil(CoachingEventPacingRule(minimumInterEventSpacing: .nan, sameKindSuppressionWindow: 0))
        XCTAssertNil(CoachingEventPacingRule(minimumInterEventSpacing: .infinity, sameKindSuppressionWindow: 0))
    }

    func testPacingRuleAllowsZero() {
        XCTAssertNotNil(CoachingEventPacingRule(minimumInterEventSpacing: 0, sameKindSuppressionWindow: 0))
    }

    // MARK: - Empty / no-op cases

    func testEmptySetReturnsEmpty() {
        let rule = makeRule(global: 1.0, perKind: 2.0)
        XCTAssertEqual(CoachingEventPacer.pace(makeSet([]), using: rule), [])
    }

    func testZeroRuleEmitsEverything() {
        // With both thresholds == 0, the pacer must pass every event
        // through in input order (silence-not-required).
        let rule = makeRule(global: 0, perKind: 0)
        let events = [
            makeEvent(time: 1.0),
            makeEvent(time: 1.0, kind: .earlyReversal),
            makeEvent(time: 1.0001, kind: .lateReversal),
        ]
        let paced = CoachingEventPacer.pace(makeSet(events), using: rule)
        XCTAssertEqual(paced.map(\.time), [1.0, 1.0, 1.0001])
    }

    // MARK: - Global spacing

    func testGlobalSpacingSuppressesCloseEvents() {
        // Two events 0.4 s apart with a 1.0 s minimum global spacing —
        // the second is suppressed regardless of kind difference.
        let rule = makeRule(global: 1.0, perKind: 0)
        let events = [
            makeEvent(time: 0.5),
            makeEvent(time: 0.9, kind: .earlyReversal),
        ]
        let paced = CoachingEventPacer.pace(makeSet(events), using: rule)
        XCTAssertEqual(paced.map(\.time), [0.5])
    }

    func testGlobalSpacingAllowsExactlyAtBoundary() {
        // Boundary semantics: an event at exactly `last + spacing` is
        // allowed through (strict less-than comparison inside the
        // pacer).
        let rule = makeRule(global: 1.0, perKind: 0)
        let events = [
            makeEvent(time: 0.5),
            makeEvent(time: 1.5),
        ]
        let paced = CoachingEventPacer.pace(makeSet(events), using: rule)
        XCTAssertEqual(paced.map(\.time), [0.5, 1.5])
    }

    // MARK: - Same-kind suppression

    func testSameKindSuppressesCloseRepeats() {
        // Two `.lateReversal` events 0.5 s apart with a 1.0 s same-
        // kind window — second is suppressed even though global
        // spacing is permissive.
        let rule = makeRule(global: 0, perKind: 1.0)
        let events = [
            makeEvent(time: 0.5, kind: .lateReversal),
            makeEvent(time: 1.0, kind: .lateReversal),
        ]
        let paced = CoachingEventPacer.pace(makeSet(events), using: rule)
        XCTAssertEqual(paced.map(\.time), [0.5])
    }

    func testDifferentKindsBypassSameKindWindow() {
        // With a 1.0 s same-kind window and a 0 s global window, a
        // `.lateReversal` followed quickly by an `.earlyReversal` both
        // pass — the same-kind rule is per-kind.
        let rule = makeRule(global: 0, perKind: 1.0)
        let events = [
            makeEvent(time: 0.5, kind: .lateReversal),
            makeEvent(time: 0.6, kind: .earlyReversal),
        ]
        let paced = CoachingEventPacer.pace(makeSet(events), using: rule)
        XCTAssertEqual(paced.map(\.kind), [.lateReversal, .earlyReversal])
    }

    // MARK: - Determinism / ordering

    func testDeterministicOrderingAcrossReruns() {
        // Exhaustive determinism: same inputs → identical outputs across
        // 100 repeated calls.
        let rule = makeRule(global: 0.3, perKind: 0.9)
        let events = [
            makeEvent(time: 0.10, kind: .lateReversal),
            makeEvent(time: 0.20, kind: .earlyReversal),
            makeEvent(time: 0.55, kind: .lateReversal),
            makeEvent(time: 0.95, kind: .lateReversal),
            makeEvent(time: 1.50, kind: .earlyReversal),
            makeEvent(time: 2.00, kind: .lateReversal),
        ]
        let set = makeSet(events)
        let first = CoachingEventPacer.pace(set, using: rule)
        for _ in 0..<99 {
            XCTAssertEqual(CoachingEventPacer.pace(set, using: rule), first)
        }
    }

    func testOutputOrderMatchesInputTimeOrder() {
        // Output must always be in input order. Construct a stream
        // covering both rules at once and assert the surviving events
        // appear in ascending time.
        let rule = makeRule(global: 0.5, perKind: 1.2)
        let events = [
            makeEvent(time: 0.0, kind: .lateReversal),
            makeEvent(time: 0.3, kind: .earlyReversal),   // suppressed by global
            makeEvent(time: 0.6, kind: .earlyReversal),   // global passes (0.6 - 0 = 0.6)
            makeEvent(time: 1.2, kind: .lateReversal),    // same-kind: 1.2 - 0 = 1.2 ≥ 1.2 → allowed
            makeEvent(time: 1.7, kind: .lateReversal),    // same-kind: 1.7 - 1.2 = 0.5 < 1.2 → suppressed
        ]
        let paced = CoachingEventPacer.pace(makeSet(events), using: rule)
        let times = paced.map(\.time)
        XCTAssertEqual(times, times.sorted())
        XCTAssertEqual(times, [0.0, 0.6, 1.2])
    }
}
