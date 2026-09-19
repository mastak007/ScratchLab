import AVFoundation
import XCTest
@testable import ScratchLab

@MainActor
final class MIDIAttemptEvidenceTests: XCTestCase {
    private let connection = UUID()

    private func window() -> MIDIAttemptEvidence {
        let result = MIDIAttemptEvidence()
        result.updateConnections(["midi_1": connection], at: 99)
        result.selectSource("midi_1", at: 99)
        result.begin(at: 100)
        return result
    }

    private func ingress(
        _ owner: MIDIAttemptEvidence, value: UInt8 = 8, cc: UInt8 = 6,
        time: Double? = 100.1, received: Double = 101,
        source: String = "midi_1", connectionID: UUID? = nil
    ) -> MIDIIngressMessage {
        let metadata = MIDIIngressMetadata(
            sourceID: source, sourceName: "Rane ONE MKII",
            connectionID: connectionID ?? connection, packetTime: time,
            receivedAt: received,
            attemptGeneration: owner.ingressGeneration.load(ordering: .acquiring)
        )
        var result: [MIDIIngressMessage] = []
        [UInt8(0xB1), cc, value].withUnsafeBytes {
            MIDIChannelMessageParser.parse($0, metadata: metadata) { result.append($0) }
        }
        return result[0]
    }

    private func record(_ message: MIDIIngressMessage, in owner: MIDIAttemptEvidence) -> Bool {
        owner.record(message, normalizedValue: Double(message.message.value) / 127,
                     mappedControl: message.message.controlNumber == 8 ? "crossfader" : nil,
                     mappingSource: message.message.controlNumber == 8 ? .learned : nil)
    }

    private func densePackets(_ owner: MIDIAttemptEvidence) {
        let values: [UInt8] = [0, 8, 16, 24, 25, 26, 27, 40, 55, 70, 85,
                               70, 55, 40, 27, 26, 25, 24, 16, 8, 0]
        for (index, value) in values.enumerated() {
            XCTAssertTrue(record(ingress(owner, value: value, time: 100.01 + Double(index) * 0.02), in: owner))
        }
    }

    func testPacketHostTimestampSurvivesQueuedDeliveryIntoRawEvidence() throws {
        let owner = window()
        let hostTicks = AVAudioTime.hostTime(forSeconds: 100.125)
        let packetTime = AVAudioTime.seconds(forHostTime: hostTicks)
        let queued = ingress(owner, time: packetTime, received: 102)
        XCTAssertTrue(record(queued, in: owner))
        let raw = try XCTUnwrap(owner.platterEvents.first)
        XCTAssertEqual(raw.timestamp, packetTime)
        XCTAssertEqual(raw.takeRelativeTime, packetTime - 100)
        XCTAssertNotEqual(raw.timestamp, queued.metadata.receivedAt)
        XCTAssertEqual(raw.deviceIdentifier, "midi_1")
        XCTAssertEqual(raw.deviceName, "Rane ONE MKII")
    }

    func testMessagesInOnePacketDoNotAcquireInventedSampleSpacing() {
        let owner = window()
        let metadata = ingress(owner).metadata
        let bytes: [UInt8] = [0xB1, 6, 0, 0xB1, 6, 20]
        bytes.withUnsafeBytes {
            MIDIChannelMessageParser.parse($0, metadata: metadata) { XCTAssertTrue(record($0, in: owner)) }
        }
        XCTAssertEqual(owner.platterEvents.map(\.timestamp), [100.1, 100.1])
        let evidence = CaptureCore.derivePlatterMotionEvidence(from: owner.platterEvents, controller: 6, channel: 1)
        XCTAssertTrue(evidence.intervals.contains { $0.kind == .insufficientSampling })
        XCTAssertTrue(evidence.events.isEmpty)
    }

    func testSameNamedSourcesRemainDistinctAndOnlySelectedSourceIsAdmitted() {
        let owner = window()
        let foreign = ingress(owner, source: "midi_2")
        let selected = ingress(owner)
        XCTAssertEqual(foreign.metadata.sourceName, selected.metadata.sourceName)
        XCTAssertNotEqual(foreign.metadata.sourceID, selected.metadata.sourceID)
        XCTAssertFalse(record(foreign, in: owner))
        XCTAssertTrue(record(selected, in: owner))
        XCTAssertEqual(owner.platterEvents.map(\.deviceIdentifier), ["midi_1"])
    }

