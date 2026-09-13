import XCTest
@testable import ScratchLab

final class SessionReviewMetadataTests: XCTestCase {

    private static let referenceDate = Date(timeIntervalSince1970: 1_780_000_000)

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    // MARK: - State enum

    func testReviewStateRawValuesAreStable() {
        XCTAssertEqual(CaptureCore.SessionReviewState.unreviewed.rawValue, "unreviewed")
        XCTAssertEqual(CaptureCore.SessionReviewState.approved.rawValue, "approved")
        XCTAssertEqual(CaptureCore.SessionReviewState.rejected.rawValue, "rejected")
        XCTAssertEqual(CaptureCore.SessionReviewState.lowSignal.rawValue, "low_signal")
        XCTAssertEqual(CaptureCore.SessionReviewState.timingDrift.rawValue, "timing_drift")
        XCTAssertEqual(CaptureCore.SessionReviewState.mislabeled.rawValue, "mislabeled")
        XCTAssertEqual(CaptureCore.SessionReviewState.needsManualReview.rawValue, "needs_manual_review")
        XCTAssertEqual(CaptureCore.SessionReviewState.allCases.count, 7)
    }

    func testReviewWarningRawValuesAreStable() {
        XCTAssertEqual(CaptureCore.SessionReviewWarning.Kind.clippedAudio.rawValue, "clipped_audio")
        XCTAssertEqual(CaptureCore.SessionReviewWarning.Kind.lowAmplitude.rawValue, "low_amplitude")
        XCTAssertEqual(CaptureCore.SessionReviewWarning.Kind.unstableOnsetSpacing.rawValue, "unstable_onset_spacing")
        XCTAssertEqual(CaptureCore.SessionReviewWarning.Kind.missingPhraseRegion.rawValue, "missing_phrase_region")
        XCTAssertEqual(CaptureCore.SessionReviewWarning.Kind.inconsistentDirection.rawValue, "inconsistent_direction")
    }

    // MARK: - Sidecar round-trip

    func testReviewMetadataRoundTripsThroughSidecarJSON() throws {
        let now = Self.referenceDate
        let sidecar = makeSidecar(at: now)
        let metadata = CaptureCore.CaptureReviewMetadata(
            reviewState: .approved,
            reviewedAt: now.addingTimeInterval(30),
            reviewedBy: "kw",
            reviewNotes: "Clean baby scratch take, fader work crisp.",
            qualityFlags: CaptureCore.SessionReviewQualityFlags(
                signalQualityFlagged: false,
                timingStabilityFlagged: true,
                noiseFloorFlagged: false,
                directionReliabilityFlagged: false
            ),
            labelOverride: "babyScratch",
            isTrainingQuality: true,
            warnings: [
                CaptureCore.SessionReviewWarning(
                    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    kind: .lowAmplitude,
                    detail: "Median peak level 0.05 below 0.10.",
                    raisedAt: now.addingTimeInterval(15)
                )
            ]
        )

        let updated = sidecar.withReviewMetadata(metadata, audit: "Reviewer kw approved.")
        let encoded = try updated.encodedData()
        let decoded = try decoder.decode(CaptureCore.LocalRecordingSidecar.self, from: encoded)

        let restored = try XCTUnwrap(decoded.reviewMetadata)
        XCTAssertEqual(restored.reviewState, .approved)
        XCTAssertEqual(restored.reviewedBy, "kw")
        XCTAssertEqual(restored.reviewNotes, "Clean baby scratch take, fader work crisp.")
        XCTAssertEqual(restored.qualityFlags.timingStabilityFlagged, true)
        XCTAssertEqual(restored.qualityFlags.signalQualityFlagged, false)
        XCTAssertEqual(restored.labelOverride, "babyScratch")
        XCTAssertTrue(restored.isTrainingQuality)
        XCTAssertEqual(restored.warnings.count, 1)
        XCTAssertEqual(restored.warnings.first?.kind, .lowAmplitude)
        XCTAssertEqual(restored.schemaVersion, CaptureCore.CaptureReviewMetadata.currentSchemaVersion)
    }

