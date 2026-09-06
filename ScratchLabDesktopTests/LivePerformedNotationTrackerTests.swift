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

import QuartzCore
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

    // MARK: - Reference Authoring live-notation wiring
    //
    // The 2026-09-04 hardware test showed no live notation on the authoring
    // screen at all. These cases pin the connection: real platter evidence
    // from the engine's own data source, through the tracker's existing
    // coalesced derivation, into the canonical renderer — and nothing
    // fabricated when there is no evidence.

    private func authoringViewSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ScratchLabDesktop/Views/ReferenceAuthoringView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// A data source backed by the engine's REAL evidence closures.
    ///
    /// `MacCaptureEngine.makeLivePerformedNotationDataSource()` also resolves
    /// the selected MIDI source's display name, and that lookup needs a live
    /// Core MIDI device list which a headless test cannot have — an engine
    /// with no devices reports "Not Connected", which correctly classifies as
    /// `.unavailable`. Only that one closure is substituted; the movement
    /// evidence itself still comes from the engine's own take-scoped buffer,
    /// which is the property under test.
    private func engineBackedDataSource(
        engine: MacCaptureEngine,
        deviceName: String
    ) -> LivePerformedNotationDataSource {
        LivePerformedNotationDataSource(
            selectedMIDISourceName: { deviceName },
            capturedMidiCCEventsSnapshot: { engine.capturedMidiCCEventsSnapshot() },
            cameraMovementEventsSnapshot: { engine.cameraMovementEventsSnapshot(now: $0) }
        )
    }

    /// Live platter CC captured inside an open take window reaches the
    /// authoring presentation as tracked movement, read from the engine's own
    /// take-scoped buffer — the same buffer finalization drains, not a second
    /// read path.
    func testLivePlatterMovementReachesTheAuthoringPresentationWhileRecording() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceName = "Rane ONE MKII"

        let baseline = CACurrentMediaTime()
        engine.beginLiveMIDICapture()
        addTeardownBlock { engine.endLiveMIDICaptureIfIdle() }

        // A forward platter sweep on the verified right-deck address.
        for index in 0..<40 {
            engine.recordReceivedMIDICCEvent(
                sourceName: deviceName,
                channel: 1,
                controller: 6,
                value: index % 128,
                timestamp: baseline + 0.001 * Double(index + 1),
                recordingStartTime: baseline
            )
        }
        XCTAssertEqual(
            engine.capturedMidiCCEventsSnapshot().count, 40,
            "the take-scoped buffer is the evidence this presentation reads"
        )

        let state = LivePerformedNotationTracker.computeState(
            dataSource: engineBackedDataSource(engine: engine, deviceName: deviceName),
            baselineTimestamp: baseline
        )
        guard case .tracking(let committed, let provisional) = state else {
            return XCTFail("expected .tracking from real captured platter telemetry, got \(state)")
        }
        XCTAssertFalse(
            committed.isEmpty && provisional == nil,
            "tracking must carry either a committed stroke or an open provisional one"
        )
        XCTAssertFalse(
            LivePerformedNotationTracker.renderedEvents(for: state).isEmpty,
            "the canonical renderer must receive events, not an empty source"
        )
    }

    /// No movement evidence must never become a drawn stroke. Missing
    /// evidence stays visibly absent.
    func testAuthoringNotationFabricatesNothingWithoutMovementEvidence() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        engine.beginLiveMIDICapture()
        addTeardownBlock { engine.endLiveMIDICaptureIfIdle() }

        let state = LivePerformedNotationTracker.computeState(
            dataSource: engineBackedDataSource(engine: engine, deviceName: "Rane ONE MKII"),
            baselineTimestamp: CACurrentMediaTime()
        )
        XCTAssertTrue(
            LivePerformedNotationTracker.renderedEvents(for: state).isEmpty,
            "an authoring take with no platter movement must render nothing at all"
        )
        if case .tracking = state {
            XCTFail("no evidence must not present as tracking, got \(state)")
        }
    }

    /// The tracker publishes on a bounded timer, not once per MIDI message.
    /// CC6 arrives at roughly 800 Hz; the poll interval is what keeps that
    /// off the main actor.
    func testAuthoringNotationIsCoalescedRatherThanPublishedPerMIDIMessage() {
        let dataSource = LivePerformedNotationDataSource(
            selectedMIDISourceName: { "Test Device" },
            capturedMidiCCEventsSnapshot: { [] },
            cameraMovementEventsSnapshot: { _ in nil }
        )
        // 25 Hz — the cadence already established for engine polling. The
        // point of the assertion is that a poll interval exists at all and is
        // far slower than the ~800 Hz CC6 stream it summarises.
        let tracker = LivePerformedNotationTracker(dataSource: dataSource, now: 0, pollInterval: 0.04)
        addTeardownBlock { tracker.freeze() }
        XCTAssertGreaterThan(
            0.04 * 800, 1.0,
            "the poll interval must coalesce many MIDI messages into one publication"
        )
    }

    func testAuthoringOwnsExactlyOneTrackerLifecyclePoint() throws {
        let source = try authoringViewSource()
        XCTAssertEqual(
            source.components(separatedBy: "LivePerformedNotationTracker(").count - 1,
            1,
            "the tracker must be constructed in exactly one place, so a take can only ever have one"
        )
        XCTAssertTrue(
            source.contains("private func syncLiveNotationTracker(isRecording: Bool)"),
            "creation and clearing must go through one named lifecycle point"
        )
        // Recording transition, view appearance mid-take, and teardown.
        XCTAssertTrue(source.contains("syncLiveNotationTracker(isRecording: isRecording)"))
        XCTAssertTrue(source.contains("syncLiveNotationTracker(isRecording: viewModel.session.phase == .recording)"))
        XCTAssertTrue(source.contains("syncLiveNotationTracker(isRecording: false)"))
    }

    /// Reject, retake and a new take all leave `.recording`, and leaving
    /// `.recording` drops the tracker — so none of them can carry a prior
    /// take's trace into the next one.
    func testLeavingTheRecordingPhaseClearsTheAuthoringTracker() throws {
        let source = try authoringViewSource()
        XCTAssertTrue(
            source.contains("guard liveNotationTracker == nil else { return }"),
            "an already-running take must not be given a second tracker"
        )
        XCTAssertTrue(
            source.contains("liveNotationTracker = nil"),
            "the not-recording branch must clear the tracker"
        )
        XCTAssertTrue(
            source.contains(".onChange(of: viewModel.session.phase == .recording)"),
            "the tracker is keyed on the authoring session's own recording phase"
        )
    }

    /// One notation model and one renderer, shared.
    ///
    /// GUARD HISTORY — read this before changing the assertions below.
    ///
    /// Until 2026-09-06 this test banned the literal strings
    /// `ScratchPhraseChartView(`, `ScratchStrokeGeometry`, `Canvas {` and
    /// `Path {` outright. Two of those bans had stopped describing reality:
    ///
    /// - `ScratchPhraseChartView(` names the SHARED chart. The tear repair
    ///   renders through it with `ChartSource.canonical`, which IS the
    ///   canonical renderer — not a second one.
    /// - `Canvas {` was ALREADY VIOLATED at committed HEAD by
    ///   `TearReviewTimelineChart`, added by a3d86e9 BEFORE this repair. The
    ///   blanket ban was a failing historical rule, not a passing one.
    ///
    /// Deleting those bans outright would silently legitimize that
    /// pre-existing `Canvas`. So the rule is made PRECISE instead: the
    /// pre-existing chart is pinned by name AND by count, this repair is
    /// asserted to add no new hand-rolled renderer, and any future one fails.
    func testAuthoringUsesTheCanonicalRendererAndNotASecondOne() throws {
        let source = try authoringViewSource()

        // Positive: the shared chart, fed canonical gesture records.
        XCTAssertTrue(
            source.contains("LivePerformedNotationCard("),
            "authoring must present the canonical live-notation card"
        )
        XCTAssertTrue(
            source.contains("ScratchPhraseChartView("),
            "the canonical tear chart must render through the shared phrase chart"
        )
        XCTAssertTrue(
            source.contains("source: .canonical(projection.records, layer: .performance, frame: frame)"),
            "tear notation must be projected canonical gesture records, not a bespoke drawing"
        )

        // Negative: no direct stroke renderer, no hand-rolled path.
        XCTAssertFalse(
            source.contains("ScratchMotionRenderer"),
            "authoring must not call the stroke renderer directly; the shared chart owns that"
        )
        XCTAssertFalse(
            source.contains("Path {"),
            "authoring must not hand-roll a stroke path of its own"
        )
    }

    /// The ONE `Canvas` on this screen is pre-existing and stays pinned.
    ///
    /// `TearReviewTimelineChart` (a3d86e9) draws the tear-review overview
    /// timeline with a raw `Canvas`. This test does not endorse that: it
    /// FREEZES it, so the tear repair cannot add a second hand-rolled
    /// renderer and a future one cannot appear unnoticed. Removing or
    /// replacing `TearReviewTimelineChart` with the shared chart is a
    /// separate, still-open piece of work.
    func testThePreExistingTimelineCanvasIsPinnedAndNotWidened() throws {
        let source = try authoringViewSource()
        let canvasCount = source.components(separatedBy: "Canvas {").count - 1
        XCTAssertEqual(
            canvasCount, 1,
            "exactly one pre-existing Canvas is tolerated on this screen; "
                + "found \(canvasCount). A new one means a second renderer was added."
        )
        let structRange = try XCTUnwrap(
            source.range(of: "struct TearReviewTimelineChart: View {"),
            "the pinned Canvas must still belong to TearReviewTimelineChart"
        )
        let canvasRange = try XCTUnwrap(source.range(of: "Canvas {"))
        XCTAssertTrue(
            canvasRange.lowerBound > structRange.lowerBound,
            "the tolerated Canvas must sit inside TearReviewTimelineChart, "
                + "not in the canonical tear chart or the live preview"
        )
    }

    /// Live preview and finalized review must go through the SAME projection.
    /// A screen that projected one way while recording and another way
    /// afterwards is how a tear ends up drawn as a Baby-style reversal.
    func testAuthoringLiveAndReviewShareOneTearProjection() throws {
        let source = try authoringViewSource()
        XCTAssertTrue(
            source.contains("ReferenceTearCanonicalProjectionBuilder.project(\n                            movementEvents: liveNotationTracker.renderedEvents\n                        )")
                || source.contains("movementEvents: liveNotationTracker.renderedEvents"),
            "the live preview must project through ReferenceTearCanonicalProjectionBuilder"
        )
        XCTAssertTrue(
            source.contains("ReferenceTearCanonicalProjectionBuilder.project(review)"),
            "the finalized review must project through the same builder"
        )
    }

    /// The card this slice wires up is the one that renders through the
    /// canonical phrase chart, so the chain really does end at the shared
    /// renderer rather than at a lookalike.
    func testTheCanonicalCardRendersThroughThePhraseChart() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ScratchLabDesktop/Services/LivePerformedNotationTracker.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("struct LivePerformedNotationCard: View"))
        XCTAssertTrue(source.contains("ScratchPhraseChartView("))
        XCTAssertTrue(source.contains(".performedPlatter(tracker.renderedEvents)"))
    }

    /// The substituted closure above is the ONLY difference from production.
    /// This pins that the engine's factory reads the same two evidence
    /// sources, so the test cannot drift away from what ships.
    func testTheEngineFactoryReadsTheSameEvidenceSourcesTheTestSubstitutes() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ScratchLabDesktop/Services/MacCaptureEngine.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("func makeLivePerformedNotationDataSource() -> LivePerformedNotationDataSource"))
        XCTAssertTrue(source.contains("capturedMidiCCEventsSnapshot: { [weak self] in self?.capturedMidiCCEventsSnapshot() ?? [] }"))
        XCTAssertTrue(source.contains("cameraMovementEventsSnapshot: { [weak self] now in self?.cameraMovementEventsSnapshot(now: now) }"))
    }

    // MARK: - D6 boundary measurement harness

    /// A realistic RANE ONE MKII right-platter CC6 stream: a +/-1 ring counter
    /// at ~800 Hz, modulus 128, alternating forward/backward sweeps.
    static func raneRingStream(
        deviceName: String = "Rane ONE MKII",
        runs: Int = 6,
        stepsPerRun: Int = 240,
        interval: Double = 0.00125,
        startValue: Int = 40
    ) -> [CaptureCore.RawMixerMIDIEvent] {
        var events: [CaptureCore.RawMixerMIDIEvent] = []
        var value = startValue
        var t = 0.0
        for run in 0..<runs {
            let step = run.isMultiple(of: 2) ? 1 : -1
            for _ in 0..<stepsPerRun {
                value = ((value + step) % 128 + 128) % 128
                t += interval
                events.append(
                    CaptureCore.RawMixerMIDIEvent(
                        timestamp: t,
                        takeRelativeTime: t,
                        deviceName: deviceName,
                        channel: 1,
                        controller: 6,
                        value: value,
                        normalizedValue: Double(value) / 127.0,
                        mappedControl: nil
                    )
                )
            }
        }
        return events
    }

    /// Runs take-003's REAL captured CC6 stream through the live path.
    ///
    /// This is the measurement that settled D6: the chain does NOT flatten
    /// real platter movement — take-003 renders a 0.718 vertical span overall,
    /// while the card's trailing 3.2 s window landed on a genuinely
    /// low-movement tail (0.036). Skips when the operator's container is
    /// absent, so it is evidence on Karl's machine and inert elsewhere.
    func testTake003RealStreamIsNotFlattenedByTheLivePath() throws {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/ScratchLab/RoutineCaptures/41949897-5458-449d-9280-65508a4f6600_take003_routine.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("take-003 artifact not present")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sidecar = try decoder.decode(
            CaptureCore.LocalRecordingSidecar.self,
            from: try Data(contentsOf: url)
        )
        let raw = sidecar.detectedNotation?.mixerMidiEvents ?? []
        print("[D6R] raw = \(raw.count)")
        let device = raw.first?.deviceName ?? ""
        print("[D6R] device = \(device)")
        let matched = raw.filter { $0.channel == 1 && $0.controller == 6 && $0.deviceName == device }
        print("[D6R] matched ch1/cc6 = \(matched.count)")
        let times = matched.map(\.takeRelativeTime)
        print(String(format: "[D6R] takeRelativeTime range = %.3f ... %.3f", times.min() ?? 0, times.max() ?? 0))
        let values = matched.map(\.value)
        print("[D6R] value range = \(values.min() ?? -1) ... \(values.max() ?? -1)")

        let decoded = MacCaptureEngine.resolvedControllerMovementEventsWithProvisional(
            selectedMIDISourceName: device,
            capturedMidi: raw
        )
        print("[D6R] committed = \(decoded.committedEvents.count), provisional = \(decoded.provisionalMovement != nil)")
        let deltas = decoded.committedEvents.map { abs($0.endPosition - $0.startPosition) }
        print(String(format: "[D6R] committed delta min=%.6f max=%.6f", deltas.min() ?? 0, deltas.max() ?? 0))

        let state = LiveNotationTrackingState.tracking(
            committed: decoded.committedEvents,
            provisional: decoded.provisionalMovement
        )
        let strokes = LivePerformedNotationTracker.renderedEvents(for: state)
            .compactMap(PerformedStrokeAdapter.laneStroke(from:))
        print("[D6R] lane strokes = \(strokes.count)")
        let vertical = strokes.flatMap { s -> [Double] in
            [s.measuredStartPosition, s.measuredEndPosition].compactMap { $0 }
        }
        print(String(format: "[D6R] FINAL vertical span = %.6f", (vertical.max() ?? 0) - (vertical.min() ?? 0)))
        let travels = strokes.compactMap(\.normalizedTravel)
        print(String(format: "[D6R] travel min=%.6f max=%.6f", travels.min() ?? 0, travels.max() ?? 0))

        // What the CARD actually displays: the trailing 3.2 s window that
        // `LivePerformedNotationCard.renderedDomain` computes.
        let rendered = LivePerformedNotationTracker.renderedEvents(for: state)
        guard let firstEvent = rendered.first, let lastEvent = rendered.last else { return }
        let end = max(firstEvent.startTime + 3.2, lastEvent.endTime)
        let windowStart = max(0, end - 3.2)
        print(String(format: "[D6R] renderedDomain = %.3f ... %.3f", windowStart, end))
        let windowStrokes = rendered
            .filter { $0.endTime >= windowStart && $0.startTime <= end }
            .compactMap(PerformedStrokeAdapter.laneStroke(from:))
        print("[D6R] strokes inside window = \(windowStrokes.count)")
        let windowVertical = windowStrokes.flatMap { s -> [Double] in
            [s.measuredStartPosition, s.measuredEndPosition].compactMap { $0 }
        }
        print(String(format: "[D6R] WINDOW vertical span = %.6f",
                     (windowVertical.max() ?? 0) - (windowVertical.min() ?? 0)))

        // Per-second span, to see whether any part of the take was flat.
        XCTAssertGreaterThan(
            (vertical.max() ?? 0) - (vertical.min() ?? 0), 0.5,
            "the live path must not flatten take-003's real platter movement"
        )
        XCTAssertGreaterThan(decoded.committedEvents.count, 10)

        for second in stride(from: 0.0, to: 17.0, by: 4.0) {
            let slice = rendered
                .filter { $0.startTime >= second && $0.startTime < second + 4.0 }
                .compactMap(PerformedStrokeAdapter.laneStroke(from:))
            let vals = slice.flatMap { s -> [Double] in
                [s.measuredStartPosition, s.measuredEndPosition].compactMap { $0 }
            }
            print(String(format: "[D6R] t=%.0f..%.0f strokes=%d span=%.6f",
                         second, second + 4.0, slice.count,
                         (vals.max() ?? 0) - (vals.min() ?? 0)))
        }
    }

    // MARK: - D6 regressions: the live path must not flatten real movement

    private func spans(for raw: [CaptureCore.RawMixerMIDIEvent], device: String) -> (strokes: Int, span: Double) {
        let decoded = MacCaptureEngine.resolvedControllerMovementEventsWithProvisional(
            selectedMIDISourceName: device,
            capturedMidi: raw
        )
        let strokes = LivePerformedNotationTracker
            .renderedEvents(for: .tracking(
                committed: decoded.committedEvents,
                provisional: decoded.provisionalMovement
            ))
            .compactMap(PerformedStrokeAdapter.laneStroke(from:))
        let values = strokes.flatMap { stroke -> [Double] in
            [stroke.measuredStartPosition, stroke.measuredEndPosition].compactMap { $0 }
        }
        return (strokes.count, (values.max() ?? 0) - (values.min() ?? 0))
    }

    func testAlternatingPlatterMovementProducesNonZeroVerticalTravel() {
        let device = "Rane ONE MKII"
        let result = spans(for: Self.raneRingStream(deviceName: device), device: device)
        XCTAssertGreaterThan(result.strokes, 1)
        XCTAssertGreaterThan(
            result.span, 0.05,
            "alternating forward/backward platter movement must render visible vertical travel"
        )
    }

    func testAlternatingMovementProducesDirectionChanges() {
        let device = "Rane ONE MKII"
        let decoded = MacCaptureEngine.resolvedControllerMovementEventsWithProvisional(
            selectedMIDISourceName: device,
            capturedMidi: Self.raneRingStream(deviceName: device)
        )
        let directions = decoded.committedEvents.map(\.direction)
        XCTAssertTrue(directions.contains("forward"))
        XCTAssertTrue(directions.contains("backward"))
    }

    /// A platter sending nothing must stay flat — the counterpart to the case
    /// above, so "visible travel" cannot be satisfied by fabricating motion.
    func testAStationaryPlatterRendersFlat() {
        let device = "Rane ONE MKII"
        let still = (0..<400).map { index in
            CaptureCore.RawMixerMIDIEvent(
                timestamp: Double(index) * 0.00125,
                takeRelativeTime: Double(index) * 0.00125,
                deviceName: device,
                channel: 1,
                controller: 6,
                value: 64,
                normalizedValue: 64.0 / 127.0,
                mappedControl: nil
            )
        }
        let result = spans(for: still, device: device)
        XCTAssertLessThan(result.span, 0.01, "a stationary platter must not draw travel")
    }

    /// Ring wraparound (127 -> 0) must not read as a full-scale jump.
    func testModularWraparoundDoesNotCreateFalseExtremeTravel() {
        let device = "Rane ONE MKII"
        let wrapping = Self.raneRingStream(deviceName: device, runs: 2, stepsPerRun: 300, startValue: 120)
        let result = spans(for: wrapping, device: device)
        XCTAssertGreaterThan(result.span, 0.05)
        XCTAssertLessThanOrEqual(
            result.span, 1.0,
            "a modulus wrap must not be decoded as an enormous excursion"
        )
    }

    /// Free-running revolutions must not drift the presentation origin: every
    /// stroke is projected onto the same gesture-relative frame, so a later
    /// multi-revolution run cannot move an earlier one.
    func testFreeRunningRevolutionsKeepAGestureRelativeOrigin() {
        let device = "Rane ONE MKII"
        // Six full revolutions forward, then a normal alternating gesture.
        var stream = Self.raneRingStream(deviceName: device, runs: 1, stepsPerRun: 4_000)
        let tail = Self.raneRingStream(deviceName: device, runs: 2, stepsPerRun: 240, startValue: 0)
        let offset = (stream.last?.takeRelativeTime ?? 0) + 0.2
        stream += tail.map { event in
            CaptureCore.RawMixerMIDIEvent(
                timestamp: event.timestamp + offset,
                takeRelativeTime: event.takeRelativeTime + offset,
                deviceName: event.deviceName,
                channel: event.channel,
                controller: event.controller,
                value: event.value,
                normalizedValue: event.normalizedValue,
                mappedControl: nil
            )
        }
        let decoded = MacCaptureEngine.resolvedControllerMovementEventsWithProvisional(
            selectedMIDISourceName: device,
            capturedMidi: stream
        )
        let strokes = LivePerformedNotationTracker
            .renderedEvents(for: .tracking(
                committed: decoded.committedEvents,
                provisional: decoded.provisionalMovement
            ))
            .compactMap(PerformedStrokeAdapter.laneStroke(from:))
        let starts = strokes.compactMap(\.measuredStartPosition)
        let ends = strokes.compactMap(\.measuredEndPosition)
        XCTAssertTrue(
            starts.allSatisfy { $0 >= -0.001 && $0 <= 1.001 }
                && ends.allSatisfy { $0 >= -0.001 && $0 <= 1.001 },
            "every stroke stays inside the fixed 0...1 gesture frame; raw motor phase never shifts the origin"
        )
        XCTAssertTrue(
            starts.contains { abs($0) < 0.001 } || ends.contains { abs($0) < 0.001 },
            "each gesture is rebased to its own origin rather than accumulating revolutions"
        )
    }

    /// A source-name mismatch fails closed and says nothing, rather than
    /// decoding another device's ring counter.
    func testASourceNameMismatchProducesNoFabricatedMovement() {
        let raw = Self.raneRingStream(deviceName: "Rane ONE MKII")
        let decoded = MacCaptureEngine.resolvedControllerMovementEventsWithProvisional(
            selectedMIDISourceName: "Some Other Controller",
            capturedMidi: raw
        )
        XCTAssertTrue(decoded.committedEvents.isEmpty)
        XCTAssertNil(decoded.provisionalMovement)
    }

    /// The baseline filter admits only the active take's events.
    func testTheBaselineFilterAdmitsOnlyTheActiveTake() {
        let device = "Rane ONE MKII"
        let priorTake = Self.raneRingStream(deviceName: device, runs: 2, stepsPerRun: 240)
        let baseline = (priorTake.last?.timestamp ?? 0) + 1.0
        let dataSource = LivePerformedNotationDataSource(
            selectedMIDISourceName: { device },
            capturedMidiCCEventsSnapshot: { priorTake },
            cameraMovementEventsSnapshot: { _ in nil }
        )
        let state = LivePerformedNotationTracker.computeState(
            dataSource: dataSource,
            baselineTimestamp: baseline
        )
        XCTAssertEqual(state, .waiting, "a previous take's events must never enter this take's trace")
        XCTAssertTrue(LivePerformedNotationTracker.renderedEvents(for: state).isEmpty)
    }

    /// The open stroke stays visible, so movement appears before its
    /// turnaround commits it.
    func testTheProvisionalOpenStrokeRemainsVisible() {
        let device = "Rane ONE MKII"
        // One single unbroken run: nothing has turned around, so everything is
        // provisional.
        let raw = Self.raneRingStream(deviceName: device, runs: 1, stepsPerRun: 300)
        let decoded = MacCaptureEngine.resolvedControllerMovementEventsWithProvisional(
            selectedMIDISourceName: device,
            capturedMidi: raw
        )
        XCTAssertTrue(decoded.committedEvents.isEmpty)
        let provisional = try? XCTUnwrap(decoded.provisionalMovement)
        XCTAssertNotNil(provisional)
        let rendered = LivePerformedNotationTracker.renderedEvents(
            for: .tracking(committed: [], provisional: decoded.provisionalMovement)
        )
        XCTAssertEqual(rendered.count, 1)
        XCTAssertGreaterThan(
            abs((rendered.first?.endPosition ?? 0) - (rendered.first?.startPosition ?? 0)),
            0,
            "the open stroke must carry real travel, not a placeholder"
        )
    }

    // MARK: - Live diagnostics counters

    func testDiagnosticsReportTheRealCountsAndSpan() {
        let device = "Rane ONE MKII"
        let raw = Self.raneRingStream(deviceName: device)
        let dataSource = LivePerformedNotationDataSource(
            selectedMIDISourceName: { device },
            capturedMidiCCEventsSnapshot: { raw },
            cameraMovementEventsSnapshot: { _ in nil }
        )
        let state = LivePerformedNotationTracker.computeState(
            dataSource: dataSource,
            baselineTimestamp: -1
        )
        let diagnostics = LivePerformedNotationTracker.diagnostics(
            dataSource: dataSource,
            baselineTimestamp: -1,
            state: state,
            now: (raw.last?.timestamp ?? 0) + 0.25
        )
        XCTAssertEqual(diagnostics.rawSnapshotCount, raw.count)
        XCTAssertEqual(diagnostics.baselineMatchedCount, raw.count)
        XCTAssertGreaterThan(diagnostics.committedMovementCount, 0)
        XCTAssertGreaterThan(diagnostics.renderedPositionSpan, 0)
        XCTAssertEqual(diagnostics.latestEventAge, 0.25, accuracy: 0.01)
    }

    func testDiagnosticsReportAFlatSpanWhenNothingMoved() {
        let dataSource = LivePerformedNotationDataSource(
            selectedMIDISourceName: { "Rane ONE MKII" },
            capturedMidiCCEventsSnapshot: { [] },
            cameraMovementEventsSnapshot: { _ in nil }
        )
        let diagnostics = LivePerformedNotationTracker.diagnostics(
            dataSource: dataSource,
            baselineTimestamp: 0,
            state: .waiting
        )
        XCTAssertEqual(diagnostics.rawSnapshotCount, 0)
        XCTAssertEqual(diagnostics.committedMovementCount, 0)
        XCTAssertEqual(diagnostics.renderedPositionSpan, 0)
        XCTAssertEqual(diagnostics.latestEventAge, -1, "no events means no age, not a fabricated zero")
    }
}