    func testQueuedAttemptACannotRepopulateAttemptBAndValidBIsAccepted() {
        let owner = window()
        let oldPlatter = ingress(owner)
        let oldFader = ingress(owner, cc: 8)
        XCTAssertTrue(record(oldPlatter, in: owner))
        XCTAssertTrue(record(oldFader, in: owner))
        owner.seal(at: 102)
        owner.begin(at: 103)
        XCTAssertTrue(owner.platterEvents.isEmpty)
        XCTAssertTrue(owner.crossfaderEvents.isEmpty)
        XCTAssertFalse(record(oldPlatter, in: owner))
        XCTAssertFalse(record(oldFader, in: owner))
        XCTAssertTrue(owner.platterEvents.isEmpty)
        XCTAssertTrue(owner.crossfaderEvents.isEmpty)
        XCTAssertTrue(record(ingress(owner, time: 103.1, received: 104), in: owner))
        XCTAssertTrue(record(ingress(owner, cc: 8, time: 103.2, received: 104), in: owner))
        XCTAssertEqual(owner.platterEvents.count, 1)
        XCTAssertEqual(owner.crossfaderEvents.count, 1)
        XCTAssertEqual(owner.crossfaderEvents.first?.mappingSource, .learned)
    }

    func testResetWithoutExplicitStopAlsoRetiresTheOldTicket() {
        let owner = window()
        let old = ingress(owner)
        owner.begin(at: 103)
        XCTAssertNotEqual(owner.activeGeneration, old.metadata.attemptGeneration)
        XCTAssertFalse(record(old, in: owner))
        XCTAssertTrue(owner.platterEvents.isEmpty)
    }

    func testReceiptFenceRejectsCallbackThatStartedBeforeResetButReadNewTicket() {
        let owner = window()
        owner.begin(at: 103)
        XCTAssertFalse(record(ingress(owner, time: 103.1, received: 102), in: owner))
        XCTAssertFalse(record(ingress(owner, time: 103, received: 103), in: owner))
        // An old packet delivered by a genuinely new callback is also old evidence.
        XCTAssertFalse(record(ingress(owner, time: 102, received: 104), in: owner))
        XCTAssertTrue(owner.platterEvents.isEmpty)
    }

    func testClosedIdleWindowCannotCollectBeforeExplicitStart() {
        let owner = window()
        owner.clear(at: 103)
        let idle = ingress(owner, time: 103.1, received: 104)
        XCTAssertEqual(idle.metadata.attemptGeneration, 0)
        XCTAssertFalse(record(idle, in: owner))
        owner.begin(at: 105)
        XCTAssertFalse(record(idle, in: owner))
        XCTAssertTrue(owner.platterEvents.isEmpty)
    }

    func testTicketCapturedOffActorCannotBeReassignedByDelayedDelivery() async {
        let owner = window()
        let connectionID = connection
        let queued = await Task.detached {
            MIDIIngressMessage(
                message: MIDIMessageParsing.parse([0xB1, 6, 20]),
                metadata: MIDIIngressMetadata(
                    sourceID: "midi_1", sourceName: "Rane ONE MKII", connectionID: connectionID,
                    packetTime: 100.1, receivedAt: 101,
                    attemptGeneration: owner.ingressGeneration.load(ordering: .acquiring)
                )
            )
        }.value
        owner.begin(at: 103)
        XCTAssertFalse(record(queued, in: owner))
        XCTAssertTrue(owner.platterEvents.isEmpty)
    }

    func testUpfaderUsesTheSameStopAndResetOwnership() {
        let owner = window()
        let queued = ingress(owner, cc: 9)
        XCTAssertTrue(owner.record(queued, normalizedValue: 0.25, mappedControl: "rightUpfader"))
        owner.seal(at: 102)
        XCTAssertFalse(owner.record(queued, normalizedValue: 0.25, mappedControl: "rightUpfader"))
        XCTAssertEqual(owner.upfaderEvents.count, 1)
        owner.begin(at: 103)
        XCTAssertFalse(owner.record(queued, normalizedValue: 0.25, mappedControl: "rightUpfader"))
        XCTAssertTrue(owner.upfaderEvents.isEmpty)
    }

