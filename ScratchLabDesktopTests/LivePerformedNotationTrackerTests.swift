// LivePerformedNotationTrackerTests.swift
// ScratchLabDesktopTests
//
// Covers two things the plan called out explicitly:
//  1. `CaptureCore.derivePlatterMovementEventsWithProvisional`'s exact
//     committed/provisional transition at a turnaround — proving the
//     provisional stroke is never a relabeled finalized event, and that
//     committed strokes are never mutated retroactively.
//  2. `LivePerformedNotationTracker.computeState` — a pure function, tested
//     directly with an injected `LivePerformedNotationDataSource` rather
//     than a timer/real MacCaptureEngine — covering unavailable/waiting/
//     tracking classification, controller-vs-camera precedence (mirroring
//     `completeRoutineFinalization`), and baseline-timestamp isolation
//     (proving events from before a tracker's construction can never leak
//     into its output — the safety property that replaced a retained array
//     index).

import XCTest
@testable import ScratchLab

final class LivePerformedNotationTrackerTests: XCTestCase {

    // MARK: - Helpers

    private func midiEvent(
        value: Int,
        takeRelativeTime: Double,
        timestamp: Double? = nil,
        deviceName: String = "Test Device"
    ) -> CaptureCore.RawMixerMIDIEvent {
        CaptureCore.RawMixerMIDIEvent(
            timestamp: timestamp ?? takeRelativeTime,
            takeRelativeTime: takeRelativeTime,
            deviceName: deviceName,
            channel: 1,
            controller: 6,
            value: value,
            normalizedValue: Double(value) / 127.0,
            mappedControl: nil
        )
    }

    /// A push (values climbing by 10 every 0.02s) long enough to clear both
    /// noise gates (`minRunDuration` 0.08s, `minRunSteps` 8) once closed.
    private func pushEvents(count: Int = 10, deviceName: String = "Test Device") -> [CaptureCore.RawMixerMIDIEvent] {
        (0..<count).map { i in
            midiEvent(value: i * 10, takeRelativeTime: Double(i) * 0.02, deviceName: deviceName)
        }
    }

    // MARK: - Provisional-stroke transition (CaptureCore.derivePlatterMovementEventsWithProvisional)

    /// The exact transition the plan requires: an open push has no committed
    /// events, only a provisional one; the sample that reverses direction
    /// commits the push exactly once and opens a new provisional for the
    /// pull-back; further growth of the pull-back does not add a second
    /// committed event or alter the first.
    func testProvisionalStrokeCommitsExactlyOnceAtTurnaround() {
        let push = pushEvents()

        let midPush = Array(push.prefix(5))
        let midPushResult = CaptureCore.derivePlatterMovementEventsWithProvisional(
            from: midPush, controller: 6, channel: 1, deviceName: "Test Device")
        XCTAssertTrue(midPushResult.committedEvents.isEmpty, "no turnaround yet — nothing should be committed")
        XCTAssertNotNil(midPushResult.provisionalMovement, "the open push must be visible as provisional")
        XCTAssertEqual(midPushResult.provisionalMovement?.direction, "forward")

        let turnaroundTime = Double(push.count) * 0.02
        let afterTurnaround = push + [midiEvent(value: 80, takeRelativeTime: turnaroundTime)]
        let afterTurnaroundResult = CaptureCore.derivePlatterMovementEventsWithProvisional(
            from: afterTurnaround, controller: 6, channel: 1, deviceName: "Test Device")
        XCTAssertEqual(afterTurnaroundResult.committedEvents.count, 1, "the push must commit exactly once at the turnaround")
        XCTAssertEqual(afterTurnaroundResult.committedEvents.first?.direction, "forward")
        XCTAssertNotNil(afterTurnaroundResult.provisionalMovement, "a new provisional stroke must open for the pull-back")
        XCTAssertEqual(afterTurnaroundResult.provisionalMovement?.direction, "backward")

        let morePull = afterTurnaround + [
            midiEvent(value: 70, takeRelativeTime: turnaroundTime + 0.02),
            midiEvent(value: 60, takeRelativeTime: turnaroundTime + 0.04),
        ]
        let morePullResult = CaptureCore.derivePlatterMovementEventsWithProvisional(
            from: morePull, controller: 6, channel: 1, deviceName: "Test Device")
        XCTAssertEqual(morePullResult.committedEvents.count, 1, "committed count must not change before the next turnaround")
        XCTAssertEqual(morePullResult.committedEvents, afterTurnaroundResult.committedEvents, "committed events must never mutate retroactively")
        XCTAssertNotNil(morePullResult.provisionalMovement)
        XCTAssertEqual(morePullResult.provisionalMovement?.direction, "backward")
    }

