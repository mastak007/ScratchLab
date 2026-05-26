import XCTest
@testable import ScratchLab

final class SessionReplayDocumentTests: XCTestCase {

    private static let referenceDate = Date(timeIntervalSince1970: 1_780_800_000)

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

    // MARK: - Round-trip

    func testReplayDocumentRoundTripPopulated() throws {
        let snapshot = makeSnapshot()
        let timeline = SessionReplayTimeline.build(
            from: snapshot,
            takeDuration: snapshot.capturedEvidenceEndTime ?? 1.0
        )
        let document = SessionExportReplayDocument(
            sessionID: "session-replay-001",
            generatedAt: Self.referenceDate,
            takes: [
                SessionExportReplayTake(takeID: "take001", takeNumber: 1, timeline: timeline),
                SessionExportReplayTake(takeID: "take002", takeNumber: 2, timeline: nil)
            ]
        )

        let encoded = try encoder.encode(document)
        let decoded = try decoder.decode(SessionExportReplayDocument.self, from: encoded)

        XCTAssertEqual(decoded.schemaVersion, SessionExportReplayDocument.currentSchemaVersion)
        XCTAssertEqual(decoded.sessionID, "session-replay-001")
        XCTAssertEqual(decoded.takes.count, 2)
        XCTAssertEqual(decoded.takes.first?.timeline, timeline)
        XCTAssertNil(decoded.takes.last?.timeline)
        XCTAssertTrue(decoded.hasTimelines)
    }

    func testReplayDocumentRoundTripEmpty() throws {
        let document = SessionExportReplayDocument(
            sessionID: "session-replay-empty",
            generatedAt: Self.referenceDate,
            takes: []
        )

        let encoded = try encoder.encode(document)
        let decoded = try decoder.decode(SessionExportReplayDocument.self, from: encoded)

        XCTAssertEqual(decoded.schemaVersion, "scratchlab_session_replay_v1")
        XCTAssertEqual(decoded.sessionID, "session-replay-empty")
        XCTAssertTrue(decoded.takes.isEmpty)
        XCTAssertFalse(decoded.hasTimelines)
    }

    // MARK: - Built from sidecar snapshot

    func testReplayDocumentBuiltFromSidecarSnapshot() throws {
        let snapshot = makeSnapshot()
        let stagedDuration: TimeInterval = 9.99 // intentionally != capturedEvidenceEndTime
        let directory = try makeTemporaryDirectory()
        let take = try writeSidecar(
            directory: directory,
            takeNumber: 1,
            duration: stagedDuration,
            detectedNotation: snapshot
        )
        let package = makePackage(sessionID: "session-replay-build", takes: [take])

        let document = SessionArchiveBuilder().replayDocument(
            for: package,
            generatedAt: Self.referenceDate
        )

        XCTAssertEqual(document.schemaVersion, SessionExportReplayDocument.currentSchemaVersion)
        XCTAssertEqual(document.sessionID, "session-replay-build")
        XCTAssertEqual(document.generatedAt, Self.referenceDate)
        XCTAssertEqual(document.takes.count, 1)

        let timeline = try XCTUnwrap(document.takes.first?.timeline)
        let expectedDuration = try XCTUnwrap(snapshot.capturedEvidenceEndTime)
        let expectedTimeline = SessionReplayTimeline.build(
            from: snapshot,
            takeDuration: expectedDuration
        )
        XCTAssertEqual(timeline, expectedTimeline)
        XCTAssertEqual(timeline.takeDurationSeconds, expectedDuration)
        XCTAssertNotEqual(timeline.takeDurationSeconds, stagedDuration,
                          "capturedEvidenceEndTime must win over the staged take.duration when available.")
    }

    func testReplayDocumentFallsBackToTakeDurationWhenNoEvidenceEndTime() throws {
        let snapshot = CaptureCore.DetectedNotationSnapshot(
            notationSource: "partial",
            notationConfidence: nil,
            detectedLabel: nil,
            labelSource: "unknown",
            labelConfidence: nil,
            detectionSources: [],
            recordMovementEvents: [],
            audioEvents: [],
            faderEvents: [],
            mixerMidiEvents: [],
            capturedAt: Self.referenceDate
        )
        XCTAssertNil(snapshot.capturedEvidenceEndTime, "Sanity: fixture must have no evidence end time.")

        let stagedDuration: TimeInterval = 3.5
        let directory = try makeTemporaryDirectory()
        let take = try writeSidecar(
            directory: directory,
            takeNumber: 2,
            duration: stagedDuration,
            detectedNotation: snapshot
        )
        let package = makePackage(sessionID: "session-replay-fallback", takes: [take])

        let document = SessionArchiveBuilder().replayDocument(for: package)

        let timeline = try XCTUnwrap(document.takes.first?.timeline)
        XCTAssertEqual(timeline.takeDurationSeconds, stagedDuration)
        XCTAssertTrue(timeline.events.isEmpty)
    }

    // MARK: - Missing detectedNotation

    func testReplayDocumentProducesNilTimelineWhenDetectedNotationMissing() throws {
        let directory = try makeTemporaryDirectory()
        let take = try writeSidecar(
            directory: directory,
            takeNumber: 1,
            duration: 4.2,
            detectedNotation: nil
        )
        let package = makePackage(sessionID: "session-replay-nil", takes: [take])

        let document = SessionArchiveBuilder().replayDocument(for: package)

        XCTAssertEqual(document.takes.count, 1)
        XCTAssertNil(document.takes.first?.timeline)
        XCTAssertFalse(document.hasTimelines)
    }

