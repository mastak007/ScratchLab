import XCTest
@testable import ScratchLab

/// Locks the contract of `SessionReplayPresentationAdapter`. Pure
/// additive projection from `SessionReplayTimeline` to
/// `NotationPresentationModel`; no SwiftUI, no rendering geometry, no
/// export-schema touch, no ML, no scoring, no re-derivation from
/// `DetectedNotationSnapshot`.
final class SessionReplayPresentationAdapterTests: XCTestCase {

    // MARK: - Helpers

    private func event(
        start: Double,
        end: Double?,
        kind: SessionReplayEvent.Kind = .audioOnset,
        sourceIndex: Int = 0,
        tag: String? = nil
    ) -> SessionReplayEvent {
        SessionReplayEvent(
            startTime: start,
            endTime: end,
            kind: kind,
            sourceIndex: sourceIndex,
            tag: tag
        )
    }

    private func timeline(
        events: [SessionReplayEvent],
        takeDuration: Double = 4
    ) -> SessionReplayTimeline {
        SessionReplayTimeline(
            takeDurationSeconds: takeDuration,
            events: events
        )
    }

    // MARK: - 1. empty source maps to empty model

    func testEmptyEventsMapsToEmptyModel() {
        let model = SessionReplayPresentationAdapter.makeModel(
            from: timeline(events: [])
        )
        XCTAssertEqual(model.strokes, [])
    }

    // MARK: - 2. source event count maps to model stroke count

    func testStrokeCountMatchesEventCount() {
        let source = timeline(events: [
            event(start: 0.10, end: 0.42, kind: .audioOnset,     sourceIndex: 0),
            event(start: 0.55, end: 0.91, kind: .recordMovement, sourceIndex: 0, tag: "forward"),
            event(start: 1.20, end: nil,  kind: .mixerMidi,      sourceIndex: 0, tag: "midi_cc_07"),
            event(start: 1.45, end: 1.60, kind: .fader,          sourceIndex: 0, tag: "crossfader"),
        ])
        let model = SessionReplayPresentationAdapter.makeModel(from: source)
        XCTAssertEqual(model.strokes.count, source.events.count)
    }

    // MARK: - 3. primitiveIndex is stable 0..<n in event order

    func testPrimitiveIndexIsStableEventOrder() {
        let source = timeline(events: [
            event(start: 0.10, end: 0.42, kind: .audioOnset),
            event(start: 0.55, end: 0.91, kind: .recordMovement, tag: "forward"),
            event(start: 1.20, end: nil,  kind: .mixerMidi,      tag: "midi_cc_07"),
            event(start: 1.45, end: 1.60, kind: .fader,          tag: "crossfader"),
        ])
        let model = SessionReplayPresentationAdapter.makeModel(from: source)
        XCTAssertEqual(model.strokes.map(\.primitiveIndex), [0, 1, 2, 3])
    }

    // MARK: - 4. startTime / endTime map correctly, including point-in-time events

    func testStartAndEndTimesMapCorrectly() {
        let source = timeline(events: [
            event(start: 0.10, end: 0.42, kind: .audioOnset),
            event(start: 0.55, end: 0.91, kind: .recordMovement),
            event(start: 1.20, end: nil,  kind: .mixerMidi),
            event(start: 1.45, end: 1.60, kind: .fader),
        ])
        let model = SessionReplayPresentationAdapter.makeModel(from: source)
        XCTAssertEqual(model.strokes.map(\.startTime), [0.10, 0.55, 1.20, 1.45])
        XCTAssertEqual(model.strokes.map(\.endTime),   [0.42, 0.91, 1.20, 1.60])
    }

    // MARK: - 5. positions are nil — no GridAnnotation sidecar on SessionReplayTimeline

    func testPositionsAreNil() {
        let source = timeline(events: [
            event(start: 0.10, end: 0.42, kind: .audioOnset),
            event(start: 1.20, end: nil,  kind: .mixerMidi),
        ])
        let model = SessionReplayPresentationAdapter.makeModel(from: source)
        XCTAssertTrue(model.strokes.allSatisfy { $0.startPosition == nil })
        XCTAssertTrue(model.strokes.allSatisfy { $0.endPosition == nil })
    }

    // MARK: - 6. family is nil — no ScratchFamilyAnnotationSet sidecar

    func testFamilyIsNil() {
        let source = timeline(events: [
            event(start: 0.10, end: 0.42, kind: .audioOnset),
            event(start: 0.55, end: 0.91, kind: .recordMovement),
        ])
        let model = SessionReplayPresentationAdapter.makeModel(from: source)
        XCTAssertTrue(model.strokes.allSatisfy { $0.family == nil })
    }

    // MARK: - 7. coachingKinds is empty — no CoachingEventSet sidecar

    func testCoachingKindsAreEmpty() {
        let source = timeline(events: [
            event(start: 0.10, end: 0.42, kind: .audioOnset),
            event(start: 1.20, end: nil,  kind: .mixerMidi),
        ])
        let model = SessionReplayPresentationAdapter.makeModel(from: source)
        XCTAssertTrue(model.strokes.allSatisfy { $0.coachingKinds.isEmpty })
    }

