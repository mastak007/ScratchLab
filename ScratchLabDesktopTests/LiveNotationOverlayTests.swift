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
}
