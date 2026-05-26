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