    // MARK: - 8. deterministic — repeated mapping returns equal models

    func testRepeatedMappingIsDeterministic() {
        let source = timeline(events: [
            event(start: 0.10, end: 0.42, kind: .audioOnset),
            event(start: 0.55, end: 0.91, kind: .recordMovement),
            event(start: 1.20, end: nil,  kind: .mixerMidi),
            event(start: 1.45, end: 1.60, kind: .fader),
        ])
        let modelA = SessionReplayPresentationAdapter.makeModel(from: source)
        let modelB = SessionReplayPresentationAdapter.makeModel(from: source)
        XCTAssertEqual(modelA, modelB)
    }

    // MARK: - Phase C0a — attachDriftKinds helper

    private func coachingEvent(
        time: TimeInterval,
        kind: CoachingEventKind
    ) -> CoachingEvent {
        guard let event = CoachingEvent(time: time, kind: kind, severity: .notice, message: nil) else {
            XCTFail("CoachingEvent unexpectedly rejected")
            return CoachingEvent(time: 0, kind: kind, severity: .notice, message: nil)!
        }
        return event
    }

    func testAttachDriftKindsMatchesStrokeByWindow() {
        // Drift events at 0.20 and 1.30 land inside the [0.10, 0.42]
        // and [1.20, 1.45] stroke windows respectively.
        let strokes: [SessionReplayEvent] = [
            event(start: 0.10, end: 0.42, kind: .audioOnset),
            event(start: 0.55, end: 0.91, kind: .recordMovement),
            event(start: 1.20, end: 1.45, kind: .fader),
        ]
        let events = [
            coachingEvent(time: 0.20, kind: .lateReversal),
            coachingEvent(time: 1.30, kind: .earlyReversal),
        ]
        let kinds = SessionReplayPresentationAdapter.attachDriftKinds(events, to: strokes)
        XCTAssertEqual(kinds, [[.lateReversal], [], [.earlyReversal]])
    }

    func testAttachDriftKindsDropsPhraseKinds() {
        // Phrase / unstable / clipped / noSignal kinds are silently
        // dropped — Phase C2 wires them after Phase B2 visibility.
        let strokes = [event(start: 0.10, end: 0.42)]
        let events = [
            coachingEvent(time: 0.20, kind: .incompletePhrase),
            coachingEvent(time: 0.25, kind: .unstableTiming),
            coachingEvent(time: 0.30, kind: .clippedMotion),
            coachingEvent(time: 0.35, kind: .noSignal),
            coachingEvent(time: 0.40, kind: .unknown),
        ]
        let kinds = SessionReplayPresentationAdapter.attachDriftKinds(events, to: strokes)
        XCTAssertEqual(kinds, [[]])
    }

    func testAttachDriftKindsDropsOutOfWindowEvents() {
        // A drift event in the gap between strokes (0.50) attaches to
        // nothing and is silently dropped.
        let strokes = [
            event(start: 0.10, end: 0.42),
            event(start: 0.60, end: 0.91),
        ]
        let events = [coachingEvent(time: 0.50, kind: .lateReversal)]
        let kinds = SessionReplayPresentationAdapter.attachDriftKinds(events, to: strokes)
        XCTAssertEqual(kinds, [[], []])
    }

    func testAttachDriftKindsHandlesPointInTimeStroke() {
        // Mixer-MIDI-style stroke (endTime == nil → zero-duration).
        // Only an event at exactly the stroke time attaches.
        let strokes = [event(start: 1.20, end: nil, kind: .mixerMidi)]
        let events = [
            coachingEvent(time: 1.20, kind: .lateReversal),
            coachingEvent(time: 1.21, kind: .earlyReversal),
        ]
        let kinds = SessionReplayPresentationAdapter.attachDriftKinds(events, to: strokes)
        XCTAssertEqual(kinds, [[.lateReversal]])
    }

    func testAttachDriftKindsEmptyInputs() {
        XCTAssertEqual(SessionReplayPresentationAdapter.attachDriftKinds([], to: []), [])
        let strokes = [event(start: 0.10, end: 0.42)]
        XCTAssertEqual(SessionReplayPresentationAdapter.attachDriftKinds([], to: strokes), [[]])
    }

    func testMakeModelPropagatesAttachedKindsWhenFlagOn() {
        // DEBUG default for COACHING_EVENTS_PIPELINE is true after
        // C0a — passing events through makeModel must produce the
        // same coachingKinds as attachDriftKinds.
        let source = timeline(events: [
            event(start: 0.10, end: 0.42, kind: .audioOnset),
            event(start: 1.20, end: 1.45, kind: .fader),
        ])
        let events = [
            coachingEvent(time: 0.20, kind: .lateReversal),
            coachingEvent(time: 1.30, kind: .earlyReversal),
        ]
        let model = SessionReplayPresentationAdapter.makeModel(
            from: source,
            coachingEvents: events
        )
        XCTAssertEqual(model.strokes.map(\.coachingKinds),
                       [[.lateReversal], [.earlyReversal]])
    }
}
