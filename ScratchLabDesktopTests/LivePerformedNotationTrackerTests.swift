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

    /// Deterministic CC6 stream built from signed run lengths. Positive =
    /// forward steps, negative = backward steps. Raw values wrap at 128 just
    /// like the real ring counter; run boundaries are therefore only the
    /// decoder's existing sign reversals, with no test-only gesture marker.
    private func platterEvents(
        signedRunSteps: [Int],
        interval: Double = 0.01
    ) -> [CaptureCore.RawMixerMIDIEvent] {
        var phase = 0
        var time = 0.0
        var events = [midiEvent(value: 0, takeRelativeTime: 0)]
        for signedSteps in signedRunSteps where signedSteps != 0 {
            let direction = signedSteps > 0 ? 1 : -1
            for _ in 0..<abs(signedSteps) {
                phase += direction
                time += interval
                let wrapped = ((phase % 128) + 128) % 128
                events.append(midiEvent(value: wrapped, takeRelativeTime: time))
            }
        }
        return events
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

    /// Three free-running revolutions are a large committed forward run once
    /// the platter reverses, but that accumulated motor phase must not become
    /// the next pull/push's lane baseline. Each run is locally rebased using
    /// the same reversal boundaries and noise gates that committed it.
    func testMultiRevolutionFreeSpinCannotShiftNextGestureBaseline() throws {
        let events = platterEvents(signedRunSteps: [300, -25, 40])
        let result = CaptureCore.derivePlatterMovementEventsWithProvisional(
            from: events,
            controller: 6,
            channel: 1,
            deviceName: "Test Device",
            notationStepsPerRevolution: 100
        )

        XCTAssertEqual(result.committedEvents.count, 2)
        let freeSpin = try XCTUnwrap(result.committedEvents.first)
        XCTAssertEqual(freeSpin.direction, "forward")
        XCTAssertEqual(freeSpin.startPosition, 0, accuracy: 1e-12)
        XCTAssertEqual(freeSpin.endPosition, 3, accuracy: 1e-12,
                       "multi-revolution travel stays real and unbounded")
        XCTAssertEqual(freeSpin.startTime, 0, accuracy: 1e-12)
        XCTAssertEqual(freeSpin.endTime, 3, accuracy: 1e-9)

        let pull = result.committedEvents[1]
        XCTAssertEqual(pull.direction, "backward")
        XCTAssertEqual(pull.startPosition, 0.25, accuracy: 1e-12)
        XCTAssertEqual(pull.endPosition, 0, accuracy: 1e-12,
                       "the pull returns to its own local baseline")
        XCTAssertEqual(pull.startTime, 3, accuracy: 1e-9)
        XCTAssertEqual(pull.endTime, 3.25, accuracy: 1e-9)

        let nextPush = try XCTUnwrap(result.provisionalMovement)
        XCTAssertEqual(nextPush.direction, "forward")
        XCTAssertEqual(nextPush.startPosition, 0, accuracy: 1e-12,
                       "the next gesture starts at baseline, not motor phase 300")
        XCTAssertEqual(nextPush.currentPosition, 0.4, accuracy: 1e-12)
        XCTAssertEqual(nextPush.displacement, 40, accuracy: 1e-12)
        XCTAssertEqual(nextPush.startTime, 3.25, accuracy: 1e-9)
        XCTAssertEqual(nextPush.currentTime, 3.65, accuracy: 1e-9)
    }

    /// A later, much larger opposite excursion changes the whole-stream raw
    /// min/max, which used to renormalize already-committed strokes. Gesture
    /// projection is per run, so every earlier event remains byte-identical.
    func testCommittedGestureCoordinatesNeverMoveWhenLaterRevolutionsExpandRange() {
        let full = platterEvents(signedRunSteps: [300, -25, 40, -500, 10])
        let prefixThroughThirdCommit = 1 + 300 + 25 + 40 + 1
        let early = CaptureCore.derivePlatterMovementEventsWithProvisional(
            from: Array(full.prefix(prefixThroughThirdCommit)),
            controller: 6,
            channel: 1,
            deviceName: "Test Device",
            notationStepsPerRevolution: 100
        )
        let later = CaptureCore.derivePlatterMovementEventsWithProvisional(
            from: full,
            controller: 6,
            channel: 1,
            deviceName: "Test Device",
            notationStepsPerRevolution: 100
        )

        XCTAssertEqual(early.committedEvents.count, 3)
        XCTAssertGreaterThan(later.committedEvents.count, early.committedEvents.count)
        XCTAssertEqual(
            Array(later.committedEvents.prefix(early.committedEvents.count)),
            early.committedEvents,
            "later motor phase/revolutions must never move committed notation"
        )
        XCTAssertEqual(early.committedEvents.map(\.direction), ["forward", "backward", "forward"])
        XCTAssertEqual(early.committedEvents[0].endPosition, 3, accuracy: 1e-12)
        XCTAssertEqual(early.committedEvents[1].startPosition, 0.25, accuracy: 1e-12)
        XCTAssertEqual(early.committedEvents[2].endPosition, 0.4, accuracy: 1e-12)
    }

    func testSamplePositionRemainsRawSignedUnwrappedFromHotCueOrigin() {
        let revolution = PlatterCoordinateSemantics.raneOneMKIIDirectMIDIStepsPerRevolution
        let origin = 1_250.0

        XCTAssertEqual(
            PlatterCoordinateSemantics.samplePosition(
                rawSignedPosition: origin + 4 * revolution + 225,
                hotCueOrigin: origin
            ),
            4 * revolution + 225,
            accuracy: 1e-12
        )
        XCTAssertEqual(
            PlatterCoordinateSemantics.samplePosition(
                rawSignedPosition: origin - 3 * revolution - 90,
                hotCueOrigin: origin
            ),
            -3 * revolution - 90,
            accuracy: 1e-12,
            "negative travel must not wrap to the end of the sample"
        )
    }

    func testSuppressedMotorAnchorWaitsForCommittedStrokeToLeaveViewport() {
        let committed = CaptureCore.DetectedNotationRecordMovementEvent(
            startTime: 0,
            endTime: 1,
            startPosition: 0,
            endPosition: 0.2,
            direction: "forward",
            movementKind: .normalPush,
            speed: 720,
            confidence: 0.9,
            source: "controller"
        )
        let openMotorPreview = CaptureCore.DetectedNotationRecordMovementEvent(
            startTime: 1,
            endTime: 2,
            startPosition: 0,
            endPosition: 0.5,
            direction: "forward",
            movementKind: .normalPush,
            speed: 1_800,
            confidence: 0.5,
            source: "live_preview"
        )

        XCTAssertFalse(
            CaptureCore.canAdvanceLiveNotationAnchorPastSuppressedMotorRotation(
                publishedEvents: [committed, openMotorPreview],
                latestTime: 2,
                viewportDuration: 3.2
            ),
            "catching the platter must not replace a still-visible committed stroke"
        )
        XCTAssertTrue(
            CaptureCore.canAdvanceLiveNotationAnchorPastSuppressedMotorRotation(
                publishedEvents: [committed, openMotorPreview],
                latestTime: 4.21,
                viewportDuration: 3.2
            ),
            "the anchor may advance once the committed stroke has scrolled out"
        )
        XCTAssertTrue(
            CaptureCore.canAdvanceLiveNotationAnchorPastSuppressedMotorRotation(
                publishedEvents: [openMotorPreview],
                latestTime: 2,
                viewportDuration: 3.2
            ),
            "an open motor preview is provisional and cannot freeze the anchor"
        )
    }

    func testSuppressedMotorAnchorRetainsCompleteReversalOnsetTail() throws {
        let forward = (0...70).map { index in
            midiEvent(
                value: index % 128,
                takeRelativeTime: Double(index) * 0.01
            )
        }
        let reversalStart = 0.701
        let backward = (0..<14).map { index in
            midiEvent(
                value: (69 - index + 128) % 128,
                takeRelativeTime: reversalStart + Double(index) * 0.001
            )
        }
        let events = forward + backward
        let latestTime = try XCTUnwrap(events.last?.takeRelativeTime)
        let anchor = try XCTUnwrap(
            CaptureCore.liveNotationAnchorIndexPreservingSuppressedMotorTail(
                in: events,
                currentAnchorIndex: 0,
                controller: 6,
                channel: 1,
                latestTime: latestTime,
                lookBehindDuration: 0.35
            )
        )
        let retained = Array(events.dropFirst(anchor))

        XCTAssertGreaterThan(anchor, 0, "old free-spin packets should be bounded")
        XCTAssertLessThan(events[anchor].takeRelativeTime, reversalStart)
        XCTAssertEqual(
            retained.filter { $0.takeRelativeTime >= reversalStart }.count,
            backward.count,
            "all early pull packets must survive until release suppression clears"
        )
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