    func testReviewMetadataAuditEventRecorded() throws {
        let now = Self.referenceDate
        let sidecar = makeSidecar(at: now)
        let metadata = CaptureCore.CaptureReviewMetadata(reviewState: .rejected, reviewedAt: now)
        let updated = sidecar.withReviewMetadata(metadata, audit: "Take rejected for clipping.")
        let lastEvent = try XCTUnwrap(updated.auditTrail.last)
        XCTAssertEqual(lastEvent.category, "review_metadata_updated")
        XCTAssertEqual(lastEvent.detail, "Take rejected for clipping.")
    }

    func testSidecarWithoutReviewMetadataDecodesAsNil() throws {
        let now = Self.referenceDate
        let sidecar = makeSidecar(at: now)
        let encoded = try sidecar.encodedData()
        let decoded = try decoder.decode(CaptureCore.LocalRecordingSidecar.self, from: encoded)
        XCTAssertNil(decoded.reviewMetadata)
    }

    // MARK: - Label decision (confirmation / correction) round-trip

    func testReviewDecisionStatusRawValuesAreStable() {
        XCTAssertEqual(CaptureCore.CaptureReviewDecision.Status.accepted.rawValue, "accepted")
        XCTAssertEqual(CaptureCore.CaptureReviewDecision.Status.corrected.rawValue, "corrected")
        XCTAssertEqual(CaptureCore.CaptureReviewDecision.Status.unknown.rawValue, "unknown")
    }

    func testLabelConfirmationRoundTripsThroughSidecarJSON() throws {
        let now = Self.referenceDate
        let sidecar = makeSidecar(at: now)
        let updated = sidecar.reviewed(
            status: .accepted,
            label: "babyScratch",
            detectedLabel: "baby_scratch",
            confidence: 0.92,
            reviewedAt: now.addingTimeInterval(60)
        )

        let encoded = try updated.encodedData()
        let decoded = try decoder.decode(CaptureCore.LocalRecordingSidecar.self, from: encoded)

        let decision = try XCTUnwrap(decoded.reviewDecision)
        XCTAssertEqual(decision.status, .accepted, "label confirmation must persist as .accepted")
        XCTAssertEqual(decision.label, "babyScratch")
        XCTAssertEqual(decision.detectedLabel, "baby_scratch")
        XCTAssertEqual(decision.confidence ?? -1, 0.92, accuracy: 1e-9)
        XCTAssertEqual(decision.reviewedAt, now.addingTimeInterval(60))
    }

    func testLabelCorrectionRoundTripsThroughSidecarJSON() throws {
        let now = Self.referenceDate
        let sidecar = makeSidecar(at: now)
        let updated = sidecar.reviewed(
            status: .corrected,
            label: "chirp",
            detectedLabel: "baby_scratch",
            confidence: 0.55,
            reviewedAt: now.addingTimeInterval(30)
        )

        let encoded = try updated.encodedData()
        let decoded = try decoder.decode(CaptureCore.LocalRecordingSidecar.self, from: encoded)

        let decision = try XCTUnwrap(decoded.reviewDecision)
        XCTAssertEqual(decision.status, .corrected, "label correction must persist as .corrected")
        XCTAssertEqual(decision.label, "chirp", "correction changes only the review label, never the raw evidence")
        XCTAssertEqual(decision.detectedLabel, "baby_scratch", "the detected label is preserved alongside the correction")
    }

    func testReviewDecisionAuditEventRecorded() throws {
        let now = Self.referenceDate
        let sidecar = makeSidecar(at: now)
        let updated = sidecar.reviewed(
            status: .accepted,
            label: "babyScratch",
            detectedLabel: "baby_scratch",
            confidence: 0.9,
            reviewedAt: now
        )
        let lastEvent = try XCTUnwrap(updated.auditTrail.last)
        XCTAssertEqual(lastEvent.category, "label_reviewed")
    }

