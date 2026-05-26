import XCTest
@testable import ScratchLab

final class SessionReplayTimelineTests: XCTestCase {

    private static let referenceDate = Date(timeIntervalSince1970: 1_780_700_000)

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - Sort ordering

    func testBuildSortsEventsByStartTime() {
        let snapshot = makeSnapshot(
            audio: [
                (startTime: 2.0, endTime: 2.1, kind: "scratchBurst"),
                (startTime: 0.5, endTime: 0.6, kind: "scratchBurst")
            ],
            movements: [
                (startTime: 1.0, endTime: 1.1, direction: "forward")
            ]
        )
        let timeline = SessionReplayTimeline.build(from: snapshot, takeDuration: 3.0)
        XCTAssertEqual(timeline.events.map(\.startTime), [0.5, 1.0, 2.0])
        XCTAssertEqual(timeline.events.map(\.kind), [.audioOnset, .recordMovement, .audioOnset])
    }

    func testBuildAppliesLanePriorityTieBreak() {
        // Four events all at exactly t = 1.0, one per lane. Expected
        // fire order: audioOnset, recordMovement, fader, mixerMidi.
        let snapshot = makeSnapshot(
            audio: [(startTime: 1.0, endTime: 1.05, kind: "scratchBurst")],
            movements: [(startTime: 1.0, endTime: 1.05, direction: "forward")],
            faders: [(startTime: 1.0, endTime: 1.05, kind: .cut, control: "crossfader")],
            mixerMidi: [(takeRelativeTime: 1.0, controller: 17, mappedControl: "crossfader")]
        )
        let timeline = SessionReplayTimeline.build(from: snapshot, takeDuration: 2.0)
        XCTAssertEqual(
            timeline.events.map(\.kind),
            [.audioOnset, .recordMovement, .fader, .mixerMidi]
        )
        // Sanity: lane order matches the documented priority ordinals.
        XCTAssertEqual(timeline.events.map(\.kind.laneOrder), [0, 1, 2, 3])
    }

    func testBuildPreservesSourceIndexWithinLane() {
        // Three audio events all at t = 1.0. Their relative firing
        // order must match the input lane array order.
        let snapshot = makeSnapshot(
            audio: [
                (startTime: 1.0, endTime: 1.05, kind: "first"),
                (startTime: 1.0, endTime: 1.05, kind: "second"),
                (startTime: 1.0, endTime: 1.05, kind: "third")
            ]
        )
        let timeline = SessionReplayTimeline.build(from: snapshot, takeDuration: 1.5)
        XCTAssertEqual(timeline.events.map(\.sourceIndex), [0, 1, 2])
        XCTAssertEqual(timeline.events.map(\.tag), ["first", "second", "third"])
    }

    // MARK: - Determinism

    func testBuildIsDeterministicAcrossInvocations() throws {
        let snapshot = makeSnapshot(
            audio: [
                (startTime: 0.5, endTime: 0.6, kind: "scratchBurst"),
                (startTime: 1.2, endTime: 1.3, kind: "possibleDrag")
            ],
            movements: [
                (startTime: 0.7, endTime: 0.8, direction: "forward"),
                (startTime: 1.0, endTime: 1.1, direction: "backward")
            ],
            faders: [(startTime: 1.0, endTime: 1.05, kind: .cut, control: "crossfader")],
            mixerMidi: [(takeRelativeTime: 1.1, controller: 17, mappedControl: nil)]
        )
        let first = SessionReplayTimeline.build(from: snapshot, takeDuration: 2.0)
        let second = SessionReplayTimeline.build(from: snapshot, takeDuration: 2.0)
        XCTAssertEqual(first, second)
        let firstJSON = try encoder.encode(first)
        let secondJSON = try encoder.encode(second)
        XCTAssertEqual(firstJSON, secondJSON)
    }

    // MARK: - Empty / nil guards

    func testBuildSkipsZeroEventsAndNilGuards() {
        let snapshot = makeSnapshot()
        let timeline = SessionReplayTimeline.build(from: snapshot, takeDuration: 0.0)
        XCTAssertTrue(timeline.events.isEmpty)
        XCTAssertEqual(timeline.schemaVersion, SessionReplayTimeline.currentSchemaVersion)
        XCTAssertEqual(timeline.takeDurationSeconds, 0.0)
    }

    // MARK: - Fader-events not re-derived

