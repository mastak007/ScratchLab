// Tests for LiveNotationOverlayModel: cursor position, windowing, silence guard,
// future-note suppression in captured mode, proportional travel preservation,
// and forward/back direction distinction.
//
// Pure model tests — no SwiftUI, no Canvas, no GraphicsContext.

import XCTest
@testable import ScratchLab

final class LiveNotationOverlayTests: XCTestCase {

    // MARK: - Helpers

    private func makeEvent(
        startTime: Double,
        endTime: Double,
        startPosition: Double = 0.0,
        endPosition: Double = 1.0,
        direction: String = "forward",
        confidence: Double = 0.8
    ) -> CaptureCore.DetectedNotationRecordMovementEvent {
        CaptureCore.DetectedNotationRecordMovementEvent(
            startTime: startTime, endTime: endTime,
            startPosition: startPosition, endPosition: endPosition,
            direction: direction, movementKind: .normalPush,
            speed: 0.5, confidence: confidence, source: "detected"
        )
    }

    private func makeCapturedModel(
        events: [CaptureCore.DetectedNotationRecordMovementEvent],
        duration: Double
    ) -> LiveNotationOverlayModel {
        LiveNotationOverlayModel(events: events, duration: duration, mode: .captured)
    }

    // MARK: - Cursor advances monotonically