    // MARK: - Validator

    func testValidatorFlagsClippedAudio() {
        let snapshot = makeAudioOnlySnapshot(peakLevels: [0.40, 0.42, 0.99, 0.38])
        let warnings = SessionReviewValidator.warnings(for: snapshot, takeDuration: 2.0)
        XCTAssertTrue(warnings.contains { $0.kind == .clippedAudio })
    }

    func testValidatorFlagsLowAmplitude() {
        let snapshot = makeAudioOnlySnapshot(peakLevels: Array(repeating: 0.05, count: 6))
        let warnings = SessionReviewValidator.warnings(for: snapshot, takeDuration: 3.0)
        XCTAssertTrue(warnings.contains { $0.kind == .lowAmplitude })
    }

    func testValidatorFlagsUnstableOnsetSpacing() {
        let snapshot = makeAudioOnlySnapshot(
            startTimes: [0.0, 1.0, 1.05, 2.5],
            peakLevels: [0.4, 0.4, 0.4, 0.4]
        )
        let warnings = SessionReviewValidator.warnings(for: snapshot, takeDuration: 3.0)
        XCTAssertTrue(warnings.contains { $0.kind == .unstableOnsetSpacing })
    }

    func testValidatorDoesNotFlagStableOnsetSpacing() {
        let snapshot = makeAudioOnlySnapshot(
            startTimes: [0.0, 0.5, 1.0, 1.5, 2.0],
            peakLevels: [0.4, 0.4, 0.4, 0.4, 0.4]
        )
        let warnings = SessionReviewValidator.warnings(for: snapshot, takeDuration: 2.5)
        XCTAssertFalse(warnings.contains { $0.kind == .unstableOnsetSpacing })
    }

    func testValidatorFlagsMissingPhraseRegion() {
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
        let warnings = SessionReviewValidator.warnings(for: snapshot, takeDuration: 5.0)
        XCTAssertTrue(warnings.contains { $0.kind == .missingPhraseRegion })
    }

    func testValidatorFlagsInconsistentDirection() {
        let directions = ["forward", "backward", "forward", "backward", "forward", "backward",
                          "forward", "backward", "forward", "backward", "forward", "backward"]
        let movements = directions.enumerated().map { index, direction in
            CaptureCore.DetectedNotationRecordMovementEvent(
                startTime: Double(index) * 0.08,
                endTime: Double(index) * 0.08 + 0.06,
                startPosition: 0.0,
                endPosition: 1.0,
                direction: direction,
                movementKind: .normalPush,
                speed: 1.0,
                confidence: 0.5,
                source: "detected"
            )
        }
        let snapshot = CaptureCore.DetectedNotationSnapshot(
            notationSource: "detected",
            notationConfidence: nil,
            detectedLabel: nil,
            labelSource: "detected",
            labelConfidence: nil,
            detectionSources: ["video"],
            recordMovementEvents: movements,
            audioEvents: [],
            faderEvents: [],
            mixerMidiEvents: [],
            capturedAt: Self.referenceDate
        )
        let warnings = SessionReviewValidator.warnings(for: snapshot, takeDuration: 1.0)
        XCTAssertTrue(warnings.contains { $0.kind == .inconsistentDirection })
    }

    // MARK: - Export document

