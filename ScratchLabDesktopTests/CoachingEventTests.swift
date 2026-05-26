import XCTest
@testable import ScratchLab

/// Section 4 / Slice 2 — locks the contract of the coaching-event
/// sidecar (`CoachingEvent`, `CoachingEventSet`). Pure metadata; no
/// primitive, timing, family, or ML coupling.
final class CoachingEventTests: XCTestCase {

    // MARK: - Helpers

    private func makeEvent(
        time: TimeInterval,
        kind: CoachingEventKind = .lateReversal,
        severity: CoachingEventSeverity = .notice,
        message: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> CoachingEvent {
        guard let event = CoachingEvent(time: time, kind: kind, severity: severity, message: message) else {
            XCTFail("CoachingEvent(time: \(time)) unexpectedly rejected", file: file, line: line)
            return CoachingEvent(time: 0, kind: kind, severity: severity, message: message)!
        }
        return event
    }

    // MARK: - 1. CoachingEvent rejects negative, NaN, infinity time

    func testCoachingEventRejectsInvalidTimes() {
        XCTAssertNil(CoachingEvent(time: -0.001, kind: .lateReversal, severity: .notice, message: nil))
        XCTAssertNil(CoachingEvent(time: -1.0, kind: .lateReversal, severity: .notice, message: nil))
        XCTAssertNil(CoachingEvent(time: .nan, kind: .lateReversal, severity: .notice, message: nil))
        XCTAssertNil(CoachingEvent(time: .infinity, kind: .lateReversal, severity: .notice, message: nil))
        XCTAssertNil(CoachingEvent(time: -.infinity, kind: .lateReversal, severity: .notice, message: nil))
    }

    // MARK: - 2. CoachingEvent accepts zero time

    func testCoachingEventAcceptsZeroTime() {
        let event = CoachingEvent(time: 0, kind: .noSignal, severity: .info, message: nil)
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.time, 0)
    }

    // MARK: - 3. CoachingEvent accepts positive time