    func testReplayDocumentAlwaysEmittedEvenWithNoTakes() {
        let package = makePackage(sessionID: "session-replay-zero-takes", takes: [])
        let document = SessionArchiveBuilder().replayDocument(for: package)

        XCTAssertEqual(document.schemaVersion, "scratchlab_session_replay_v1")
        XCTAssertTrue(document.takes.isEmpty)
        XCTAssertFalse(document.hasTimelines)
    }

    // MARK: - Additive contract

    func testReplaySchemaVersionMatchesTimelineContract() {
        XCTAssertEqual(SessionExportReplayDocument.currentSchemaVersion, "scratchlab_session_replay_v1")
        XCTAssertEqual(SessionReplayTimeline.currentSchemaVersion, "scratchlab_session_replay_v1")
    }

    func testV4SessionExportSchemaVersionUnchanged() {
        XCTAssertEqual(SessionExportMetadata.currentSchemaVersion, "scratchlab_session_export_v4")
    }

    // MARK: - Helpers

    private func makeSnapshot() -> CaptureCore.DetectedNotationSnapshot {
        CaptureCore.DetectedNotationSnapshot(
            notationSource: "detected",
            notationConfidence: 0.71,
            detectedLabel: "Baby Scratch",
            labelSource: "detected",
            labelConfidence: 57,
            detectionSources: ["audio", "video"],
            recordMovementEvents: [
                CaptureCore.DetectedNotationRecordMovementEvent(
                    startTime: 0.10,
                    endTime: 0.28,
                    startPosition: 0.02,
                    endPosition: 0.96,
                    direction: "forward",
                    movementKind: .normalPush,
                    speed: 5.2,
                    confidence: 0.82,
                    source: "detected"
                ),
                CaptureCore.DetectedNotationRecordMovementEvent(
                    startTime: 0.34,
                    endTime: 0.56,
                    startPosition: 0.94,
                    endPosition: 0.08,
                    direction: "backward",
                    movementKind: .normalPull,
                    speed: 3.9,
                    confidence: 0.76,
                    source: "detected"
                )
            ],
            audioEvents: [
                CaptureCore.DetectedNotationAudioEvent(
                    startTime: 0.10,
                    endTime: 0.28,
                    duration: 0.18,
                    peakLevel: 0.42,
                    rmsLevel: 0.18,
                    confidence: 0.71,
                    eventKind: "scratchBurst",
                    source: "audio"
                ),
                CaptureCore.DetectedNotationAudioEvent(
                    startTime: 0.34,
                    endTime: 0.56,
                    duration: 0.22,
                    peakLevel: 0.37,
                    rmsLevel: 0.15,
                    confidence: 0.67,
                    eventKind: "possibleDrag",
                    source: "audio"
                )
            ],
            faderEvents: [],
            mixerMidiEvents: [],
            capturedAt: Self.referenceDate
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionReplayDocumentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func writeSidecar(
        directory: URL,
        takeNumber: Int,
        duration: TimeInterval,
        detectedNotation: CaptureCore.DetectedNotationSnapshot?
    ) throws -> SessionExportTake {
        let sessionID = "replay-test-session"
        let baseName = "\(sessionID)_take\(String(format: "%03d", takeNumber))_routine"
        let mediaURL = directory.appendingPathComponent("\(baseName).mov")
        let sidecarURL = directory.appendingPathComponent("\(baseName).json")
        let files = CaptureCore.LocalRecordingFiles(
            baseName: baseName,
            mediaURL: mediaURL,
            sidecarURL: sidecarURL
        )
        var sidecar = CaptureCore.LocalRecordingSidecar.recording(
            sessionID: sessionID,
            takeIdentity: CaptureCore.LocalRecordingNaming.takeIdentity(
                sessionID: sessionID,
                takeNumber: takeNumber
            ),
            files: files,
            recordingRole: "routine_capture",
            platform: "macOS",
            appSurface: "mac_desktop",
            sourceDeviceName: "ScratchLab Mac",
            startedAt: Self.referenceDate
        )
        if let detectedNotation {
            sidecar = sidecar.withDetectedNotation(detectedNotation, recordedAt: Self.referenceDate)
        }
        try sidecar.encodedData().write(to: sidecarURL, options: .atomic)

        return SessionExportTake(
            takeID: sidecar.takeID,
            takeNumber: takeNumber,
            bpm: 90,
            mediaURL: mediaURL,
            audioArtifactURL: nil,
            sidecarURL: sidecarURL,
            watchCaptureSession: nil,
            drillName: nil,
            duration: duration,
            quality: nil,
            comboTagged: false,
            audioPresent: true,
            motionPresent: false,
            syncStatus: nil,
            recordingStatus: "completed",
            verbalSlateUsed: nil,
            syncClapUsed: nil,
            note: nil
        )
    }

    private func makePackage(sessionID: String, takes: [SessionExportTake]) -> SessionExportPackage {
        let totalDuration = takes.reduce(into: 0.0) { $0 += $1.duration }
        let metadata = SessionExportMetadata(
            sessionID: sessionID,
            workflow: "routine",
            platform: "macOS",
            sessionName: "Session Replay Test",
            createdAt: Self.referenceDate,
            takeCount: takes.count,
            totalDurationSeconds: totalDuration
        )
        return SessionExportPackage(metadata: metadata, takes: takes, calibrationData: nil)
    }
}
