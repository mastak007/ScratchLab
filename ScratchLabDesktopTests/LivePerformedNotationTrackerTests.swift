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

import Combine
import CoreMIDI
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
        guard case .tracking(let committed, let provisional, _, _, _, _) = state else {
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
            for: .tracking(committed: [], provisional: openStroke, continuousCommitted: [], continuousProvisional: nil, platterEvidenceIntervals: [], faderDerivation: nil)
        )

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].startPosition, 0.2)
        XCTAssertEqual(events[0].endPosition, 0.8)
        XCTAssertEqual(events[0].source, "live_preview")
    }

    /// Regression: exposing continuous positions for the Tear projection must
    /// not alter the ordinary `.performedPlatter` feed. `renderedEvents` stays
    /// gesture-relative (each run rebased to its own origin), while the new
    /// `continuousRenderedEvents` carries the global span-normalised track.
    func testContinuousExposureLeavesGestureRelativePerformedPlatterUnchanged() {
        let committed = [
            CaptureCore.DetectedNotationRecordMovementEvent(
                startTime: 0, endTime: 0.5, startPosition: 0, endPosition: 0.7,
                direction: "forward", movementKind: .normalPush,
                speed: 1.4, confidence: 0.9, source: "controller"
            )
        ]
        let continuous = [
            CaptureCore.DetectedNotationRecordMovementEvent(
                startTime: 0, endTime: 0.5, startPosition: 0.3, endPosition: 1.0,
                direction: "forward", movementKind: .normalPush,
                speed: 1.4, confidence: 0.9, source: "controller"
            )
        ]
        let state = LiveNotationTrackingState.tracking(
            committed: committed,
            provisional: nil,
            continuousCommitted: continuous,
            continuousProvisional: nil,
            platterEvidenceIntervals: [],
            faderDerivation: nil
        )
        XCTAssertEqual(
            LivePerformedNotationTracker.renderedEvents(for: state), committed,
            "the gesture-relative feed used by .performedPlatter must not change"
        )
        // The continuous feed is now re-normalised over a rolling window, so
        // exact pass-through positions are no longer guaranteed; the stroke
        // itself must still be present and carry its measured direction.
        XCTAssertEqual(
            LivePerformedNotationTracker.continuousRenderedEvents(for: state).map(\.direction),
            ["forward"],
            "the continuous feed must still carry the stroke"
        )
    }

    // MARK: - Free-rotation / rolling-window regression (hardware acceptance)

    /// Several off-screen forward revolutions must not pin a subsequent Tear
    /// against the top of the lane. The old free-spin history is dropped from
    /// the rolling window and the current Tear is re-normalised to a healthy
    /// vertical range while keeping one shared reversal apex.
    func testFreeRotationDoesNotPinSubsequentTearAtTheCeiling() {
        let freeSpin = CaptureCore.DetectedNotationRecordMovementEvent(
            startTime: 0, endTime: 3.0, startPosition: 0.0, endPosition: 1.0,
            direction: "forward", movementKind: .normalPush,
            speed: 0.4, confidence: 0.9, source: "controller"
        )
        let tearForward = CaptureCore.DetectedNotationRecordMovementEvent(
            startTime: 6.0, endTime: 6.5, startPosition: 0.98, endPosition: 0.99,
            direction: "forward", movementKind: .normalPush,
            speed: 0.02, confidence: 0.9, source: "controller"
        )
        let tearReverse = CaptureCore.DetectedNotationRecordMovementEvent(
            startTime: 6.5, endTime: 7.0, startPosition: 0.99, endPosition: 0.98,
            direction: "backward", movementKind: .normalPull,
            speed: 0.02, confidence: 0.9, source: "controller"
        )
        let state = LiveNotationTrackingState.tracking(
            committed: [], provisional: nil,
            continuousCommitted: [freeSpin, tearForward, tearReverse],
            continuousProvisional: nil,
            platterEvidenceIntervals: [],
            faderDerivation: nil
        )

        let rendered = LivePerformedNotationTracker.continuousRenderedEvents(for: state)

        XCTAssertEqual(rendered.count, 2, "the off-screen free spin must be dropped from the live window")
        let positions = rendered.flatMap { [$0.startPosition, $0.endPosition] }
        XCTAssertGreaterThan(
            (positions.max() ?? 0) - (positions.min() ?? 0), 0.5,
            "the post-spin Tear must span a healthy range, not a tiny band at the ceiling"
        )
        XCTAssertEqual(
            rendered[0].endPosition, rendered[1].startPosition, accuracy: 1e-9,
            "forward/reverse must still share one reversal apex"
        )
    }

    /// Adding old off-screen free-spin history must not materially flatten an
    /// otherwise identical current Tear fixture (history independence).
    func testOldFreeSpinHistoryDoesNotFlattenTheCurrentTear() {
        let freeSpin = CaptureCore.DetectedNotationRecordMovementEvent(
            startTime: 0, endTime: 3.0, startPosition: 0.0, endPosition: 1.0,
            direction: "forward", movementKind: .normalPush,
            speed: 0.4, confidence: 0.9, source: "controller"
        )
        let tearForward = CaptureCore.DetectedNotationRecordMovementEvent(
            startTime: 6.0, endTime: 6.5, startPosition: 0.98, endPosition: 0.99,
            direction: "forward", movementKind: .normalPush,
            speed: 0.02, confidence: 0.9, source: "controller"
        )
        let tearReverse = CaptureCore.DetectedNotationRecordMovementEvent(
            startTime: 6.5, endTime: 7.0, startPosition: 0.99, endPosition: 0.98,
            direction: "backward", movementKind: .normalPull,
            speed: 0.02, confidence: 0.9, source: "controller"
        )
        let withSpin = LiveNotationTrackingState.tracking(
            committed: [], provisional: nil,
            continuousCommitted: [freeSpin, tearForward, tearReverse],
            continuousProvisional: nil,
            platterEvidenceIntervals: [],
            faderDerivation: nil
        )
        let withoutSpin = LiveNotationTrackingState.tracking(
            committed: [], provisional: nil,
            continuousCommitted: [tearForward, tearReverse],
            continuousProvisional: nil,
            platterEvidenceIntervals: [],
            faderDerivation: nil
        )

        let a = LivePerformedNotationTracker.continuousRenderedEvents(for: withSpin)
        let b = LivePerformedNotationTracker.continuousRenderedEvents(for: withoutSpin)

        XCTAssertEqual(a.count, b.count, "history must not change the number of live strokes")
        for (x, y) in zip(a, b) {
            XCTAssertEqual(x.startPosition, y.startPosition, accuracy: 1e-9)
            XCTAssertEqual(x.endPosition, y.endPosition, accuracy: 1e-9)
            XCTAssertEqual(x.direction, y.direction)
        }
    }

    /// After free rotation, a Clover (forward ascent → apex → reverse descent)
    /// keeps a readable continuous topology rather than collapsing to a band.
    func testCloverAfterFreeRotationKeepsReadableTopology() {
        let freeSpin = CaptureCore.DetectedNotationRecordMovementEvent(
            startTime: 0, endTime: 3.0, startPosition: 0.0, endPosition: 1.0,
            direction: "forward", movementKind: .normalPush,
            speed: 0.4, confidence: 0.9, source: "controller"
        )
        let ascent1 = CaptureCore.DetectedNotationRecordMovementEvent(
            startTime: 6.0, endTime: 6.4, startPosition: 0.90, endPosition: 0.93,
            direction: "forward", movementKind: .normalPush,
            speed: 0.05, confidence: 0.9, source: "controller"
        )
        let ascent2 = CaptureCore.DetectedNotationRecordMovementEvent(
            startTime: 6.5, endTime: 6.9, startPosition: 0.93, endPosition: 0.96,
            direction: "forward", movementKind: .normalPush,
            speed: 0.05, confidence: 0.9, source: "controller"
        )
        let descent1 = CaptureCore.DetectedNotationRecordMovementEvent(
            startTime: 7.0, endTime: 7.4, startPosition: 0.96, endPosition: 0.93,
            direction: "backward", movementKind: .normalPull,
            speed: 0.05, confidence: 0.9, source: "controller"
        )
        let descent2 = CaptureCore.DetectedNotationRecordMovementEvent(
            startTime: 7.5, endTime: 7.9, startPosition: 0.93, endPosition: 0.90,
            direction: "backward", movementKind: .normalPull,
            speed: 0.05, confidence: 0.9, source: "controller"
        )
        let state = LiveNotationTrackingState.tracking(
            committed: [], provisional: nil,
            continuousCommitted: [freeSpin, ascent1, ascent2, descent1, descent2],
            continuousProvisional: nil,
            platterEvidenceIntervals: [],
            faderDerivation: nil
        )

        let rendered = LivePerformedNotationTracker.continuousRenderedEvents(for: state)

        XCTAssertEqual(rendered.count, 4, "the free spin must be dropped; the clover's four strokes remain")
        XCTAssertEqual(
            rendered[1].endPosition, rendered[2].startPosition, accuracy: 1e-9,
            "the ascent apex must feed the descent without a discontinuity"
        )
        XCTAssertEqual(rendered.map(\.direction), ["forward", "forward", "backward", "backward"])
    }

    /// An open provisional Tear stroke after free rotation stays visible and
    /// shares the same windowed basis as the committed stroke around it.
    func testProvisionalTearSharesTheWindowedBasisAfterFreeSpin() {
        let freeSpin = CaptureCore.DetectedNotationRecordMovementEvent(
            startTime: 0, endTime: 3.0, startPosition: 0.0, endPosition: 1.0,
            direction: "forward", movementKind: .normalPush,
            speed: 0.4, confidence: 0.9, source: "controller"
        )
        let tearForward = CaptureCore.DetectedNotationRecordMovementEvent(
            startTime: 6.0, endTime: 6.5, startPosition: 0.98, endPosition: 0.99,
            direction: "forward", movementKind: .normalPush,
            speed: 0.02, confidence: 0.9, source: "controller"
        )
        let provisional = CaptureCore.ProvisionalPlatterMovement(
            startTime: 6.5, currentTime: 7.0, startPosition: 0.99, currentPosition: 0.98,
            direction: "backward", movementKind: .normalPull, displacement: -0.01
        )
        let state = LiveNotationTrackingState.tracking(
            committed: [], provisional: nil,
            continuousCommitted: [freeSpin, tearForward],
            continuousProvisional: provisional,
            platterEvidenceIntervals: [],
            faderDerivation: nil
        )

        let rendered = LivePerformedNotationTracker.continuousRenderedEvents(for: state)

        XCTAssertEqual(rendered.count, 2, "free spin dropped; committed stroke + open provisional remain")
        XCTAssertEqual(rendered.last?.source, "live_preview", "the open stroke stays visible")
        XCTAssertEqual(
            rendered[0].endPosition, rendered[1].startPosition, accuracy: 1e-9,
            "the provisional stroke shares the committed stroke's reversal apex"
        )
    }

    // MARK: - Live evidence parity (stillness + crossfader wiring)

    private func crossfaderCC8Event(
        value: Int,
        takeRelativeTime: Double,
        deviceName: String = "Rane ONE MKII"
    ) -> CaptureCore.RawMixerMIDIEvent {
        CaptureCore.RawMixerMIDIEvent(
            timestamp: takeRelativeTime,
            takeRelativeTime: takeRelativeTime,
            deviceName: deviceName,
            channel: 15,
            controller: 8,
            value: value,
            normalizedValue: Double(value) / 127.0,
            mappedControl: nil
        )
    }

    private func usableCrossfaderCalibration() -> CrossfaderCalibration {
        CrossfaderCalibration(
            address: CrossfaderMIDIAddress(
                deviceIdentifier: "Rane ONE MKII", deviceName: "Rane ONE MKII",
                channel: 15, controller: 8
            ),
            fullLeftRawValue: 0, centerRawValue: 52, fullRightRawValue: 104,
            openEnd: .left, activeDeck: .rightDeck,
            calibratedAt: Date(timeIntervalSince1970: 1_788_000_000)
        )
    }

    /// A CC6 stream whose runs are separated by genuine zero-delta stillness,
    /// so `decodePlatterCore` emits `.observedStillness` provenance intervals.
    private func cc6WithStillness() -> [CaptureCore.RawMixerMIDIEvent] {
        var events: [CaptureCore.RawMixerMIDIEvent] = []
        var t = 0.0
        var value = 40
        for _ in 0..<20 { value += 1; events.append(midiEvent(value: value, takeRelativeTime: t, deviceName: "Rane ONE MKII")); t += 0.005 }
        for _ in 0..<8 { events.append(midiEvent(value: value, takeRelativeTime: t, deviceName: "Rane ONE MKII")); t += 0.005 }
        for _ in 0..<20 { value += 1; events.append(midiEvent(value: value, takeRelativeTime: t, deviceName: "Rane ONE MKII")); t += 0.005 }
        return events
    }

    func testLiveDecodeCarriesPlatterStillnessIntervals() {
        let decoded = MacCaptureEngine.resolvedControllerMovementEventsWithProvisional(
            selectedMIDISourceName: "Rane ONE MKII",
            capturedMidi: cc6WithStillness()
        )
        XCTAssertTrue(
            decoded.platterEvidenceIntervals.contains { $0.kind == .observedStillness },
            "the live decode result must expose decodePlatterCore's stillness provenance"
        )
    }

    func testLiveTearTrackingCarriesPlatterIntervalsAndOpenFader() {
        let calibration = usableCrossfaderCalibration()
        let snapshot = cc6WithStillness() + [
            crossfaderCC8Event(value: 0, takeRelativeTime: 0.0),
            crossfaderCC8Event(value: 0, takeRelativeTime: 0.2),
            crossfaderCC8Event(value: 0, takeRelativeTime: 0.4),
        ]
        let dataSource = LivePerformedNotationDataSource(
            selectedMIDISourceName: { "Rane ONE MKII" },
            capturedMidiCCEventsSnapshot: { snapshot },
            cameraMovementEventsSnapshot: { _ in nil },
            activeCrossfaderCalibration: { calibration }
        )
        let state = LivePerformedNotationTracker.computeState(dataSource: dataSource, baselineTimestamp: 0)
        guard case .tracking(_, _, _, _, let platterIntervals, let faderDerivation) = state else {
            return XCTFail("expected .tracking, got \(state)")
        }
        XCTAssertTrue(
            platterIntervals.contains { $0.kind == .observedStillness },
            "the live tracker must carry observed platter stillness into the Tear state"
        )
        XCTAssertNotNil(faderDerivation, "calibrated CC8 must derive live fader evidence")
        XCTAssertFalse(faderDerivation?.intervals.isEmpty ?? true, "derived fader evidence must not be empty")
    }

    func testLiveTearFaderDerivationReflectsTransitionNotLatestState() {
        let calibration = usableCrossfaderCalibration()
        // OPEN for a while, then CLOSED (centre detent) — a real state change.
        let cc8 = (0..<8).map { i in crossfaderCC8Event(value: 0, takeRelativeTime: Double(i) * 0.05) }
            + (0..<8).map { i in crossfaderCC8Event(value: 52, takeRelativeTime: 0.4 + Double(i) * 0.05) }
        let snapshot = Self.raneRingStream(runs: 2, stepsPerRun: 40) + cc8
        let dataSource = LivePerformedNotationDataSource(
            selectedMIDISourceName: { "Rane ONE MKII" },
            capturedMidiCCEventsSnapshot: { snapshot },
            cameraMovementEventsSnapshot: { _ in nil },
            activeCrossfaderCalibration: { calibration }
        )
        let state = LivePerformedNotationTracker.computeState(dataSource: dataSource, baselineTimestamp: 0)
        guard case .tracking(_, _, _, _, _, let faderDerivation) = state else {
            return XCTFail("expected .tracking, got \(state)")
        }
        XCTAssertNotNil(faderDerivation)
        XCTAssertGreaterThan(
            faderDerivation?.intervals.count ?? 0, 1,
            "a real open→closed change must produce more than one interval, not a single stamped state"
        )
    }

    func testLiveTearFaderUnknownWithoutCalibration() {
        let snapshot = Self.raneRingStream(runs: 2, stepsPerRun: 40)
            + [crossfaderCC8Event(value: 0, takeRelativeTime: 0.0)]
        let dataSource = LivePerformedNotationDataSource(
            selectedMIDISourceName: { "Rane ONE MKII" },
            capturedMidiCCEventsSnapshot: { snapshot },
            cameraMovementEventsSnapshot: { _ in nil },
            activeCrossfaderCalibration: { nil }
        )
        let state = LivePerformedNotationTracker.computeState(dataSource: dataSource, baselineTimestamp: 0)
        guard case .tracking(_, _, _, _, _, let faderDerivation) = state else {
            return XCTFail("expected .tracking, got \(state)")
        }
        XCTAssertNil(faderDerivation, "no usable calibration must yield no fader derivation (UNKNOWN, not fabricated OPEN)")
    }

    func testLiveTearFaderDerivationIsBaselineScoped() {
        let calibration = usableCrossfaderCalibration()
        // Pre-baseline CC8 (timestamp < 0) plus post-baseline platter. The
        // baseline filter must exclude the CC8, so no in-take fader evidence
        // is derived even though platter motion reaches `.tracking`.
        let snapshot = Self.raneRingStream(runs: 2, stepsPerRun: 40)
            + [crossfaderCC8Event(value: 0, takeRelativeTime: -1.0)]
        let dataSource = LivePerformedNotationDataSource(
            selectedMIDISourceName: { "Rane ONE MKII" },
            capturedMidiCCEventsSnapshot: { snapshot },
            cameraMovementEventsSnapshot: { _ in nil },
            activeCrossfaderCalibration: { calibration }
        )
        let state = LivePerformedNotationTracker.computeState(dataSource: dataSource, baselineTimestamp: 0.0)
        guard case .tracking(_, _, _, _, _, let faderDerivation) = state else {
            return XCTFail("expected .tracking, got \(state)")
        }
        XCTAssertNil(faderDerivation, "pre-baseline CC8 must not enter the live take's fader derivation")
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
            for: .tracking(committed: [event], provisional: nil, continuousCommitted: [], continuousProvisional: nil, platterEvidenceIntervals: [], faderDerivation: nil)
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

        engine.beginLiveMIDICapture()
        addTeardownBlock { engine.endLiveMIDICaptureIfIdle() }
        // AFTER the window opens: the window's own epoch is now the only epoch
        // admission uses, so a baseline taken before it could fall outside the
        // window and make this case timing-dependent.
        let baseline = CACurrentMediaTime()

        // A forward platter sweep on the verified right-deck address.
        for index in 0..<40 {
            engine.recordReceivedMIDICCEvent(
                sourceName: deviceName,
                channel: 1,
                controller: 6,
                value: index % 128,
                timestamp: baseline + 0.001 * Double(index + 1)
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
        guard case .tracking(let committed, let provisional, _, _, _, _) = state else {
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
        // UNCHANGED ownership rule. The lane now has three modes rather than
        // two states, but there is still exactly ONE construction site, so a
        // take — or a preview — can only ever have one tracker.
        XCTAssertEqual(
            source.components(separatedBy: "LivePerformedNotationTracker(").count - 1,
            1,
            "the tracker must be constructed in exactly one place, so a take can only ever have one"
        )
        XCTAssertTrue(
            source.contains("private func syncLiveNotationTracker(mode: LiveNotationMode)"),
            "creation and clearing must go through one named lifecycle point"
        )
        // The three modes are the whole contract, and nothing else may set one.
        XCTAssertTrue(
            source.contains("enum LiveNotationMode: Equatable {"),
            "the lane's modes must be a closed set, not ad-hoc booleans"
        )
        for mode in ["case off", "case preview", "case take"] {
            XCTAssertTrue(source.contains(mode), "LiveNotationMode must declare \(mode)")
        }
        // Entry/restoration, the recording transition, and teardown.
        XCTAssertTrue(source.contains("syncLiveNotationTracker(mode: resolvedLiveNotationMode)"))
        XCTAssertTrue(source.contains("syncLiveNotationTracker(mode: .off)"))
        XCTAssertTrue(
            source.contains("viewModel.session.phase == .recording ? .take : .preview"),
            "the mode must still be keyed on the authoring session's own recording phase"
        )
        // Idempotency: re-syncing to the mode already running must not rebuild
        // the tracker and discard the trace currently on screen.
        XCTAssertTrue(
            source.contains("guard mode != liveNotationMode else { return }"),
            "the lifecycle point must be idempotent per mode"
        )
    }

    /// Reject, retake and a new take all leave `.recording`. Under the mode
    /// contract that is a `.take` → `.preview` transition, and a transition is
    /// what REBUILDS the tracker — so none of them can carry a prior take's
    /// trace into the next thing shown, and equally the pre-record preview
    /// cannot be carried into a take.
    ///
    /// This is strictly stronger than the boolean rule it replaces. The old
    /// `guard liveNotationTracker == nil` KEPT an existing tracker when
    /// entering `.recording`; with a preview tracker now always present before
    /// Record, that guard would have handed the take the preview's trace.
    func testLeavingTheRecordingPhaseRebuildsTheAuthoringTracker() throws {
        let source = try authoringViewSource()
        XCTAssertFalse(
            source.contains("guard liveNotationTracker == nil else { return }"),
            "the take must not inherit whatever tracker the preview left behind"
        )
        XCTAssertTrue(
            source.contains("liveNotationTracker = nil"),
            "the .off branch must clear the tracker"
        )
        XCTAssertTrue(
            source.contains(".onChange(of: viewModel.session.phase == .recording)"),
            "the tracker is keyed on the authoring session's own recording phase"
        )
        // Every mode change rebuilds, and `.off` is the only branch that
        // clears — so crossing into or out of `.take` is always a re-anchor.
        let syncRange = try XCTUnwrap(
            source.range(of: "private func syncLiveNotationTracker(mode: LiveNotationMode)")
        )
        let reopenRange = try XCTUnwrap(
            source.range(of: "static func handleMIDIWindowRelease(")
        )
        let body = String(source[syncRange.lowerBound..<reopenRange.lowerBound])
        XCTAssertEqual(
            body.components(separatedBy: "liveNotationTracker = nil").count - 1, 1,
            "exactly one branch may clear the tracker"
        )
        XCTAssertEqual(
            body.components(separatedBy: "LivePerformedNotationTracker(").count - 1, 1,
            "both live modes must share the single construction site"
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
            source.contains("ReferenceTearCanonicalProjectionBuilder.project(\n                            movementEvents: liveNotationTracker.continuousRenderedEvents\n                        )")
                || source.contains("movementEvents: liveNotationTracker.continuousRenderedEvents"),
            "the live preview must project through ReferenceTearCanonicalProjectionBuilder"
        )
        XCTAssertTrue(
            source.contains("ReferenceTearCanonicalProjectionBuilder.project(review)"),
            "the finalized review must project through the same builder"
        )
        // The live boundary must also DECLARE which coordinate its positions
        // are in. Without this the projection falls back to the non-claiming
        // take-local basis and the live chart silently stops saying
        // "revolutions" even though the decoder really did divide by
        // steps-per-revolution.
        XCTAssertTrue(
            source.contains("coordinates: liveNotationTracker.continuousPlatterCoordinates"),
            "the live preview must state its platter coordinate basis"
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
            provisional: decoded.provisionalMovement,
            continuousCommitted: decoded.continuousEvents,
            continuousProvisional: decoded.continuousProvisionalMovement,
            platterEvidenceIntervals: decoded.platterEvidenceIntervals,
            faderDerivation: nil
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
                provisional: decoded.provisionalMovement,
                continuousCommitted: [],
                continuousProvisional: nil,
                platterEvidenceIntervals: [],
                faderDerivation: nil
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
                provisional: decoded.provisionalMovement,
                continuousCommitted: [],
                continuousProvisional: nil,
                platterEvidenceIntervals: [],
                faderDerivation: nil
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
            for: .tracking(committed: [], provisional: decoded.provisionalMovement, continuousCommitted: [], continuousProvisional: nil, platterEvidenceIntervals: [], faderDerivation: nil)
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

    // MARK: - Pre-record live preview (Reference Authoring)
    //
    // The 2026-09-07 hardware session showed the authoring notation lane blank
    // until Record was pressed, which is exactly the moment it is least useful:
    // before a take it is the only place the operator can confirm the RANE
    // platter is actually reaching the app. Two independent boundaries caused
    // it, and both are pinned here.
    //
    //  1. `ReferenceAuthoringView` only built a tracker while the session phase
    //     was `.recording`.
    //  2. Even with a tracker, `recordReceivedMIDICCEvent` only appends to
    //     `capturedMidiCCEvents` once an accumulation window with an open epoch
    //     exists, and nothing on this route ever opened the preview window
    //     `beginLiveMIDICapture()` exists to open — it had no production caller.
    //
    // The repair adds a THIRD owner of that one buffer, so the cases below are
    // mostly about ownership, not about drawing: the buffer is now claimed by
    // `.idle` → `.preview` → `.take` → `.idle` transitions decided under
    // `midiCaptureLock`, never by the asynchronously published
    // `isRoutineRecording` / `isRoutineFinalizationPending` flags. Every
    // interleaving case below drives real threads through the engine's own
    // append seam; none asserts on source text for its primary claim.
    //
    // Everything here is presentation only. No case writes a sidecar, a take,
    // an approval or an export.

    /// The engine-backed data source, minus the Core MIDI device-name lookup a
    /// headless test cannot have. Same substitution as
    /// `engineBackedDataSource`, reused for the pre-record cases.
    private func previewDataSource(
        engine: MacCaptureEngine,
        deviceName: String = "Rane ONE MKII"
    ) -> LivePerformedNotationDataSource {
        engineBackedDataSource(engine: engine, deviceName: deviceName)
    }

    /// 1 + 2. An ACTIVE authoring route that is NOT recording accumulates real
    /// platter telemetry and presents it as drawn movement.
    ///
    /// This is the whole defect in one case: before the repair the buffer stayed
    /// empty because no window was open, so the canonical renderer received
    /// nothing no matter how much the operator moved the platter.
    func testInactiveAuthoringRouteWithFreshPlatterInputPublishesVisibleNotation() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        engine.beginLiveMIDICapture()
        addTeardownBlock { engine.endLiveMIDICaptureIfIdle() }

        XCTAssertFalse(
            engine.isRoutineRecording,
            "this case is explicitly the NOT-recording route"
        )
        XCTAssertEqual(
            engine.midiCaptureWindowTicket.owner, .preview,
            "the route's own window must be the preview window"
        )

        // Timestamps are taken after the window opens so every event lands
        // inside it. Deterministic offsets, no sleeping.
        let base = CACurrentMediaTime()
        for index in 0..<40 {
            engine.recordReceivedMIDICCEvent(
                sourceName: "Rane ONE MKII",
                channel: 1,
                controller: 6,
                value: index % 128,
                timestamp: base + 0.001 * Double(index + 1)
            )
        }

        XCTAssertEqual(
            engine.capturedMidiCCEventsSnapshot().count, 40,
            "an open preview window must accumulate platter telemetry before Record"
        )

        let state = LivePerformedNotationTracker.computeState(
            dataSource: previewDataSource(engine: engine),
            baselineTimestamp: base
        )
        guard case .tracking = state else {
            return XCTFail("pre-record platter movement must present as tracking, got \(state)")
        }
        XCTAssertFalse(
            LivePerformedNotationTracker.renderedEvents(for: state).isEmpty,
            "the canonical renderer must receive pre-record events, not an empty source"
        )
    }

    /// Without an open window the same input reaches nothing — the exact
    /// pre-repair behaviour, kept as the negative control so a future change
    /// that silently stops opening the window fails here rather than on the rig.
    func testWithoutAPreviewWindowThePreRecordChartReceivesNothing() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        // Deliberately no `beginLiveMIDICapture()`.
        XCTAssertEqual(engine.midiCaptureWindowTicket.owner, .idle)
        let base = CACurrentMediaTime()
        for index in 0..<40 {
            engine.recordReceivedMIDICCEvent(
                sourceName: "Rane ONE MKII",
                channel: 1, controller: 6, value: index % 128,
                timestamp: base + 0.001 * Double(index + 1)
            )
        }
        XCTAssertTrue(
            engine.capturedMidiCCEventsSnapshot().isEmpty,
            "no window means no accumulation; this is what made the lane blank"
        )
    }

    /// Opening a preview window must not fabricate ANY take state. The preview
    /// is not a take: no media-start epoch, no sidecar, no artifact status, no
    /// detected notation, no Watch linkage.
    func testPreRecordPreviewFabricatesNoTakeEvidence() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        engine.beginLiveMIDICapture()
        addTeardownBlock { engine.endLiveMIDICaptureIfIdle() }

        let base = CACurrentMediaTime()
        for index in 0..<20 {
            engine.recordReceivedMIDICCEvent(
                sourceName: "Rane ONE MKII",
                channel: 1, controller: 6, value: index % 128,
                timestamp: base + 0.001 * Double(index + 1)
            )
        }

        XCTAssertFalse(engine.isRoutineRecording, "preview must not start a take")
        XCTAssertFalse(engine.isRoutineFinalizationPending, "preview must not finalize anything")
        XCTAssertNil(engine.lastRoutineRecordingURL, "preview must not produce a media file")
        XCTAssertNil(engine.lastRoutineRecordingSessionID, "preview must not claim a session")
        XCTAssertNil(engine.lastRoutineDetectedNotation, "preview must not publish detected notation")
        XCTAssertTrue(
            engine.routineTakeArtifactStatuses.isEmpty,
            "preview must not register a take artifact"
        )
        XCTAssertNotEqual(
            engine.midiCaptureWindowTicket.owner, .take,
            "a preview must never take ownership of a take's window"
        )
    }

    // MARK: - Ownership interleavings
    //
    // Each case below pauses a real MIDI packet inside the engine's append
    // seam on a background thread, performs a lifecycle transition on the test
    // thread while it is paused, then releases it. Semaphores with bounded
    // waits throughout; there is no sleep and no timing-sensitive assertion.

    /// (1) A preview packet paused across record arming must never enter the
    /// take. Its window was retired by arming, so it is dropped.
    func testPreviewPacketPausedAcrossRecordArmingNeverEntersTheTake() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        engine.beginLiveMIDICapture()
        addTeardownBlock { engine.testOnly_setMIDIAppendInterleavingHook(nil) }

        let base = CACurrentMediaTime()
        let mediaStart = base + 1

        var ticketAtIngress: MacCaptureEngine.MIDICaptureWindowTicket?
        pauseOneMIDIPacket(
            engine: engine,
            packet: {
                engine.recordReceivedMIDICCEvent(
                    sourceName: "Rane ONE MKII",
                    channel: 1, controller: 6, value: 40,
                    timestamp: base + 0.001
                )
            },
            observingTicket: { ticketAtIngress = $0 },
            whilePaused: {
                engine.testOnly_armTakeMIDIWindow()
                engine.testOnly_openTakeMIDIEpoch(at: mediaStart)
            }
        )

        XCTAssertEqual(
            ticketAtIngress?.owner, .preview,
            "the packet must have captured the PREVIEW window's ticket at ingress"
        )
        XCTAssertNil(ticketAtIngress?.takeToken, "a preview ticket carries no take token")

        XCTAssertEqual(engine.midiCaptureWindowTicket.owner, .take)
        XCTAssertTrue(
            engine.capturedMidiCCEventsSnapshot().isEmpty,
            "a packet admitted under the preview window must never land in the take"
        )
        XCTAssertEqual(
            engine.testOnly_midiEventsRejectedAsStale, 1,
            "the packet must be dropped explicitly, not silently mis-filed"
        )
    }

    /// (2) A preview begin/end attempted AFTER arming but BEFORE
    /// `isRoutineRecording` has been published must be refused.
    ///
    /// This is the interleaving the published flags could not cover:
    /// `startRoutineRecording` schedules `isRoutineRecording = true` on the
    /// MainActor and arms on the session queue, and those are not ordered. Here
    /// both published flags still read false while the take already owns the
    /// window.
    func testPreviewWindowMutationAfterArmingBeforeRecordingPublicationIsRefused() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        engine.testOnly_armTakeMIDIWindow()
        let mediaStart = CACurrentMediaTime()
        engine.testOnly_openTakeMIDIEpoch(at: mediaStart)

        for index in 0..<12 {
            engine.recordReceivedMIDICCEvent(
                sourceName: "Rane ONE MKII",
                channel: 1, controller: 6, value: index % 128,
                timestamp: mediaStart + 0.01 * Double(index + 1)
            )
        }
        let armedTicket = engine.midiCaptureWindowTicket
        XCTAssertEqual(engine.capturedMidiCCEventsSnapshot().count, 12)

        XCTAssertFalse(
            engine.isRoutineRecording,
            "the publication this repair must not depend on has deliberately not happened"
        )
        XCTAssertFalse(engine.isRoutineFinalizationPending)

        engine.beginLiveMIDICapture()
        engine.endLiveMIDICaptureIfIdle()

        XCTAssertEqual(
            engine.capturedMidiCCEventsSnapshot().count, 12,
            "an armed take's evidence survives a preview begin/end in the arming gap"
        )
        XCTAssertEqual(
            engine.midiCaptureWindowTicket, armedTicket,
            "a refused preview mutation must not even change the window identity"
        )
    }

    /// (3) Navigation away during Stop, before finalization-pending is
    /// published, must not clear undrained take evidence.
    ///
    /// `stopRoutineRecording` publishes `isRoutineRecording = false` and closes
    /// the epoch, while `isRoutineFinalizationPending` is not set until the
    /// AVFoundation completion callback. Both published flags therefore read
    /// false here — the exact gap in which route teardown used to be able to
    /// wipe the crossfader samples the sidecar is written from.
    func testPreviewShutdownDuringStopBeforeFinalizationPendingKeepsTakeEvidence() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let token = engine.testOnly_armTakeMIDIWindow()
        let mediaStart = CACurrentMediaTime()
        engine.testOnly_openTakeMIDIEpoch(at: mediaStart)
        for index in 0..<9 {
            engine.recordReceivedMIDICCEvent(
                sourceName: "Rane ONE MKII",
                channel: 1, controller: 6, value: index % 128,
                timestamp: mediaStart + 0.01 * Double(index + 1)
            )
        }

        // Stop: epoch closed, ownership deliberately retained.
        engine.testOnly_closeTakeMIDIEpoch()
        XCTAssertFalse(engine.isRoutineRecording)
        XCTAssertFalse(engine.isRoutineFinalizationPending)
        XCTAssertEqual(
            engine.midiCaptureWindowTicket.owner, .take,
            "a stopped take still owns its undrained evidence"
        )

        // Route teardown, then route re-entry, in that gap.
        engine.endLiveMIDICaptureIfIdle()
        engine.beginLiveMIDICapture()

        XCTAssertEqual(
            engine.capturedMidiCCEventsSnapshot().count, 9,
            "preview cleanup must never clear undrained take evidence"
        )
        XCTAssertEqual(
            engine.testOnly_drainTakeMIDIWindow(token: token)?.count, 9,
            "finalization must still receive the whole take"
        )
    }

    /// (4) A take packet already in flight when Stop begins is DROPPED, not
    /// appended after the media has ended. This is the defined behaviour, and
    /// it leaves the already-admitted evidence untouched.
    func testTakePacketPausedAcrossStopIsDroppedNotAppendedAfterMediaEnd() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        engine.testOnly_armTakeMIDIWindow()
        addTeardownBlock { engine.testOnly_setMIDIAppendInterleavingHook(nil) }
        let mediaStart = CACurrentMediaTime()
        engine.testOnly_openTakeMIDIEpoch(at: mediaStart)
        for index in 0..<5 {
            engine.recordReceivedMIDICCEvent(
                sourceName: "Rane ONE MKII",
                channel: 1, controller: 6, value: index,
                timestamp: mediaStart + 0.01 * Double(index + 1)
            )
        }

        pauseOneMIDIPacket(
            engine: engine,
            packet: {
                engine.recordReceivedMIDICCEvent(
                    sourceName: "Rane ONE MKII",
                    channel: 1, controller: 6, value: 99,
                    timestamp: mediaStart + 0.5
                )
            },
            whilePaused: { engine.testOnly_closeTakeMIDIEpoch() }
        )

        let held = engine.capturedMidiCCEventsSnapshot()
        XCTAssertEqual(held.count, 5, "the in-flight packet must not be appended after Stop")
        XCTAssertFalse(
            held.contains { $0.value == 99 },
            "and specifically not that packet"
        )
        XCTAssertEqual(engine.midiCaptureWindowTicket.owner, .take)
    }

    /// (5) A take packet paused across the FINAL DRAIN cannot race it. The
    /// drain takes exactly what was admitted; the in-flight packet is dropped
    /// rather than appended into an already-drained window.
    func testTakePacketPausedAcrossTheFinalDrainCannotRaceIt() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let token = engine.testOnly_armTakeMIDIWindow()
        addTeardownBlock { engine.testOnly_setMIDIAppendInterleavingHook(nil) }
        let mediaStart = CACurrentMediaTime()
        engine.testOnly_openTakeMIDIEpoch(at: mediaStart)
        for index in 0..<7 {
            engine.recordReceivedMIDICCEvent(
                sourceName: "Rane ONE MKII",
                channel: 1, controller: 6, value: index,
                timestamp: mediaStart + 0.01 * Double(index + 1)
            )
        }

        var drained: [CaptureCore.RawMixerMIDIEvent] = []
        pauseOneMIDIPacket(
            engine: engine,
            packet: {
                engine.recordReceivedMIDICCEvent(
                    sourceName: "Rane ONE MKII",
                    channel: 1, controller: 6, value: 99,
                    timestamp: mediaStart + 0.5
                )
            },
            whilePaused: { drained = engine.testOnly_drainTakeMIDIWindow(token: token) ?? [] }
        )

        XCTAssertEqual(drained.count, 7, "the drain takes exactly the admitted evidence")
        XCTAssertFalse(drained.contains { $0.value == 99 })
        XCTAssertTrue(
            engine.capturedMidiCCEventsSnapshot().isEmpty,
            "and nothing may be appended into the window it just closed"
        )
        XCTAssertEqual(engine.midiCaptureWindowTicket.owner, .idle)
    }

    /// (6) A stale append released after the drain, with a NEW preview window
    /// already open, must not contaminate that preview either.
    func testStaleAppendAfterTheDrainCannotContaminateTheNextPreview() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let token = engine.testOnly_armTakeMIDIWindow()
        addTeardownBlock {
            engine.testOnly_setMIDIAppendInterleavingHook(nil)
            engine.endLiveMIDICaptureIfIdle()
        }
        let mediaStart = CACurrentMediaTime()
        engine.testOnly_openTakeMIDIEpoch(at: mediaStart)
        engine.recordReceivedMIDICCEvent(
            sourceName: "Rane ONE MKII",
            channel: 1, controller: 6, value: 1,
            timestamp: mediaStart + 0.01
        )

        pauseOneMIDIPacket(
            engine: engine,
            packet: {
                engine.recordReceivedMIDICCEvent(
                    sourceName: "Rane ONE MKII",
                    channel: 1, controller: 6, value: 99,
                    timestamp: mediaStart + 0.5
                )
            },
            whilePaused: {
                engine.testOnly_drainTakeMIDIWindow(token: token)
                engine.beginLiveMIDICapture()
            }
        )

        XCTAssertEqual(engine.midiCaptureWindowTicket.owner, .preview)
        XCTAssertTrue(
            engine.capturedMidiCCEventsSnapshot().isEmpty,
            "a take packet must never be appended into a later preview window"
        )
    }

    /// (7) The finalization paths that never drain must still release the
    /// window, or the preview could never re-arm for the rest of the session.
    func testEarlyReturnFinalizationPathsReleaseTheWindow() throws {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let token = engine.testOnly_armTakeMIDIWindow()
        let mediaStart = CACurrentMediaTime()
        engine.testOnly_openTakeMIDIEpoch(at: mediaStart)
        engine.recordReceivedMIDICCEvent(
            sourceName: "Rane ONE MKII",
            channel: 1, controller: 6, value: 3,
            timestamp: mediaStart + 0.01
        )
        XCTAssertEqual(engine.capturedMidiCCEventsSnapshot().count, 1)

        XCTAssertTrue(engine.testOnly_releaseAbandonedTakeMIDIWindow(token: token))

        XCTAssertEqual(engine.midiCaptureWindowTicket.owner, .idle)
        XCTAssertTrue(
            engine.capturedMidiCCEventsSnapshot().isEmpty,
            "an abandoned take's accumulation is discarded, not inherited"
        )
        engine.beginLiveMIDICapture()
        addTeardownBlock { engine.endLiveMIDICaptureIfIdle() }
        XCTAssertEqual(
            engine.midiCaptureWindowTicket.owner, .preview,
            "and the preview can claim the window again"
        )

        // Both no-drain paths must actually call it.
        let source = try engineSource()
        let armFailure = try XCTUnwrap(
            source.range(of: "self.scratchPlaybackController.cancelRoutineOutputCapture()")
        )
        XCTAssertTrue(
            String(source[armFailure.upperBound...].prefix(700))
                .contains("releaseAbandonedTakeMIDIWindow(token: midiTakeToken)"),
            "a take that fails to start must hand the window back"
        )
        let noSidecar = try XCTUnwrap(
            source.range(of: "guard let sidecar = activeRoutineRecordingSidecar else {")
        )
        XCTAssertTrue(
            String(source[noSidecar.upperBound...].prefix(900))
                .contains("releaseAbandonedTakeMIDIWindow(token: midiTakeToken)"),
            "the no-sidecar finalization early return must hand the window back"
        )
    }

    /// (8) Repeated preview → take → preview generations stay isolated. No
    /// generation is ever reused, and each take drains exactly its own events.
    func testRepeatedPreviewTakePreviewGenerationsStayIsolated() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        addTeardownBlock { engine.endLiveMIDICaptureIfIdle() }
        var seenGenerations: [UInt64] = [engine.midiCaptureWindowTicket.generation]
        var seenTokens: [MacCaptureEngine.MIDICaptureTakeToken] = []

        for cycle in 1...3 {
            engine.beginLiveMIDICapture()
            seenGenerations.append(engine.midiCaptureWindowTicket.generation)
            let previewBase = CACurrentMediaTime()
            for index in 0..<4 {
                engine.recordReceivedMIDICCEvent(
                    sourceName: "Rane ONE MKII",
                    channel: 1, controller: 6, value: index,
                    timestamp: previewBase + 0.001 * Double(index + 1)
                )
            }
            XCTAssertEqual(
                engine.capturedMidiCCEventsSnapshot().count, 4,
                "cycle \(cycle): the preview accumulates"
            )

            let token = engine.testOnly_armTakeMIDIWindow()
            seenTokens.append(token)
            seenGenerations.append(engine.midiCaptureWindowTicket.generation)
            XCTAssertTrue(
                engine.capturedMidiCCEventsSnapshot().isEmpty,
                "cycle \(cycle): arming discards the preview"
            )

            let mediaStart = CACurrentMediaTime()
            engine.testOnly_openTakeMIDIEpoch(at: mediaStart)
            seenGenerations.append(engine.midiCaptureWindowTicket.generation)
            for index in 0..<cycle {
                engine.recordReceivedMIDICCEvent(
                    sourceName: "Rane ONE MKII",
                    channel: 1, controller: 6, value: index,
                    timestamp: mediaStart + 0.01 * Double(index + 1)
                )
            }
            engine.testOnly_closeTakeMIDIEpoch()
            seenGenerations.append(engine.midiCaptureWindowTicket.generation)

            let drained = engine.testOnly_drainTakeMIDIWindow(token: token)
            seenGenerations.append(engine.midiCaptureWindowTicket.generation)
            XCTAssertEqual(
                drained?.count, cycle,
                "cycle \(cycle): a take drains exactly its own events, never a neighbour's"
            )
            XCTAssertEqual(engine.midiCaptureWindowTicket.owner, .idle)
        }

        XCTAssertEqual(
            seenGenerations.count, Set(seenGenerations).count,
            "no window generation may ever be reused"
        )
        XCTAssertEqual(
            seenGenerations, seenGenerations.sorted(),
            "window generations must advance monotonically"
        )
        XCTAssertEqual(
            seenTokens.count, Set(seenTokens).count,
            "no take token may ever be reused"
        )
    }

    /// (9) Record arming discards every pre-record preview event BEFORE the
    /// take epoch is established, which is what makes contamination
    /// structurally impossible rather than merely unlikely.
    func testRecordArmingClearsPreviewDataBeforeTheTakeEpochExists() throws {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        engine.beginLiveMIDICapture()
        let previewBase = CACurrentMediaTime()
        for index in 0..<25 {
            engine.recordReceivedMIDICCEvent(
                sourceName: "Rane ONE MKII",
                channel: 1, controller: 6, value: index % 128,
                timestamp: previewBase + 0.001 * Double(index + 1)
            )
        }
        XCTAssertEqual(engine.capturedMidiCCEventsSnapshot().count, 25)

        let token = engine.testOnly_armTakeMIDIWindow()

        let armed = engine.midiCaptureWindowTicket
        XCTAssertEqual(armed.owner, .take)
        XCTAssertEqual(armed.takeToken, token, "the armed window carries this take's token")
        XCTAssertEqual(
            armed.epochStartHostTime, 0,
            "arming must leave the epoch closed until media start is confirmed"
        )
        XCTAssertTrue(
            engine.capturedMidiCCEventsSnapshot().isEmpty,
            "preview accumulation must be discarded at arming"
        )

        // With the epoch still closed, nothing at all can be admitted.
        engine.recordReceivedMIDICCEvent(
            sourceName: "Rane ONE MKII",
            channel: 1, controller: 6, value: 7,
            timestamp: CACurrentMediaTime()
        )
        XCTAssertTrue(
            engine.capturedMidiCCEventsSnapshot().isEmpty,
            "pre-roll traffic must not enter the take timeline"
        )

        // And the epoch comes only from the confirmed media start.
        let source = try engineSource()
        XCTAssertTrue(
            source.contains("beginMIDIRecordingWindow(at: mediaStartHostTime, token: midiTakeToken)"),
            "the take epoch must come from the confirmed media start host time"
        )
    }

    /// (10) Admitted take evidence is drained exactly once, with no loss and no
    /// contamination from the preview that preceded it or the preview that
    /// follows it.
    func testAdmittedTakeEvidenceIsDrainedExactlyOnce() throws {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        addTeardownBlock { engine.endLiveMIDICaptureIfIdle() }

        engine.beginLiveMIDICapture()
        let previewBase = CACurrentMediaTime()
        for index in 0..<6 {
            engine.recordReceivedMIDICCEvent(
                sourceName: "Rane ONE MKII",
                channel: 1, controller: 6, value: 111,
                timestamp: previewBase + 0.001 * Double(index + 1)
            )
        }

        let token = engine.testOnly_armTakeMIDIWindow()
        let mediaStart = CACurrentMediaTime()
        engine.testOnly_openTakeMIDIEpoch(at: mediaStart)
        for index in 0..<10 {
            engine.recordReceivedMIDICCEvent(
                sourceName: "Rane ONE MKII",
                channel: 1, controller: 6, value: 22,
                timestamp: mediaStart + 0.01 * Double(index + 1)
            )
        }
        engine.testOnly_closeTakeMIDIEpoch()

        let drained = try XCTUnwrap(engine.testOnly_drainTakeMIDIWindow(token: token))
        XCTAssertEqual(drained.count, 10, "no loss")
        XCTAssertFalse(
            drained.contains { $0.value == 111 },
            "no contamination from the preceding preview"
        )
        XCTAssertTrue(
            drained.allSatisfy { $0.takeRelativeTime >= 0 },
            "every drained event is expressed on the take's own timeline"
        )

        // Exactly once: the window is released, so a second drain for the same
        // token matches nothing at all — nil, not an empty take.
        XCTAssertNil(engine.testOnly_drainTakeMIDIWindow(token: token))
        engine.beginLiveMIDICapture()
        XCTAssertTrue(
            engine.capturedMidiCCEventsSnapshot().isEmpty,
            "the next preview must not inherit a drained take"
        )
    }

    /// The preview re-arms on the engine's window RELEASE, not on a published
    /// lifecycle flag — which is what covers the finalization paths that never
    /// set `isRoutineFinalizationPending` at all.
    func testPreviewReArmsOnTheEngineWindowRelease() throws {
        let view = try authoringViewSource()
        XCTAssertTrue(
            view.contains(".onReceive(captureEngine.$midiCaptureWindowReleaseCount)"),
            "the route must SUBSCRIBE to the engine publisher; captureEngine is a plain let, so onChange of one of its properties establishes no observation and would never fire"
        )
        XCTAssertFalse(
            view.contains(".onChange(of: captureEngine."),
            "no engine property may be watched through onChange from a non-observed reference"
        )
        XCTAssertFalse(
            view.contains(".onChange(of: captureEngine.isRoutineFinalizationPending)"),
            "re-arming must not depend on a flag the early-return paths never set"
        )
        XCTAssertTrue(view.contains("Self.handleMIDIWindowRelease("))

        // Re-arming must not build a second tracker.
        let reopenRange = try XCTUnwrap(
            view.range(of: "static func handleMIDIWindowRelease(")
        )
        XCTAssertFalse(
            String(view[reopenRange.upperBound...].prefix(300))
                .contains("LivePerformedNotationTracker("),
            "re-arming reopens the window only; the preview already has its tracker"
        )

        // And the engine publishes that release from BOTH release paths.
        let source = try engineSource()
        XCTAssertEqual(
            source.components(separatedBy: "publishMIDICaptureWindowRelease()").count - 1, 3,
            "one definition plus exactly the drain and abandonment release sites"
        )
    }

    /// The two preview-window accessors must decide on LOCK-OWNED ownership.
    /// Reading the asynchronously published lifecycle flags is what left the
    /// arming and drain gaps open, so neither accessor may consult them.
    func testPreviewWindowAccessorsDoNotDependOnPublishedFlags() throws {
        let source = try engineSource()
        for accessor in ["func beginLiveMIDICapture() {", "func endLiveMIDICaptureIfIdle() {"] {
            let range = try XCTUnwrap(source.range(of: accessor), "missing \(accessor)")
            let body = String(source[range.upperBound...].prefix(400))
            XCTAssertTrue(
                body.contains("midiWindowOwnerStorage =="),
                "\(accessor) must decide on lock-owned ownership"
            )
            XCTAssertTrue(
                body.contains("midiCaptureLock.lock()"),
                "\(accessor) must decide under the lock"
            )
            for flag in ["isRoutineRecording", "isRoutineFinalizationPending"] {
                XCTAssertFalse(
                    body.contains(flag),
                    "\(accessor) must not read the published \(flag)"
                )
            }
        }
        // Finalization keeps its own destructive drain, now token-scoped.
        XCTAssertTrue(
            source.contains("guard let capturedMidi = drainCapturedMidiCCEvents(token: midiTakeToken) else { return }"),
            "finalization must still own ending a real take's window, for its own take"
        )
    }

    // MARK: - Epoch and take-token boundaries

    /// A `.take` window whose epoch is still zero rejects EVERY packet.
    ///
    /// Zero is the epoch from arming until `didStartRecordingTo` confirms
    /// media start, and again from Stop until the drain. Nothing may be
    /// admitted in either interval.
    func testTakeWindowWithAZeroEpochRejectsEveryPacket() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let token = engine.testOnly_armTakeMIDIWindow()
        XCTAssertEqual(engine.midiCaptureWindowTicket.epochStartHostTime, 0)

        let now = CACurrentMediaTime()
        for offset in [-1.0, 0.0, 0.001, 5.0] {
            engine.recordReceivedMIDICCEvent(
                sourceName: "Rane ONE MKII",
                channel: 1, controller: 6, value: 5,
                timestamp: now + offset
            )
        }
        XCTAssertTrue(
            engine.capturedMidiCCEventsSnapshot().isEmpty,
            "an epoch of zero must reject every packet, at any host time"
        )

        // Same again after Stop closes the epoch on a take that HAS captured.
        engine.testOnly_openTakeMIDIEpoch(at: now)
        engine.recordReceivedMIDICCEvent(
            sourceName: "Rane ONE MKII",
            channel: 1, controller: 6, value: 6, timestamp: now + 0.01
        )
        XCTAssertEqual(engine.capturedMidiCCEventsSnapshot().count, 1)
        engine.testOnly_closeTakeMIDIEpoch()
        XCTAssertEqual(engine.midiCaptureWindowTicket.epochStartHostTime, 0)
        engine.recordReceivedMIDICCEvent(
            sourceName: "Rane ONE MKII",
            channel: 1, controller: 6, value: 7, timestamp: now + 0.02
        )
        XCTAssertEqual(
            engine.capturedMidiCCEventsSnapshot().count, 1,
            "nothing may be admitted after Stop closed the epoch"
        )
        XCTAssertEqual(engine.testOnly_drainTakeMIDIWindow(token: token)?.count, 1)
    }

    /// No cached or caller-supplied epoch may override the active ticket.
    ///
    /// The regression this pins: an epoch read once at ingress and carried
    /// past an arming would admit a preview packet into a take whose own epoch
    /// was still zero. `recordReceivedMIDICCEvent` no longer accepts an epoch
    /// at all — only a whole ticket, validated unchanged before the append.
    func testNoCachedEpochCanOverrideTheActiveTicket() throws {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        engine.beginLiveMIDICapture()
        let previewEpoch = engine.midiCaptureWindowTicket.epochStartHostTime
        XCTAssertGreaterThan(previewEpoch, 0)

        // A timestamp that WOULD be admissible under the preview epoch.
        let admissibleUnderPreview = previewEpoch + 1
        engine.testOnly_armTakeMIDIWindow()

        engine.recordReceivedMIDICCEvent(
            sourceName: "Rane ONE MKII",
            channel: 1, controller: 6, value: 9,
            timestamp: admissibleUnderPreview
        )
        XCTAssertTrue(
            engine.capturedMidiCCEventsSnapshot().isEmpty,
            "the retired preview epoch must not admit anything into the take"
        )

        // And the ingress path carries a whole ticket, never a bare epoch.
        let source = try engineSource()
        XCTAssertFalse(
            source.contains("let startTime = midiRecordingStartTime"),
            "the cached-epoch read at packet-list ingress must be gone"
        )
        XCTAssertTrue(
            source.contains("let ingressTicket = lockedMIDICaptureWindowTicket()"),
            "ingress must capture owner, generation and epoch together"
        )
        XCTAssertFalse(
            source.contains("recordingStartTime:"),
            "no caller-supplied epoch parameter may remain"
        )
    }

    /// An old take's token can neither drain nor abandon a newer take, and a
    /// duplicate release of an already-released take does nothing.
    func testAStaleTakeTokenCannotDrainOrAbandonAnotherTake() throws {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let tokenA = engine.testOnly_armTakeMIDIWindow()
        let startA = CACurrentMediaTime()
        engine.testOnly_openTakeMIDIEpoch(at: startA)
        engine.recordReceivedMIDICCEvent(
            sourceName: "Rane ONE MKII",
            channel: 1, controller: 6, value: 1, timestamp: startA + 0.01
        )
        XCTAssertEqual(try XCTUnwrap(engine.testOnly_drainTakeMIDIWindow(token: tokenA)).count, 1)

        // Take B arms and captures.
        let tokenB = engine.testOnly_armTakeMIDIWindow()
        XCTAssertNotEqual(tokenA, tokenB)
        let startB = CACurrentMediaTime()
        engine.testOnly_openTakeMIDIEpoch(at: startB)
        for index in 0..<4 {
            engine.recordReceivedMIDICCEvent(
                sourceName: "Rane ONE MKII",
                channel: 1, controller: 6, value: index,
                timestamp: startB + 0.01 * Double(index + 1)
            )
        }

        // A's token must not touch B.
        XCTAssertNil(
            engine.testOnly_drainTakeMIDIWindow(token: tokenA),
            "an old token must not drain a newer take"
        )
        XCTAssertFalse(
            engine.testOnly_releaseAbandonedTakeMIDIWindow(token: tokenA),
            "an old token must not abandon a newer take"
        )
        XCTAssertEqual(
            engine.capturedMidiCCEventsSnapshot().count, 4,
            "B's evidence must be untouched"
        )
        XCTAssertEqual(engine.midiCaptureWindowTicket.takeToken, tokenB)
        XCTAssertEqual(try XCTUnwrap(engine.testOnly_drainTakeMIDIWindow(token: tokenB)).count, 4)
    }

    /// A start that fails must not abandon a DIFFERENT take's stopped,
    /// undrained evidence.
    ///
    /// The production shape: `startRoutineRecording` holds an optional token
    /// that is nil until arming actually happened, and its catch releases only
    /// that token.
    func testAFailedStartCannotAbandonAnotherTakesStoppedEvidence() throws {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let stoppedTake = engine.testOnly_armTakeMIDIWindow()
        let start = CACurrentMediaTime()
        engine.testOnly_openTakeMIDIEpoch(at: start)
        for index in 0..<6 {
            engine.recordReceivedMIDICCEvent(
                sourceName: "Rane ONE MKII",
                channel: 1, controller: 6, value: index,
                timestamp: start + 0.01 * Double(index + 1)
            )
        }
        engine.testOnly_closeTakeMIDIEpoch()

        let beforeFailedStart = engine.midiCaptureWindowTicket
        // Actual start entry point fails before device discovery or recording.
        let failedRequest = engine.startRoutineRecording()
        XCTAssertNotNil(engine.routineRecordingBoundary(for: failedRequest)?.startFailureDescription)
        let failedToken = engine.testOnly_tryArmTakeMIDIWindow(
            mediaURL: URL(fileURLWithPath: "/tmp/failed-new-take.mov")
        )
        XCTAssertNil(failedToken)
        XCTAssertEqual(engine.midiCaptureWindowTicket, beforeFailedStart)
        // A later start attempt that threw BEFORE arming holds no token, so it
        // releases nothing. Model the only other possibility too: a token from
        // some earlier take must also release nothing.
        let unrelated = MacCaptureEngine.MIDICaptureTakeToken(value: stoppedTake.value &- 1)
        XCTAssertFalse(engine.testOnly_releaseAbandonedTakeMIDIWindow(token: unrelated))

        XCTAssertEqual(
            engine.capturedMidiCCEventsSnapshot().count, 6,
            "a stopped take's undrained evidence must survive an unrelated failed start"
        )
        XCTAssertEqual(engine.midiCaptureWindowTicket.takeToken, stoppedTake)
        XCTAssertEqual(try XCTUnwrap(engine.testOnly_drainTakeMIDIWindow(token: stoppedTake)).count, 6)

        // The production catch is token-scoped and conditional on arming.
        let source = try engineSource()
        XCTAssertTrue(
            source.contains("var midiTakeToken: MIDICaptureTakeToken?"),
            "the start path must hold an OPTIONAL token, nil until arming happened"
        )
        XCTAssertTrue(
            source.contains("midiTakeToken = self.openMIDIInputForRecording(mediaURL: preparedRecording.mediaURL)"),
            "the token must come from arming itself"
        )
    }

    /// Duplicate drains and duplicate abandonments are no-ops that publish no
    /// release. Only a real take→idle transition publishes.
    func testDuplicateDrainAndAbandonmentPublishNoRelease() throws {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        var published: [Int] = []
        var cancellables = Set<AnyCancellable>()
        engine.$midiCaptureWindowReleaseCount
            .sink { published.append($0) }
            .store(in: &cancellables)
        let replayCount = published.count

        let token = engine.testOnly_armTakeMIDIWindow()
        let start = CACurrentMediaTime()
        engine.testOnly_openTakeMIDIEpoch(at: start)
        engine.recordReceivedMIDICCEvent(
            sourceName: "Rane ONE MKII",
            channel: 1, controller: 6, value: 1, timestamp: start + 0.01
        )

        XCTAssertEqual(try XCTUnwrap(engine.testOnly_drainTakeMIDIWindow(token: token)).count, 1)
        XCTAssertNil(engine.testOnly_drainTakeMIDIWindow(token: token), "duplicate drain is a no-op")
        XCTAssertFalse(
            engine.testOnly_releaseAbandonedTakeMIDIWindow(token: token),
            "abandoning an already-drained take is a no-op"
        )
        XCTAssertFalse(
            engine.testOnly_releaseAbandonedTakeMIDIWindow(token: token),
            "and stays a no-op however many times it is repeated"
        )

        drainMainQueue()
        XCTAssertEqual(
            published.count - replayCount, 1,
            "exactly one real take→idle transition may publish a release"
        )
    }

    /// Real publisher delivery, through the same shape the route uses: one
    /// matching release re-arms the preview exactly once; the subscription
    /// replay and every stale or duplicated release re-arm nothing.
    @MainActor
    func testOneRealReleaseCausesExactlyOnePreviewReArm() throws {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        addTeardownBlock { engine.endLiveMIDICaptureIfIdle() }

        // Identical to ReferenceAuthoringView's `.onReceive` handler: a
        // Published publisher replays its current value on subscribe, so the
        // first delivery is primed and never treated as a release.
        var reArmCount = 0
        var lastHandled: Int?
        var cancellables = Set<AnyCancellable>()
        engine.$midiCaptureWindowReleaseCount
            .sink { count in
                XCTAssertTrue(Thread.isMainThread)
                if ReferenceAuthoringView.handleMIDIWindowRelease(
                    count, lastHandled: &lastHandled, mode: .preview, captureEngine: engine
                ) { reArmCount += 1 }
            }
            .store(in: &cancellables)

        drainMainQueue()
        XCTAssertEqual(reArmCount, 0, "the subscription replay is not a release")

        let token = engine.testOnly_armTakeMIDIWindow()
        let start = CACurrentMediaTime()
        engine.testOnly_openTakeMIDIEpoch(at: start)
        engine.recordReceivedMIDICCEvent(
            sourceName: "Rane ONE MKII",
            channel: 1, controller: 6, value: 1, timestamp: start + 0.01
        )
        XCTAssertEqual(try XCTUnwrap(engine.testOnly_drainTakeMIDIWindow(token: token)).count, 1)

        // Stale and duplicated releases in the same window of time.
        XCTAssertNil(engine.testOnly_drainTakeMIDIWindow(token: token))
        XCTAssertFalse(engine.testOnly_releaseAbandonedTakeMIDIWindow(token: token))

        drainMainQueue()
        XCTAssertEqual(reArmCount, 1, "one matching release, one re-arm")
        XCTAssertEqual(
            engine.midiCaptureWindowTicket.owner, .preview,
            "and the re-arm actually reopened the preview window"
        )

        let rearmed = engine.midiCaptureWindowTicket
        XCTAssertFalse(ReferenceAuthoringView.handleMIDIWindowRelease(
            1, lastHandled: &lastHandled, mode: .preview, captureEngine: engine
        ))
        XCTAssertFalse(ReferenceAuthoringView.handleMIDIWindowRelease(
            0, lastHandled: &lastHandled, mode: .preview, captureEngine: engine
        ))
        XCTAssertEqual(engine.midiCaptureWindowTicket, rearmed)
        drainMainQueue()
        XCTAssertEqual(reArmCount, 1, "no further deliveries arrive later")
    }

    func testRealMIDIIngressPreviewTicketRetiresAcrossArmingAndMediaStart() {
        for opensEpoch in [false, true] {
            let engine = MacCaptureEngine(autoRefreshDevices: false)
            engine.beginLiveMIDICapture()
            var captured: MacCaptureEngine.MIDICaptureWindowTicket?
            pauseOneMIDIPacket(
                engine: engine,
                packet: { self.receiveRealCCPacket(engine) },
                observingTicket: { captured = $0 },
                whilePaused: {
                    engine.testOnly_armTakeMIDIWindow()
                    if opensEpoch { engine.testOnly_openTakeMIDIEpoch(at: CACurrentMediaTime()) }
                }
            )
            XCTAssertEqual(captured?.owner, .preview)
            XCTAssertTrue(engine.capturedMidiCCEventsSnapshot().isEmpty)
            XCTAssertEqual(engine.testOnly_midiEventsRejectedAsStale, 1)
        }
    }

    func testSameGenerationCannotOverrideTicketOwnerEpochOrTakeToken() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let token = engine.testOnly_armTakeMIDIWindow()
        let closed = engine.midiCaptureWindowTicket
        let now = CACurrentMediaTime()
        let forgedEpoch = MacCaptureEngine.MIDICaptureWindowTicket(
            owner: .take, generation: closed.generation,
            epochStartHostTime: now - 1, takeToken: token
        )
        engine.recordReceivedMIDICCEvent(
            sourceName: "Test", channel: 2, controller: 16, value: 1,
            timestamp: now, ingressTicket: forgedEpoch
        )
        XCTAssertTrue(engine.capturedMidiCCEventsSnapshot().isEmpty)
        engine.testOnly_openTakeMIDIEpoch(at: now)
        let opened = engine.midiCaptureWindowTicket
        for malformed in [
            MacCaptureEngine.MIDICaptureWindowTicket(
                owner: .preview, generation: opened.generation,
                epochStartHostTime: now, takeToken: token),
            MacCaptureEngine.MIDICaptureWindowTicket(
                owner: .take, generation: opened.generation,
                epochStartHostTime: now, takeToken: nil)
        ] {
            engine.recordReceivedMIDICCEvent(
                sourceName: "Test", channel: 2, controller: 16, value: 1,
                timestamp: now + 1, ingressTicket: malformed
            )
        }
        XCTAssertTrue(engine.capturedMidiCCEventsSnapshot().isEmpty)
        engine.recordReceivedMIDICCEvent(
            sourceName: "Test", channel: 2, controller: 16, value: 1,
            timestamp: now + 2, ingressTicket: opened
        )
        XCTAssertEqual(engine.capturedMidiCCEventsSnapshot().first?.takeRelativeTime, 2)
    }

    func testDelayedMediaCallbackCannotAcquireAnotherTakesToken() throws {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let urlA = URL(fileURLWithPath: "/tmp/midi-take-a.mov")
        let urlB = URL(fileURLWithPath: "/tmp/midi-take-b.mov")
        let a = try XCTUnwrap(engine.testOnly_tryArmTakeMIDIWindow(mediaURL: urlA))
        let delegateToken = try XCTUnwrap(engine.testOnly_midiTakeToken(for: urlA))
        XCTAssertEqual(delegateToken, a)
        engine.testOnly_releaseAbandonedTakeMIDIWindow(token: a)
        let b = try XCTUnwrap(engine.testOnly_tryArmTakeMIDIWindow(mediaURL: urlB))
        XCTAssertNil(engine.testOnly_midiTakeToken(for: urlA))
        XCTAssertEqual(engine.testOnly_midiTakeToken(for: urlB), b)
        XCTAssertNil(engine.testOnly_drainTakeMIDIWindow(token: delegateToken))
        XCTAssertFalse(engine.testOnly_releaseAbandonedTakeMIDIWindow(token: delegateToken))
        XCTAssertEqual(engine.midiCaptureWindowTicket.takeToken, b)
    }

    func testNoSidecarFinalizationReleasesOnlyItsCapturedTokenOnce() throws {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let url = URL(fileURLWithPath: "/tmp/midi-no-sidecar.mov")
        let token = try XCTUnwrap(engine.testOnly_tryArmTakeMIDIWindow(mediaURL: url))
        engine.testOnly_finalizeWithoutSidecar(mediaURL: url, token: token)
        engine.testOnly_finalizeWithoutSidecar(mediaURL: url, token: token)
        drainMainQueue()
        XCTAssertEqual(engine.midiCaptureWindowTicket.owner, .idle)
        XCTAssertEqual(engine.midiCaptureWindowReleaseCount, 1)
    }

    // MARK: - Bounded preview retention
    //
    // 15 seconds, the 32 000-event ceiling and the 2x trim multiplier are all
    // PROVISIONAL ENGINEERING POLICY, not hardware-calibrated truth. What is
    // pinned here is that BOTH bounds hold after every preview append, and that
    // neither is reachable from take evidence. The bounds are enforced on
    // append only: an idle buffer is not re-trimmed, but it is also not
    // growing, so it keeps satisfying the bounds it satisfied last. No idle
    // expiry is claimed.

    func testPreviewRetentionDropsOnlyEventsOlderThanTheTrailingWindow() {
        let events = (0..<60).map { index in
            Self.previewEvent(timestamp: Double(index))
        }
        let trimmed = MacCaptureEngine.trimmedLivePreviewEvents(
            events, now: 59, retentionSeconds: 15
        )
        XCTAssertEqual(trimmed.first?.timestamp, 44, "the window starts at now - retention")
        XCTAssertEqual(trimmed.last?.timestamp, 59, "the newest event is always kept")
        XCTAssertEqual(trimmed.count, 16)
    }

    func testPreviewRetentionKeepsEverythingInsideTheWindow() {
        let events = (0..<10).map { Self.previewEvent(timestamp: Double($0)) }
        let trimmed = MacCaptureEngine.trimmedLivePreviewEvents(
            events, now: 9, retentionSeconds: 15
        )
        XCTAssertEqual(trimmed.count, 10, "nothing has aged out yet")
    }

    /// The time bound alone bounds a SPAN, not memory: how many events fit in a
    /// span depends entirely on the controller's message rate, which this code
    /// does not measure. The count ceiling is the bound that holds regardless.
    func testPreviewRetentionAppliesTheEventCountCeiling() {
        // 500 events all inside the retention window — the time rule alone
        // would keep every one of them.
        let events = (0..<500).map { Self.previewEvent(timestamp: 100 + 0.001 * Double($0)) }
        XCTAssertTrue(
            MacCaptureEngine.livePreviewNeedsTrim(
                heldCount: events.count,
                oldestTimestamp: events.map(\.timestamp).min(),
                newestTimestamp: events.map(\.timestamp).max(),
                retentionSeconds: 15,
                maximumEventCount: 100
            ),
            "the count ceiling must trigger a trim on its own"
        )
        let trimmed = MacCaptureEngine.trimmedLivePreviewEvents(
            events, now: 100.5, retentionSeconds: 15, maximumEventCount: 100
        )
        XCTAssertEqual(trimmed.count, 100, "the ceiling is a hard cap")
        XCTAssertEqual(
            trimmed.last?.timestamp, events.last?.timestamp,
            "and it keeps the NEWEST events, not the oldest"
        )
    }

    /// Both bounds hold after a sustained stream, driven entirely by explicit
    /// timestamps.
    func testPreviewAccumulationStaysInsideBothBoundsUnderASustainedStream() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        engine.beginLiveMIDICapture()
        addTeardownBlock { engine.endLiveMIDICaptureIfIdle() }

        // 120 s of platter at 200 Hz — eight times the trim span.
        let base = CACurrentMediaTime()
        for index in 0..<24_000 {
            engine.recordReceivedMIDICCEvent(
                sourceName: "Rane ONE MKII",
                channel: 1, controller: 6, value: index % 128,
                timestamp: base + 0.005 * Double(index + 1)
            )
        }

        let held = engine.capturedMidiCCEventsSnapshot()
        XCTAssertFalse(held.isEmpty, "a bounded buffer is not an empty one")
        let span = (held.last?.timestamp ?? 0) - (held.first?.timestamp ?? 0)
        XCTAssertLessThanOrEqual(
            span,
            MacCaptureEngine.livePreviewRetentionSeconds
                * MacCaptureEngine.livePreviewTrimSpanMultiplier + 0.01,
            "the span bound must hold after every append"
        )
        XCTAssertLessThanOrEqual(
            held.count, MacCaptureEngine.livePreviewMaximumEventCount,
            "the count bound must hold after every append"
        )
        XCTAssertLessThan(
            held.count, 24_000,
            "an unbounded preview buffer is the defect these rules exist to prevent"
        )
    }

    /// Take evidence is NEVER trimmed, however long the take runs, because the
    /// trim is gated on lock-owned PREVIEW ownership which no take ever has.
    func testTakeEvidenceIsNeverTrimmedByThePreviewRetentionRule() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let token = engine.testOnly_armTakeMIDIWindow()
        let start = CACurrentMediaTime()
        engine.testOnly_openTakeMIDIEpoch(at: start)
        let count = 8_000
        for index in 0..<count {
            engine.recordReceivedMIDICCEvent(
                sourceName: "Rane ONE MKII",
                channel: 1, controller: 6, value: index % 128,
                timestamp: start + 0.01 * Double(index + 1)
            )
        }
        let held = engine.capturedMidiCCEventsSnapshot()
        XCTAssertEqual(
            held.count, count,
            "an 80-second take must keep every event; retention is preview-only"
        )
        XCTAssertEqual(held.first?.timestamp, start + 0.01, "the take's first event must survive")
        XCTAssertEqual(engine.testOnly_drainTakeMIDIWindow(token: token)?.count, count)
    }

    /// The retention rule must be unreachable for take evidence by
    /// construction, not merely unobserved above.
    func testRetentionIsGatedOnPreviewOwnershipAtTheAppendSite() throws {
        let source = try engineSource()
        let appendRange = try XCTUnwrap(
            source.range(of: "capturedMidiCCEvents.append(CaptureCore.RawMixerMIDIEvent(")
        )
        let body = String(source[appendRange.upperBound...].prefix(2000))
        XCTAssertTrue(
            body.contains("if midiWindowOwnerStorage == .preview,"),
            "the trim must be gated on lock-owned preview ownership"
        )
        XCTAssertTrue(
            body.contains("Self.livePreviewNeedsTrim("),
            "and must go through the pure, tested predicate"
        )
        XCTAssertTrue(
            body.contains("trimmedLivePreviewEvents("),
            "and the pure, tested trim"
        )
        // Both policy numbers must still be documented as provisional.
        for provisional in [
            "static let livePreviewRetentionSeconds",
            "static let livePreviewMaximumEventCount",
            "static let livePreviewTrimSpanMultiplier",
        ] {
            let range = try XCTUnwrap(source.range(of: provisional), "missing \(provisional)")
            let preamble = String(source[..<range.lowerBound].suffix(900))
            XCTAssertTrue(
                preamble.contains("PROVISIONAL"),
                "\(provisional) must be documented as provisional policy"
            )
        }
    }

    /// Out-of-order MIDI timestamps must still be bounded correctly. The
    /// oldest and newest held instants are running extremes, not the first and
    /// last array elements, so a late-arriving old packet cannot defeat the
    /// span rule and an early-arriving new one cannot evict a recent event.
    func testOutOfOrderPreviewTimestampsRemainCorrectlyBounded() {
        // Deliberately shuffled: the array's first element is NOT the oldest
        // and its last is NOT the newest.
        let events = [50.0, 10.0, 90.0, 30.0, 70.0].map { Self.previewEvent(timestamp: $0) }
        XCTAssertTrue(
            MacCaptureEngine.livePreviewNeedsTrim(
                heldCount: events.count,
                oldestTimestamp: events.map(\.timestamp).min(),
                newestTimestamp: events.map(\.timestamp).max(),
                retentionSeconds: 15,
                maximumEventCount: 1_000
            ),
            "a span of 80 s must trigger a trim even though first > last"
        )
        let trimmed = MacCaptureEngine.trimmedLivePreviewEvents(
            events, now: 90, retentionSeconds: 15, maximumEventCount: 1_000
        )
        XCTAssertEqual(
            Set(trimmed.map(\.timestamp)), [90.0],
            "the time rule must FILTER, not drop a prefix; only 90 is inside now - 15"
        )

        // The same through the production append path.
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        engine.beginLiveMIDICapture()
        addTeardownBlock { engine.endLiveMIDICaptureIfIdle() }
        let base = engine.midiCaptureWindowTicket.epochStartHostTime
        for offset in [1.0, 100.0, 2.0, 99.0, 3.0, 98.0] {
            engine.recordReceivedMIDICCEvent(
                sourceName: "Rane ONE MKII",
                channel: 1, controller: 6, value: 1,
                timestamp: base + offset
            )
        }
        let held = engine.capturedMidiCCEventsSnapshot()
        let oldest = try? XCTUnwrap(held.map(\.timestamp).min())
        let newest = try? XCTUnwrap(held.map(\.timestamp).max())
        XCTAssertLessThanOrEqual(
            (newest ?? 0) - (oldest ?? 0),
            MacCaptureEngine.livePreviewRetentionSeconds
                * MacCaptureEngine.livePreviewTrimSpanMultiplier + 0.01,
            "the span bound must hold under out-of-order arrival"
        )
        XCTAssertTrue(
            held.contains { $0.timestamp == base + 98 },
            "the most recent instants must survive, wherever they arrived in the sequence"
        )
    }

    /// The REAL configured ceiling, exercised through the production append
    /// path with more than 32,000 preview events.
    func testPreviewAppendCapsAtTheRealConfiguredEventCeiling() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        engine.beginLiveMIDICapture()
        addTeardownBlock { engine.endLiveMIDICaptureIfIdle() }

        let ceiling = MacCaptureEngine.livePreviewMaximumEventCount
        let base = engine.midiCaptureWindowTicket.epochStartHostTime
        // Tight spacing so the whole stream stays inside the retention window
        // and the COUNT rule is the only thing that can bite.
        let total = ceiling + 1_000
        for index in 0..<total {
            engine.recordReceivedMIDICCEvent(
                sourceName: "Rane ONE MKII",
                channel: 1, controller: 6, value: index % 128,
                timestamp: base + 0.0001 * Double(index + 1)
            )
            if index + 1 == ceiling {
                XCTAssertEqual(engine.capturedMidiCCEventsSnapshot().count, ceiling)
            }
            if index + 1 == ceiling + 1 {
                XCTAssertLessThanOrEqual(engine.capturedMidiCCEventsSnapshot().count, ceiling)
            }
        }

        let held = engine.capturedMidiCCEventsSnapshot()
        XCTAssertLessThanOrEqual(
            held.count, ceiling,
            "more than \(ceiling) preview events must cap at the configured ceiling"
        )
        XCTAssertGreaterThanOrEqual(
            held.count, MacCaptureEngine.livePreviewTrimTargetEventCount,
            "a trim reduces to the target watermark and no further"
        )
        XCTAssertLessThan(held.count, total, "and the buffer really was capped")
        XCTAssertEqual(
            held.last?.timestamp, base + 0.0001 * Double(total),
            "the newest arrival is always kept"
        )
    }

    /// A take exceeding the same ceiling is NOT trimmed, and drains whole.
    func testATakeLargerThanTheCeilingIsNeverTrimmedAndDrainsOnce() throws {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let token = engine.testOnly_armTakeMIDIWindow()
        let start = CACurrentMediaTime()
        engine.testOnly_openTakeMIDIEpoch(at: start)

        let count = MacCaptureEngine.livePreviewMaximumEventCount + 1_000
        for index in 0..<count {
            engine.recordReceivedMIDICCEvent(
                sourceName: "Rane ONE MKII",
                channel: 1, controller: 6, value: index % 128,
                timestamp: start + 0.0001 * Double(index + 1)
            )
        }
        XCTAssertEqual(
            engine.capturedMidiCCEventsSnapshot().count, count,
            "a take past the preview ceiling must keep every event"
        )
        let drained = try XCTUnwrap(engine.testOnly_drainTakeMIDIWindow(token: token))
        XCTAssertEqual(drained.count, count, "and drain whole")
        XCTAssertNil(engine.testOnly_drainTakeMIDIWindow(token: token), "exactly once")
    }

    // MARK: - Route lifecycle

    /// Leaving the route stops presentation work and closes only the window this
    /// route opened. It must NOT stop the shared engine: the camera session and
    /// capture ownership belong to the engine, and a take may still be running.
    func testRouteExitStopsPresentationWithoutStoppingSharedCaptureOwnership() throws {
        let source = try authoringViewSource()

        let disappearRange = try XCTUnwrap(
            source.range(of: ".onDisappear {"),
            "the route must still tear down on disappearance"
        )
        let body = String(source[disappearRange.upperBound...].prefix(900))
        XCTAssertTrue(
            body.contains("syncLiveNotationTracker(mode: .off)"),
            "leaving the route must drop the tracker and its poll timer"
        )
        // The engine is shared. Route exit may never stop it, stop the session,
        // stop recording, or reconfigure the camera.
        for forbidden in [
            "captureEngine.stop()",
            "captureEngine.stopRoutineRecording",
            "captureEngine.stopSession",
        ] {
            XCTAssertFalse(
                source.contains(forbidden),
                "route exit must not take capture ownership away: found \(forbidden)"
            )
        }
        // The ONLY engine state the route lifecycle touches is the preview
        // window, through the two ownership-guarded accessors.
        XCTAssertTrue(source.contains("captureEngine.endLiveMIDICaptureIfIdle()"))
        XCTAssertTrue(source.contains("captureEngine.beginLiveMIDICapture()"))
        // And starting the engine remains the route's single existing call.
        XCTAssertEqual(
            source.components(separatedBy: "captureEngine.start()").count - 1, 1,
            "the route keeps exactly one engine start, unchanged by this repair"
        )
    }

    /// Repeated and restored entry must not stack trackers or windows. The mode
    /// guard makes every redundant sync a no-op, and the engine claims the
    /// window only from `.idle`, so a second open is a no-op too.
    @MainActor
    func testRepeatedRouteEntryCreatesNoDuplicateTrackerOrWindow() throws {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        var mode: ReferenceAuthoringView.LiveNotationMode = .off
        var tracker: LivePerformedNotationTracker?
        func sync(_ next: ReferenceAuthoringView.LiveNotationMode) {
            ReferenceAuthoringView.syncLiveNotationTracker(
                mode: next, liveNotationMode: &mode,
                liveNotationTracker: &tracker, captureEngine: engine
            )
        }
        sync(.preview) // Entry, including restored entry without a phase change.
        let first = try XCTUnwrap(tracker)
        let opened = engine.midiCaptureWindowTicket
        sync(.preview)
        XCTAssertTrue(tracker === first)
        XCTAssertEqual(engine.midiCaptureWindowTicket, opened)
        sync(.off)
        XCTAssertNil(tracker)
        XCTAssertEqual(engine.midiCaptureWindowTicket.owner, .idle)
        sync(.preview) // Re-entry has exactly one fresh tracker and window.
        let second = try XCTUnwrap(tracker)
        XCTAssertFalse(second === first)
        let reopened = engine.midiCaptureWindowTicket
        sync(.preview)
        XCTAssertTrue(tracker === second)
        XCTAssertEqual(engine.midiCaptureWindowTicket, reopened)
        let token = engine.testOnly_armTakeMIDIWindow()
        sync(.take)
        XCTAssertFalse(tracker === second)
        let takeTracker = try XCTUnwrap(tracker)
        sync(.take)
        XCTAssertTrue(tracker === takeTracker)
        sync(.off)
        XCTAssertNil(tracker)
        XCTAssertEqual(engine.midiCaptureWindowTicket.takeToken, token)
        engine.testOnly_releaseAbandonedTakeMIDIWindow(token: token)
        sync(.preview)
        sync(.off)
    }

    /// Restored navigation resolves the mode explicitly rather than relying on a
    /// transition that already happened, which is what made a restored route
    /// show a blank lane.
    func testRestoredRouteEntryResolvesTheModeExplicitly() throws {
        let source = try authoringViewSource()
        let taskRange = try XCTUnwrap(source.range(of: ".task {"))
        let body = String(source[taskRange.upperBound...].prefix(1400))
        XCTAssertTrue(
            body.contains("syncLiveNotationTracker(mode: resolvedLiveNotationMode)"),
            "entry and restoration must resolve the mode, not wait for a transition"
        )
        XCTAssertTrue(
            body.contains("activateCaptureInput()"),
            "the existing restored-route engine start must be preserved"
        )
    }

    /// Finalized review notation is untouched by this repair: it still projects
    /// through the same builder, and the preview never reaches it.
    func testFinalizedNotationBehaviourIsUnchanged() throws {
        let source = try authoringViewSource()
        XCTAssertTrue(
            source.contains("ReferenceTearCanonicalProjectionBuilder.project(review)"),
            "the finalized review must still project through the shared builder"
        )
        XCTAssertTrue(
            source.contains("movementEvents: liveNotationTracker.continuousRenderedEvents"),
            "and the live lane through the same one"
        )
        XCTAssertTrue(
            source.contains("coordinates: liveNotationTracker.continuousPlatterCoordinates"),
            "the live boundary must still declare its coordinate basis"
        )
        // No second engine, decoder, model or renderer was introduced.
        XCTAssertEqual(
            source.components(separatedBy: "MacCaptureEngine(").count - 1, 0,
            "the route must keep using the injected engine, never build one"
        )
        XCTAssertFalse(source.contains("ScratchMotionRenderer"))
        XCTAssertFalse(source.contains("Path {"))
    }

    /// The idle copy must describe the pre-record preview truthfully, and must
    /// not imply it is recorded or saved.
    func testIdleCopyDoesNotClaimTheLaneWaitsForARecording() throws {
        let source = try authoringViewSource()
        XCTAssertFalse(
            source.contains("Live motion appears here while a take is recording."),
            "the lane no longer waits for a take, so that copy is now false"
        )
        XCTAssertTrue(
            source.contains("Live motion appears here while this screen is open."),
            "the copy must describe the route-scoped preview"
        )
        for overclaim in ["recorded", "saved", "captured evidence"] {
            XCTAssertFalse(
                source.contains("Live motion appears here while this screen is open. \(overclaim)"),
                "preview copy must not imply the preview is saved evidence"
            )
        }
    }

    // MARK: - Pre-record preview helpers

    /// One-shot latch so the append seam pauses exactly ONE packet, however
    /// many packets the interleaving under test happens to generate.
    private final class OneShotSeamLatch {
        private let lock = NSLock()
        private var hasFired = false
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if hasFired { return false }
            hasFired = true
            return true
        }
    }

    /// Runs `packet` on a background thread and blocks it inside the engine's
    /// append seam — after it has taken its window ticket and BEFORE it
    /// appends — while `transition` runs on the test thread. Then releases it
    /// and waits for it to finish.
    ///
    /// The seam is invoked with `midiCaptureLock` NOT held, so `transition` can
    /// take the lock freely. Every wait is bounded; nothing sleeps.
    private func pauseOneMIDIPacket(
        engine: MacCaptureEngine,
        packet: @escaping () -> Void,
        observingTicket: ((MacCaptureEngine.MIDICaptureWindowTicket) -> Void)? = nil,
        whilePaused transition: () -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let latch = OneShotSeamLatch()
        let reachedSeam = DispatchSemaphore(value: 0)
        let mayResume = DispatchSemaphore(value: 0)
        engine.testOnly_setMIDIAppendInterleavingHook { ticket in
            guard latch.claim() else { return }
            observingTicket?(ticket)
            reachedSeam.signal()
            XCTAssertEqual(
                mayResume.wait(timeout: .now() + 5), .success,
                "seam release timed out", file: file, line: line
            )
        }
        let finished = expectation(description: "paused MIDI packet completed")
        DispatchQueue.global(qos: .userInitiated).async {
            packet()
            finished.fulfill()
        }
        XCTAssertEqual(
            reachedSeam.wait(timeout: .now() + 5), .success,
            "the packet never reached the append seam", file: file, line: line
        )
        transition()
        mayResume.signal()
        wait(for: [finished], timeout: 5)
        engine.testOnly_setMIDIAppendInterleavingHook(nil)
    }

    private func receiveRealCCPacket(_ engine: MacCaptureEngine) {
        var list = MIDIPacketList()
        withUnsafeMutablePointer(to: &list) { pointer in
            let first = MIDIPacketListInit(pointer)
            let bytes: [UInt8] = [0xB2, 16, 40]
            bytes.withUnsafeBufferPointer { buffer in
                XCTAssertNotNil(MIDIPacketListAdd(
                    pointer, MemoryLayout<MIDIPacketList>.size, first,
                    0, buffer.count, buffer.baseAddress!
                ))
            }
            engine.testOnly_receiveMIDIPacketList(pointer)
        }
    }

    /// Runs the main queue until everything already enqueued has executed.
    /// Bounded; no sleeping.
    private func drainMainQueue(file: StaticString = #filePath, line: UInt = #line) {
        let settled = expectation(description: "main queue drained")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 5)
    }

    private func engineSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ScratchLabDesktop/Services/MacCaptureEngine.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func previewEvent(timestamp: Double) -> CaptureCore.RawMixerMIDIEvent {
        CaptureCore.RawMixerMIDIEvent(
            timestamp: timestamp,
            takeRelativeTime: timestamp,
            deviceName: "Rane ONE MKII",
            channel: 1,
            controller: 6,
            value: 64,
            normalizedValue: 0.5,
            mappedControl: nil,
            calibratedPosition: nil,
            calibrationID: nil
        )
    }
}