    func testCoachingEventAcceptsPositiveTime() {
        let event = CoachingEvent(time: 2.5, kind: .earlyReversal, severity: .notice, message: nil)
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.time, 2.5)
    }

    // MARK: - 4. CoachingEvent preserves kind and severity

    func testCoachingEventPreservesKindAndSeverity() {
        let event = makeEvent(time: 1.0, kind: .unstableTiming, severity: .warning)
        XCTAssertEqual(event.kind, .unstableTiming)
        XCTAssertEqual(event.severity, .warning)
    }

    // MARK: - 5. CoachingEvent preserves nil message

    func testCoachingEventPreservesNilMessage() {
        let event = makeEvent(time: 1.0, message: nil)
        XCTAssertNil(event.message)
    }

    // MARK: - 6. CoachingEvent preserves empty message

    func testCoachingEventPreservesEmptyMessage() {
        let event = makeEvent(time: 1.0, message: "")
        XCTAssertEqual(event.message, "")
    }

    // MARK: - 7. CoachingEventSet accepts empty events

    func testCoachingEventSetAcceptsEmptyEvents() {
        let set = CoachingEventSet(events: [])
        XCTAssertNotNil(set)
        XCTAssertEqual(set?.events.count, 0)
    }

    // MARK: - 8. CoachingEventSet accepts sorted events

    func testCoachingEventSetAcceptsSortedEvents() {
        let events = [
            makeEvent(time: 0.0, kind: .noSignal, severity: .info),
            makeEvent(time: 1.5, kind: .earlyReversal),
            makeEvent(time: 2.5, kind: .lateReversal),
        ]
        let set = CoachingEventSet(events: events)
        XCTAssertNotNil(set)
        XCTAssertEqual(set?.events, events)
    }

    // MARK: - 9. CoachingEventSet rejects unsorted events

    func testCoachingEventSetRejectsUnsortedEvents() {
        let events = [
            makeEvent(time: 2.5),
            makeEvent(time: 1.0),
        ]
        XCTAssertNil(CoachingEventSet(events: events))
    }

    // MARK: - 10. CoachingEventSet allows duplicate times

    func testCoachingEventSetAllowsDuplicateTimes() {
        let events = [
            makeEvent(time: 1.0, kind: .lateReversal),
            makeEvent(time: 1.0, kind: .earlyReversal),
            makeEvent(time: 1.0, kind: .unstableTiming, severity: .warning),
        ]
        let set = CoachingEventSet(events: events)
        XCTAssertNotNil(set)
        XCTAssertEqual(set?.events.count, 3)
    }

    // MARK: - 11. events(of:) filters by kind and preserves order

    func testEventsOfKindFiltersAndPreservesOrder() {
        let events = [
            makeEvent(time: 0.5, kind: .lateReversal),
            makeEvent(time: 1.0, kind: .earlyReversal),
            makeEvent(time: 1.5, kind: .lateReversal),
            makeEvent(time: 2.0, kind: .noSignal, severity: .info),
            makeEvent(time: 2.5, kind: .lateReversal),
        ]
        let set = CoachingEventSet(events: events)!
        let late = set.events(of: .lateReversal)
        XCTAssertEqual(late.map(\.time), [0.5, 1.5, 2.5])
        XCTAssertEqual(set.events(of: .clippedMotion), [])
    }

    // MARK: - 12. events(atOrAfter:) includes equality and preserves order

    func testEventsAtOrAfterIncludesEqualityAndPreservesOrder() {
        let events = [
            makeEvent(time: 0.0),
            makeEvent(time: 1.0),
            makeEvent(time: 2.0),
            makeEvent(time: 3.0),
        ]
        let set = CoachingEventSet(events: events)!
        XCTAssertEqual(set.events(atOrAfter: 1.0).map(\.time), [1.0, 2.0, 3.0])
        XCTAssertEqual(set.events(atOrAfter: 1.5).map(\.time), [2.0, 3.0])
        XCTAssertEqual(set.events(atOrAfter: 0.0).map(\.time), [0.0, 1.0, 2.0, 3.0])
        XCTAssertEqual(set.events(atOrAfter: 4.0), [])
    }

    // MARK: - 13. CoachingEvent Codable round-trip

    func testCoachingEventCodableRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        let cases: [CoachingEvent] = [
            makeEvent(time: 0.0, kind: .noSignal, severity: .info, message: nil),
            makeEvent(time: 1.25, kind: .lateReversal, severity: .notice, message: ""),
            makeEvent(time: 99.5, kind: .clippedMotion, severity: .warning, message: "slipped"),
        ]
        for event in cases {
            let data = try encoder.encode(event)
            let decoded = try decoder.decode(CoachingEvent.self, from: data)
            XCTAssertEqual(decoded, event)
            let second = try encoder.encode(decoded)
            XCTAssertEqual(second, data)
        }
    }

    // MARK: - 14. CoachingEventSet Codable round-trip

    func testCoachingEventSetCodableRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        let events = [
            makeEvent(time: 0.0, kind: .noSignal, severity: .info),
            makeEvent(time: 1.0, kind: .lateReversal),
            makeEvent(time: 1.0, kind: .earlyReversal),
            makeEvent(time: 2.0, kind: .unstableTiming, severity: .warning, message: "drift"),
        ]
        let set = CoachingEventSet(events: events)!
        let data = try encoder.encode(set)
        let decoded = try decoder.decode(CoachingEventSet.self, from: data)
        XCTAssertEqual(decoded, set)
        let second = try encoder.encode(decoded)
        XCTAssertEqual(second, data)

        let emptySet = CoachingEventSet(events: [])!
        let emptyData = try encoder.encode(emptySet)
        let decodedEmpty = try decoder.decode(CoachingEventSet.self, from: emptyData)
        XCTAssertEqual(decodedEmpty, emptySet)
    }

    // MARK: - 15. Codable rejects invalid event time

    func testCodableRejectsInvalidEventTime() {
        let decoder = JSONDecoder()
        let negative = """
        {"time": -0.001, "kind": "lateReversal", "severity": "notice"}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(CoachingEvent.self, from: negative))

        // JSON has no NaN/Infinity literal — use the standard Codable
        // failure path via .deferredToData encoder strategy. Here we
        // assert the raw payload form is rejected.
        let nonFinite = """
        {"time": 1e1000, "kind": "lateReversal", "severity": "notice"}
        """.data(using: .utf8)!
        // JSONDecoder default rejects non-finite floats outright with a
        // dataCorrupted error, which is the behaviour we want.
        XCTAssertThrowsError(try decoder.decode(CoachingEvent.self, from: nonFinite))
    }

    // MARK: - 16. Codable rejects unsorted event set

    func testCodableRejectsUnsortedEventSet() {
        let decoder = JSONDecoder()
        let unsorted = """
        {
          "events": [
            {"time": 2.0, "kind": "lateReversal", "severity": "notice"},
            {"time": 1.0, "kind": "earlyReversal", "severity": "notice"}
          ]
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(CoachingEventSet.self, from: unsorted))
    }

    // MARK: - 17. Deterministic repeated lookups

    func testDeterministicRepeatedLookups() {
        let events = [
            makeEvent(time: 0.5, kind: .lateReversal),
            makeEvent(time: 1.0, kind: .earlyReversal),
            makeEvent(time: 1.5, kind: .lateReversal),
        ]
        let set = CoachingEventSet(events: events)!
        XCTAssertEqual(set.events(of: .lateReversal), set.events(of: .lateReversal))
        XCTAssertEqual(set.events(atOrAfter: 1.0), set.events(atOrAfter: 1.0))
        XCTAssertEqual(set, set)
    }

    // MARK: - 18. No primitive/timing/family/ML access required

    /// The sidecar must build a representative CoachingEvent and
    /// CoachingEventSet using only `TimeInterval`,
    /// `CoachingEventKind`, `CoachingEventSeverity`, and `String?`.
    /// If any symbol from notation primitives, timing grid, scratch
    /// family, or ML/classifier vocabulary is reached for here, this
    /// test deliberately does *not* mention it — the compile remains
    /// the proof that the surface is reachable without those imports.
    func testCoachingEventBuildableWithoutPrimitiveTimingFamilyOrMLImports() {
        let event = CoachingEvent(
            time: 0.0,
            kind: .noSignal,
            severity: .info,
            message: nil
        )
        XCTAssertNotNil(event)
        let set = CoachingEventSet(events: [event!])
        XCTAssertNotNil(set)
    }
}