    func testLiveNotationCursorAdvancesWithCurrentTime() {
        let model = makeCapturedModel(
            events: [makeEvent(startTime: 0.0, endTime: 0.5)],
            duration: 2.0
        )
        let f0 = model.cursorFraction(at: 0.0)
        let f1 = model.cursorFraction(at: 1.0)
        let f2 = model.cursorFraction(at: 2.0)

        XCTAssertEqual(f0, 0.0, accuracy: 1e-9)
        XCTAssertEqual(f1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(f2, 1.0, accuracy: 1e-9)
        XCTAssertLessThan(f0, f1, "Cursor must advance as time increases")
        XCTAssertLessThan(f1, f2, "Cursor must advance as time increases")
    }

    // MARK: - Cursor clamping

    func testLiveNotationCursorClampsAtPhraseBounds() {
        let model = makeCapturedModel(
            events: [makeEvent(startTime: 0.0, endTime: 0.5)],
            duration: 2.0
        )
        XCTAssertEqual(model.cursorFraction(at: -1.0), 0.0, accuracy: 1e-9,
                       "Cursor must clamp to 0 before phrase start")
        XCTAssertEqual(model.cursorFraction(at: -99.0), 0.0, accuracy: 1e-9,
                       "Large negative time must still clamp to 0")
        XCTAssertEqual(model.cursorFraction(at: 5.0), 1.0, accuracy: 1e-9,
                       "Cursor must clamp to 1 after phrase end")
        XCTAssertEqual(model.cursorFraction(at: 0.0), 0.0, accuracy: 1e-9,
                       "Cursor at exact start must be 0")
        XCTAssertEqual(model.cursorFraction(at: 2.0), 1.0, accuracy: 1e-9,
                       "Cursor at exact end must be 1")
    }

    // MARK: - Proportional travel

    func testLiveNotationPreservesProportionalStrokeTravel() {
        let fullEvent    = makeEvent(startTime: 0.0, endTime: 0.3,
                                     startPosition: 0.0, endPosition: 1.0)
        let halfEvent    = makeEvent(startTime: 0.5, endTime: 0.8,
                                     startPosition: 0.0, endPosition: 0.5)
        let quarterEvent = makeEvent(startTime: 1.0, endTime: 1.3,
                                     startPosition: 0.0, endPosition: 0.25)
        let model = makeCapturedModel(
            events: [fullEvent, halfEvent, quarterEvent],
            duration: 2.0
        )

        let visible = model.visibleEvents(at: 2.0)
        XCTAssertEqual(visible.count, 3, "All three strokes must be visible at end of phrase")

        let fractions = visible.map { CapturedNotationStrokeGeometry.travelFraction(for: $0) }
        XCTAssertEqual(fractions[0], 1.0,  accuracy: 1e-6, "Full-travel stroke must yield fraction 1.0")
        XCTAssertEqual(fractions[1], 0.5,  accuracy: 1e-6, "Half-travel stroke must yield fraction 0.5")
        XCTAssertEqual(fractions[2], 0.25, accuracy: 1e-6, "Quarter-travel stroke must yield fraction 0.25")
        XCTAssertGreaterThan(fractions[0], fractions[1], "Full must exceed half")
        XCTAssertGreaterThan(fractions[1], fractions[2], "Half must exceed quarter")
    }

    // MARK: - Silence stays empty

    func testLiveNotationKeepsSilenceEmpty() {
        let idleEvent = makeEvent(startTime: 0.0, endTime: 0.5,
                                   startPosition: 0.3, endPosition: 0.3)
        let model = makeCapturedModel(events: [idleEvent], duration: 2.0)

        XCTAssertEqual(
            model.visibleEvents(at: 2.0).count,
            0,
            "Zero-travel event must be suppressed — silence must produce no overlay strokes"
        )
        XCTAssertFalse(
            model.hasMeaningfulStrokes(at: 2.0),
            "hasMeaningfulStrokes must be false when all events have zero travel"
        )
    }

    // MARK: - Direction distinction

    func testLiveNotationDistinguishesForwardAndBackStrokes() {
        let fwdEvent  = makeEvent(startTime: 0.0, endTime: 0.4,
                                   startPosition: 0.1, endPosition: 0.9,
                                   direction: "forward")
        let backEvent = makeEvent(startTime: 0.5, endTime: 0.9,
                                   startPosition: 0.9, endPosition: 0.1,
                                   direction: "backward")
        let model = makeCapturedModel(events: [fwdEvent, backEvent], duration: 2.0)

        let visible = model.visibleEvents(at: 2.0)
        XCTAssertEqual(visible.count, 2)

        let directions = Set(visible.map { $0.direction })
        XCTAssertTrue(directions.contains("forward"),  "Forward stroke must be in visible set")
        XCTAssertTrue(directions.contains("backward"), "Backward stroke must be in visible set")

        // Same 0.8-unit travel in both — direction is the sole distinguishing factor.
        let fwdFraction  = CapturedNotationStrokeGeometry.travelFraction(
            for: visible.first(where: { $0.direction == "forward" })!
        )
        let backFraction = CapturedNotationStrokeGeometry.travelFraction(
            for: visible.first(where: { $0.direction == "backward" })!
        )
        XCTAssertEqual(fwdFraction, backFraction, accuracy: 1e-6,
                       "Equal travel must produce equal fractions — direction is tag only")
    }

    // MARK: - Future notes suppression

    func testCapturedOverlayDoesNotRevealFuturePerformanceNotes() {
        let events = [
            makeEvent(startTime: 0.2, endTime: 0.4,
                      startPosition: 0.0, endPosition: 0.8),
            makeEvent(startTime: 0.6, endTime: 0.8,
                      startPosition: 0.2, endPosition: 0.9),
            makeEvent(startTime: 1.2, endTime: 1.5,
                      startPosition: 0.1, endPosition: 0.7),
        ]
        let captured = makeCapturedModel(events: events, duration: 2.0)

        // Before the first stroke.
        XCTAssertEqual(
            captured.visibleEvents(at: 0.1).count, 0,
            "No strokes visible before the first startTime"
        )

        // After first stroke starts but before second.
        let at05 = captured.visibleEvents(at: 0.5)
        XCTAssertEqual(at05.count, 1,
                       "Only the first stroke must be revealed at currentTime 0.5")
        XCTAssertEqual(at05.first?.startTime ?? -1.0, 0.2, accuracy: 1e-9)

        // After second stroke starts but before third.
        let at09 = captured.visibleEvents(at: 0.9)
        XCTAssertEqual(at09.count, 2,
                       "First two strokes visible at currentTime 0.9")

        // After all strokes.
        let at20 = captured.visibleEvents(at: 2.0)
        XCTAssertEqual(at20.count, 3,
                       "All three strokes visible at end of phrase")

        // Target/coach mode must reveal all strokes regardless of currentTime.
        let target = LiveNotationOverlayModel(events: events, duration: 2.0, mode: .target)
        XCTAssertEqual(
            target.visibleEvents(at: 0.0).count, 3,
            "Target/coach mode must show all strokes at time 0 — coach display is instructional"
        )
        XCTAssertEqual(
            target.visibleEvents(at: 0.1).count, 3,
            "Target/coach mode must show all strokes at any time before first stroke"
        )
    }

    // MARK: - Performer display slice tests

    /// Replicates the model-construction path used by
    /// `PerformerNotationDisplayView.init(snapshot:)`.
    private func makePerformerModel(
        from snapshot: CaptureCore.DetectedNotationSnapshot
    ) -> LiveNotationOverlayModel? {
        guard !snapshot.recordMovementEvents.isEmpty else { return nil }
        let duration = max(snapshot.capturedEvidenceEndTime ?? 0, 0.1)
        return LiveNotationOverlayModel(
            events: snapshot.recordMovementEvents,
            duration: duration,
            mode: .captured
        )
    }

    private func makePerformerSnapshot(
        events: [CaptureCore.DetectedNotationRecordMovementEvent],
        extraDuration: Double? = nil
    ) -> CaptureCore.DetectedNotationSnapshot {
        var audioEvents: [CaptureCore.DetectedNotationAudioEvent] = []
        if let extra = extraDuration {
            let movementMax = events.map(\.endTime).max() ?? 0
            if extra > movementMax {
                audioEvents.append(CaptureCore.DetectedNotationAudioEvent(
                    startTime: extra - 0.01,
                    endTime: extra,
                    duration: 0.01,
                    peakLevel: 0.5,
                    rmsLevel: 0.3,
                    confidence: 0.8,
                    eventKind: "onset",
                    source: "test"
                ))
            }
        }
        return CaptureCore.DetectedNotationSnapshot(
            notationSource: "detected",
            notationConfidence: nil,
            detectedLabel: nil,
            labelSource: "",
            labelConfidence: nil,
            detectionSources: ["test"],
            recordMovementEvents: events,
            audioEvents: audioEvents,
            faderEvents: [],
            mixerMidiEvents: [],
            capturedAt: Date()
        )
    }

    func testPerformerDisplayBuildsOverlayFromCapturedNotation() {
        let events = [
            makeEvent(startTime: 0.0, endTime: 0.4,
                      startPosition: 0.0, endPosition: 1.0),
            makeEvent(startTime: 0.5, endTime: 0.9,
                      startPosition: 0.0, endPosition: 0.6),
        ]
        let snapshot = makePerformerSnapshot(events: events)

        let model = makePerformerModel(from: snapshot)
        XCTAssertNotNil(model,
                        "Performer model must build from a snapshot with events")
        XCTAssertEqual(model?.events.count, 2,
                       "Model must contain the same events as the snapshot")
        XCTAssertEqual(model?.mode, .captured,
                       "Performer display must use .captured mode")
        XCTAssertGreaterThan(model?.duration ?? 0, 0,
                             "Duration must be positive when events exist")
    }

    func testPerformerDisplayPreservesProportionalTravel() {
        let fullEvent = makeEvent(startTime: 0.0, endTime: 0.3,
                                   startPosition: 0.0, endPosition: 1.0)
        let halfEvent = makeEvent(startTime: 0.5, endTime: 0.8,
                                   startPosition: 0.0, endPosition: 0.5)
        let quarterEvent = makeEvent(startTime: 1.0, endTime: 1.3,
                                      startPosition: 0.0, endPosition: 0.25)
        let snapshot = makePerformerSnapshot(
            events: [fullEvent, halfEvent, quarterEvent]
        )

        guard let model = makePerformerModel(from: snapshot) else {
            XCTFail("Performer model must build from valid snapshot")
            return
        }

        let visible = model.visibleEvents(at: model.duration)
        XCTAssertEqual(visible.count, 3,
                       "All strokes must be visible at end of phrase")

        let fractions = visible.map {
            CapturedNotationStrokeGeometry.travelFraction(for: $0)
        }
        XCTAssertEqual(fractions[0], 1.0,  accuracy: 1e-6)
        XCTAssertEqual(fractions[1], 0.5,  accuracy: 1e-6)
        XCTAssertEqual(fractions[2], 0.25, accuracy: 1e-6)
    }

    func testPerformerDisplayKeepsSilenceEmpty() {
        let idleEvent = makeEvent(startTime: 0.0, endTime: 0.5,
                                   startPosition: 0.3, endPosition: 0.3)
        let snapshot = makePerformerSnapshot(events: [idleEvent])

        guard let model = makePerformerModel(from: snapshot) else {
            XCTFail("Performer model must build even with zero-travel events " +
                    "(suppression happens at display time)")
            return
        }

        XCTAssertEqual(
            model.visibleEvents(at: model.duration).count, 0,
            "Zero-travel event must be suppressed"
        )
        XCTAssertFalse(
            model.hasMeaningfulStrokes(at: model.duration),
            "hasMeaningfulStrokes must be false for zero-travel events"
        )
    }

    func testPerformerDisplayCursorClampsToBounds() {
        let events = [
            makeEvent(startTime: 0.2, endTime: 0.6,
                      startPosition: 0.0, endPosition: 1.0)
        ]
        let snapshot = makePerformerSnapshot(
            events: events,
            extraDuration: 2.0
        )

        guard let model = makePerformerModel(from: snapshot) else {
            XCTFail("Performer model must build from valid snapshot")
            return
        }

        XCTAssertEqual(model.cursorFraction(at: -1.0), 0.0, accuracy: 1e-9)
        XCTAssertEqual(model.cursorFraction(at: -99.0), 0.0, accuracy: 1e-9)
        XCTAssertEqual(model.cursorFraction(at: 5.0), 1.0, accuracy: 1e-9)
        XCTAssertEqual(model.cursorFraction(at: 0.0), 0.0, accuracy: 1e-9)
        XCTAssertEqual(model.cursorFraction(at: 2.0), 1.0, accuracy: 1e-9)
    }

    func testPerformerDisplayHandlesEmptyNotation() {
        // Nil snapshot path.
        let modelFromNil: LiveNotationOverlayModel? = {
            let snapshot: CaptureCore.DetectedNotationSnapshot? = nil
            guard let snapshot,
                  !snapshot.recordMovementEvents.isEmpty else {
                return nil
            }
            let duration = max(snapshot.capturedEvidenceEndTime ?? 0, 0.1)
            return LiveNotationOverlayModel(
                events: snapshot.recordMovementEvents,
                duration: duration,
                mode: .captured
            )
        }()
        XCTAssertNil(modelFromNil,
                     "Nil snapshot must produce nil performer model (empty state)")

        // Empty events path.
        let emptySnapshot = makePerformerSnapshot(events: [])
        let modelFromEmpty = makePerformerModel(from: emptySnapshot)
        XCTAssertNil(modelFromEmpty,
                     "Empty-events snapshot must produce nil performer model")
    }

    func testPerformerDisplayDoesNotRevealFutureNotes() {
        let events = [
            makeEvent(startTime: 0.2, endTime: 0.4,
                      startPosition: 0.0, endPosition: 0.8),
            makeEvent(startTime: 0.6, endTime: 0.8,
                      startPosition: 0.2, endPosition: 0.9),
            makeEvent(startTime: 1.2, endTime: 1.5,
                      startPosition: 0.1, endPosition: 0.7),
        ]
        let snapshot = makePerformerSnapshot(events: events)

        guard let model = makePerformerModel(from: snapshot) else {
            XCTFail("Performer model must build from valid snapshot")
            return
        }

        // Before first stroke — nothing visible.
        XCTAssertEqual(model.visibleEvents(at: 0.1).count, 0)

        // After first stroke starts but before second.
        let at05 = model.visibleEvents(at: 0.5)
        XCTAssertEqual(at05.count, 1)
        XCTAssertEqual(at05.first?.startTime ?? -1, 0.2, accuracy: 1e-9)

        // After second stroke starts but before third.
        let at09 = model.visibleEvents(at: 0.9)
        XCTAssertEqual(at09.count, 2)

        // At end — all three visible.
        let atEnd = model.visibleEvents(at: model.duration)
        XCTAssertEqual(atEnd.count, 3)

        // Verify the third stroke (future at time 0.5) is NOT visible early.
        let thirdStrokes = at05.filter { $0.startTime > 1.0 }
        XCTAssertTrue(thirdStrokes.isEmpty,
                      "Future strokes must not leak into early visible set")
    }

    // MARK: - babyScratchDemo factory

    /// The test bundle is not the main app bundle, so `Bundle.main` (the
    /// default for the `static let`) won't find the resource. Tests call
    /// `babyScratchDemoFromExtractedStrokes(appBundle)` with the actual
    /// app bundle to exercise the factory logic against the shipped data.
    private var appBundle: Bundle {
        // The macOS test host layout:
        //   ScratchLab.app/Contents/PlugIns/ScratchLabDesktopTests.xctest
        // Walk up 3 components to reach ScratchLab.app.
        let testBundleURL = Bundle(for: type(of: self)).bundleURL
        let appURL = testBundleURL
            .deletingLastPathComponent()  // PlugIns
            .deletingLastPathComponent()  // Contents
            .deletingLastPathComponent()  // ScratchLab.app
        return Bundle(url: appURL) ?? Bundle(for: type(of: self))
    }

    func testBabyScratchDemoFactoryProducesNonNilNotation() {
        let demo = ScratchNotation.babyScratchDemoFromExtractedStrokes(appBundle)
        XCTAssertNotNil(demo, "babyScratchDemo factory must produce non-nil notation from the app bundle")
    }

    func testBabyScratchDemoHasExactly32Strokes() throws {
        let demo = try XCTUnwrap(ScratchNotation.babyScratchDemoFromExtractedStrokes(appBundle))
        XCTAssertEqual(demo.strokes.count, 32,
                       "Live demo must contain the selected 16 forward/backward cycles")
        XCTAssertEqual(demo.strokes.count, demo.strokeSegments.count)
    }

    func testBabyScratchDemoHasMoreStrokesThanDeterministicTemplate() throws {
        let demo = try XCTUnwrap(ScratchNotation.babyScratchDemoFromExtractedStrokes(appBundle))
        let template = try XCTUnwrap(ScratchNotation.loadBabyScratchFromBundle(appBundle))
        XCTAssertGreaterThan(demo.strokes.count, template.strokes.count,
                             "Full-demo notation (\(demo.strokes.count) strokes) must exceed deterministic template (\(template.strokes.count) strokes)")
        XCTAssertEqual(template.strokes.count, 12,
                       "Deterministic authored template must have 12 strokes")
    }

    func testBabyScratchDemoTimelineDurationMatchesSelectedTake() throws {
        let demo = try XCTUnwrap(ScratchNotation.babyScratchDemoFromExtractedStrokes(appBundle))
        XCTAssertEqual(demo.timelineDuration, 14.048311, accuracy: 0.001,
                       "Movement timeline must match the live take, got \(demo.timelineDuration)")
        let phraseEnd = try XCTUnwrap(demo.phraseEnd)
        XCTAssertEqual(demo.timelineDuration, phraseEnd, accuracy: 0.1,
                       "timelineDuration must match phraseEnd")
    }

    func testBabyScratchDemoMetadataPreserved() throws {
        let demo = try XCTUnwrap(ScratchNotation.babyScratchDemoFromExtractedStrokes(appBundle))
        XCTAssertEqual(demo.scratchID, "baby")
        XCTAssertEqual(demo.demoStart, 0.0, accuracy: 0.0001)
        XCTAssertEqual(demo.demoEnd, 16.0483125, accuracy: 0.001)
        let phraseStart = try XCTUnwrap(demo.phraseStart)
        XCTAssertEqual(phraseStart, 2.0, accuracy: 0.001)
        XCTAssertEqual(demo.timingBasis, "extracted_strokes_full_demo")
    }

    func testBabyScratchDemoStrokesSpanFullDemoRange() throws {
        let demo = try XCTUnwrap(ScratchNotation.babyScratchDemoFromExtractedStrokes(appBundle))
        let first = try XCTUnwrap(demo.strokes.first)
        let last = try XCTUnwrap(demo.strokes.last)
        XCTAssertGreaterThanOrEqual(first.startTime, 0.0)
        XCTAssertEqual(first.startTime, 2.0, accuracy: 0.001,
                       "First stroke must start after the two-second lead-in")
        XCTAssertLessThan(first.endTime, 3.0,
                          "First stroke should end early in the demo")
        XCTAssertGreaterThan(last.endTime, 14.0,
                             "Last stroke should end before the two-second tail")
        XCTAssertEqual(last.endTime, 14.048311, accuracy: 0.001,
                       "Last stroke end time must match phraseEnd")
        XCTAssertLessThanOrEqual(last.endTime, demo.timelineDuration + 0.01)
    }

    func testBabyScratchDemoStrokesAllHaveMediumSpeedAndOpenFader() throws {
        let demo = try XCTUnwrap(ScratchNotation.babyScratchDemoFromExtractedStrokes(appBundle))
        for stroke in demo.strokes {
            XCTAssertEqual(stroke.speedClassification, .medium,
                           "All extracted demo strokes must default to .medium speed")
            XCTAssertEqual(stroke.faderState, .open,
                           "All Baby Scratch strokes must be fader-open")
        }
    }

    func testBabyScratchDemoContainsBothDirections() throws {
        let demo = try XCTUnwrap(ScratchNotation.babyScratchDemoFromExtractedStrokes(appBundle))
        let directions = Set(demo.strokes.map(\.direction))
        XCTAssertTrue(directions.contains(.forward),
                      "Full-demo strokes must include at least one forward stroke")
        XCTAssertTrue(directions.contains(.backward),
                      "Full-demo strokes must include at least one backward stroke")
        XCTAssertEqual(directions.count, 2,
                       "Full-demo strokes must have exactly two distinct directions")
    }

    func testBabyScratchDemoStrokesHaveValidDirections() throws {
        let demo = try XCTUnwrap(ScratchNotation.babyScratchDemoFromExtractedStrokes(appBundle))
        for stroke in demo.strokes {
            XCTAssertTrue(
                stroke.direction == .forward || stroke.direction == .backward,
                "Every demo stroke must have a valid direction, got \(stroke.direction)"
            )
            XCTAssertGreaterThan(stroke.endTime, stroke.startTime,
                                 "Every demo stroke must have positive duration")
        }
    }

    func testBabyScratchDemoTargetNotationModelIsNotEmpty() throws {
        let notation = try XCTUnwrap(ScratchNotation.babyScratchDemoFromExtractedStrokes(appBundle))
        let model = LiveNotationOverlayModel.targetNotation(from: notation)
        XCTAssertFalse(model.isEmpty)
        XCTAssertEqual(model.mode, .target)
        XCTAssertEqual(model.duration, notation.timelineDuration, accuracy: 0.001,
                       "Overlay model duration must cover the complete movement phrase")
        XCTAssertEqual(model.events.count, notation.strokes.count)
    }

    // MARK: - replayNotation factory

    func testReplayNotationModelIsNotEmpty() throws {
        let notation = try XCTUnwrap(ScratchNotation.babyScratchDemoFromExtractedStrokes(appBundle))
        let model = LiveNotationOverlayModel.replayNotation(from: notation)
        XCTAssertFalse(model.isEmpty)
        XCTAssertEqual(model.mode, .captured)
        XCTAssertEqual(model.duration, notation.timelineDuration, accuracy: 0.001)
        XCTAssertEqual(model.events.count, 32)
    }

    func testReplayNotationEventsHaveVaryingAmplitude() throws {
        let notation = try XCTUnwrap(ScratchNotation.babyScratchDemoFromExtractedStrokes(appBundle))
        let model = LiveNotationOverlayModel.replayNotation(from: notation)
        let fractions = model.events.map {
            CapturedNotationStrokeGeometry.travelFraction(for: $0)
        }
        let uniqueFractions = Set(fractions.map { Int(($0 * 100).rounded()) })
        XCTAssertGreaterThan(uniqueFractions.count, 1,
                             "Replay notation strokes must have varying amplitudes, got \(uniqueFractions.count) unique values")
        XCTAssertGreaterThan(fractions.max() ?? 0, 0.8,
                             "Longest stroke should reach near full amplitude")
        XCTAssertLessThan(fractions.min() ?? 1, fractions.max() ?? 0,
                          "Shortest live stroke should be visibly smaller than the longest")
    }

    func testReplayNotationHidesFutureStrokes() throws {
        let notation = try XCTUnwrap(ScratchNotation.babyScratchDemoFromExtractedStrokes(appBundle))
        let model = LiveNotationOverlayModel.replayNotation(from: notation)
        // The demo has a two-second silent lead-in before its first stroke.
        let atStart = model.visibleEvents(at: 0.0)
        XCTAssertEqual(atStart.count, 0, "No strokes should be visible before the first stroke starts")
        let duringLeadIn = model.visibleEvents(at: 1.0)
        XCTAssertEqual(duringLeadIn.count, 0, "Lead-in must remain visually empty")
        let afterFirstStroke = model.visibleEvents(at: 2.5)
        XCTAssertGreaterThan(afterFirstStroke.count, 0, "The first stroke should be visible after 2.5s")
        XCTAssertLessThan(afterFirstStroke.count, 10,
                          "Only early strokes should be visible after 2.5s, not all 32")
        // All strokes visible at end.
        let atEnd = model.visibleEvents(at: model.duration)
        XCTAssertEqual(atEnd.count, 32, "All 32 strokes must be visible at the end")
    }

    func testReplayNotationShortestStrokeHasAtLeastFloorAmplitude() throws {
        let notation = try XCTUnwrap(ScratchNotation.babyScratchDemoFromExtractedStrokes(appBundle))
        let model = LiveNotationOverlayModel.replayNotation(from: notation)
        for event in model.events {
            let fraction = CapturedNotationStrokeGeometry.travelFraction(for: event)
            XCTAssertGreaterThanOrEqual(fraction, 0.14,
                                        "Every replay stroke must have at least floor amplitude (~0.15)")
        }
    }

    func testTargetNotationBackwardCompatible() throws {
        let notation = try XCTUnwrap(ScratchNotation.babyScratchDemoFromExtractedStrokes(appBundle))
        let targetModel = LiveNotationOverlayModel.targetNotation(from: notation)
        XCTAssertEqual(targetModel.mode, .target)
        // targetNotation should still use fixed 0.5 amplitude.
        let fractions = targetModel.events.map {
            CapturedNotationStrokeGeometry.travelFraction(for: $0)
        }
        let uniqueFractions = Set(fractions)
        XCTAssertEqual(uniqueFractions.count, 1, "All target strokes must have identical amplitude")
        XCTAssertEqual(uniqueFractions.first ?? 0, 0.5, accuracy: 0.01,
                       "Target notation must still use fixed 0.5 travel fraction")
    }

    // MARK: - babyScratchFull76 resource

    func testBabyScratchFull76ResourceLoads() throws {
        let notation = try XCTUnwrap(ScratchNotation.loadBabyScratchFull76FromBundle(appBundle))
        XCTAssertEqual(notation.scratchID, "baby")
        XCTAssertEqual(notation.strokes.count, 76)
    }

    func testBabyScratchFull76StrokeCounts() throws {
        let notation = try XCTUnwrap(ScratchNotation.loadBabyScratchFull76FromBundle(appBundle))
        // Partition strokes into phrases by timing
        let strokes = notation.strokes
        var p1=0; var p2=0; var p3=0; var p4=0
        for s in strokes {
            if s.startTime < 6.0          { p1 += 1 }
            else if s.startTime < 20.0    { p2 += 1 }
            else if s.startTime < 32.0    { p3 += 1 }
            else                           { p4 += 1 }
        }
        XCTAssertEqual(p1, 19); XCTAssertEqual(p2, 19)
        XCTAssertEqual(p3, 13); XCTAssertEqual(p4, 25)
    }

    func testBabyScratchFull76Directions() throws {
        let notation = try XCTUnwrap(ScratchNotation.loadBabyScratchFull76FromBundle(appBundle))
        let strokes = notation.strokes

        // Partition into phrases, roughly
        var phrases: [[ScratchNotation.Stroke]] = [[],[],[],[]]
        for s in strokes {
            if s.startTime < 6.0          { phrases[0].append(s) }
            else if s.startTime < 20.0    { phrases[1].append(s) }
            else if s.startTime < 32.0    { phrases[2].append(s) }
            else                           { phrases[3].append(s) }
        }

        for ph in phrases {
            XCTAssertFalse(ph.isEmpty)
            // Odd strokes = forward, even = backward, final = forward
            for (i, s) in ph.enumerated() {
                let expected: ScratchNotationDirection = (i % 2 == 0) ? .forward : .backward
                XCTAssertEqual(s.direction, expected,
                               "Phrase stroke \(i+1) expected \(expected), got \(s.direction)")
            }
            // Final stroke must be forward let-go
            XCTAssertEqual(ph.last!.direction, .forward)
        }
    }

    func testBabyScratchFull76StrokeTimingsValid() throws {
        let notation = try XCTUnwrap(ScratchNotation.loadBabyScratchFull76FromBundle(appBundle))
        for s in notation.strokes {
            XCTAssertGreaterThan(s.endTime, s.startTime,
                                 "Every stroke must have positive duration")
        }
        // Monotonic within each rough phrase
        var lastEnd = -1.0; var currentPh = 1
        for s in notation.strokes {
            let ph = s.startTime < 6.0 ? 1 : (s.startTime < 20.0 ? 2 : (s.startTime < 32.0 ? 3 : 4))
            if ph != currentPh { lastEnd = -1.0; currentPh = ph }
            XCTAssertGreaterThan(s.startTime, lastEnd - 0.001,
                                 "Strokes must be monotonic within each phrase")
            lastEnd = s.endTime
        }
    }

    func testBabyScratchFull76FaderState() throws {
        let notation = try XCTUnwrap(ScratchNotation.loadBabyScratchFull76FromBundle(appBundle))
        for s in notation.strokes {
            XCTAssertEqual(s.faderState, .open, "Baby Scratch is always fader-open")
        }
    }

    func testBabyScratchFull76SpeedClassificationsRecognized() throws {
        let notation = try XCTUnwrap(ScratchNotation.loadBabyScratchFull76FromBundle(appBundle))
        let speeds = Set(notation.strokes.map(\.speedClassification))
        XCTAssertTrue(speeds.isSubset(of: [.fast, .medium, .slow]),
                      "All speed classifications must be recognized")
    }

    // MARK: - babyScratchFull76BeatQuantized resource

    func testBeatQuantizedResourceLoads() throws {
        let n = try XCTUnwrap(ScratchNotation.loadBabyScratchFull76BeatQuantizedFromBundle(appBundle))
        XCTAssertEqual(n.scratchID, "baby")
        XCTAssertEqual(n.strokes.count, 76)
    }

    func testBeatQuantizedPhraseCounts() throws {
        let n = try XCTUnwrap(ScratchNotation.loadBabyScratchFull76BeatQuantizedFromBundle(appBundle))
        var counts = [0,0,0,0]
        for s in n.strokes {
            if s.startTime < 6.0          { counts[0] += 1 }
            else if s.startTime < 20.0    { counts[1] += 1 }
            else if s.startTime < 32.0    { counts[2] += 1 }
            else                           { counts[3] += 1 }
        }
        XCTAssertEqual(counts, [19, 19, 13, 25])
    }

    func testBeatQuantizedDirections() throws {
        let n = try XCTUnwrap(ScratchNotation.loadBabyScratchFull76BeatQuantizedFromBundle(appBundle))
        let phrases = partitionStrokes(n.strokes)
        for ph in phrases {
            for (i, s) in ph.enumerated() {
                let expected: ScratchNotationDirection = (i % 2 == 0) ? .forward : .backward
                XCTAssertEqual(s.direction, expected)
            }
            XCTAssertEqual(ph.last!.direction, .forward)
        }
    }

    func testBeatQuantizedNoOverlaps() throws {
        let n = try XCTUnwrap(ScratchNotation.loadBabyScratchFull76BeatQuantizedFromBundle(appBundle))
        let phrases = partitionStrokes(n.strokes)
        for ph in phrases {
            for i in 0..<(ph.count - 1) {
                XCTAssertLessThanOrEqual(ph[i].endTime, ph[i+1].startTime + 0.001,
                                         "Strokes must not overlap in phrase")
            }
        }
    }

    func testBeatQuantizedFaderState() throws {
        let n = try XCTUnwrap(ScratchNotation.loadBabyScratchFull76BeatQuantizedFromBundle(appBundle))
        for s in n.strokes {
            XCTAssertEqual(s.faderState, .open)
        }
    }

    // MARK: - Notation Lab template verification

    func testNotationLabTemplateIsDeterministicShortNotation() throws {
        let template = try XCTUnwrap(ScratchNotation.loadBabyScratchFromBundle(appBundle),
                                     "Notation/baby_scratch.json must load from the app bundle")
        XCTAssertEqual(template.strokes.count, 12,
                       "Notation Lab template must have 12 strokes (deterministic authored)")
        XCTAssertEqual(template.timelineDuration, 4.700, accuracy: 0.001,
                       "Notation Lab template loop duration must be 4.700s")
        XCTAssertEqual(template.timingBasis, "authored_deterministic_v1",
                       "Notation Lab template must use authored_deterministic_v1 timing basis, not audio peak detection")
    }

    func testNotationLabTemplateLoopDurationIsFromNotationNotFromReferenceTimeline() throws {
        let template = try XCTUnwrap(ScratchNotation.loadBabyScratchFromBundle(appBundle))
        let templateDuration = template.timelineDuration
        let demoTimelineDuration = BabyScratchReferenceMotionTimeline.phraseEnd
        XCTAssertEqual(templateDuration, 4.700, accuracy: 0.001,
                       "Template loop duration must be ~4.700s")
        XCTAssertEqual(demoTimelineDuration, 14.048311, accuracy: 0.001,
                       "Reference timeline must match the selected live demo phrase")
        XCTAssertNotEqual(templateDuration, demoTimelineDuration, accuracy: 1.0,
                          "Notation Lab loop duration must not be derived from BabyScratchReferenceMotionTimeline.phraseEnd")
    }

    func testBabyScratchDemoStillAvailableForCoachPaths() throws {
        let demo = try XCTUnwrap(ScratchNotation.babyScratchDemoFromExtractedStrokes(appBundle),
                                  "babyScratchDemo factory must remain available for coach/audio demo paths")
        XCTAssertEqual(demo.strokes.count, 32,
                       "Coach-motion demo must expose all 16 forward/backward cycles")
        XCTAssertEqual(demo.timelineDuration, 14.048311, accuracy: 0.001,
                       "Coach-motion demo timeline must match the selected live take")
    }

    func testNotationLabTemplateAndDemoAreDistinctResources() throws {
        let template = try XCTUnwrap(ScratchNotation.loadBabyScratchFromBundle(appBundle))
        let demo = try XCTUnwrap(ScratchNotation.babyScratchDemoFromExtractedStrokes(appBundle))
        XCTAssertNotEqual(template.strokes.count, demo.strokes.count,
                          "Template (12) and demo (32) must have different stroke counts")
        XCTAssertNotEqual(template.timingBasis, demo.timingBasis,
                          "Template and demo must carry different timingBasis values")
        let templateDuration = template.timelineDuration
        let demoDuration = demo.timelineDuration
        XCTAssertGreaterThan(demoDuration, templateDuration * 2.5,
                             "Coach-motion demo must be substantially longer than the short template")
    }

    // MARK: - NotationViewportMapper (playhead-relative scrolling math)

    func testViewportMapperAtTimeZero_FirstStrokeAtPlayhead() {
        let mapper = ScratchNotationViewportMapper.notationLab
        let width: CGFloat = 800
        let now: TimeInterval = 0.0

        // At t=0, visibleStart should be negative lead-in.
        let visibleRange = mapper.visibleTimeRange(now: now, width: width)
        XCTAssertEqual(visibleRange.lowerBound, -mapper.leadInDuration, accuracy: 0.001,
                       "visibleStart must be -leadInDuration at t=0")
        XCTAssertEqual(visibleRange.upperBound, mapper.viewportDuration - mapper.leadInDuration, accuracy: 0.001)

        // A stroke starting at 0.0 maps to the playhead.
        let playheadX = mapper.playheadX(forWidth: width)
        let strokeX = mapper.xFor(time: 0.0, now: now, width: width)
        XCTAssertEqual(strokeX, playheadX, accuracy: 0.5,
                       "Stroke at time 0.0 must map to playhead X when now=0")
    }

    func testViewportMapperAtTimeZeroPointThree_FutureAndPastCorrect() {
        let mapper = ScratchNotationViewportMapper.notationLab
        let width: CGFloat = 800
        let now: TimeInterval = 0.3
        let playheadX = mapper.playheadX(forWidth: width)

        // A stroke AT the current time maps to the playhead.
        let atPlayhead = mapper.xFor(time: 0.3, now: now, width: width)
        XCTAssertEqual(atPlayhead, playheadX, accuracy: 0.5,
                       "Stroke at time 0.3 must map to playhead X when now=0.3")

        // A FUTURE stroke maps to the RIGHT of the playhead.
        let futureX = mapper.xFor(time: 0.6, now: now, width: width)
        XCTAssertGreaterThan(futureX, playheadX + 1,
                             "Future stroke at 0.6 must be right of playhead")

        // A PAST stroke maps to the LEFT of the playhead.
        let pastX = mapper.xFor(time: 0.0, now: now, width: width)
        XCTAssertLessThan(pastX, playheadX - 1,
                          "Past stroke at 0.0 must be left of playhead")
    }

    func testViewportMapperNoStartClamp_VisibleStartNegativeAtEarlyTime() {
        let mapper = ScratchNotationViewportMapper.notationLab
        let now: TimeInterval = 0.0

        // visibleStart must NOT be clamped to 0 during active scrolling.
        let visibleStart = mapper.visibleTimeRange(now: now, width: 800).lowerBound
        XCTAssertLessThan(visibleStart, 0.0,
                          "visibleStart must be negative at t=0 (no clamp to 0)")
    }

    func testViewportMapperNoEndClamp_VisibleStartAllowedPastPhraseEnd() {
        let mapper = ScratchNotationViewportMapper.notationLab
        let phraseEnd: TimeInterval = 4.7
        let now: TimeInterval = phraseEnd

        // visibleStart should NOT be clamped to phraseEnd - viewportDuration.
        // With playheadFraction=0.30, visibleStart = now - 0.72 = 3.98 at now=4.7.
        let visibleStart = mapper.visibleTimeRange(now: now, width: 800).lowerBound
        let clampedMinimum = phraseEnd - mapper.viewportDuration
        XCTAssertGreaterThan(visibleStart, clampedMinimum - 0.01,
                             "visibleStart at phrase end should be computed from now, not duration-clamped")
        XCTAssertEqual(visibleStart, phraseEnd - mapper.leadInDuration, accuracy: 0.001,
                       "visibleStart = now - leadInDuration")
    }

    func testViewportMapperTailOut_FinalStrokePassesThroughPlayhead() {
        let mapper = ScratchNotationViewportMapper.notationLab
        let width: CGFloat = 800
        let lastStrokeStart: TimeInterval = 4.4
        let lastStrokeEnd: TimeInterval = 4.7
        let playheadX = mapper.playheadX(forWidth: width)

        // At now = lastStrokeEnd, the stroke's end should be AT the playhead.
        let endX = mapper.xFor(time: lastStrokeEnd, now: lastStrokeEnd, width: width)
        XCTAssertEqual(endX, playheadX, accuracy: 0.5,
                       "Last stroke end at playhead when now = lastStrokeEnd")

        // At now = lastStrokeStart, the stroke's start should be AT the playhead.
        let startX = mapper.xFor(time: lastStrokeStart, now: lastStrokeStart, width: width)
        XCTAssertEqual(startX, playheadX, accuracy: 0.5,
                       "Last stroke start at playhead when now = lastStrokeStart")

        // At now = lastStrokeEnd + leadInDuration, the stroke end should be left of playhead.
        let tailOutNow = lastStrokeEnd + mapper.leadInDuration
        let endPastX = mapper.xFor(time: lastStrokeEnd, now: tailOutNow, width: width)
        XCTAssertLessThan(endPastX, playheadX - 1,
                          "Stroke end must pass through playhead during tail-out")
    }

    func testViewportMapperStrokeVisibility_FiltersOutsideVisibleWindow() {
        let mapper = ScratchNotationViewportMapper.notationLab
        let width: CGFloat = 800
        let now: TimeInterval = 2.0
        // visible ≈ [1.28, 3.68]

        // A stroke entirely before visibleStart should NOT be visible.
        XCTAssertFalse(mapper.isVisible(from: 0.0, to: 0.3, now: now, width: width),
                       "Stroke [0.0, 0.3] before visible window should not be visible")

        // A stroke overlapping visibleStart should be visible.
        XCTAssertTrue(mapper.isVisible(from: 1.2, to: 1.5, now: now, width: width),
                      "Stroke overlapping visibleStart should be visible")

        // A stroke entirely within the window should be visible.
        XCTAssertTrue(mapper.isVisible(from: 2.0, to: 2.3, now: now, width: width),
                      "Stroke within window should be visible")

        // A stroke entirely after visibleEnd should NOT be visible.
        XCTAssertFalse(mapper.isVisible(from: 4.0, to: 4.3, now: now, width: width),
                       "Stroke after visible window should not be visible")
    }

    func testViewportMapperLeadIn_EmptySpaceBeforeFirstStroke() {
        let mapper = ScratchNotationViewportMapper.notationLab
        let width: CGFloat = 800
        let playheadX = mapper.playheadX(forWidth: width)

        // At t=0, time=-0.5s (0.5s before phrase start) is within the lead-in
        // window (leadInDuration = 0.72s). It maps to a position left of the
        // playhead but still on screen.
        let leadInX = mapper.xFor(time: -0.5, now: 0.0, width: width)
        XCTAssertLessThan(leadInX, playheadX,
                          "Time before phrase start should map left of playhead (lead-in space)")
        XCTAssertGreaterThan(leadInX, -10,
                             "Lead-in time should still be on screen, not off-screen left")

        // Time=-1.0s is before the lead-in window (visibleStart=-0.72), so it
        // maps off-screen left.
        let offScreenX = mapper.xFor(time: -1.0, now: 0.0, width: width)
        XCTAssertLessThan(offScreenX, 0,
                          "Time well before phrase start should map off-screen left")

        // The mapper faithfully maps time — it never creates fake strokes.
    }

    func testViewportMapperLoopWrap_SeamlessCycling() {
        let phraseDuration: TimeInterval = 4.7

        // phraseTime maps audio time into [0, phraseDuration) with continuous wrapping.
        let t0 = ScratchNotationViewportMapper.phraseTime(forAudioTime: 0.0, phraseDuration: phraseDuration)
        XCTAssertEqual(t0, 0.0, accuracy: 0.001)

        let t1 = ScratchNotationViewportMapper.phraseTime(forAudioTime: 2.3, phraseDuration: phraseDuration)
        XCTAssertEqual(t1, 2.3, accuracy: 0.001)

        // At the exact wrap point, it should cycle back to 0.
        let tWrap = ScratchNotationViewportMapper.phraseTime(forAudioTime: 4.7, phraseDuration: phraseDuration)
        XCTAssertEqual(tWrap, 0.0, accuracy: 0.001)

        // Just before the wrap.
        let tBeforeWrap = ScratchNotationViewportMapper.phraseTime(forAudioTime: 4.699, phraseDuration: phraseDuration)
        XCTAssertEqual(tBeforeWrap, 4.699, accuracy: 0.001)

        // Well past the phrase (multiple cycles).
        // 4.7 * 3 = 14.1, so audio time 14.1 wraps to 0.
        // Use an integer multiple to avoid floating-point rounding.
        let threeCycles = phraseDuration * 3
        let tMulti = ScratchNotationViewportMapper.phraseTime(forAudioTime: threeCycles, phraseDuration: phraseDuration)
        XCTAssertEqual(tMulti, 0.0, accuracy: 0.001,
                       "\(threeCycles) = 3 * \(phraseDuration), should wrap to 0")

        // In-cycle value: 5.9 = 4.7 + 1.2, so should wrap to 1.2.
        let oneCyclePlus = phraseDuration + 1.2
        let tMulti2 = ScratchNotationViewportMapper.phraseTime(forAudioTime: oneCyclePlus, phraseDuration: phraseDuration)
        XCTAssertEqual(tMulti2, 1.2, accuracy: 0.01,
                       "\(oneCyclePlus) - \(phraseDuration) should be 1.2")
    }

    // MARK: - Baby Scratch Template (post-duration-fix verification)

    func testBabyScratchTemplateDurationIsFourPointSevenSeconds() throws {
        let template = try XCTUnwrap(ScratchNotation.loadBabyScratchFromBundle(appBundle))
        XCTAssertEqual(template.timelineDuration, 4.700, accuracy: 0.001,
                       "Baby Scratch Template duration must be 4.700s")
        let phraseStart = try XCTUnwrap(template.phraseStart)
        XCTAssertEqual(phraseStart, 0.0, accuracy: 0.001)
        let phraseEnd = try XCTUnwrap(template.phraseEnd)
        XCTAssertEqual(phraseEnd, 4.700, accuracy: 0.001)
    }

    func testBabyScratchTemplateHasTwelveStrokes() throws {
        let template = try XCTUnwrap(ScratchNotation.loadBabyScratchFromBundle(appBundle))
        XCTAssertEqual(template.strokes.count, 12,
                       "Deterministic baby scratch template must have exactly 12 strokes")
    }

    func testBabyScratchTemplateStrokesSpanFullPhrase() throws {
        let template = try XCTUnwrap(ScratchNotation.loadBabyScratchFromBundle(appBundle))
        let firstStart = template.strokes.first?.startTime ?? -1
        let lastEnd = template.strokes.last?.endTime ?? -1
        XCTAssertEqual(firstStart, 0.0, accuracy: 0.001, "First stroke must start at 0.0")
        XCTAssertEqual(lastEnd, 4.700, accuracy: 0.001, "Last stroke must end at 4.700")
    }

    func testNotationLabTemplateSource_UsesShortTemplateNotCoachDemo() throws {
        // The ViewModel init loads ScratchNotation.babyScratch, not .babyScratchDemo.
        // Verify the underlying notation source used by the Notation Lab.
        let template = try XCTUnwrap(ScratchNotation.babyScratch)
        let demo = ScratchNotation.babyScratchDemoFromExtractedStrokes(appBundle)

        // Template timelineDuration must be 4.700s (short deterministic phrase).
        XCTAssertEqual(template.timelineDuration, 4.700, accuracy: 0.001,
                       "Notation Lab source (babyScratch) must have 4.700s duration")

        // The demo is a separate resource — longer, more strokes. The Notation Lab
        // must use the short template, not the demo.
        if let demo {
            XCTAssertGreaterThan(demo.timelineDuration, template.timelineDuration * 2.5,
                                 "Demo must be substantially longer — Notation Lab uses template")
        }

        // The strokes in the template are the deterministic 12-stroke authored phrase.
        XCTAssertEqual(template.strokes.count, 12,
                       "Template has 12 strokes — Notation Lab uses this, not the 32-stroke demo")
    }

    func testViewportMapperIsPlayheadRelative_NotStaticClampedTimeline() {
        // A static clamped timeline would have visibleStart = max(0, now - leadIn)
        // and visibleStart = min(duration - viewportDuration, now - leadIn).
        // Our playhead-relative mapper does neither.
        let mapper = ScratchNotationViewportMapper.notationLab
        let phraseDuration: TimeInterval = 4.7

        // At t=0, static clamp would give visibleStart = 0. Ours is negative.
        let at0 = mapper.visibleTimeRange(now: 0.0, width: 800).lowerBound
        XCTAssertLessThan(at0, 0.0, "Playhead-relative: visibleStart < 0 at t=0 (not clamped)")

        // At t=phraseEnd, static clamp would give visibleStart = duration - viewportDuration = 2.3.
        // Ours is phraseEnd - leadInDuration = 3.98 (computed from now, not clamped).
        let atEnd = mapper.visibleTimeRange(now: phraseDuration, width: 800).lowerBound
        XCTAssertGreaterThan(atEnd, phraseDuration - mapper.viewportDuration + 0.5,
                             "Playhead-relative: visibleStart near phraseEnd is derived from now, not duration-clamped")
        XCTAssertEqual(atEnd, phraseDuration - mapper.leadInDuration, accuracy: 0.01)
    }

    // MARK: - Tile offset suppression (hasWrapped flag)

    func testTileOffsets_WithoutWrapping_OnlyZeroOffset() {
        // Before any loop wrap, Notation Lab should only draw the 0-offset tile
        // so the visible window shows the current phrase with empty lead-in/tail.
        let loopDuration: TimeInterval = 4.7
        let viewportDuration: TimeInterval = 2.4
        let playheadFraction: Double = 0.30
        let now: TimeInterval = 0.0
        let phX = 800.0 * playheadFraction
        let pps = 800.0 / viewportDuration
        let visibleStart = now - phX / pps
        let visibleEnd = visibleStart + viewportDuration

        // Without wrapping: only tile offset 0.
        let kMin0 = Int((visibleStart / loopDuration).rounded(.down))
        let kMax0 = Int((visibleEnd   / loopDuration).rounded(.up))
        // kMin=-1, kMax=1. But we suppress negative offsets before first wrap.
        let unwrappedOffsets = [0.0]
        XCTAssertEqual(unwrappedOffsets, [0],
                       "Before first wrap, only 0-offset tile drawn")

        // With wrapping: k=-1..1 = [-4.7, 0, 4.7]
        let wrappedOffsets = (kMin0...kMax0).map { Double($0) * loopDuration }
        XCTAssertEqual(wrappedOffsets, [-4.7, 0, 4.7].map { $0 },
                       "After wrap, all overlapping tiles drawn for continuity")
    }

    func testTileOffsets_BeforeWrap_FirstStrokeAtPlayheadAndNoPastArtifacts() {
        // At now=0 (before any wrap): only the 0-tile is drawn.
        // The -4.7 tile's tail segments (shifted to times -0.15..0.0)
        // are NOT drawn, so the past region shows empty lead-in.
        let mapper = ScratchNotationViewportMapper.notationLab
        let width: CGFloat = 800

        // First stroke start is at the playhead.
        let stroke1Start = mapper.xFor(time: 0.0, now: 0.0, width: width)
        XCTAssertEqual(stroke1Start, mapper.playheadX(forWidth: width), accuracy: 0.5,
                       "Stroke 1 start at playhead when only 0-tile is drawn")

        // Stroke 1 end is to the right (future).
        let stroke1End = mapper.xFor(time: 0.3, now: 0.0, width: width)
        XCTAssertGreaterThan(stroke1End, mapper.playheadX(forWidth: width),
                             "Stroke 1 end is future (right of playhead) at now=0")

        // Nothing occupies the region left of the playhead from the 0-tile. No
        // -tile segments draw confusing past-loop content.
    }

    func testTileOffsets_AfterWrap_PastRegionHasPreviousLoopTail() {
        // After wrapping: the -tile IS drawn and the visible past region
        // contains strokes from the previous loop.
        let mapper = ScratchNotationViewportMapper.notationLab
        let loopDuration: TimeInterval = 4.7
        let width: CGFloat = 800

        // At now=0.01 (just wrapped), with wrapping=true:
        // The -4.7-tile draws the last backward stroke's return half at [-0.15, 0.0].
        let shiftedTime = 4.7 - 0.01
        // shiftedTime ≈ 4.69 (prev loop's last stroke end, near 0 after tiling)

        // The -tile would position the last stroke end at approx:
        let prevLastEnd = mapper.xFor(time: 4.7 - 4.7, now: 0.01, width: width)
        // time=0.0, now=0.01 → phX + (0 - 0.01) * pps ≈ phX - 3.3 px
        // Within tolerance of playhead.
        XCTAssertLessThan(abs(prevLastEnd - mapper.playheadX(forWidth: width)), 5,
                          "Previous loop's last stroke end near playhead after wrap")
    }

    func testTilingWithWrapping_NoVisibleGapAtWrapBoundary() {
        let mapper = ScratchNotationViewportMapper.notationLab
        let loopDuration: TimeInterval = 4.7
        let width: CGFloat = 800

        // Just before wrap: last stroke (4.4-4.7) crosses playhead.
        let preWrapNow: TimeInterval = 4.699
        let lastEndBefore = mapper.xFor(time: 4.7, now: preWrapNow, width: width)
        // lastEndBefore ≈ phX + (4.7 - 4.699) * pps ≈ phX + 0.33 px — just right of playhead
        XCTAssertGreaterThan(lastEndBefore, mapper.playheadX(forWidth: width) - 1,
                             "Last stroke end at/near playhead just before wrap")

        // Just after wrap: the -tile's last stroke return reaches the playhead.
        let postWrapNow: TimeInterval = 0.001
        let firstStartAfter = mapper.xFor(time: 0.0, now: postWrapNow, width: width)
        // firstStartAfter ≈ phX + (0 - 0.001) * pps ≈ phX - 0.33 px — slightly left
        // This is the 0-tile stroke. The -tile (-4.7) draws the previous last stroke
        // at times [-0.3, 0.0] which overlaps the visible window seamless.
        XCTAssertLessThan(abs(firstStartAfter - mapper.playheadX(forWidth: width)), 5,
                          "First stroke start near playhead after wrap")

        // The -tile (-4.7) draws content at -0.15 to 0.0 times, connecting
        // seamlessly to the 0-tile's first stroke at 0.0.
        let prevTailX = mapper.xFor(time: -0.001, now: postWrapNow, width: width)
        // -0.001 time is achievable via -4.7-tile: 4.699 - 4.7 = -0.001
        XCTAssertLessThan(prevTailX, mapper.playheadX(forWidth: width),
                          "Previous loop tail extends left of playhead for continuity")
    }

    func testTileOffsets_MidLoop_DynamicRange() {
        // At now=2.0 (mid-loop): visibleStart=1.28, visibleEnd=3.68.
        // kMin = floor(1.28/4.7) = 0, kMax = ceil(3.68/4.7) = 1.
        // The +4.7 tile (k=1) doesn't actually overlap but over-inclusion
        // is harmless — the renderer filters non-visible segments.
        let loopDuration: TimeInterval = 4.7
        let viewportDuration: TimeInterval = 2.4
        let playheadFraction: Double = 0.30
        let now: TimeInterval = 2.0
        let phX = 800.0 * playheadFraction
        let pps = 800.0 / viewportDuration
        let visibleStart = now - phX / pps
        let visibleEnd = visibleStart + viewportDuration

        let kMin = Int((visibleStart / loopDuration).rounded(.down))
        let kMax = Int((visibleEnd   / loopDuration).rounded(.up))
        let offsets = (kMin...kMax).map { Double($0) * loopDuration }

        XCTAssertEqual(offsets, [0.0, 4.7].map { $0 },
                       "Mid-loop: 0-tile + over-inclusive +4.7 tile (harmless)")
    }

    func testTileOffsets_EndOfLoop_Wrapped_HasNextTile() {
        // At now=4.5 (near end, hasWrapped=true):
        // visibleStart=3.78, visibleEnd=6.18. kMin=0, kMax=ceil(6.18/4.7)=2.
        // Tiles: 0 (current), +4.7 (next loop), +9.4 (over-inclusive but harmless).
        let loopDuration: TimeInterval = 4.7
        let viewportDuration: TimeInterval = 2.4
        let playheadFraction: Double = 0.30
        let now: TimeInterval = 4.5
        let phX = 800.0 * playheadFraction
        let pps = 800.0 / viewportDuration
        let visibleStart = now - phX / pps
        let visibleEnd = visibleStart + viewportDuration

        let kMin = Int((visibleStart / loopDuration).rounded(.down))
        let kMax = Int((visibleEnd   / loopDuration).rounded(.up))
        let offsets = (kMin...kMax).map { Double($0) * loopDuration }

        XCTAssertEqual(offsets, [0.0, 4.7, 9.4].map { $0 },
                       "End of loop with wrapping: 0, +4.7, +9.4 tiles for future continuity")
    }

    // MARK: - Helpers
    private func partitionStrokes(_ strokes: [ScratchNotation.Stroke]) -> [[ScratchNotation.Stroke]] {
        var p1:[ScratchNotation.Stroke]=[]; var p2=p1; var p3=p1; var p4=p1
        for s in strokes {
            if s.startTime < 6.0          { p1.append(s) }
            else if s.startTime < 20.0    { p2.append(s) }
            else if s.startTime < 32.0    { p3.append(s) }
            else                           { p4.append(s) }
        }
        return [p1, p2, p3, p4]
    }
}