    /// Across a monotonically growing event prefix spanning two turnarounds,
    /// `committedEvents` must only ever grow, and every previously committed
    /// event must remain byte-identical once a later poll re-derives it.
    func testCommittedEventsOnlyGrowAndNeverChangeAcrossGrowingInput() {
        let push = pushEvents()                                          // forward
        let turn1 = midiEvent(value: 80, takeRelativeTime: 0.20)          // starts pull-back
        let pull = (1...5).map { i in midiEvent(value: 80 - i * 10, takeRelativeTime: 0.20 + Double(i) * 0.02) }
        let turn2 = midiEvent(value: 40, takeRelativeTime: 0.34)          // starts a second forward run

        let full = push + [turn1] + pull + [turn2]
        var previousCommitted: [CaptureCore.DetectedNotationRecordMovementEvent] = []
        for prefixLength in 2...full.count {
            let prefix = Array(full.prefix(prefixLength))
            let result = CaptureCore.derivePlatterMovementEventsWithProvisional(
                from: prefix, controller: 6, channel: 1, deviceName: "Test Device")
            XCTAssertGreaterThanOrEqual(result.committedEvents.count, previousCommitted.count, "committed count must never shrink")
            XCTAssertEqual(
                Array(result.committedEvents.prefix(previousCommitted.count)), previousCommitted,
                "previously committed events must never change as more data arrives")
            previousCommitted = result.committedEvents
        }
        XCTAssertEqual(previousCommitted.count, 2, "both turnarounds should have committed a stroke by the end")
    }

    // MARK: - computeState

    func testUnavailableWhenNoControllerOrCameraSource() {
        let dataSource = LivePerformedNotationDataSource(
            selectedMIDISourceName: { "Not Connected" },
            capturedMidiCCEventsSnapshot: { [] },
            cameraMovementEventsSnapshot: { _ in nil }
        )
        let state = LivePerformedNotationTracker.computeState(dataSource: dataSource, baselineTimestamp: 0)
        XCTAssertEqual(state, .unavailable)
    }

    func testWaitingWhenControllerSourceConnectedButNoEventsYet() {
        let dataSource = LivePerformedNotationDataSource(
            selectedMIDISourceName: { "Test Device" },
            capturedMidiCCEventsSnapshot: { [] },
            cameraMovementEventsSnapshot: { _ in nil }
        )
        let state = LivePerformedNotationTracker.computeState(dataSource: dataSource, baselineTimestamp: 0)
        XCTAssertEqual(state, .waiting)
    }

    func testWaitingWhenCameraSourceActiveButHasProducedNoMovementYet() {
        let dataSource = LivePerformedNotationDataSource(
            selectedMIDISourceName: { "Not Connected" },
            capturedMidiCCEventsSnapshot: { [] },
            cameraMovementEventsSnapshot: { _ in [] }
        )
        let state = LivePerformedNotationTracker.computeState(dataSource: dataSource, baselineTimestamp: 0)
        XCTAssertEqual(state, .waiting, "an active camera builder with zero events yet is waiting, not unavailable")
    }

    /// The safety property that replaced a retained array index: events
    /// whose timestamp predates the tracker's baseline must never appear in
    /// its output, however many of them there are.
    func testBaselineTimestampExcludesEventsFromBeforeAttemptStart() {
        let priorEvents = pushEvents(count: 10)  // timestamps 0.00...0.18, well before the baseline below
        let dataSource = LivePerformedNotationDataSource(
            selectedMIDISourceName: { "Test Device" },
            capturedMidiCCEventsSnapshot: { priorEvents },
            cameraMovementEventsSnapshot: { _ in nil }
        )
        let state = LivePerformedNotationTracker.computeState(dataSource: dataSource, baselineTimestamp: 1000)
        XCTAssertEqual(state, .waiting, "events entirely before the attempt baseline must never leak into tracking state")
    }

    func testTrackingWhenControllerProducesMovement() {
        let events = pushEvents()
        let dataSource = LivePerformedNotationDataSource(
            selectedMIDISourceName: { "Test Device" },
            capturedMidiCCEventsSnapshot: { events },
            cameraMovementEventsSnapshot: { _ in nil }
        )
        let state = LivePerformedNotationTracker.computeState(dataSource: dataSource, baselineTimestamp: -1)
        guard case .tracking = state else {
            return XCTFail("expected .tracking, got \(state)")
        }
    }

    /// Camera fallback is used only when the controller path produced
    /// nothing — mirrors `completeRoutineFinalization`'s own precedence.
    func testCameraFallbackUsedOnlyWhenControllerProducesNothing() {
        let cameraEvents = [CaptureCore.DetectedNotationRecordMovementEvent(
            startTime: 0, endTime: 1, startPosition: 0, endPosition: 1,
            direction: "forward", movementKind: .normalPush, speed: 1, confidence: 0.9, source: "camera"
        )]
        let dataSource = LivePerformedNotationDataSource(
            selectedMIDISourceName: { "Not Connected" },
            capturedMidiCCEventsSnapshot: { [] },
            cameraMovementEventsSnapshot: { _ in cameraEvents }
        )
        let state = LivePerformedNotationTracker.computeState(dataSource: dataSource, baselineTimestamp: 0)
        guard case .tracking(let committed, let provisional) = state else {
            return XCTFail("expected .tracking via camera fallback, got \(state)")
        }
        XCTAssertEqual(committed, cameraEvents)
        XCTAssertNil(provisional, "camera-sourced events never carry a controller-style provisional stroke")
    }
}