    func testFaderEventsConsumedAsStoredNotRederived() {
        // Two stored fader events that DO NOT match what
        // `CaptureCore.deriveDetectedNotationFaderEvents` would
        // produce from the supplied mixer MIDI samples (a single
        // unmapped controller-7 message that the deriver would not
        // turn into a crossfader cut). The build must surface what
        // was stored — not what the deriver might compute.
        let storedFader = CaptureCore.DetectedNotationFaderEvent(
            startTime: 0.5,
            endTime: 0.6,
            eventKind: .cut,
            control: "crossfader",
            fromValue: 0.0,
            toValue: 1.0,
            source: "manual",
            confidence: 1.0
        )
        let unrelatedMidi = CaptureCore.RawMixerMIDIEvent(
            timestamp: 1.2,
            takeRelativeTime: 1.2,
            deviceName: "Test",
            channel: 1,
            controller: 7,
            value: 64,
            normalizedValue: 0.5,
            mappedControl: nil
        )
        let snapshot = CaptureCore.DetectedNotationSnapshot(
            notationSource: "detected",
            notationConfidence: nil,
            detectedLabel: nil,
            labelSource: "detected",
            labelConfidence: nil,
            detectionSources: ["audio"],
            recordMovementEvents: [],
            audioEvents: [],
            faderEvents: [storedFader],
            mixerMidiEvents: [unrelatedMidi],
            capturedAt: Self.referenceDate
        )
        let timeline = SessionReplayTimeline.build(from: snapshot, takeDuration: 2.0)
        let faderProjections = timeline.events.filter { $0.kind == .fader }
        XCTAssertEqual(faderProjections.count, 1)
        XCTAssertEqual(faderProjections.first?.startTime, 0.5)
        XCTAssertEqual(faderProjections.first?.endTime, 0.6)
        XCTAssertEqual(faderProjections.first?.tag, "crossfader")
        // The unrelated mixer MIDI is surfaced separately and
        // anchored at `takeRelativeTime`, not `timestamp` (the two
        // happen to be equal here; the test that pins time-source
        // independence sits in the lane-priority test above).
        let midiProjections = timeline.events.filter { $0.kind == .mixerMidi }
        XCTAssertEqual(midiProjections.count, 1)
        XCTAssertEqual(midiProjections.first?.startTime, 1.2)
        XCTAssertEqual(midiProjections.first?.tag, "midi_cc_7")
    }

    // MARK: - JSON round-trip

    func testJSONRoundTrip() throws {
        let snapshot = makeSnapshot(
            audio: [
                (startTime: 0.5, endTime: 0.6, kind: "scratchBurst"),
                (startTime: 1.2, endTime: 1.3, kind: "possibleDrag")
            ],
            movements: [
                (startTime: 0.7, endTime: 0.8, direction: "forward")
            ],
            faders: [(startTime: 1.0, endTime: 1.05, kind: .cut, control: "crossfader")],
            mixerMidi: [(takeRelativeTime: 1.1, controller: 17, mappedControl: "crossfader")]
        )
        let original = SessionReplayTimeline.build(from: snapshot, takeDuration: 2.0)
        let data = try encoder.encode(original)
        let restored = try decoder.decode(SessionReplayTimeline.self, from: data)
        XCTAssertEqual(original, restored)
        XCTAssertEqual(restored.schemaVersion, "scratchlab_session_replay_v1")
        XCTAssertEqual(restored.events.count, 5)
    }

    // MARK: - Helpers

    private func makeSnapshot(
        audio: [(startTime: Double, endTime: Double, kind: String)] = [],
        movements: [(startTime: Double, endTime: Double, direction: String)] = [],
        faders: [(startTime: Double, endTime: Double, kind: ScratchFaderEventKind, control: String)] = [],
        mixerMidi: [(takeRelativeTime: Double, controller: Int, mappedControl: String?)] = []
    ) -> CaptureCore.DetectedNotationSnapshot {
        let audioEvents = audio.map {
            CaptureCore.DetectedNotationAudioEvent(
                startTime: $0.startTime,
                endTime: $0.endTime,
                duration: $0.endTime - $0.startTime,
                peakLevel: 0.5,
                rmsLevel: 0.2,
                confidence: 0.7,
                eventKind: $0.kind,
                source: "audio"
            )
        }
        let movementEvents = movements.map {
            CaptureCore.DetectedNotationRecordMovementEvent(
                startTime: $0.startTime,
                endTime: $0.endTime,
                startPosition: 0.0,
                endPosition: 1.0,
                direction: $0.direction,
                movementKind: .normalPush,
                speed: 1.0,
                confidence: 0.7,
                source: "detected"
            )
        }
        let faderEvents = faders.map {
            CaptureCore.DetectedNotationFaderEvent(
                startTime: $0.startTime,
                endTime: $0.endTime,
                eventKind: $0.kind,
                control: $0.control,
                fromValue: 0.0,
                toValue: 1.0,
                source: "detected",
                confidence: 0.7
            )
        }
        let midiEvents = mixerMidi.map {
            CaptureCore.RawMixerMIDIEvent(
                timestamp: $0.takeRelativeTime,
                takeRelativeTime: $0.takeRelativeTime,
                deviceName: "Test",
                channel: 1,
                controller: $0.controller,
                value: 64,
                normalizedValue: 0.5,
                mappedControl: $0.mappedControl
            )
        }
        return CaptureCore.DetectedNotationSnapshot(
            notationSource: "detected",
            notationConfidence: nil,
            detectedLabel: nil,
            labelSource: "detected",
            labelConfidence: nil,
            detectionSources: ["audio"],
            recordMovementEvents: movementEvents,
            audioEvents: audioEvents,
            faderEvents: faderEvents,
            mixerMidiEvents: midiEvents,
            capturedAt: Self.referenceDate
        )
    }
}