    func testCompletedEvidenceAndDerivedResultStayImmutableAfterStop() throws {
        let owner = window()
        densePackets(owner)
        XCTAssertTrue(record(ingress(owner, cc: 8), in: owner))
        let queued = ingress(owner, value: 90, time: 100.9)
        let queuedFader = ingress(owner, cc: 8, time: 100.9)
        owner.seal(at: 102)
        let raw = owner.platterEvents
        let fader = owner.crossfaderEvents
        let before = CaptureCore.derivePlatterMotionEvidence(from: raw, controller: 6, channel: 1)
        XCTAssertFalse(record(queued, in: owner))
        XCTAssertFalse(record(queuedFader, in: owner))
        XCTAssertFalse(record(ingress(owner, time: 103, received: 104), in: owner))
        XCTAssertFalse(record(ingress(owner, cc: 8, time: 103, received: 104), in: owner))
        XCTAssertEqual(owner.platterEvents, raw)
        XCTAssertEqual(owner.crossfaderEvents, fader)
        XCTAssertEqual(owner.stopRelativeTime, 2)
        let after = CaptureCore.derivePlatterMotionEvidence(from: owner.platterEvents, controller: 6, channel: 1)
        XCTAssertEqual(after.events, before.events)
        XCTAssertEqual(after.trajectorySegments, before.trajectorySegments)
    }

    func testDisconnectAndSameIDReconnectSealTheOldWindow() {
        let owner = window()
        XCTAssertTrue(record(ingress(owner), in: owner))
        let queued = ingress(owner)
        owner.updateConnections([:], at: 102)
        XCTAssertEqual(owner.interruption, .connectionChanged)
        let newConnection = UUID()
        owner.updateConnections(["midi_1": newConnection], at: 103)
        XCTAssertFalse(record(queued, in: owner))
        XCTAssertFalse(record(ingress(owner, time: 103.1, received: 104, connectionID: newConnection), in: owner))
        XCTAssertEqual(owner.platterEvents.count, 1)
        owner.begin(at: 105)
        XCTAssertFalse(record(ingress(owner, time: 105.1, received: 106), in: owner))
        XCTAssertTrue(record(ingress(owner, time: 105.1, received: 106, connectionID: newConnection), in: owner))
        XCTAssertEqual(owner.platterEvents.count, 1)
    }

    func testConnectionReplacementWithoutEmptyDiscoveryAlsoSeals() {
        let owner = window()
        owner.updateConnections(["midi_1": UUID()], at: 102)
        XCTAssertNil(owner.activeGeneration)
        XCTAssertEqual(owner.interruption, .connectionChanged)
    }

    func testSelectedSourceChangeSealsWhileUnrelatedDiscoveryDoesNot() {
        let owner = window()
        owner.updateConnections(["midi_1": connection, "midi_2": UUID()], at: 101)
        XCTAssertNotNil(owner.activeGeneration)
        owner.selectSource("midi_2", at: 102)
        XCTAssertNil(owner.activeGeneration)
        XCTAssertEqual(owner.interruption, .sourceChanged)
        XCTAssertFalse(record(ingress(owner, source: "midi_2"), in: owner))
    }

    func testUnknownOrInvalidPacketTimeSealsRatherThanBridging() {
        for time: Double? in [nil, 0, .nan, .infinity, 105] {
            let owner = window()
            XCTAssertTrue(record(ingress(owner), in: owner))
            XCTAssertFalse(record(ingress(owner, time: time), in: owner))
            XCTAssertEqual(owner.interruption, .timestampUnavailable)
            XCTAssertFalse(record(ingress(owner, time: 102, received: 103), in: owner))
            XCTAssertEqual(owner.platterEvents.count, 1)
        }
    }

    func testFaderWithUnknownTimeAlsoClosesTheSharedEvidenceWindow() {
        let owner = window()
        XCTAssertFalse(record(ingress(owner, cc: 8, time: nil), in: owner))
        XCTAssertEqual(owner.interruption, .timestampUnavailable)
        XCTAssertFalse(record(ingress(owner), in: owner))
        XCTAssertTrue(owner.crossfaderEvents.isEmpty)
    }