    func testReviewExportDocumentRoundTripPopulated() throws {
        let metadata = CaptureCore.CaptureReviewMetadata(
            reviewState: .needsManualReview,
            reviewedAt: Self.referenceDate,
            reviewedBy: "qa",
            reviewNotes: "Hand obscured in second half.",
            qualityFlags: CaptureCore.SessionReviewQualityFlags(directionReliabilityFlagged: true),
            isTrainingQuality: false
        )
        let document = SessionExportReviewDocument(
            sessionID: "session-001",
            generatedAt: Self.referenceDate,
            takes: [
                SessionExportReviewTake(takeID: "take001", takeNumber: 1, metadata: metadata),
                SessionExportReviewTake(takeID: "take002", takeNumber: 2, metadata: nil)
            ]
        )
        let encoded = try encoder.encode(document)
        let decoded = try decoder.decode(SessionExportReviewDocument.self, from: encoded)

        XCTAssertEqual(decoded.schemaVersion, SessionExportReviewDocument.currentSchemaVersion)
        XCTAssertEqual(decoded.sessionID, "session-001")
        XCTAssertEqual(decoded.takes.count, 2)
        XCTAssertEqual(decoded.takes.first?.metadata?.reviewState, .needsManualReview)
        XCTAssertEqual(decoded.takes.first?.metadata?.qualityFlags.directionReliabilityFlagged, true)
        XCTAssertNil(decoded.takes.last?.metadata)
        XCTAssertTrue(decoded.hasReviewedTakes)
    }

    func testReviewExportDocumentRoundTripEmpty() throws {
        let document = SessionExportReviewDocument(
            sessionID: "session-002",
            generatedAt: Self.referenceDate,
            takes: []
        )
        let encoded = try encoder.encode(document)
        let decoded = try decoder.decode(SessionExportReviewDocument.self, from: encoded)
        XCTAssertEqual(decoded.takes.count, 0)
        XCTAssertFalse(decoded.hasReviewedTakes)
    }

    // MARK: - On-disk sidecar decode

