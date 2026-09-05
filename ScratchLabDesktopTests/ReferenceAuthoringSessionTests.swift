// ReferenceAuthoringSessionTests.swift
// ScratchLabDesktopTests
//
// Pure state-machine tests for the CXL reference-authoring flow. Every
// hardware seam is faked — no CoreMIDI, no camera, no MacCaptureEngine — which
// is exactly what `ReferenceAuthoringSession` was designed to allow.
//
// These tests exercise the WORKFLOW ORDER (steps 1–11) and the lifecycle
// safety rules; they do not assert anything about what a correct scratch
// looks like. No take built here is claimed to be, or is used as, valid
// reference material.

import XCTest
@testable import ScratchLab

final class ReferenceAuthoringSessionTests: XCTestCase {

    private let calibration = CrossfaderCalibration(
        address: CrossfaderMIDIAddress(
            deviceIdentifier: "Rane ONE MKII",
            deviceName: "Rane ONE MKII",
            channel: 15,
            controller: 8
        ),
        fullLeftRawValue: 0,
        centerRawValue: 52,
        fullRightRawValue: 104,
        openEnd: .left,
        activeDeck: .rightDeck,
        calibratedAt: Date(timeIntervalSince1970: 1_788_000_000)
    )

    private func makeStore() throws -> CrossfaderCalibrationStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReferenceAuthoringSessionTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return CrossfaderCalibrationStore(directoryURL: directory)
    }

    private func passingSnapshot() -> ReferencePreflightSnapshot {
        ReferencePreflightSnapshot(
            controllerName: "Rane ONE MKII",
            controllerIdentifier: "Rane ONE MKII",
            observedCrossfaderAddress: calibration.address,
            latestCrossfaderRawValue: 1,
            calibration: calibration,
            crossfaderEventCount: 40,
            platterEventCount: 100,
            platterIsMoving: true,
            audioInputPeakLevel: 0.5,
            audioDeviceName: "Rane ONE MKII",
            watchIsReachable: true,
            watchMotionIsStreaming: true,
            cameraDeviceName: "Studio Camera",
            cameraIsActive: true,
            crossfaderSecondsSinceLastMessage: 0.1
        )
    }

    /// Everything ready EXCEPT the paired Watch.
    private func watchUnreachableSnapshot() -> ReferencePreflightSnapshot {
        ReferencePreflightSnapshot(
            controllerName: "Rane ONE MKII",
            controllerIdentifier: "Rane ONE MKII",
            observedCrossfaderAddress: calibration.address,
            latestCrossfaderRawValue: 1,
            calibration: calibration,
            crossfaderEventCount: 40,
            platterEventCount: 100,
            platterIsMoving: true,
            audioInputPeakLevel: 0.5,
            audioDeviceName: "Rane ONE MKII",
            watchIsReachable: false,
            watchMotionIsStreaming: false,
            cameraDeviceName: "Studio Camera",
            cameraIsActive: true,
            crossfaderSecondsSinceLastMessage: 0.1
        )
    }

    private func blockedSnapshot() -> ReferencePreflightSnapshot {
        ReferencePreflightSnapshot(
            controllerName: nil,
            controllerIdentifier: nil,
            observedCrossfaderAddress: nil,
            latestCrossfaderRawValue: nil,
            calibration: nil,
            crossfaderEventCount: 0,
            platterEventCount: 0,
            platterIsMoving: false,
            audioInputPeakLevel: nil,
            audioDeviceName: nil,
            watchIsReachable: false,
            watchMotionIsStreaming: false
        )
    }

    private func goodArtifacts(
        autoDetected: ReferenceTechnique? = nil,
        crossfaderStaysOpen: Bool = true,
        watchLinked: Bool = true,
        watchEvidence: ReferenceWatchEvidence? = nil
    ) -> ReferenceRecordedTakeArtifacts {
        let samples: [CrossfaderPositionSample] = (0..<800).map { index in
            CrossfaderPositionSample(
                takeRelativeTime: Double(index) * 0.001,
                rawValue: crossfaderStaysOpen ? 1 : (index % 100 < 50 ? 1 : 52),
                normalizedPosition: crossfaderStaysOpen ? 1 : (index % 100 < 50 ? 1 : 0)
            )
        }
        return ReferenceRecordedTakeArtifacts(
            audio: ReferenceArtifactMeasurement(
                fileName: "reference.wav",
                exists: true,
                byteCount: 500_000,
                peakLevel: 0.8,
                frameCount: 100_000
            ),
            video: nil,
            sidecar: ReferenceArtifactMeasurement(fileName: "take.json", exists: true, byteCount: 2_048),
            actualMediaFileName: nil,
            crossfaderRawSamples: samples,
            observedCrossfaderAddress: calibration.address,
            platterMovementEventCount: 60,
            recordedAt: Date(timeIntervalSince1970: 1_788_000_500),
            autoDetectedTechnique: autoDetected,
            // Linked wrist motion is required evidence for a canonical
            // reference; the missing-Watch case has its own test.
            watchEvidence: watchEvidence ?? (
                watchLinked
                    ? .linked(motionFileName: "watch-motion.json")
                    : .acknowledgedTransferPending
            )
        )
    }

    private func makeConfiguredSession(
        technique: ReferenceTechnique = .babyScratch
    ) -> ReferenceAuthoringSession {
        var session = ReferenceAuthoringSession(authoringSessionID: "auth-0001", operatorName: "Karl")
        session.selectTechnique(technique)
        session.selectPattern(
            ReferencePatternIdentity(id: "quarter_notes", name: "Quarter notes", phraseBars: 1),
            bpm: 95
        )
        session.declareVariant(
            startingDirection: .forward,
            faderVariant: technique == .babyScratch ? .faderOpenThroughout : .crossfader,
            handedness: .right
        )
        return session
    }

    // MARK: - Configuration order (steps 1–3)

    func testConfigurationIsIncompleteUntilAllFourFieldsAreSet() {
        var session = ReferenceAuthoringSession(authoringSessionID: "auth-0001", operatorName: "Karl")
        XCTAssertFalse(session.configurationIsComplete)
        session.selectTechnique(.chirp)
        XCTAssertFalse(session.configurationIsComplete)
        session.selectPattern(
            ReferencePatternIdentity(id: "eighths", name: "Eighths", phraseBars: 1),
            bpm: 90
        )
        XCTAssertFalse(session.configurationIsComplete)
        session.declareVariant(startingDirection: .forward, faderVariant: .crossfader, handedness: .right)
        XCTAssertTrue(session.configurationIsComplete)
    }

    func testChangingTechniqueAwayFromBabyScratchClearsTheFaderVariant() {
        var session = makeConfiguredSession(technique: .babyScratch)
        XCTAssertNotNil(session.selectedFaderVariant)
        session.selectTechnique(.chirp)
        XCTAssertNil(session.selectedFaderVariant, "A stale variant from a different technique must not carry over silently.")
    }

    // MARK: - Preflight (step 4) and calibration (step 5)

    func testRecordingIsBlockedByPreflightBeforeCalibration() {
        var session = makeConfiguredSession()
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: { .success(self.goodArtifacts()) },
            currentPreflightSnapshot: { self.blockedSnapshot() },
            latestCalibrationObservation: { nil }
        )
        let result = session.beginRecording(using: hooks)
        guard case .failure(let error) = result else {
            return XCTFail("Expected a blocking failure, got success.")
        }
        // Calibration is checked before the preflight snapshot for an
        // unconfigured session, since there is nothing to record against yet.
        XCTAssertEqual(error, .calibrationIncomplete)
    }

    func testCalibrationSweepMustCompleteBeforeItCanBeCommitted() throws {
        var session = makeConfiguredSession()
        session.beginCalibration(address: calibration.address, openEnd: .left, activeDeck: .rightDeck)
        let store = try makeStore()
        XCTAssertThrowsError(try session.commitCalibration(store: store)) { error in
            XCTAssertEqual(error as? ReferenceAuthoringError, .calibrationIncomplete)
        }

        Self.sweepThroughAllThreePositions(&session)
        try session.commitCalibration(store: store)
        XCTAssertEqual(session.phase, .readyToRecord)
        XCTAssertNotNil(store.calibration(deviceIdentifier: "Rane ONE MKII", channel: 15, controller: 8))
    }

    func testBeginRecordingRefusesWithoutACommittedCalibration() {
        var session = makeConfiguredSession()
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: { .success(self.goodArtifacts()) },
            currentPreflightSnapshot: { self.passingSnapshot() },
            latestCalibrationObservation: { nil }
        )
        let result = session.beginRecording(using: hooks)
        guard case .failure(.calibrationIncomplete) = result else {
            return XCTFail("Expected calibrationIncomplete, got \(result)")
        }
    }

    func testBeginRecordingRefusesOnABlockingPreflightEvenWithCalibration() throws {
        var session = makeConfiguredSession()
        try calibrateSession(&session)
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: { .success(self.goodArtifacts()) },
            currentPreflightSnapshot: { self.blockedSnapshot() },
            latestCalibrationObservation: { nil }
        )
        let result = session.beginRecording(using: hooks)
        guard case .failure(.preflightBlocked) = result else {
            return XCTFail("Expected preflightBlocked, got \(result)")
        }
        XCTAssertEqual(session.phase, .readyToRecord, "A blocked attempt must not enter .recording.")
    }

    /// Drives a complete, VALID three-position sweep with genuinely fresh
    /// observations — each reading carries a higher `observationSequence`, the
    /// way real MIDI messages do. A sweep fed a repeating sequence number
    /// deliberately cannot complete; see
    /// `testStaleObservationsCannotSettleACalibrationStep`.
    static func sweepThroughAllThreePositions(
        _ session: inout ReferenceAuthoringSession,
        values: [Int] = [0, 52, 104]
    ) {
        var sequence = 0
        for value in values {
            // Every stage is UNARMED until the operator presses its Capture
            // button, so the sweep has to be armed before its observations
            // count. This mirrors the real interaction exactly.
            session.calibrationSweep = session.calibrationSweep?
                .arming(atObservationSequence: sequence)
            for _ in 0..<CrossfaderCalibrationSweep.defaultSettleSampleCount {
                sequence += 1
                session.ingestCalibrationObservation(
                    CrossfaderCalibrationObservation(rawValue: value, observationSequence: sequence),
                    now: Date(timeIntervalSince1970: 1_788_000_000)
                )
            }
        }
    }

    private func calibrateSession(
        _ session: inout ReferenceAuthoringSession,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        session.beginCalibration(address: calibration.address, openEnd: .left, activeDeck: .rightDeck)
        Self.sweepThroughAllThreePositions(&session)
        XCTAssertNotNil(
            session.confirmedCalibration,
            "The sweep did not produce a usable calibration.",
            file: file,
            line: line
        )
        try session.commitCalibration(store: try makeStore())
    }

    // MARK: - Recording and validation (steps 6–7)

    func testARecordedTakeEntersReviewWithAValidationReport() throws {
        var session = makeConfiguredSession()
        try calibrateSession(&session)
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: { .success(self.goodArtifacts()) },
            currentPreflightSnapshot: { self.passingSnapshot() },
            latestCalibrationObservation: { nil }
        )
        guard case .success = session.beginRecording(using: hooks) else {
            return XCTFail("Expected beginRecording to succeed.")
        }
        XCTAssertEqual(session.phase, .recording)

        let report = try session.finishRecording(using: hooks).get()
        // No repetition is pre-selected (step 9 is an explicit operator
        // action), so the only expected failure at this point is that one —
        // everything else about the recorded evidence must already be clean.
        XCTAssertEqual(
            report.failureMessages,
            ["No repetition has been selected. Audition the repetitions and choose the one to publish."]
        )
        guard case .reviewing(let index) = session.phase else {
            return XCTFail("Expected .reviewing, got \(session.phase)")
        }
        XCTAssertEqual(index, 0)
        XCTAssertEqual(session.takes.count, 1)
        XCTAssertEqual(session.takes[0].evidence.metadata.lifecycleState, .draft)
    }

    func testFinishRecordingRefusesWhenNotCurrentlyRecording() {
        var session = makeConfiguredSession()
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: { .success(self.goodArtifacts()) },
            currentPreflightSnapshot: { self.passingSnapshot() },
            latestCalibrationObservation: { nil }
        )
        let result = session.finishRecording(using: hooks)
        guard case .failure(.noActiveRecording) = result else {
            return XCTFail("Expected noActiveRecording, got \(result)")
        }
    }

    func testAutoDetectionIsAdvisoryAndNeverOverwritesTheSelectedTechnique() throws {
        var session = makeConfiguredSession(technique: .babyScratch)
        try calibrateSession(&session)
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: { .success(self.goodArtifacts(autoDetected: .chirp)) },
            currentPreflightSnapshot: { self.passingSnapshot() },
            latestCalibrationObservation: { nil }
        )
        _ = session.beginRecording(using: hooks)
        _ = try session.finishRecording(using: hooks).get()

        let take = session.takeInReview!
        XCTAssertEqual(take.evidence.metadata.technique, .babyScratch, "CXL's selection must not be overwritten by detection.")
        XCTAssertEqual(take.autoDetectedTechnique, .chirp)
        XCTAssertTrue(take.autoDetectionDisagreesWithSelection)
    }

    func testARejectedTakeCannotBeApprovedOrPublishedLater() throws {
        var session = makeConfiguredSession()
        try calibrateSession(&session)
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: { .success(self.goodArtifacts()) },
            currentPreflightSnapshot: { self.passingSnapshot() },
            latestCalibrationObservation: { nil }
        )
        _ = session.beginRecording(using: hooks)
        _ = try session.finishRecording(using: hooks).get()

        try session.rejectTakeInReview(notes: "Bad take — controller dropped out mid-phrase.")
        XCTAssertEqual(session.takes[0].evidence.metadata.lifecycleState, .rejected)
        XCTAssertEqual(session.phase, .readyToRecord)

        XCTAssertThrowsError(try session.markTakeReviewed())
        XCTAssertNil(session.takeReadyForPublication(takeIndex: 0))
    }

    // MARK: - Repetition review and approval (steps 8–10)

    func testApprovalRequiresAPassingValidationReport() throws {
        var session = makeConfiguredSession()
        try calibrateSession(&session)
        // Fader dips closed mid-take — a Baby Scratch open-fader violation,
        // which is a capture-integrity check (not gated on operator
        // confirmation) and must block approval.
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: { .success(self.goodArtifacts(crossfaderStaysOpen: false)) },
            currentPreflightSnapshot: { self.passingSnapshot() },
            latestCalibrationObservation: { nil }
        )
        _ = session.beginRecording(using: hooks)
        let report = try session.finishRecording(using: hooks).get()
        XCTAssertFalse(report.passes)

        session.selectRepetitionForApproval(0)
        XCTAssertThrowsError(try session.approveTakeInReview(notes: "")) { error in
            guard case .recordingFailed = error as? ReferenceAuthoringError else {
                return XCTFail("Expected recordingFailed, got \(error)")
            }
        }
        XCTAssertEqual(session.takes[0].evidence.metadata.lifecycleState, .draft)
    }

    func testApprovalRequiresARepetitionToBeSelectedFirst() throws {
        var session = makeConfiguredSession()
        try calibrateSession(&session)
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: { .success(self.goodArtifacts()) },
            currentPreflightSnapshot: { self.passingSnapshot() },
            latestCalibrationObservation: { nil }
        )
        _ = session.beginRecording(using: hooks)
        _ = try session.finishRecording(using: hooks).get()

        XCTAssertThrowsError(try session.approveTakeInReview(notes: ""))
    }

    func testApprovingACleanTakeAdvancesThroughReviewedToApprovedCanonicalButNotPublished() throws {
        var session = makeConfiguredSession()
        try calibrateSession(&session)
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: { .success(self.goodArtifacts()) },
            currentPreflightSnapshot: { self.passingSnapshot() },
            latestCalibrationObservation: { nil }
        )
        _ = session.beginRecording(using: hooks)
        _ = try session.finishRecording(using: hooks).get()

        session.selectRepetitionForApproval(1)
        session.revalidateTakeInReview()
        try session.approveTakeInReview(notes: "Clean, four consistent repetitions.")

        let take = session.takes[0]
        XCTAssertEqual(take.evidence.metadata.lifecycleState, .approvedCanonical)
        XCTAssertEqual(take.evidence.metadata.reviewDecision?.outcome, .approved)
        XCTAssertEqual(take.evidence.metadata.reviewDecision?.selectedRepetitionIndex, 1)
        // Step 10/11: approved is not yet published, and is therefore not yet
        // available to training.
        XCTAssertFalse(take.evidence.metadata.lifecycleState.isPlayableByLearner)
        XCTAssertNotNil(session.takeReadyForPublication(takeIndex: 0))
    }

    func testPublishingMovesAnApprovedTakeToTheOnlyPlayableState() throws {
        var session = makeConfiguredSession()
        try calibrateSession(&session)
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: { .success(self.goodArtifacts()) },
            currentPreflightSnapshot: { self.passingSnapshot() },
            latestCalibrationObservation: { nil }
        )
        _ = session.beginRecording(using: hooks)
        _ = try session.finishRecording(using: hooks).get()
        session.selectRepetitionForApproval(0)
        session.revalidateTakeInReview()
        try session.approveTakeInReview(notes: "")

        try session.markTakePublished(takeIndex: 0)
        XCTAssertEqual(session.takes[0].evidence.metadata.lifecycleState, .published)
        XCTAssertTrue(session.takes[0].evidence.metadata.lifecycleState.isPlayableByLearner)
    }

    func testPublishingBeforeApprovalIsRefused() throws {
        var session = makeConfiguredSession()
        try calibrateSession(&session)
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: { .success(self.goodArtifacts()) },
            currentPreflightSnapshot: { self.passingSnapshot() },
            latestCalibrationObservation: { nil }
        )
        _ = session.beginRecording(using: hooks)
        _ = try session.finishRecording(using: hooks).get()
        XCTAssertThrowsError(try session.markTakePublished(takeIndex: 0))
    }

    // MARK: - Retake

    func testRetakeReturnsToReadyToRecordWithoutRemovingThePriorTake() throws {
        var session = makeConfiguredSession()
        try calibrateSession(&session)
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: { .success(self.goodArtifacts()) },
            currentPreflightSnapshot: { self.passingSnapshot() },
            latestCalibrationObservation: { nil }
        )
        _ = session.beginRecording(using: hooks)
        _ = try session.finishRecording(using: hooks).get()
        session.retake()
        XCTAssertEqual(session.phase, .readyToRecord)
        XCTAssertEqual(session.takes.count, 1, "Retake starts a new take; it must not delete the evidence of the old one.")

        _ = session.beginRecording(using: hooks)
        _ = try session.finishRecording(using: hooks).get()
        XCTAssertEqual(session.takes.count, 2)
    }

    // MARK: - Recording failure surfaces, does not crash

    func testAHardwareStartFailureIsSurfacedAsAResult() throws {
        var session = makeConfiguredSession()
        try calibrateSession(&session)
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { .failure(.recordingFailed("Audio device disconnected.")) },
            stopRecording: { .success(self.goodArtifacts()) },
            currentPreflightSnapshot: { self.passingSnapshot() },
            latestCalibrationObservation: { nil }
        )
        let result = session.beginRecording(using: hooks)
        guard case .failure(.recordingFailed(let detail)) = result else {
            return XCTFail("Expected recordingFailed, got \(result)")
        }
        XCTAssertEqual(detail, "Audio device disconnected.")
        XCTAssertEqual(session.phase, .readyToRecord, "A failed start must not leave the session stuck in .recording.")
    }

    // MARK: - 2026-09-04 hardware-smoke regressions

    /// The physical smoke's sweep settled every position without the operator
    /// being able to say the fader had moved. A session polling a silent
    /// address must not advance a single step, however long it polls.
    func testAStaleAddressCannotDriveACalibrationSweepAtAll() {
        var session = makeConfiguredSession()
        session.beginCalibration(address: calibration.address, openEnd: .left, activeDeck: .rightDeck)
        // 500 polls of the SAME message — exactly what the 20 ms poller does
        // when the crossfader is not transmitting.
        for _ in 0..<500 {
            session.ingestCalibrationObservation(
                CrossfaderCalibrationObservation(rawValue: 0, observationSequence: 7),
                now: Date(timeIntervalSince1970: 1_788_000_000)
            )
        }
        XCTAssertEqual(session.calibrationSweep?.state.currentStep, .fullLeft)
        XCTAssertNil(session.confirmedCalibration)
    }

    /// The first reading after a sweep opens is whatever was already sitting
    /// in the host's cache — the value the fader was left at, not a position
    /// the operator has been asked to hold. It must be baselined, not counted.
    func testTheFirstReadingAfterASweepOpensIsTreatedAsStale() {
        var session = makeConfiguredSession()
        session.beginCalibration(address: calibration.address, openEnd: .left, activeDeck: .rightDeck)
        session.ingestCalibrationObservation(
            CrossfaderCalibrationObservation(rawValue: 0, observationSequence: 4_096),
            now: Date(timeIntervalSince1970: 1_788_000_000)
        )
        XCTAssertEqual(session.calibrationSweep?.freshObservationCount, 0)
        XCTAssertEqual(session.lastIngestedCalibrationSequence, 4_096)
    }

    /// A sweep fed genuinely new messages still completes and commits.
    func testAFreshSweepStillCompletesAndCommits() throws {
        var session = makeConfiguredSession()
        session.beginCalibration(address: calibration.address, openEnd: .left, activeDeck: .rightDeck)
        Self.sweepThroughAllThreePositions(&session)
        let confirmed = try XCTUnwrap(session.confirmedCalibration)
        XCTAssertEqual(confirmed.fullLeftRawValue, 0)
        XCTAssertEqual(confirmed.centerRawValue, 52)
        XCTAssertEqual(confirmed.fullRightRawValue, 104)
        try session.commitCalibration(store: try makeStore())
        XCTAssertEqual(session.phase, .readyToRecord)
    }

    /// A sweep whose three measurements are not distinct can never commit,
    /// even when every reading is fresh — the exact 0 / 0 / 126 shape the
    /// hardware smoke persisted.
    func testASweepWithACentreOnAnEndStopCannotCommit() throws {
        var session = makeConfiguredSession()
        session.beginCalibration(address: calibration.address, openEnd: .right, activeDeck: .rightDeck)
        Self.sweepThroughAllThreePositions(&session, values: [0, 0, 126])
        XCTAssertNil(session.confirmedCalibration)
        XCTAssertThrowsError(try session.commitCalibration(store: try makeStore())) { error in
            XCTAssertEqual(error as? ReferenceAuthoringError, .calibrationIncomplete)
        }
    }

    // MARK: - Watch evidence

    /// Media can finalize while the wrist evidence goes missing. That take
    /// must never become approvable — a reference with no wrist data is not
    /// the thing this workflow produces.
    func testATakeWithNoLinkedWatchMotionCannotBeApproved() throws {
        var session = makeConfiguredSession()
        try calibrateSession(&session)
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: {
                .success(
                    self.goodArtifacts(
                        watchEvidence: .missing(syncState: "notRequested")
                    )
                )
            },
            currentPreflightSnapshot: { self.passingSnapshot() },
            latestCalibrationObservation: { nil }
        )
        _ = session.beginRecording(using: hooks)
        let report = try session.finishRecording(using: hooks).get()
        XCTAssertFalse(report.passes)
        XCTAssertTrue(
            report.failureMessages.contains { $0.contains("no linked Apple Watch motion") },
            report.failureMessages.description
        )
        session.selectRepetitionForApproval(1)
        session.revalidateTakeInReview()
        XCTAssertThrowsError(try session.approveTakeInReview(notes: ""))
        XCTAssertEqual(
            session.takes.last?.evidence.metadata.lifecycleState,
            .draft,
            "A take that cannot be approved must stay a draft."
        )
    }

    /// `watchLinked` comes from the finalized artifacts, never a hardcoded
    /// constant and never the start handshake's optimistic reply.
    func testWatchLinkedIsCarriedFromTheFinalizedArtifactsIntoTheTakeMetadata() throws {
        var session = makeConfiguredSession()
        try calibrateSession(&session)
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: { .success(self.goodArtifacts(watchLinked: true)) },
            currentPreflightSnapshot: { self.passingSnapshot() },
            latestCalibrationObservation: { nil }
        )
        _ = session.beginRecording(using: hooks)
        _ = try session.finishRecording(using: hooks).get()
        XCTAssertTrue(session.takes.last?.evidence.metadata.deviceInfo.watchLinked == true)
    }

    /// Recording is refused while the Watch is unreachable, so no take exists
    /// to review or approve from a blocked attempt.
    func testRecordingIsBlockedWhileTheWatchIsUnreachable() throws {
        var session = makeConfiguredSession()
        try calibrateSession(&session)
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { XCTFail("Recording must not start with the Watch unreachable."); return .success(()) },
            stopRecording: { .success(self.goodArtifacts()) },
            currentPreflightSnapshot: { self.watchUnreachableSnapshot() },
            latestCalibrationObservation: { nil }
        )
        guard case .failure(let error) = session.beginRecording(using: hooks) else {
            return XCTFail("Expected the preflight to block recording.")
        }
        guard case .preflightBlocked = error else {
            return XCTFail("Expected preflightBlocked, got \(error)")
        }
        XCTAssertEqual(session.phase, .readyToRecord)
        XCTAssertTrue(session.takes.isEmpty)
    }

    // MARK: - Watch transfer completes after macOS finalization (D1)

    private func reviewedSessionWithPendingWatch() throws -> ReferenceAuthoringSession {
        var session = makeConfiguredSession()
        try calibrateSession(&session)
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: { .success(self.goodArtifacts(watchLinked: false)) },
            currentPreflightSnapshot: { self.passingSnapshot() },
            latestCalibrationObservation: { nil }
        )
        _ = session.beginRecording(using: hooks)
        _ = try session.finishRecording(using: hooks).get()
        return session
    }

    /// The 2026-09-05 take-003 shape: acknowledged, stopped, motion still
    /// transferring when media finalization read the sidecar.
    func testATakeFinalizedWhileTheTransferIsPendingIsPendingNotMissing() throws {
        let session = try reviewedSessionWithPendingWatch()
        let take = try XCTUnwrap(session.takeInReview)
        XCTAssertEqual(take.evidence.watchEvidence, .acknowledgedTransferPending)
        XCTAssertFalse(take.evidence.metadata.deviceInfo.watchLinked)
        XCTAssertNotNil(session.approvalBlockReason())
    }

    func testAMatchingTransferLandingAfterFinalizationMakesTheTakeApprovable() throws {
        var session = try reviewedSessionWithPendingWatch()
        session.selectRepetitionForApproval(1)
        XCTAssertFalse(session.canApproveTakeInReview(), "pending transfer must block")

        session.updateWatchEvidenceForTakeInReview(.linked(motionFileName: "scratch-motion.json"))

        let take = try XCTUnwrap(session.takeInReview)
        XCTAssertTrue(take.evidence.watchEvidence.isLinked)
        XCTAssertTrue(
            take.evidence.metadata.deviceInfo.watchLinked,
            "watchLinked is derived from the evidence state and nowhere else"
        )
        XCTAssertTrue(
            session.canApproveTakeInReview(),
            session.approvalBlockReason() ?? ""
        )
    }

    func testATransferThatFailsLeavesTheTakeUnapprovable() throws {
        var session = try reviewedSessionWithPendingWatch()
        session.selectRepetitionForApproval(1)
        session.updateWatchEvidenceForTakeInReview(.transferFailed(detail: "synthetic."))
        XCTAssertFalse(session.canApproveTakeInReview())
        XCTAssertFalse(try XCTUnwrap(session.takeInReview).evidence.metadata.deviceInfo.watchLinked)
    }

    func testMismatchedWatchEvidenceIsNeverAttachedAsLinked() throws {
        var session = try reviewedSessionWithPendingWatch()
        session.selectRepetitionForApproval(1)
        session.updateWatchEvidenceForTakeInReview(
            .identityMismatch(expected: "s/take-001", found: "s/take-009")
        )
        XCTAssertFalse(try XCTUnwrap(session.takeInReview).evidence.watchEvidence.isLinked)
        XCTAssertFalse(session.canApproveTakeInReview())
    }

    /// Once matching evidence has landed a later poll must not un-land it.
    func testLandedWatchEvidenceIsNotRevertedByALaterUpdate() throws {
        var session = try reviewedSessionWithPendingWatch()
        session.updateWatchEvidenceForTakeInReview(.linked(motionFileName: "scratch-motion.json"))
        session.updateWatchEvidenceForTakeInReview(.acknowledgedTransferPending)
        XCTAssertTrue(try XCTUnwrap(session.takeInReview).evidence.watchEvidence.isLinked)
    }

    func testWatchEvidenceUpdatesAreIgnoredOutsideReview() {
        var session = makeConfiguredSession()
        session.updateWatchEvidenceForTakeInReview(.linked(motionFileName: "x.json"))
        XCTAssertTrue(session.takes.isEmpty)
    }

    // MARK: - Approval gating is enforced in the domain, not the button (D3)

    /// The 2026-09-05 screen offered an ENABLED Approve button against a take
    /// with three blocking findings. A direct call must refuse regardless of
    /// what any UI allowed.
    func testADirectApproveCallCannotBypassBlockingFindings() throws {
        var session = try reviewedSessionWithPendingWatch()
        session.selectRepetitionForApproval(1)
        XCTAssertThrowsError(try session.approveTakeInReview(notes: "")) { error in
            guard case ReferenceAuthoringError.recordingFailed(let detail)? = error as? ReferenceAuthoringError else {
                return XCTFail("expected recordingFailed, got \(error)")
            }
            XCTAssertTrue(detail.contains("Cannot approve") || detail.contains("Apple Watch"), detail)
        }
        XCTAssertEqual(
            session.takeInReview?.evidence.metadata.lifecycleState,
            .draft,
            "a refused approval must leave the take a draft"
        )
    }

    func testADirectApproveCallCannotBypassAMissingRepetitionSelection() throws {
        var session = try reviewedSessionWithPendingWatch()
        session.updateWatchEvidenceForTakeInReview(.linked(motionFileName: "scratch-motion.json"))
        XCTAssertNil(session.takeInReview?.evidence.boundaries.selectedRepetitionIndex)
        XCTAssertThrowsError(try session.approveTakeInReview(notes: ""))
        XCTAssertEqual(session.takeInReview?.evidence.metadata.lifecycleState, .draft)
    }

    /// Approval must re-validate against the take's CURRENT boundaries, so a
    /// stale passing report cannot authorise it.
    func testApprovalRevalidatesRatherThanTrustingAStaleReport() throws {
        var session = try reviewedSessionWithPendingWatch()
        session.updateWatchEvidenceForTakeInReview(.linked(motionFileName: "scratch-motion.json"))
        session.selectRepetitionForApproval(1)
        XCTAssertTrue(session.canApproveTakeInReview(), session.approvalBlockReason() ?? "")

        // Break a boundary AFTER the passing report was produced.
        session.adjustRepetitionBoundary(repetitionIndex: 1, startBeat: 9_999, endBeat: 10_000)
        XCTAssertThrowsError(try session.approveTakeInReview(notes: ""))
        XCTAssertEqual(session.takeInReview?.evidence.metadata.lifecycleState, .draft)
    }

    func testApprovalBlockReasonIsNilOnlyWhenEveryGateIsSatisfied() throws {
        var session = try reviewedSessionWithPendingWatch()
        XCTAssertNotNil(session.approvalBlockReason(), "pending watch + no repetition")
        session.updateWatchEvidenceForTakeInReview(.linked(motionFileName: "scratch-motion.json"))
        XCTAssertNotNil(session.approvalBlockReason(), "still no repetition selected")
        session.selectRepetitionForApproval(1)
        XCTAssertNil(session.approvalBlockReason())
        try session.approveTakeInReview(notes: "verified")
        XCTAssertEqual(session.takes.last?.evidence.metadata.lifecycleState, .approvedCanonical)
        XCTAssertEqual(session.phase, .complete)
    }

    // MARK: - D4: the session never auto-arms a calibration stage

    func testBeginCalibrationLeavesTheFirstStageUnarmed() {
        var session = makeConfiguredSession()
        session.beginCalibration(address: calibration.address, openEnd: .right, activeDeck: .rightDeck)
        XCTAssertTrue(session.calibrationIsAwaitingArm)
        XCTAssertEqual(session.calibrationSweep?.state.currentStep, .fullLeft)
        // Poll it hard while unarmed: nothing may be taken.
        for sequence in 1...200 {
            session.ingestCalibrationObservation(
                CrossfaderCalibrationObservation(rawValue: 0, observationSequence: sequence),
                now: Date(timeIntervalSince1970: 1_788_000_000)
            )
        }
        XCTAssertNil(session.calibrationSweep?.capturedValues[.fullLeft])
        XCTAssertNil(session.confirmedCalibration)
    }

    func testArmingUsesTheAddressCurrentObservationSequence() {
        var session = makeConfiguredSession()
        session.beginCalibration(address: calibration.address, openEnd: .right, activeDeck: .rightDeck)
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: { .success(self.goodArtifacts()) },
            currentPreflightSnapshot: { self.passingSnapshot() },
            latestCalibrationObservation: {
                CrossfaderCalibrationObservation(rawValue: 0, observationSequence: 1_234)
            }
        )
        session.armCalibrationCapture(using: hooks)
        XCTAssertFalse(session.calibrationIsAwaitingArm)
        XCTAssertEqual(session.calibrationSweep?.armBoundarySequence, 1_234)

        // Anything at or before that boundary is pre-arm.
        for sequence in 1_200...1_234 {
            session.ingestCalibrationObservation(
                CrossfaderCalibrationObservation(rawValue: 0, observationSequence: sequence),
                now: Date(timeIntervalSince1970: 1_788_000_000)
            )
        }
        XCTAssertNil(session.calibrationSweep?.capturedValues[.fullLeft])
    }

    func testRetryReturnsTheStageToItsInstructionAndRequiresAnotherCapture() throws {
        var session = makeConfiguredSession()
        session.beginCalibration(address: calibration.address, openEnd: .left, activeDeck: .rightDeck)
        Self.sweepThroughAllThreePositions(&session, values: [0])
        XCTAssertEqual(session.calibrationSweep?.capturedValues[.fullLeft], 0)

        session.retryCalibrationStep()
        XCTAssertTrue(session.calibrationIsAwaitingArm)
        XCTAssertEqual(session.calibrationSweep?.state.currentStep, .center)
        XCTAssertEqual(
            session.calibrationSweep?.capturedValues[.fullLeft], 0,
            "retrying centre must not disturb the completed full-left measurement"
        )
    }
}