    func testIngressPacketGapSurvivesDelayedMainActorDelivery() {
        let owner = window()
        for (time, value): (Double, UInt8) in [(100.01, 0), (100.06, 20), (100.11, 40),
                                               (100.5, 50), (100.55, 70), (100.6, 90)] {
            XCTAssertTrue(record(ingress(owner, value: value, time: time, received: 102), in: owner))
        }
        let evidence = CaptureCore.derivePlatterMotionEvidence(from: owner.platterEvents, controller: 6, channel: 1)
        XCTAssertEqual(evidence.trajectorySegments.count, 2)
        XCTAssertEqual(evidence.trajectorySegments.last?.boundaryBefore, .packetGap)
    }

    func testDenseProjectionScoringAndExistingEncodedSnapshotRemainStable() throws {
        let owner = window()
        densePackets(owner)
        let raw = owner.platterEvents
        let evidence = CaptureCore.derivePlatterMotionEvidence(from: raw, controller: 6, channel: 1)
        let snapshot = CaptureCore.DetectedNotationSnapshot(
            notationSource: "detected", notationConfidence: 0.9, detectedLabel: nil,
            labelSource: "unknown", labelConfidence: nil, detectionSources: ["controller"],
            recordMovementEvents: evidence.events, audioEvents: [], faderEvents: [],
            mixerMidiEvents: raw, capturedAt: Date(timeIntervalSince1970: 0)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(snapshot)
        let score = PracticeAttemptEvidenceResolver.liveCycleAttempt(
            pattern: ScratchNotation.babyScratchCycle, bpm: 150, countInBeats: 0, cycleIndex: 0, snapshot: snapshot)
        XCTAssertNotNil(score)
        let projection = PracticePerformedNotationPresentation.project(
            movementEvents: evidence.events, trajectorySegments: evidence.trajectorySegments,
            evidenceIntervals: evidence.intervals)
        let geometry = try XCTUnwrap(PracticePerformedNotationPresentation.geometry(projection: projection, bpm: 150))
        XCTAssertEqual(geometry.motion.segments.count, 20)
        XCTAssertEqual(geometry.motion.position(at: 0.13), 27.0 / 85, accuracy: 1e-8)
        owner.seal(at: 102)
        XCTAssertFalse(record(ingress(owner, time: 103, received: 104), in: owner))
        XCTAssertEqual(owner.platterEvents, raw)
        XCTAssertEqual(try encoder.encode(snapshot), encoded)
        XCTAssertEqual(PracticeAttemptEvidenceResolver.liveCycleAttempt(
            pattern: ScratchNotation.babyScratchCycle, bpm: 150, countInBeats: 0, cycleIndex: 0, snapshot: snapshot), score)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(json.contains("attemptGeneration"))
        XCTAssertFalse(json.contains("connectionID"))
        XCTAssertFalse(json.contains("trajectorySegments"))
    }

    func testIOSAdapterAndPracticeLifecycleUseTheTestedOwner() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let adapter = try source("ScratchLab/MIDI/iOSMIDIManager.swift")
        let practice = try source("ScratchLab/Views/PracticeModeView.swift")
        let app = try source("ScratchLab/ScratchLabApp.swift")
        XCTAssertTrue(adapter.contains("AVAudioTime.seconds(forHostTime: timestamp)"))
        XCTAssertTrue(adapter.contains("MIDIChannelMessageParser.parse(bytes, metadata: metadata)"))
        XCTAssertTrue(adapter.contains("metadata.connectionID"))
        XCTAssertTrue(adapter.contains("notification.pointee.messageID == .msgObjectRemoved"))
        XCTAssertTrue(adapter.contains("self.evidence.activeGeneration == generation"))
        XCTAssertFalse(adapter.contains("capturedPlatterMIDIEvents.append"))
        XCTAssertFalse(adapter.contains("capturedCrossfaderMIDIEvents.append"))
        XCTAssertFalse(adapter.contains("capturedUpfaderMIDIEvents.append"))
        XCTAssertTrue(app.contains("IOSMIDIManager(evidence: evidence)"))
        XCTAssertTrue(app.contains("playbackEngine: scratchPlaybackEngine,\n            evidence: evidence"))
        XCTAssertTrue(practice.contains("private func endSession() {\n        midiControllerDispatcher.markCaptureStopped()"))
        XCTAssertTrue(practice.contains("private func cleanupSession() {\n        midiControllerDispatcher.markCaptureStopped()"))
        XCTAssertTrue(practice.contains("midiControllerDispatcher.clearCapturedPlatterEvents()"))
    }
}