    /// Decodes a sidecar shaped exactly like a routine take written to disk by
    /// the macOS capture engine (captured `~/Library/Application Support/ScratchLab/RoutineCaptures`).
    /// This is the real-world shape `SessionExportCoordinator.decodeSidecar` must
    /// accept; a regression in `LocalRecordingSidecar`/`DetectedNotationSnapshot`
    /// Codable synthesis fails here with the raw `DecodingError`, which is what the
    /// export path would otherwise swallow behind the generic validation message.
    func testDecodesRealOnDiskSidecarShape() throws {
        let json = #"""
        {
          "appLocalTakeNumber" : 1,
          "appSurface" : "ScratchLab Routine Recorder",
          "audioDeviceName" : "Rane ONE MKII",
          "audioDeviceUniqueID" : "AppleUSBAudioEngine:Rane:Rane ONE MKII:3100000:1,2",
          "auditTrail" : [
            {
              "category" : "take_allocated",
              "detail" : "Allocated take-001 for session 657ec5f1-d893-4171-bdf4-9c3195615d9b.",
              "id" : "396A2B50-19BF-4E90-AE69-3FC40B1060AD",
              "timestamp" : "2026-07-12T11:17:38Z"
            },
            {
              "category" : "notation_snapshot",
              "detail" : "Captured detected notation snapshot with 0 movement events and 1 audio events.",
              "id" : "DD6972C7-A3D5-4ACB-BB12-10DF6E3E3384",
              "timestamp" : "2026-07-12T11:17:43Z"
            }
          ],
          "captureTiming" : {
            "clickStartHostTime" : 615010009431,
            "recordingStartHostTime" : 615070641009
          },
          "detectedNotation" : {
            "audioEvents" : [
              {
                "confidence" : 0.2072223573923111,
                "duration" : 5.109333333333354,
                "endTime" : 5.109333333333354,
                "eventKind" : "possibleDrag",
                "peakLevel" : 0.08893529325723648,
                "rmsLevel" : 0.07565431296825409,
                "source" : "audio",
                "startTime" : 0
              }
            ],
            "capturedAt" : "2026-07-12T11:17:43Z",
            "detectedLabel" : "Baby Scratch",
            "detectionSources" : ["audio"],
            "faderEvents" : [],
            "labelConfidence" : 56.80677612304687,
            "labelSource" : "detected",
            "mixerMidiEvents" : [],
            "notationConfidence" : 0.2072223573923111,
            "notationSource" : "partial",
            "recordMovementEvents" : []
          },
          "endedAt" : "2026-07-12T11:17:43Z",
          "mediaFileName" : "657ec5f1-d893-4171-bdf4-9c3195615d9b_take001_routine.mov",
          "platform" : "macOS",
          "recordingRole" : "mac_routine_capture",
          "recordingStatus" : "completed",
          "schemaVersion" : "scratchlab_local_recording_sidecar_v1",
          "sessionConfig" : {
            "beatEnabled" : false,
            "beatEngineMode" : "click_track",
            "beatPatternVersion" : "scratchlab-beats-v1",
            "beatsPerBar" : 4,
            "bpm" : 95,
            "captureMode" : "timed_click",
            "clickAccentPattern" : "accent-first-beat",
            "clickEnabled" : true,
            "clickVersion" : "scratchlab-click-v1",
            "countInBeats" : 4,
            "createdAt" : "2026-07-12T11:11:41Z",
            "drillMode" : "fullCapture",
            "engineVersion" : "scratchlab-beat-engine-v1",
            "handedness" : "right",
            "notes" : "",
            "performerName" : "K",
            "scratchTypeID" : "baby_scratch",
            "scratchTypeName" : "Baby Scratch",
            "sessionID" : "657ec5f1-d893-4171-bdf4-9c3195615d9b",
            "swingAmount" : 0,
            "takeCount" : 0,
            "timingPrintedToRecording" : "unknown",
            "updatedAt" : "2026-07-12T11:17:35Z"
          },
          "sessionID" : "657ec5f1-d893-4171-bdf4-9c3195615d9b",
          "sidecarFileName" : "657ec5f1-d893-4171-bdf4-9c3195615d9b_take001_routine.json",
          "sourceDeviceName" : "DJ",
          "startedAt" : "2026-07-12T11:17:38Z",
          "takeID" : "take-001",
          "videoDeviceName" : "MacBook Pro Camera",
          "videoDeviceUniqueID" : "6C707041-05AC-0010-0001-000000000001",
          "watchCommandID" : "52626e6b-e3e9-4ac5-9998-d25935401b69",
          "watchSyncState" : "unavailable"
        }
        """#

        let data = Data(json.utf8)
        let sidecar = try decoder.decode(CaptureCore.LocalRecordingSidecar.self, from: data)

        XCTAssertEqual(sidecar.schemaVersion, "scratchlab_local_recording_sidecar_v1")
        XCTAssertEqual(sidecar.sessionID, "657ec5f1-d893-4171-bdf4-9c3195615d9b")
        XCTAssertEqual(sidecar.takeID, "take-001")
        XCTAssertEqual(sidecar.recordingStatus, "completed")
        XCTAssertEqual(sidecar.recordingRole, "mac_routine_capture")
        XCTAssertEqual(sidecar.platform, "macOS")
        XCTAssertEqual(sidecar.watchSyncState, .unavailable)

        let sessionConfig = try XCTUnwrap(sidecar.sessionConfig)
        XCTAssertEqual(sessionConfig.performerName, "K")
        XCTAssertEqual(sessionConfig.bpm, 95)
        XCTAssertEqual(sessionConfig.captureMode, .timedClick)
        XCTAssertEqual(sessionConfig.scratchType, .babyScratch)

        let notation = try XCTUnwrap(sidecar.detectedNotation)
        XCTAssertEqual(notation.notationSource, "partial")
        XCTAssertEqual(notation.audioEvents.count, 1)
        XCTAssertEqual(notation.audioEvents.first?.eventKind, "possibleDrag")
        XCTAssertEqual(notation.faderEvents.count, 0)
        XCTAssertEqual(notation.mixerMidiEvents.count, 0)
        XCTAssertEqual(notation.recordMovementEvents.count, 0)
    }

    func testSidecarRoundTripsTypedFaderAndMixerMidiEvents() throws {
        let now = Self.referenceDate
        var sidecar = makeSidecar(at: now)
        let snapshot = CaptureCore.DetectedNotationSnapshot(
            notationSource: "detected",
            notationConfidence: 0.9,
            detectedLabel: "Baby Scratch",
            labelSource: "detected",
            labelConfidence: 0.88,
            detectionSources: ["audio", "midi"],
            recordMovementEvents: [
                CaptureCore.DetectedNotationRecordMovementEvent(
                    startTime: 0.1,
                    endTime: 0.3,
                    startPosition: 0.0,
                    endPosition: 1.0,
                    direction: "forward",
                    movementKind: .normalPush,
                    speed: 5.0,
                    confidence: 0.8,
                    source: "controller"
                )
            ],
            audioEvents: [],
            faderEvents: [
                CaptureCore.DetectedNotationFaderEvent(
                    startTime: 0.2,
                    endTime: 0.25,
                    eventKind: .cut,
                    control: "crossfader",
                    fromValue: 0.0,
                    toValue: 1.0,
                    source: "midi",
                    confidence: 0.9
                )
            ],
            mixerMidiEvents: [
                CaptureCore.RawMixerMIDIEvent(
                    timestamp: 100.0,
                    takeRelativeTime: 0.2,
                    deviceName: "Rane ONE",
                    channel: 0,
                    controller: 31,
                    value: 127,
                    normalizedValue: 1.0,
                    mappedControl: "crossfader"
                )
            ],
            capturedAt: now
        )
        sidecar = sidecar.withDetectedNotation(snapshot, recordedAt: now)

        let data = try encoder.encode(sidecar)
        let decoded = try decoder.decode(CaptureCore.LocalRecordingSidecar.self, from: data)

        let restored = try XCTUnwrap(decoded.detectedNotation)
        XCTAssertEqual(restored.faderEvents.count, 1)
        XCTAssertEqual(restored.faderEvents.first?.eventKind, .cut)
        XCTAssertEqual(restored.mixerMidiEvents.count, 1)
        XCTAssertEqual(restored.mixerMidiEvents.first?.mappedControl, "crossfader")
        XCTAssertEqual(restored.recordMovementEvents.first?.movementKind, .normalPush)
    }

    // MARK: - Helpers

    private func makeSidecar(at startedAt: Date) -> CaptureCore.LocalRecordingSidecar {
        let files = CaptureCore.LocalRecordingFiles(
            baseName: "routine-session_take001_routine",
            mediaURL: URL(fileURLWithPath: "/tmp/routine-session_take001_routine.mov"),
            sidecarURL: URL(fileURLWithPath: "/tmp/routine-session_take001_routine.json")
        )
        return CaptureCore.LocalRecordingSidecar.recording(
            sessionID: "routine-session",
            takeIdentity: CaptureCore.LocalRecordingNaming.takeIdentity(
                sessionID: "routine-session",
                takeNumber: 1
            ),
            files: files,
            recordingRole: "routine_capture",
            platform: "macOS",
            appSurface: "mac_desktop",
            sourceDeviceName: "ScratchLab Mac",
            startedAt: startedAt
        )
    }

    private func makeAudioOnlySnapshot(
        startTimes: [Double]? = nil,
        peakLevels: [Double]
    ) -> CaptureCore.DetectedNotationSnapshot {
        let times = startTimes ?? peakLevels.enumerated().map { index, _ in Double(index) * 0.5 }
        let events = zip(times, peakLevels).map { startTime, peak in
            CaptureCore.DetectedNotationAudioEvent(
                startTime: startTime,
                endTime: startTime + 0.05,
                duration: 0.05,
                peakLevel: peak,
                rmsLevel: peak * 0.4,
                confidence: 0.5,
                eventKind: "scratchBurst",
                source: "audio"
            )
        }
        return CaptureCore.DetectedNotationSnapshot(
            notationSource: "partial",
            notationConfidence: nil,
            detectedLabel: nil,
            labelSource: "detected",
            labelConfidence: nil,
            detectionSources: ["audio"],
            recordMovementEvents: [],
            audioEvents: events,
            faderEvents: [],
            mixerMidiEvents: [],
            capturedAt: Self.referenceDate
        )
    }
}
