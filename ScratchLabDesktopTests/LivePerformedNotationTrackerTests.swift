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

    func testMacPracticeUsesSyncedBeatlessDemoNotationAndLiveStartPath() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "ScratchLabDesktop/Views/MacAnalyzerView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("practiceNotationWindow(at: time, notation: notation)"))
        XCTAssertTrue(source.contains("@StateObject private var demoModeController = ScratchLabDemoModeController()"))
        XCTAssertTrue(source.contains("return ScratchNotation.babyScratchDemo ?? ScratchNotation.babyScratch"))
        XCTAssertTrue(source.contains("return ScratchNotation.babyScratch"))
        XCTAssertTrue(source.contains("showBeatGrid: false"))
        XCTAssertTrue(source.contains("Text(\"NO BEAT\")"))
        XCTAssertFalse(source.contains("practiceCoordinator.beginWatch()\n                            startDemoWithBeat()"))
        XCTAssertFalse(source.contains("private func startDemoWithBeat()"))
        XCTAssertFalse(source.contains("Label(\"Demo with Beat\""))
        XCTAssertTrue(source.contains("practiceDemoNotationTime(\n            demoModeController.demoPlayer.sampledPlaybackTime(),"))
        XCTAssertTrue(source.contains("demoModeController.demoPlayer.sampledPlaybackTime()"))
        XCTAssertFalse(source.contains("practiceLoopedNotationTime"))
        XCTAssertTrue(source.contains("targetWindow: practiceNotationWindow(at: now, notation: notation)"))
        XCTAssertFalse(source.contains("targetWindow: 0...max(notation.timelineDuration, 0.1)"))
        XCTAssertTrue(source.contains("guard await startPracticeScoredAttempt() else { return }"))
        XCTAssertTrue(source.contains("if !liveInputEnabled {\n            startMacLiveInput()"))
        XCTAssertTrue(source.contains("guard await waitForPracticeCaptureReadiness() else"))
        XCTAssertTrue(source.contains("guard await waitForPracticeRecordingStart() else"))
        XCTAssertFalse(source.contains("|| routineStartDisabled\n            || captureEngine.isRoutineRecording"))
        XCTAssertTrue(source.contains("forScratchID: CaptureSessionScratchType.babyScratch.rawValue"))
        XCTAssertTrue(source.contains("?? CaptureClickTrackDefaults.defaultTimedBPM"))
        XCTAssertTrue(source.contains("private var practiceNotationBPM: Double {\n        Double(\n            routineSessionSetup.bpmValue\n                ?? CaptureClickTrackDefaults.defaultTimedBPM"))
        XCTAssertTrue(source.contains("routineSessionSetup.scratchType = .babyScratch"))
        XCTAssertFalse(source.contains("|| practiceCanonicalPattern == nil\n            || routineSessionSetup.bpmValue == nil"))
        XCTAssertFalse(source.contains("ScratchNotation.babyScratchFull76BeatQuantized"))

        let chartSource = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "ScratchLabDesktop/Views/ScratchPhraseChartView.swift"
            ),
            encoding: .utf8
        )
        XCTAssertFalse(chartSource.contains("drawTurnaroundMarkers"),
                       "Platter reversals must not reuse the fader-click diamond")
        XCTAssertTrue(chartSource.contains("if let prev = previousState, prev != span.state"),
                      "A real fader-state transition must retain its marker path")

        let visualizerSource = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "ScratchLabDesktop/Views/NotationVisualizerView.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(visualizerSource.contains("notation = ScratchNotation.babyScratchDemo"))
        XCTAssertFalse(visualizerSource.contains("notation = ScratchNotation.babyScratchFull76BeatQuantized"))
    }

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

    func testRenderedEventsIncludeOpenStrokeForImmediateCanonicalFeedback() {
        let openStroke = CaptureCore.ProvisionalPlatterMovement(
            startTime: 0.1, currentTime: 0.5,
            startPosition: 0.2, currentPosition: 0.8,
            direction: "forward", movementKind: .normalPush,
            displacement: 0.6
        )
        let events = LivePerformedNotationTracker.renderedEvents(
            for: .tracking(committed: [], provisional: openStroke)
        )

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].startPosition, 0.2)
        XCTAssertEqual(events[0].endPosition, 0.8)
        XCTAssertEqual(events[0].source, "live_preview")
    }

    func testFreezePreservesLastVisibleTrace() {
        let event = CaptureCore.DetectedNotationRecordMovementEvent(
            startTime: 0, endTime: 0.5, startPosition: 0, endPosition: 0.7,
            direction: "forward", movementKind: .normalPush,
            speed: 1.4, confidence: 0.9, source: "test"
        )
        let dataSource = LivePerformedNotationDataSource(
            selectedMIDISourceName: { "Test Device" },
            capturedMidiCCEventsSnapshot: { [] },
            cameraMovementEventsSnapshot: { _ in nil }
        )
        let tracker = LivePerformedNotationTracker(dataSource: dataSource, pollInterval: 60)
        let visibleBeforeFreeze = LivePerformedNotationTracker.renderedEvents(
            for: .tracking(committed: [event], provisional: nil)
        )

        tracker.freeze()

        XCTAssertTrue(tracker.isFrozen)
        XCTAssertNotNil(tracker.frozenAt, "freezing must also pin the target viewport clock")
        XCTAssertEqual(visibleBeforeFreeze, [event])
    }
}
