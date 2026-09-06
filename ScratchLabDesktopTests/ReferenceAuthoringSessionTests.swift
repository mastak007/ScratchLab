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
        // Capture-integrity preflight is what blocks here. A missing
        // calibration is deliberately NOT a recording gate any more: it costs
        // the take its fader evidence and its canonical approval, never the
        // raw capture. See `testBeginRecordingProceedsWithoutACalibration`.
        guard case .preflightBlocked = error else {
            return XCTFail("Expected preflightBlocked, got \(error)")
        }
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

    /// Capture eligibility and canonical-reference eligibility are separate
    /// gates. A take recorded with no calibration must still record, finalize
    /// and be retained; what it loses is its fader evidence and its ability to
    /// be approved — not the raw diagnostic capture.
    func testBeginRecordingProceedsWithoutACalibration() {
        var session = makeConfiguredSession()
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: { .success(self.goodArtifacts()) },
            currentPreflightSnapshot: { self.passingSnapshot() },
            latestCalibrationObservation: { nil }
        )
        XCTAssertNil(session.confirmedCalibration)
        let result = session.beginRecording(using: hooks)
        guard case .success = result else {
            return XCTFail("Expected recording to start without a calibration, got \(result)")
        }
        XCTAssertEqual(session.phase, .recording)
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

// MARK: - Tear segmentation review

/// Pure tests for inspecting and correcting one take's tear segmentation.
///
/// Nothing here claims a take is valid reference material, and every test
/// that corrects anything also asserts the take stayed un-approved: this
/// review layer exists to record disagreement with the automatic pass, not to
/// sign a take off.
/// These authored fixtures explicitly stipulate repeated equal-position
/// observations in their gaps. Production event gaps never imply this evidence.
func syntheticObservedPlatterStillness(_ events: [CaptureCore.DetectedNotationRecordMovementEvent]) -> [CaptureCore.PlatterEvidenceInterval] {
    zip(events, events.dropFirst()).compactMap { before, after in
        guard after.startTime > before.endTime else { return nil }
        return .init(startTime: before.endTime, endTime: after.startTime, kind: .observedStillness, signedSteps: 0)
    }
}

final class ReferenceTearSegmentationReviewTests: XCTestCase {

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

    private let correctedAt = Date(timeIntervalSince1970: 1_788_001_000)

    // MARK: Fixtures

    private func movement(
        _ startTime: Double,
        _ endTime: Double,
        _ direction: String,
        confidence: Double = 0.9
    ) -> CaptureCore.DetectedNotationRecordMovementEvent {
        CaptureCore.DetectedNotationRecordMovementEvent(
            startTime: startTime,
            endTime: endTime,
            startPosition: 0,
            endPosition: 1,
            direction: direction,
            movementKind: direction == "forward" ? .normalPush : .normalPull,
            speed: 1,
            confidence: confidence,
            source: "controller"
        )
    }

    /// Backward travel interrupted by two bounded stationary intervals, then a
    /// reversal into one forward run: a 2-tear candidate followed by a
    /// non-tear gesture.
    private func twoTearMovementEvents() -> [CaptureCore.DetectedNotationRecordMovementEvent] {
        [
            movement(0.00, 0.20, "backward"),
            movement(0.35, 0.55, "backward"),
            movement(0.75, 0.95, "backward"),
            movement(1.10, 1.40, "forward", confidence: 0.7)
        ]
    }

    private func openFaderDerivation(
        clicks: [CrossfaderSemanticEvent] = []
    ) -> CrossfaderDerivation {
        CrossfaderDerivation(
            intervals: [
                CrossfaderStateInterval(
                    state: .open,
                    startTime: 0,
                    endTime: 2,
                    startPosition: 1,
                    endPosition: 1
                )
            ],
            events: clicks
        )
    }

    private func review(
        movementEvents: [CaptureCore.DetectedNotationRecordMovementEvent]? = nil,
        derivation: CrossfaderDerivation? = nil
    ) -> ReferenceTearSegmentationReview {
        ReferenceTearSegmentationReviewBuilder.build(
            referenceTakeID: "auth-0001-take-001",
            movementEvents: movementEvents ?? twoTearMovementEvents(),
            platterEvidenceIntervals: syntheticObservedPlatterStillness(movementEvents ?? twoTearMovementEvents()),
            derivation: derivation ?? openFaderDerivation()
        )
    }

    private func correction(_ reason: String, notes: String = "") -> ReferenceTearCorrection {
        ReferenceTearCorrection(
            correctedBy: "Karl",
            correctedAt: correctedAt,
            notes: notes,
            reason: reason
        )
    }

    // MARK: The automatic pass

    func testTheAutomaticPassGroupsBoundedStationaryIntervalsIntoATearCandidate() {
        let review = review()

        XCTAssertEqual(review.candidates.count, 2)
        let tear = review.candidates[0]
        XCTAssertEqual(tear.direction, .backward)
        XCTAssertEqual(tear.proposedClassification, .tear2)
        XCTAssertEqual(tear.boundaries.count, 2)
        XCTAssertEqual(tear.countedTearHoldCount, 2)
        XCTAssertEqual(tear.effectiveClassification.derivedStructure, .tear2Candidate)
        XCTAssertEqual(tear.proposedConfidence, 0.9)

        let plain = review.candidates[1]
        XCTAssertEqual(plain.direction, .forward)
        XCTAssertEqual(plain.proposedClassification, .nonTear)
        XCTAssertTrue(plain.boundaries.isEmpty)
        XCTAssertNil(
            plain.effectiveClassification.derivedStructure,
            "non-tear is not a structure the canonical vocabulary names"
        )
    }

    func testStationaryIntervalsReversalsAndFaderEvidenceAreAllInspectable() {
        let review = review()

        XCTAssertEqual(review.travelIntervals.count, 4)
        // Two bounded tear holds plus the stop before the reversal.
        XCTAssertEqual(review.stationaryIntervals.count, 3)
        XCTAssertEqual(review.reversals.count, 1)
        XCTAssertEqual(review.reversals[0].from, .backward)
        XCTAssertEqual(review.reversals[0].to, .forward)
        XCTAssertEqual(review.reversals[0].span.startTime, 0.95, accuracy: 1e-9)
        XCTAssertEqual(review.reversals[0].span.endTime, 1.10, accuracy: 1e-9)
        XCTAssertFalse(review.reversals[0].isDirectTurnaround)
        XCTAssertEqual(review.faderIntervals.count, 1)
        XCTAssertEqual(review.faderReading(over: review.candidates[0].span), .open)

        // Travel carries the decoder's own confidence; a stationary interval
        // inferred from an absence of telemetry carries none.
        XCTAssertEqual(review.travelIntervals.first?.confidence, 0.9)
        XCTAssertNil(review.stationaryIntervals.first?.confidence)
        XCTAssertTrue(
            review.stationaryIntervals.allSatisfy {
                $0.reasons.contains(.observedStationarySamples)
            }
        )
        XCTAssertTrue(
            review.segments.contains {
                $0.confidence == 0.7 && $0.reasons.contains(.lowMovementConfidence)
            },
            "a low-confidence movement event must be flagged, not smoothed away"
        )
    }

    func testTheReviewStatesThatItsPlatterCoordinatesAreNotCalibrated() {
        XCTAssertTrue(review().reasons.contains(.uncalibratedPlatterCoordinates))
    }

    func testRawMovementEventsAreRetainedVerbatimIncludingOnesTooMalformedToSegment() {
        var events = twoTearMovementEvents()
        events.append(movement(2.0, 2.0, "forward"))
        let review = review(movementEvents: events)

        XCTAssertEqual(review.rawMovementEvents, events, "raw evidence is never filtered or repaired")
        XCTAssertTrue(review.reasons.contains(.malformedMovementEvent))
        XCTAssertEqual(review.travelIntervals.count, 4, "a zero-width event cannot become a travel interval")
    }

    func testAFaderClickOverAStationaryIntervalIsCitedButNeverProposedAsTheBoundaryKind() {
        let click = CrossfaderSemanticEvent(
            kind: .cut,
            startTime: 0.25,
            endTime: 0.28,
            fromPosition: 1,
            toPosition: 0
        )
        let review = review(derivation: openFaderDerivation(clicks: [click]))
        let boundary = review.candidates[0].boundaries[0]

        XCTAssertEqual(boundary.kind, .hold, "the tear hold count derives from the platter stream alone")
        XCTAssertEqual(boundary.evidenceQuality, .ambiguous)
        XCTAssertEqual(boundary.proposal?.reasons.contains(.coincidentFaderClick), true)
        XCTAssertEqual(
            review.candidates[0].proposedClassification, .tear2,
            "a coincident click may not raise or lower the platter hold count"
        )
        XCTAssertTrue(review.candidates[0].hasAmbiguousEvidence)
        XCTAssertEqual(review.faderClicks(over: boundary.span).count, 1)
    }

    func testAHoldCountOutsideTheSupportedVocabularyIsUnknownNotTheNearestTear() {
        let events = [
            movement(0.0, 0.2, "backward"),
            movement(0.4, 0.6, "backward"),
            movement(0.8, 1.0, "backward"),
            movement(1.2, 1.4, "backward"),
            movement(1.6, 1.8, "backward")
        ]
        let review = review(movementEvents: events)

        XCTAssertEqual(review.candidates.count, 1)
        XCTAssertEqual(review.candidates[0].boundaries.count, 4)
        XCTAssertEqual(review.candidates[0].proposedClassification, .unknown)
        XCTAssertNil(review.candidates[0].effectiveClassification.assertedTearHoldCount)
        XCTAssertTrue(review.candidates[0].proposalReasons.contains(.holdCountOutsideSupportedRange))
    }

    func testATakeWithNoPlatterMotionSaysSoInsteadOfProposingAnything() {
        let review = review(movementEvents: [], derivation: nil)
        XCTAssertFalse(review.hasMotionEvidence)
        XCTAssertTrue(review.candidates.isEmpty)
        XCTAssertTrue(review.reasons.contains(.noMotionEvidence))
    }

    func testAnUnobservedFaderIsUnknownAndNeverImplicitlyOpen() {
        let review = review(derivation: CrossfaderDerivation(intervals: [], events: []))
        XCTAssertEqual(review.faderReading(over: review.candidates[0].span), .unobserved)
        XCTAssertTrue(review.reasons.contains(.faderUnobserved))
        XCTAssertEqual(
            review.candidates[0].boundaries[0].evidenceQuality, .ambiguous,
            "a boundary with no fader observation over it is not clean evidence"
        )
    }

    // MARK: Corrections through the review value

    func testClassifyingACandidateRetainsTheAutomaticProposalBesideIt() {
        var review = review()
        let candidateID = review.candidates[0].id

        XCTAssertTrue(
            review.classifyCandidate(id: candidateID, as: .tear1, correction: correction("test"))
        )
        let candidate = review.candidate(id: candidateID)!
        XCTAssertEqual(candidate.manualClassification, .tear1)
        XCTAssertEqual(candidate.effectiveClassification, .tear1)
        XCTAssertEqual(
            candidate.proposedClassification, .tear2,
            "the machine's reading survives the operator disagreeing with it"
        )
        XCTAssertTrue(candidate.isManuallyClassified)
    }

    func testAClassificationDisagreeingWithTheBoundaryCountIsReportedNotReconciled() {
        var review = review()
        let candidateID = review.candidates[0].id
        review.classifyCandidate(id: candidateID, as: .tear1, correction: correction("test"))

        let candidate = review.candidate(id: candidateID)!
        XCTAssertTrue(candidate.classificationDisagreesWithBoundaryCount)
        XCTAssertEqual(candidate.countedTearHoldCount, 2, "the boundaries were not silently deleted to match")
        XCTAssertEqual(candidate.boundarySupportedClassification, .tear2)
        XCTAssertEqual(candidate.effectiveClassification, .tear1, "the operator's reading still wins")
    }

    func testNamingABoundaryAFaderClickStopsItCountingWithoutDeletingIt() {
        var review = review()
        let candidateID = review.candidates[0].id
        let boundaryID = review.candidates[0].boundaries[0].id

        XCTAssertTrue(
            review.setBoundaryKind(
                inCandidate: candidateID,
                boundaryID: boundaryID,
                to: .faderClick,
                correction: correction("test")
            )
        )
        let candidate = review.candidate(id: candidateID)!
        let boundary = candidate.boundaries.first { $0.id == boundaryID }!
        XCTAssertEqual(boundary.kind, .faderClick)
        XCTAssertFalse(boundary.countsAsTearHold)
        XCTAssertEqual(boundary.proposal?.kind, .hold, "the proposal is retained verbatim")
        XCTAssertEqual(candidate.boundaries.count, 2, "nothing was deleted")
        XCTAssertEqual(candidate.countedTearHoldCount, 1)
        XCTAssertEqual(candidate.boundarySupportedClassification, .tear1)
    }

    func testRemovingABoundaryIsAFlagAndIsReversible() {
        var review = review()
        let candidateID = review.candidates[0].id
        let boundaryID = review.candidates[0].boundaries[1].id

        review.setBoundaryRemoved(
            inCandidate: candidateID,
            boundaryID: boundaryID,
            removed: true,
            correction: correction("test")
        )
        var boundary = review.candidate(id: candidateID)!.boundaries.first { $0.id == boundaryID }!
        XCTAssertTrue(boundary.isRemoved)
        XCTAssertFalse(boundary.countsAsTearHold)
        XCTAssertEqual(review.candidate(id: candidateID)!.countedTearHoldCount, 1)
        XCTAssertEqual(review.candidate(id: candidateID)!.boundaries.count, 2)
        XCTAssertEqual(
            review.rawMovementEvents.count, 4,
            "striking a boundary out must never delete raw motion evidence"
        )

        review.setBoundaryRemoved(
            inCandidate: candidateID,
            boundaryID: boundaryID,
            removed: false,
            correction: correction("test")
        )
        boundary = review.candidate(id: candidateID)!.boundaries.first { $0.id == boundaryID }!
        XCTAssertFalse(boundary.isRemoved)
        XCTAssertEqual(boundary.corrections.count, 2, "both decisions are kept, not overwritten")
    }

    func testAddingABoundaryIsRefusedForAnUnusableSpanAndAcceptedOtherwise() {
        var review = review()
        let candidateID = review.candidates[1].id

        XCTAssertNil(
            review.addBoundary(
                toCandidate: candidateID,
                span: ReferenceTearTimeSpan(startTime: 1.2, endTime: 1.2),
                kind: .hold,
                evidenceQuality: .clear,
                correction: correction("test")
            ),
            "a zero-width boundary is refused, never clamped into existence"
        )
        XCTAssertTrue(review.candidate(id: candidateID)!.boundaries.isEmpty)

        let added = review.addBoundary(
            toCandidate: candidateID,
            span: ReferenceTearTimeSpan(startTime: 1.20, endTime: 1.25),
            kind: .hold,
            evidenceQuality: .ambiguous,
            correction: correction("test", notes: "pause I can hear but the decoder missed")
        )
        let candidate = review.candidate(id: candidateID)!
        XCTAssertNotNil(added)
        XCTAssertEqual(candidate.boundaries.count, 1)
        XCTAssertEqual(candidate.boundaries[0].origin, .operatorAdded)
        XCTAssertNil(candidate.boundaries[0].proposal, "the machine proposed nothing here")
        XCTAssertTrue(candidate.boundaries[0].differsFromProposal)
        XCTAssertEqual(candidate.countedTearHoldCount, 1)
        XCTAssertEqual(candidate.boundarySupportedClassification, .tear1)
        XCTAssertTrue(candidate.hasAmbiguousEvidence)
    }

    func testAddingADuplicateHoldCoalescesInsteadOfDoubleCounting() {
        var review = review()
        let candidateID = review.candidates[0].id
        let existing = review.candidates[0].boundaries[0]

        let added = review.addBoundary(
            toCandidate: candidateID,
            span: existing.span,
            kind: .hold,
            evidenceQuality: .clear,
            correction: correction("duplicate")
        )
        XCTAssertEqual(added, existing.id, "an exact duplicate coalesces into the boundary already there")
        let candidate = review.candidate(id: candidateID)!
        XCTAssertEqual(candidate.boundaries.count, 2, "a duplicate must not add a second boundary")
        XCTAssertEqual(candidate.countedTearHoldCount, 2, "the platter hold count must not double")
        XCTAssertEqual(
            candidate.boundaries.first { $0.id == existing.id }?.corrections.count, 1,
            "the duplicate correction is folded into the existing boundary's provenance"
        )
    }

    func testAddingAHoldOutsideTheGestureIsRefused() {
        var review = review()
        let candidateID = review.candidates[0].id
        let before = review.candidates[0].boundaries.count

        // candidate[0] is the backward gesture spanning 0.00–0.95; a hold at
        // 1.10–1.20 lies inside the following forward gesture instead.
        let added = review.addBoundary(
            toCandidate: candidateID,
            span: ReferenceTearTimeSpan(startTime: 1.10, endTime: 1.20),
            kind: .hold,
            evidenceQuality: .clear,
            correction: correction("outside")
        )
        XCTAssertNil(added, "a hold outside the gesture is refused, never clamped into it")
        XCTAssertEqual(review.candidate(id: candidateID)!.boundaries.count, before)
    }

    func testMovingABoundaryKeepsTheProposalAndTheEditedSpanSideBySide() {
        var review = review()
        let candidateID = review.candidates[0].id
        let boundaryID = review.candidates[0].boundaries[0].id
        let proposedSpan = review.candidates[0].boundaries[0].span

        XCTAssertTrue(
            review.moveBoundary(
                inCandidate: candidateID,
                boundaryID: boundaryID,
                to: ReferenceTearTimeSpan(startTime: 0.22, endTime: 0.33),
                correction: correction("test")
            )
        )
        let boundary = review.candidate(id: candidateID)!.boundaries.first { $0.id == boundaryID }!
        XCTAssertEqual(boundary.span.startTime, 0.22, accuracy: 1e-9)
        XCTAssertEqual(boundary.proposal?.span, proposedSpan)
        XCTAssertTrue(boundary.differsFromProposal)
        XCTAssertEqual(review.rawMovementEvents, twoTearMovementEvents())
    }

    func testMovingAHoldOutsideTheGestureIsRefused() {
        var review = review()
        let candidateID = review.candidates[0].id
        let boundaryID = review.candidates[0].boundaries[0].id
        let originalSpan = review.candidates[0].boundaries[0].span

        XCTAssertFalse(
            review.moveBoundary(
                inCandidate: candidateID,
                boundaryID: boundaryID,
                to: ReferenceTearTimeSpan(startTime: 1.10, endTime: 1.20),
                correction: correction("outside")
            ),
            "a hold moved outside the gesture is refused, never clamped"
        )
        let boundary = review.candidate(id: candidateID)!.boundaries.first { $0.id == boundaryID }!
        XCTAssertEqual(boundary.span, originalSpan, "the refused move leaves the hold exactly where it was")
    }

    func testCorrectionProvenanceIsManualAndValidates() {
        let correction = correction("boundary_moved", notes: "second pause is fader work")
        XCTAssertEqual(correction.correctedBy, "Karl")
        XCTAssertEqual(correction.correctedAt, correctedAt)
        XCTAssertEqual(correction.notes, "second pause is fader work")
        XCTAssertEqual(correction.evidence.provenance, .manuallyCorrected)
        XCTAssertEqual(correction.evidence.observation.source, .manualCorrection)
        XCTAssertTrue(correction.validationIssues().isEmpty, "\(correction.validationIssues())")
    }

    func testAnUnknownCandidateOrBoundaryIsRefusedRatherThanSilentlyIgnored() {
        var review = review()
        XCTAssertFalse(review.classifyCandidate(id: "nope", as: .tear1, correction: correction("test")))
        XCTAssertFalse(
            review.setBoundaryKind(
                inCandidate: review.candidates[0].id,
                boundaryID: "nope",
                to: .faderClick,
                correction: correction("test")
            )
        )
    }

    // MARK: Corrections through the session

    private func reviewingSession(
        movementEvents: [CaptureCore.DetectedNotationRecordMovementEvent]? = nil,
        derivation: CrossfaderDerivation? = nil
    ) -> ReferenceAuthoringSession {
        var session = ReferenceAuthoringSession(authoringSessionID: "auth-0001", operatorName: "Karl")
        session.selectTechnique(.babyScratch)
        session.selectPattern(
            ReferencePatternIdentity(id: "quarter_notes", name: "Quarter notes", phraseBars: 1),
            bpm: 95
        )
        session.declareVariant(
            startingDirection: .forward,
            faderVariant: .faderOpenThroughout,
            handedness: .right
        )
        session.confirmedCalibration = calibration
        session.phase = .readyToRecord

        let events = movementEvents ?? twoTearMovementEvents()
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: { .success(self.artifacts(movementEvents: events)) },
            currentPreflightSnapshot: { self.passingSnapshot() },
            latestCalibrationObservation: { nil }
        )
        _ = session.beginRecording(using: hooks)
        _ = session.finishRecording(using: hooks)
        return session
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

    private func artifacts(
        movementEvents: [CaptureCore.DetectedNotationRecordMovementEvent]
    ) -> ReferenceRecordedTakeArtifacts {
        let samples: [CrossfaderPositionSample] = (0..<800).map { index in
            CrossfaderPositionSample(
                takeRelativeTime: Double(index) * 0.001,
                rawValue: 1,
                normalizedPosition: 1
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
            platterMovementEventCount: movementEvents.count,
            recordedAt: Date(timeIntervalSince1970: 1_788_000_500),
            autoDetectedTechnique: nil,
            watchEvidence: .linked(motionFileName: "watch-motion.json"),
            platterMovementEvents: movementEvents,
            platterEvidenceIntervals: syntheticObservedPlatterStillness(movementEvents)
        )
    }

    func testFinishingATakeBuildsItsTearReviewFromThatTakesOwnEvidence() {
        let session = reviewingSession()
        let review = session.tearReviewForTakeInReview

        XCTAssertEqual(review?.referenceTakeID, "auth-0001-take-001")
        XCTAssertEqual(review?.rawMovementEvents, twoTearMovementEvents())
        XCTAssertEqual(review?.candidates.count, 2)
        XCTAssertEqual(review?.candidates.first?.proposedClassification, .tear2)
    }

    func testTheSessionRecordsWhoCorrectedWhatAndWhen() {
        var session = reviewingSession()
        let candidateID = session.tearReviewForTakeInReview!.candidates[0].id
        let boundaryID = session.tearReviewForTakeInReview!.candidates[0].boundaries[1].id
        let now = Date(timeIntervalSince1970: 1_788_002_000)

        XCTAssertTrue(
            session.classifyTearCandidate(
                candidateID,
                as: .tear1,
                notes: "second pause is a fader cut, not a platter hold",
                now: now
            )
        )
        XCTAssertTrue(
            session.setTearBoundaryKind(
                inCandidate: candidateID,
                boundaryID: boundaryID,
                to: .faderClick,
                notes: "cut, not a hold",
                now: now
            )
        )

        let candidate = session.tearReviewForTakeInReview!.candidate(id: candidateID)!
        let classification = candidate.latestClassificationCorrection!
        XCTAssertEqual(classification.correctedBy, "Karl")
        XCTAssertEqual(classification.correctedAt, now)
        XCTAssertEqual(classification.notes, "second pause is a fader cut, not a platter hold")
        XCTAssertEqual(classification.evidence.provenance, .manuallyCorrected)

        let boundary = candidate.boundaries.first { $0.id == boundaryID }!
        XCTAssertEqual(boundary.latestCorrection?.notes, "cut, not a hold")
        XCTAssertEqual(candidate.countedTearHoldCount, 1)
        XCTAssertEqual(candidate.effectiveClassification, .tear1)
        XCTAssertFalse(
            candidate.classificationDisagreesWithBoundaryCount,
            "one counted hold and a 1-tear reading agree"
        )
    }

    func testTheSessionCanAddMoveAndRemoveBoundariesWithoutTouchingRawMotion() {
        var session = reviewingSession()
        let candidateID = session.tearReviewForTakeInReview!.candidates[1].id

        XCTAssertTrue(
            session.addTearBoundary(
                toCandidate: candidateID,
                startTime: 1.20,
                endTime: 1.25,
                notes: "missed pause"
            )
        )
        let addedID = session.tearReviewForTakeInReview!.candidate(id: candidateID)!.boundaries[0].id
        XCTAssertTrue(
            session.moveTearBoundary(
                inCandidate: candidateID,
                boundaryID: addedID,
                startTime: 1.22,
                endTime: 1.28
            )
        )
        XCTAssertTrue(
            session.setTearBoundaryEvidenceQuality(
                inCandidate: candidateID,
                boundaryID: addedID,
                to: .ambiguous
            )
        )
        XCTAssertTrue(
            session.setTearBoundaryRemoved(
                inCandidate: candidateID,
                boundaryID: addedID,
                removed: true
            )
        )

        let review = session.tearReviewForTakeInReview!
        let boundary = review.candidate(id: candidateID)!.boundaries[0]
        XCTAssertEqual(boundary.span.startTime, 1.22, accuracy: 1e-9)
        XCTAssertTrue(boundary.isRemoved)
        XCTAssertEqual(boundary.evidenceQuality, .ambiguous)
        XCTAssertEqual(boundary.corrections.count, 4, "every correction is appended, never overwritten")
        XCTAssertEqual(review.rawMovementEvents, twoTearMovementEvents())
        XCTAssertEqual(
            session.takeInReview?.evidence.platterMovementEvents,
            twoTearMovementEvents(),
            "the take's own evidence is never rewritten by a review correction"
        )
    }

    func testTearReviewNotesAreRetainedWithProvenance() {
        var session = reviewingSession()
        let now = Date(timeIntervalSince1970: 1_788_003_000)
        XCTAssertTrue(session.setTearReviewNotes("Third pass; second gesture still unclear.", now: now))

        let review = session.tearReviewForTakeInReview!
        XCTAssertEqual(review.notes, "Third pass; second gesture still unclear.")
        XCTAssertEqual(review.noteCorrections.last?.correctedAt, now)
        XCTAssertEqual(review.noteCorrections.last?.correctedBy, "Karl")
    }

    /// The safety property this whole layer is built around.
    func testNoTearCorrectionApprovesValidatesOrPublishesTheTake() throws {
        var session = reviewingSession()
        let before = try XCTUnwrap(session.takeInReview)
        let approvalBlockedBefore = session.approvalBlockReason()
        let candidateID = session.tearReviewForTakeInReview!.candidates[0].id
        let boundaryID = session.tearReviewForTakeInReview!.candidates[0].boundaries[0].id

        session.classifyTearCandidate(candidateID, as: .tear2)
        session.setTearBoundaryKind(inCandidate: candidateID, boundaryID: boundaryID, to: .faderClick)
        session.setTearBoundaryEvidenceQuality(inCandidate: candidateID, boundaryID: boundaryID, to: .ambiguous)
        session.setTearBoundaryRemoved(inCandidate: candidateID, boundaryID: boundaryID, removed: true)
        session.addTearBoundary(toCandidate: candidateID, startTime: 0.21, endTime: 0.30)
        session.setTearReviewNotes("reviewed")
        session.classifyTearCandidate(session.tearReviewForTakeInReview!.candidates[1].id, as: .nonTear)

        let after = try XCTUnwrap(session.takeInReview)
        XCTAssertTrue(
            after.tearReview.everyCandidateHasAnOperatorReading,
            "the fixture must actually complete the review, or this test proves nothing"
        )
        XCTAssertEqual(after.evidence.metadata.lifecycleState, .draft)
        XCTAssertNil(after.evidence.metadata.reviewDecision)
        XCTAssertEqual(after.latestValidation, before.latestValidation, "no correction re-runs validation")
        XCTAssertEqual(
            session.approvalBlockReason(), approvalBlockedBefore,
            "a completed tear review must not move the approval gate in either direction"
        )
        XCTAssertNil(session.takeReadyForPublication(takeIndex: 0))
        XCTAssertEqual(after.evidence.boundaries, before.evidence.boundaries)
    }

    func testTearCorrectionsAreRefusedWhenNoTakeIsInReview() {
        var session = reviewingSession()
        let candidateID = session.tearReviewForTakeInReview!.candidates[0].id
        session.retake()

        XCTAssertNil(session.tearReviewForTakeInReview)
        XCTAssertFalse(session.classifyTearCandidate(candidateID, as: .tear1))
        XCTAssertFalse(session.addTearBoundary(toCandidate: candidateID, startTime: 0.1, endTime: 0.2))
        XCTAssertFalse(session.setTearReviewNotes("no take"))
        XCTAssertEqual(
            session.takes[0].tearReview.candidates[0].manualClassification, nil,
            "a refused correction changes nothing on the retained take"
        )
    }
}

// MARK: - Direction chatter and evidence-boundary regressions

/// Synthetic regressions for direction grouping. Duration and a gap alone
/// cannot establish physical intent or stationary platter evidence.
final class ReferenceTearSegmentationChatterRootCauseTests: XCTestCase {

    private func movement(
        _ startTime: Double,
        _ endTime: Double,
        _ direction: String,
        confidence: Double = 0.9,
        excursion: Double = 1
    ) -> CaptureCore.DetectedNotationRecordMovementEvent {
        CaptureCore.DetectedNotationRecordMovementEvent(
            startTime: startTime,
            endTime: endTime,
            startPosition: direction == "forward" ? 0 : excursion,
            endPosition: direction == "forward" ? excursion : 0,
            direction: direction,
            movementKind: direction == "forward" ? .normalPush : .normalPull,
            speed: 1,
            confidence: confidence,
            source: "controller"
        )
    }

    /// Synthetic low-amplitude turnaround chatter, with no physical label.
    private func noisyBabyScratchMovementEvents() -> [CaptureCore.DetectedNotationRecordMovementEvent] {
        var events: [CaptureCore.DetectedNotationRecordMovementEvent] = [
            movement(0.00, 1.00, "forward")
        ]
        // Six alternating micro-runs sharing boundaries exactly as
        // decodePlatterCore emits them (one run's endTime is the next run's
        // startTime — no gap, matching a continuous MIDI stream broken only
        // by sign flips).
        let chatterStarts = stride(from: 1.00, to: 1.36, by: 0.06)
        var direction = "backward"
        for start in chatterStarts {
            events.append(movement(start, start + 0.06, direction, excursion: 0.005))
            direction = direction == "backward" ? "forward" : "backward"
        }
        let lastChatterEnd = events.last!.endTime
        events.append(movement(lastChatterEnd, lastChatterEnd + 1.00, "backward"))
        return events
    }

    /// Raw counter-motion remains inspectable as unknown and never becomes
    /// a monotonic curve under the surrounding direction.
    func testLowAmplitudeTurnaroundChatterRemainsUnknownWithOneConfirmedReversal() {
        let events = noisyBabyScratchMovementEvents()
        let review = ReferenceTearSegmentationReviewBuilder.build(
            referenceTakeID: "root-cause-proof",
            movementEvents: events,
            derivation: nil
        )

        XCTAssertEqual(review.rawMovementEvents.count, events.count, "raw evidence must never be filtered")
        XCTAssertEqual(review.segments.filter { $0.movementEventIndex != nil }.count, events.count,
            "every raw event must still surface as its own inspectable segment")
        XCTAssertGreaterThanOrEqual(review.candidates.count, 2)
        XCTAssertTrue(review.segments.contains { $0.state == .unknown && $0.reasons.contains(.mergedDirectionChatter) })
        XCTAssertEqual(review.reversals.count, 1)
        XCTAssertEqual(review.candidates[0].direction, .forward)
        XCTAssertEqual(review.candidates.last?.direction, .backward)
        XCTAssertTrue(
            review.segments.contains { $0.reasons.contains(.mergedDirectionChatter) },
            "the absorbed chatter runs must say so, not disappear silently"
        )
        XCTAssertTrue(review.reasons.contains(.mergedDirectionChatter))
    }

    /// A clean Baby Scratch (no chatter at all) must be completely unaffected
    /// by the repair — it has no run short enough to be chatter-eligible.
    func testCleanBabyScratchIsUnaffectedByChatterRepair() {
        let events = [movement(0.0, 1.0, "forward"), movement(1.0, 2.0, "backward")]
        let review = ReferenceTearSegmentationReviewBuilder.build(
            referenceTakeID: "clean-baby", movementEvents: events, derivation: nil
        )
        XCTAssertEqual(review.candidates.count, 2)
        XCTAssertEqual(review.reversals.count, 1)
        XCTAssertFalse(review.reasons.contains(.mergedDirectionChatter))
    }

    /// A short INTENTIONAL hold (a real, explicitly observed stationary interval)
    /// sitting right next to turnaround jitter must survive as a hold — the
    /// repair targets opposite-direction TRAVEL chatter only, never a
    /// stationary gap, however short.
    func testShortIntentionalHoldBesideReversalJitterIsPreserved() {
        var events = [movement(0.0, 1.0, "backward")]
        // This synthetic fixture supplies explicit observed stillness below;
        // the time gap in the travel array is insufficient on its own.
        events.append(movement(1.09, 1.50, "backward"))
        // Turnaround jitter immediately after, then the real backward-to-
        // forward reversal.
        events.append(movement(1.50, 1.56, "forward", excursion: 0.005))
        events.append(movement(1.56, 1.62, "backward"))
        events.append(movement(1.62, 2.60, "forward"))
        let review = ReferenceTearSegmentationReviewBuilder.build(
            referenceTakeID: "hold-beside-jitter", movementEvents: events,
            platterEvidenceIntervals: [.init(startTime: 1, endTime: 1.09, kind: .observedStillness)], derivation: nil
        )
        XCTAssertEqual(review.candidates.count, 3, "unknown counter-motion splits measured curves")
        let tear = review.candidates[0]
        XCTAssertEqual(tear.direction, .backward)
        XCTAssertEqual(tear.boundaries.count, 1, "the genuine explicitly observed hold must survive, uncounted as chatter")
        XCTAssertEqual(tear.countedTearHoldCount, 1)
        XCTAssertEqual(review.candidates.last?.direction, .forward)
        XCTAssertEqual(review.reversals.count, 1)
    }

    /// Missing packets beside high-excursion opposing travel must stay
    /// unknown rather than becoming a same-direction hold.
    func testSilenceBesideOpposingTravelDoesNotBecomeAHold() {
        let events = [
            movement(0.0, 1.0, "backward"),
            movement(1.10, 1.16, "forward"), // 60 ms chatter, after a gap
            movement(1.16, 2.0, "backward")
        ]
        let review = ReferenceTearSegmentationReviewBuilder.build(
            referenceTakeID: "pause-beside-chatter", movementEvents: events, derivation: nil
        )
        XCTAssertEqual(review.candidates.count, 3)
        XCTAssertEqual(review.totalCountedTearHoldCount, 0)
        XCTAssertEqual(review.stationaryIntervals.count, 0)
        XCTAssertEqual(review.reversals.count, 2)
        XCTAssertFalse(review.reasons.contains(.mergedDirectionChatter))
    }

    /// 1/2/3-tears (clean, no chatter) must still report their exact hold
    /// counts — the repair must never invent or remove a genuine hold.
    func test123TearsAreUnaffectedByChatterRepair() {
        func tearEvents(holdCount: Int) -> [CaptureCore.DetectedNotationRecordMovementEvent] {
            var events: [CaptureCore.DetectedNotationRecordMovementEvent] = []
            var t = 0.0
            for i in 0...holdCount {
                events.append(movement(t, t + 0.4, "backward"))
                t += 0.4
                if i < holdCount {
                    // Explicitly observed hold, not a travel event.
                    t += 0.15
                }
            }
            events.append(movement(t, t + 1.0, "forward"))
            return events
        }
        for holdCount in 1...3 {
            let review = ReferenceTearSegmentationReviewBuilder.build(
                referenceTakeID: "tear-\(holdCount)", movementEvents: tearEvents(holdCount: holdCount),
                platterEvidenceIntervals: syntheticObservedPlatterStillness(tearEvents(holdCount: holdCount)), derivation: nil
            )
            XCTAssertEqual(review.candidates.count, 2, "holdCount \(holdCount)")
            XCTAssertEqual(review.candidates[0].countedTearHoldCount, holdCount, "holdCount \(holdCount)")
            XCTAssertEqual(
                review.candidates[0].proposedClassification.assertedTearHoldCount, holdCount,
                "holdCount \(holdCount)"
            )
        }
    }

    /// Unequal subdivisions (a real tear whose moving slices have different
    /// durations) must be unaffected — duration asymmetry between REAL
    /// travel runs, both well above the sustained threshold, is not chatter.
    func testUnequalSubdivisionsAreUnaffectedByChatterRepair() {
        let events = [
            movement(0.0, 0.30, "backward"),
            movement(0.45, 1.80, "backward"),
            movement(1.80, 2.20, "forward")
        ]
        let review = ReferenceTearSegmentationReviewBuilder.build(
            referenceTakeID: "unequal-subdivisions", movementEvents: events,
            platterEvidenceIntervals: syntheticObservedPlatterStillness(events), derivation: nil
        )
        XCTAssertEqual(review.candidates.count, 2)
        XCTAssertEqual(review.candidates[0].countedTearHoldCount, 1)
        XCTAssertEqual(review.candidates[0].motionSegmentIndices.count, 3)
    }

    /// A slow drag: one long, low-speed, single-direction run. Nothing to
    /// merge — must pass through completely unchanged.
    func testSlowDragIsUnaffectedByChatterRepair() {
        let events = [movement(0.0, 4.0, "forward", confidence: 0.95)]
        let review = ReferenceTearSegmentationReviewBuilder.build(
            referenceTakeID: "slow-drag", movementEvents: events, derivation: nil
        )
        XCTAssertEqual(review.candidates.count, 1)
        XCTAssertTrue(review.candidates[0].boundaries.isEmpty)
        XCTAssertFalse(review.reasons.contains(.mergedDirectionChatter))
    }

    /// Duplicate/zero-duration timestamps are already rejected as malformed
    /// upstream of the repair; the repair must not change that or crash on
    /// the remaining valid events.
    func testDuplicateTimestampsAreRejectedNotFedToTheRepair() {
        let events = [
            movement(0.0, 1.0, "forward"),
            movement(1.0, 1.0, "backward"), // zero-duration: malformed, dropped
            movement(1.0, 2.0, "backward")
        ]
        let review = ReferenceTearSegmentationReviewBuilder.build(
            referenceTakeID: "duplicate-timestamps", movementEvents: events, derivation: nil
        )
        XCTAssertTrue(review.reasons.contains(.malformedMovementEvent))
        XCTAssertEqual(review.candidates.count, 2)
    }

    /// Missing retained events cannot establish stationary evidence.
    func testDroppedEventsLeaveUnknownInsteadOfStationaryInterval() {
        let events = [movement(0.0, 1.0, "forward"), movement(1.30, 2.0, "forward")]
        let review = ReferenceTearSegmentationReviewBuilder.build(
            referenceTakeID: "dropped-event", movementEvents: events, derivation: nil
        )
        XCTAssertEqual(review.candidates.count, 2)
        XCTAssertEqual(review.totalCountedTearHoldCount, 0)
        XCTAssertEqual(review.stationaryIntervals.count, 0)
        XCTAssertTrue(review.segments.contains { $0.state == .unknown })
    }

    /// A lone quantized travel event retains its recorded direction.
    func testQuantizedPositionsDoNotAffectChatterRepair() {
        let coarse = CaptureCore.DetectedNotationRecordMovementEvent(
            startTime: 0.0, endTime: 1.0, startPosition: 0.0, endPosition: 0.0,
            direction: "forward", movementKind: .normalPush, speed: 1, confidence: 0.9, source: "controller"
        )
        let review = ReferenceTearSegmentationReviewBuilder.build(
            referenceTakeID: "quantized", movementEvents: [coarse], derivation: nil
        )
        XCTAssertEqual(review.candidates.count, 1)
        XCTAssertEqual(review.candidates[0].direction, .forward)
    }

    /// A quick but GENUINE reversal — a single short opposite-direction run,
    /// well above `minimumSustainedTravelDuration`, with no surrounding
    /// chatter — must still register as its own real reversal, never merged
    /// away. This is the required counterpart to the chatter test: short
    /// duration alone is never sufficient to call something chatter.
    func testQuickGenuineReversalIsNeverMergedAway() {
        let events = [
            movement(0.0, 1.0, "forward"),
            movement(1.0, 1.15, "backward"), // 150 ms, high displacement
            movement(1.15, 2.5, "forward")
        ]
        let review = ReferenceTearSegmentationReviewBuilder.build(
            referenceTakeID: "quick-genuine-reversal", movementEvents: events, derivation: nil
        )
        XCTAssertEqual(review.candidates.count, 3, "the quick middle reversal is real and must stand on its own")
        XCTAssertEqual(review.reversals.count, 2)
        XCTAssertEqual(review.candidates[1].direction, .backward)
        XCTAssertFalse(review.reasons.contains(.mergedDirectionChatter))
    }

    /// A long single-direction run spanning what would be several platter
    /// revolutions in calibrated units. The repair never reads absolute
    /// position/revolution counts, only direction and duration, so a
    /// free-running multi-revolution run cannot shift or split under it.
    func testFreeRunningMultiRevolutionTravelIsUnaffected() {
        let events = [movement(0.0, 8.0, "forward", confidence: 0.9)]
        let review = ReferenceTearSegmentationReviewBuilder.build(
            referenceTakeID: "free-running", movementEvents: events, derivation: nil
        )
        XCTAssertEqual(review.candidates.count, 1)
        XCTAssertEqual(review.candidates[0].span.startTime, 0.0)
        XCTAssertEqual(review.candidates[0].span.endTime, 8.0)
    }

    /// A single isolated opposing delta — one short opposite-direction run
    /// between two sustained same-direction runs — must not establish a
    /// reversal on its own. This is the single-delta sibling of the
    /// multi-delta chatter test: sustained opposite evidence, not one sign
    /// flip, is what ends a gesture.
    func testIsolatedOpposingDeltaIsAbsorbedNotAReversal() {
        let events = [
            movement(0.0, 1.0, "forward"),
            movement(1.0, 1.04, "backward", excursion: 0.005), // 40 ms: isolated, not sustained
            movement(1.04, 2.0, "forward")
        ]
        let review = ReferenceTearSegmentationReviewBuilder.build(
            referenceTakeID: "isolated-opposing-delta", movementEvents: events, derivation: nil
        )
        XCTAssertEqual(review.candidates.count, 2, "unknown counter-motion must separate measured curves")
        XCTAssertTrue(review.segments.contains { $0.state == .unknown })
        XCTAssertEqual(review.candidates[0].direction, .forward)
        XCTAssertEqual(review.reversals.count, 0)
        XCTAssertTrue(review.reasons.contains(.mergedDirectionChatter))
    }

    /// A clock discontinuity — a large, unexplained time jump between two
    /// runs — is read as an ABSENCE of telemetry, never as a confident
    /// measured hold, and the chatter repair never fabricates a reversal
    /// across it.
    func testClockDiscontinuityStaysGapDerivedUnknownAndUnmerged() {
        // A 4 s recording gap between two backward runs, then a real
        // backward-to-forward reversal.
        let events = [
            movement(0.0, 0.5, "backward"),
            movement(4.5, 5.0, "backward"),
            movement(5.0, 6.0, "forward")
        ]
        let review = ReferenceTearSegmentationReviewBuilder.build(
            referenceTakeID: "clock-discontinuity", movementEvents: events, derivation: nil
        )
        XCTAssertEqual(review.candidates.count, 3)
        XCTAssertEqual(review.totalCountedTearHoldCount, 0)
        XCTAssertEqual(review.stationaryIntervals.count, 0)
        XCTAssertTrue(review.segments.contains { $0.state == .unknown })
        XCTAssertEqual(review.reversals.count, 1)
    }
}

// MARK: - Tear authoring, calibration reuse, take-start correlation, raw export

/// Regression cover for the 2026-09-06 authoring slice.
///
/// Every fixture here is SYNTHETIC. Take 008 is used only as the shape to
/// reproduce (a Tear performed with the fader parked open, a valid learned
/// Ch16/CC8 mapping, and zero mapped crossfader samples); the physical take is
/// never read, altered, approved or promoted by anything in this file.
final class ReferenceTearAuthoringSliceTests: XCTestCase {

    // MARK: Fixtures

    /// Mirrors the physical rig: Rane ONE MKII, Ch16 (channel 15) CC8, right
    /// deck, open at the far right — so a PARKED-OPEN fader reads raw 127 and
    /// emits nothing for the whole take.
    private let calibration = CrossfaderCalibration(
        address: CrossfaderMIDIAddress(
            deviceIdentifier: "Rane ONE MKII",
            deviceName: "Rane ONE MKII",
            channel: 15,
            controller: 8
        ),
        fullLeftRawValue: 0,
        centerRawValue: 63,
        fullRightRawValue: 127,
        openEnd: .right,
        activeDeck: .rightDeck,
        calibratedAt: Date(timeIntervalSince1970: 1_788_000_000)
    )

    private var otherDeviceCalibration: CrossfaderCalibration {
        CrossfaderCalibration(
            address: CrossfaderMIDIAddress(
                deviceIdentifier: "Pioneer DDJ-GRV6",
                deviceName: "Pioneer DDJ-GRV6",
                channel: 6,
                controller: 31
            ),
            fullLeftRawValue: 0,
            centerRawValue: 63,
            fullRightRawValue: 127,
            openEnd: .right,
            activeDeck: .rightDeck,
            calibratedAt: Date(timeIntervalSince1970: 1_788_000_000)
        )
    }

    private func makeStore() throws -> CrossfaderCalibrationStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReferenceTearAuthoringSliceTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return CrossfaderCalibrationStore(directoryURL: directory)
    }

    private func passingSnapshot() -> ReferencePreflightSnapshot {
        ReferencePreflightSnapshot(
            controllerName: "Rane ONE MKII",
            controllerIdentifier: "Rane ONE MKII",
            observedCrossfaderAddress: calibration.address,
            latestCrossfaderRawValue: 127,
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

    private func makeConfiguredTearSession() -> ReferenceAuthoringSession {
        var session = ReferenceAuthoringSession(authoringSessionID: "auth-tear", operatorName: "Karl")
        session.selectTechnique(.tear)
        session.selectPattern(
            ReferencePatternIdentity(id: "tear_1bar", name: "Tear · 1 bar", phraseBars: 1),
            bpm: 95
        )
        session.declareVariant(
            startingDirection: .forward,
            faderVariant: .faderOpenThroughout,
            handedness: .right
        )
        return session
    }

    /// The correlation the host supplies for a take. Defaults line up with
    /// `parkedTakeStartState`; each rejection test perturbs exactly one field.
    private func correlation(
        sessionID: String = "session-008",
        takeID: String = "take-008",
        takeGeneration: UInt64? = 8,
        midiSourceID: String? = "midi_rane_one_mkii",
        midiConnectionGeneration: UInt64? = 3
    ) -> ReferenceCrossfaderTakeStart.Correlation {
        ReferenceCrossfaderTakeStart.Correlation(
            sessionID: sessionID,
            takeID: takeID,
            takeGeneration: takeGeneration,
            midiSourceID: midiSourceID,
            midiConnectionGeneration: midiConnectionGeneration
        )
    }

    /// A parked-open fader observed 0.4 s BEFORE media start. Negative
    /// observation time and snapshot provenance are the point: it is never
    /// presented as an in-take MIDI packet.
    private func parkedTakeStartState(
        sessionID: String = "session-008",
        takeID: String = "take-008",
        takeGeneration: UInt64? = 8,
        midiSourceID: String? = "midi_rane_one_mkii",
        midiConnectionGeneration: UInt64? = 3,
        channel: Int? = 15,
        controller: Int? = 8,
        deviceName: String? = "Rane ONE MKII",
        rawValue: Int? = 127,
        calibrationID: String? = "Rane ONE MKII#15#8",
        observedTakeRelativeTime: Double? = -0.4,
        provenance: CaptureCore.CrossfaderTakeStartState.Provenance = .preTakeSnapshot
    ) -> CaptureCore.CrossfaderTakeStartState {
        CaptureCore.CrossfaderTakeStartState(
            provenance: provenance,
            sessionID: sessionID,
            takeID: takeID,
            takeGeneration: takeGeneration,
            midiSourceID: midiSourceID,
            deviceName: deviceName,
            midiConnectionGeneration: midiConnectionGeneration,
            channel: channel,
            controller: controller,
            rawValue: rawValue,
            calibratedPosition: 1,
            calibrationID: calibrationID,
            observationSequence: 412,
            observedTakeRelativeTime: observedTakeRelativeTime,
            unknownReason: nil
        )
    }

    /// A finalized take with ZERO mapped crossfader samples — exactly the
    /// shape take 008 produced with the fader parked open.
    private func parkedArtifacts(
        autoDetected: ReferenceTechnique? = nil,
        takeStartState: CaptureCore.CrossfaderTakeStartState? = nil,
        takeStartCorrelation: ReferenceCrossfaderTakeStart.Correlation? = nil,
        crossfaderRawSamples: [CrossfaderPositionSample] = []
    ) -> ReferenceRecordedTakeArtifacts {
        ReferenceRecordedTakeArtifacts(
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
            crossfaderRawSamples: crossfaderRawSamples,
            observedCrossfaderAddress: crossfaderRawSamples.isEmpty ? nil : calibration.address,
            platterMovementEventCount: 55,
            recordedAt: Date(timeIntervalSince1970: 1_788_000_500),
            autoDetectedTechnique: autoDetected,
            watchEvidence: .linked(motionFileName: "watch-motion.json"),
            platterMovementEvents: [],
            crossfaderTakeStartState: takeStartState,
            crossfaderTakeStartCorrelation: takeStartCorrelation
        )
    }

    private func hooks(
        artifacts: ReferenceRecordedTakeArtifacts
    ) -> ReferenceAuthoringRecordingHooks {
        ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: { .success(artifacts) },
            currentPreflightSnapshot: { self.passingSnapshot() },
            latestCalibrationObservation: { nil }
        )
    }

    // MARK: Tear is a first-class authorable technique

    func testTearIsAuthorableAndRoundTripsThroughItsScratchType() {
        XCTAssertTrue(ReferenceTechnique.authorableSet.contains(.tear))
        XCTAssertEqual(ReferenceTechnique.tear.scratchType, .tear)
        XCTAssertEqual(ReferenceTechnique.tear.id, "tear")
        XCTAssertEqual(ReferenceTechnique(scratchType: .tear), .tear)
        XCTAssertEqual(ReferenceTechnique(scratchTypeID: "tear"), .tear)
        XCTAssertEqual(ReferenceTechnique.tear.displayName, "Tear")
        // Authorability must not widen training eligibility as a side effect.
        XCTAssertFalse(
            ReferenceTechnique.minimumRequiredSet.contains(.tear),
            "Tear must not enter the registry's trainingEnabledTechniques by becoming authorable."
        )
    }

    func testTearFaderExpectationRequiresAnOpenFaderAndNoCuts() {
        let expectation = ReferenceTechnique.tear.defaultFaderExpectation
        XCTAssertTrue(expectation.requiresContinuouslyOpenFader)
        XCTAssertEqual(expectation.minimumCutEventsPerRepetition, 0)
    }

    func testTearSetupWritesTearMetadataIntoTheFinalizedTake() throws {
        var session = makeConfiguredTearSession()
        let store = try makeStore()
        try store.save(calibration)
        _ = session.adoptPersistedCalibrationIfExact(
            store: store,
            openEnd: .right,
            activeDeck: .rightDeck,
            address: calibration.address
        )
        let artifacts = parkedArtifacts(
            takeStartState: parkedTakeStartState(),
            takeStartCorrelation: correlation()
        )
        let recordingHooks = hooks(artifacts: artifacts)
        guard case .success = session.beginRecording(using: recordingHooks) else {
            return XCTFail("Expected recording to start.")
        }
        guard case .success = session.finishRecording(using: recordingHooks) else {
            return XCTFail("Expected the take to finalize.")
        }
        let take = try XCTUnwrap(session.takeInReview)
        XCTAssertEqual(take.evidence.metadata.technique, .tear)
        XCTAssertEqual(take.evidence.metadata.technique.scratchType, .tear)
        XCTAssertEqual(take.evidence.metadata.technique.scratchType.rawValue, "tear")
    }

    func testAdvisoryBabyDetectionNeverOverwritesASelectedTear() throws {
        var session = makeConfiguredTearSession()
        let store = try makeStore()
        try store.save(calibration)
        _ = session.adoptPersistedCalibrationIfExact(
            store: store,
            openEnd: .right,
            activeDeck: .rightDeck,
            address: calibration.address
        )
        let artifacts = parkedArtifacts(
            autoDetected: .babyScratch,
            takeStartState: parkedTakeStartState(),
            takeStartCorrelation: correlation()
        )
        let recordingHooks = hooks(artifacts: artifacts)
        _ = session.beginRecording(using: recordingHooks)
        _ = session.finishRecording(using: recordingHooks)
        let take = try XCTUnwrap(session.takeInReview)
        XCTAssertEqual(session.selectedTechnique, .tear, "Advisory detection must never write back into the selection.")
        XCTAssertEqual(take.evidence.metadata.technique, .tear)
        XCTAssertEqual(take.autoDetectedTechnique, .babyScratch)
        XCTAssertTrue(take.autoDetectionDisagreesWithSelection)
    }

    // MARK: Crossfader setup reuse

    func testExactPersistedCalibrationIsAdoptedWithoutANewSweep() throws {
        var session = makeConfiguredTearSession()
        let store = try makeStore()
        try store.save(calibration)

        let outcome = session.adoptPersistedCalibrationIfExact(
            store: store,
            openEnd: .right,
            activeDeck: .rightDeck,
            address: calibration.address
        )
        guard case .adopted(let adopted) = outcome else {
            return XCTFail("Expected the exact stored calibration to be adopted, got \(outcome)")
        }
        XCTAssertEqual(adopted, calibration)
        XCTAssertEqual(session.confirmedCalibration, calibration)
        XCTAssertTrue(session.confirmedCalibrationSource?.isReused == true)
        XCTAssertEqual(session.phase, .readyToRecord, "Reuse must advance the session without a sweep.")
        XCTAssertNil(session.calibrationSweep, "Adoption must never start a sweep.")
    }

    func testAWrongDeviceCalibrationIsNeverAdopted() throws {
        var session = makeConfiguredTearSession()
        let store = try makeStore()
        try store.save(otherDeviceCalibration)

        let outcome = session.adoptPersistedCalibrationIfExact(
            store: store,
            openEnd: .right,
            activeDeck: .rightDeck,
            address: calibration.address
        )
        XCTAssertEqual(outcome, .noStoredCalibration)
        XCTAssertNil(session.confirmedCalibration)
        XCTAssertEqual(session.phase, .configuring)
    }

    func testACalibrationForADifferentDeckOrOpenEndIsNeverAdopted() throws {
        var session = makeConfiguredTearSession()
        let store = try makeStore()
        try store.save(calibration)

        XCTAssertEqual(
            session.adoptPersistedCalibrationIfExact(
                store: store,
                openEnd: .left,
                activeDeck: .rightDeck,
                address: calibration.address
            ),
            .configurationMismatch
        )
        XCTAssertEqual(
            session.adoptPersistedCalibrationIfExact(
                store: store,
                openEnd: .right,
                activeDeck: .leftDeck,
                address: calibration.address
            ),
            .configurationMismatch
        )
        XCTAssertNil(session.confirmedCalibration)
    }

    func testNoStoredCalibrationAndNoObservedAddressAreBothRefused() throws {
        var session = makeConfiguredTearSession()
        let store = try makeStore()
        XCTAssertEqual(
            session.adoptPersistedCalibrationIfExact(
                store: store,
                openEnd: .right,
                activeDeck: .rightDeck,
                address: nil
            ),
            .noObservedAddress
        )
        XCTAssertEqual(
            session.adoptPersistedCalibrationIfExact(
                store: store,
                openEnd: .right,
                activeDeck: .rightDeck,
                address: calibration.address
            ),
            .noStoredCalibration
        )
        XCTAssertNil(session.confirmedCalibration)
    }

    func testAdoptionIsRefusedWhileASweepIsInProgressOrAlreadyCalibrated() throws {
        var session = makeConfiguredTearSession()
        let store = try makeStore()
        try store.save(calibration)

        session.beginCalibration(address: calibration.address, openEnd: .right, activeDeck: .rightDeck)
        XCTAssertEqual(
            session.adoptPersistedCalibrationIfExact(
                store: store,
                openEnd: .right,
                activeDeck: .rightDeck,
                address: calibration.address
            ),
            .calibrationInProgress
        )

        var second = makeConfiguredTearSession()
        _ = second.adoptPersistedCalibrationIfExact(
            store: store,
            openEnd: .right,
            activeDeck: .rightDeck,
            address: calibration.address
        )
        XCTAssertEqual(
            second.adoptPersistedCalibrationIfExact(
                store: store,
                openEnd: .right,
                activeDeck: .rightDeck,
                address: calibration.address
            ),
            .alreadyCalibrated
        )
    }

    func testRecalibrationDiscardsTheAdoptedCalibration() throws {
        var session = makeConfiguredTearSession()
        let store = try makeStore()
        try store.save(calibration)
        _ = session.adoptPersistedCalibrationIfExact(
            store: store,
            openEnd: .right,
            activeDeck: .rightDeck,
            address: calibration.address
        )
        XCTAssertNotNil(session.confirmedCalibration)

        session.beginCalibration(address: calibration.address, openEnd: .right, activeDeck: .rightDeck)
        XCTAssertNil(session.confirmedCalibration, "An explicit recalibration must supersede an adopted calibration.")
        XCTAssertNil(session.confirmedCalibrationSource)
        XCTAssertEqual(session.phase, .calibrating)
    }

    // MARK: Take-start crossfader correlation

    func testAParkedCrossfaderIsAdoptedAsCorrelatedTakeStartState() {
        let outcome = ReferenceCrossfaderTakeStart.correlate(
            parkedTakeStartState(),
            against: correlation(),
            calibration: calibration,
            recordedSamples: []
        )
        guard case .adopted(let rawValue, let observedAt) = outcome else {
            return XCTFail("Expected the parked snapshot to be adopted, got \(outcome)")
        }
        XCTAssertEqual(rawValue, 127)
        XCTAssertEqual(observedAt, -0.4, accuracy: 1e-9)

        // The baseline exists ONLY in the derivation input; the take's own
        // recorded samples are untouched.
        let input = ReferenceCrossfaderTakeStart.derivationInput(
            recordedSamples: [],
            outcome: outcome
        )
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0].takeRelativeTime, 0)
        XCTAssertEqual(input[0].rawValue, 127)
    }

    func testAnInTakeFaderEventProducesNoDuplicateBaseline() {
        let inTakeSample = CrossfaderPositionSample(
            takeRelativeTime: 0.05,
            rawValue: 127,
            normalizedPosition: 1
        )
        let outcome = ReferenceCrossfaderTakeStart.correlate(
            parkedTakeStartState(),
            against: correlation(),
            calibration: calibration,
            recordedSamples: [inTakeSample]
        )
        XCTAssertEqual(outcome, .notNeeded)
        let input = ReferenceCrossfaderTakeStart.derivationInput(
            recordedSamples: [inTakeSample],
            outcome: outcome
        )
        XCTAssertEqual(input.count, 1, "A real in-take sample must not be joined by a contradictory baseline.")
        XCTAssertEqual(input[0].takeRelativeTime, 0.05)
    }

    func testStalePreviousTakeAndPreviousConnectionSnapshotsAreRejected() {
        func reason(
            _ state: CaptureCore.CrossfaderTakeStartState,
            _ correlation: ReferenceCrossfaderTakeStart.Correlation,
            calibration: CrossfaderCalibration? = nil
        ) -> ReferenceCrossfaderTakeStart.RejectionReason? {
            let outcome = ReferenceCrossfaderTakeStart.correlate(
                state,
                against: correlation,
                calibration: calibration ?? self.calibration,
                recordedSamples: []
            )
            if case .rejected(let rejection) = outcome { return rejection }
            return nil
        }

        XCTAssertEqual(reason(parkedTakeStartState(takeID: "take-007"), correlation()), .takeIdentityMismatch)
        XCTAssertEqual(reason(parkedTakeStartState(sessionID: "session-007"), correlation()), .takeIdentityMismatch)
        XCTAssertEqual(reason(parkedTakeStartState(takeGeneration: 7), correlation()), .takeGenerationMismatch)
        XCTAssertEqual(reason(parkedTakeStartState(takeGeneration: nil), correlation()), .takeGenerationMismatch)
        XCTAssertEqual(reason(parkedTakeStartState(midiSourceID: "midi_other"), correlation()), .midiSourceMismatch)
        XCTAssertEqual(reason(parkedTakeStartState(midiSourceID: nil), correlation()), .midiSourceMismatch)
        XCTAssertEqual(
            reason(parkedTakeStartState(midiConnectionGeneration: 2), correlation()),
            .connectionGenerationMismatch
        )
        XCTAssertEqual(
            reason(parkedTakeStartState(midiConnectionGeneration: nil), correlation()),
            .connectionGenerationMismatch
        )
    }

    func testWrongAddressWrongCalibrationAndMissingCalibrationSnapshotsAreRejected() {
        func reason(
            _ state: CaptureCore.CrossfaderTakeStartState?,
            calibration: CrossfaderCalibration?
        ) -> ReferenceCrossfaderTakeStart.RejectionReason? {
            let outcome = ReferenceCrossfaderTakeStart.correlate(
                state,
                against: correlation(),
                calibration: calibration,
                recordedSamples: []
            )
            if case .rejected(let rejection) = outcome { return rejection }
            return nil
        }

        XCTAssertEqual(reason(parkedTakeStartState(), calibration: nil), .calibrationMissing)
        XCTAssertEqual(reason(parkedTakeStartState(controller: 9), calibration: calibration), .addressMismatch)
        XCTAssertEqual(reason(parkedTakeStartState(channel: 0), calibration: calibration), .addressMismatch)
        XCTAssertEqual(
            reason(parkedTakeStartState(deviceName: "Pioneer DDJ-GRV6"), calibration: calibration),
            .addressMismatch
        )
        XCTAssertEqual(
            reason(parkedTakeStartState(calibrationID: "Rane ONE MKII#15#9"), calibration: calibration),
            .calibrationMismatch
        )
        XCTAssertEqual(reason(nil, calibration: calibration), .notRecorded)
        XCTAssertEqual(
            reason(
                CaptureCore.CrossfaderTakeStartState.unknown(
                    sessionID: "session-008",
                    takeID: "take-008",
                    takeGeneration: 8,
                    reason: "no learned crossfader MIDI mapping exists"
                ),
                calibration: calibration
            ),
            .recordedUnknown
        )
        // A record claiming an in-take instant is refused, never re-timed:
        // a pre-take packet must never masquerade as a measured one.
        XCTAssertEqual(
            reason(parkedTakeStartState(observedTakeRelativeTime: 0.25), calibration: calibration),
            .observationNotBeforeTakeStart
        )
    }

    func testAParkedTakeProvesItsOpenFaderWithoutAnArtificialWiggle() throws {
        var session = makeConfiguredTearSession()
        let store = try makeStore()
        try store.save(calibration)
        _ = session.adoptPersistedCalibrationIfExact(
            store: store,
            openEnd: .right,
            activeDeck: .rightDeck,
            address: calibration.address
        )
        let artifacts = parkedArtifacts(
            takeStartState: parkedTakeStartState(),
            takeStartCorrelation: correlation()
        )
        let recordingHooks = hooks(artifacts: artifacts)
        _ = session.beginRecording(using: recordingHooks)
        _ = session.finishRecording(using: recordingHooks)

        let take = try XCTUnwrap(session.takeInReview)
        XCTAssertTrue(
            take.evidence.crossfaderRawSamples.isEmpty,
            "The recorded sample stream must stay exactly what the take received."
        )
        XCTAssertEqual(take.evidence.crossfaderTakeStartOutcome?.adoptedRawValue, 127)
        XCTAssertNotNil(take.evidence.derivation)
        XCTAssertEqual(
            ReferenceValidator.faderOpenEvidence(for: take.evidence),
            .provenContinuouslyOpen
        )
    }

    func testAnUncorrelatedSnapshotLeavesFaderEvidenceExplicitlyUnknown() throws {
        var session = makeConfiguredTearSession()
        let store = try makeStore()
        try store.save(calibration)
        _ = session.adoptPersistedCalibrationIfExact(
            store: store,
            openEnd: .right,
            activeDeck: .rightDeck,
            address: calibration.address
        )
        let artifacts = parkedArtifacts(
            takeStartState: parkedTakeStartState(takeGeneration: 7),
            takeStartCorrelation: correlation()
        )
        let recordingHooks = hooks(artifacts: artifacts)
        _ = session.beginRecording(using: recordingHooks)
        _ = session.finishRecording(using: recordingHooks)

        let take = try XCTUnwrap(session.takeInReview)
        XCTAssertEqual(
            take.evidence.crossfaderTakeStartOutcome,
            .rejected(.takeGenerationMismatch)
        )
        guard case .unknown = ReferenceValidator.faderOpenEvidence(for: take.evidence) else {
            return XCTFail("A rejected snapshot must leave the fader state unknown, never open.")
        }
    }

    // MARK: Calibration does not block raw capture or raw export

    func testATakeRecordedWithoutACalibrationFinalizesAndStaysExportable() throws {
        var session = makeConfiguredTearSession()
        let artifacts = parkedArtifacts()
        let recordingHooks = hooks(artifacts: artifacts)

        XCTAssertNil(session.confirmedCalibration)
        guard case .success = session.beginRecording(using: recordingHooks) else {
            return XCTFail("A missing calibration must not block recording.")
        }
        guard case .success(let report) = session.finishRecording(using: recordingHooks) else {
            return XCTFail("A missing calibration must not block finalization.")
        }

        let take = try XCTUnwrap(session.takeInReview)
        XCTAssertNil(take.evidence.metadata.crossfaderCalibration)
        XCTAssertNil(take.evidence.derivation)
        XCTAssertTrue(
            report.findings.contains(.crossfaderCalibrationMissing),
            "The absence must be reported explicitly, never papered over."
        )
        guard case .unknown = ReferenceValidator.faderOpenEvidence(for: take.evidence) else {
            return XCTFail("An uncalibrated take's fader evidence must be explicitly unknown.")
        }
        // Retained and exportable all the same.
        XCTAssertNil(session.rawCaptureExportBlockReason())
        XCTAssertTrue(session.canExportRawCapture)
        // And still not approvable.
        XCTAssertNotNil(session.approvalBlockReason())
    }

    func testRawExportIsAvailableWithNoSelectedRepetitionAndFailingValidation() throws {
        var session = makeConfiguredTearSession()
        let artifacts = parkedArtifacts()
        let recordingHooks = hooks(artifacts: artifacts)
        _ = session.beginRecording(using: recordingHooks)
        _ = session.finishRecording(using: recordingHooks)

        let take = try XCTUnwrap(session.takeInReview)
        XCTAssertNil(
            take.evidence.boundaries.selectedRepetitionIndex,
            "No repetition is pre-selected; export must not depend on one."
        )
        XCTAssertFalse(take.latestValidation.passes)
        XCTAssertNotNil(session.approvalBlockReason(), "Canonical approval stays blocked.")
        XCTAssertNil(session.rawCaptureExportBlockReason(), "Raw export must be independent of approval.")
    }

    func testRawExportIsRefusedWhileRecordingAndBeforeAnyTake() {
        var session = makeConfiguredTearSession()
        XCTAssertNotNil(session.rawCaptureExportBlockReason())

        let recordingHooks = hooks(artifacts: parkedArtifacts())
        _ = session.beginRecording(using: recordingHooks)
        XCTAssertEqual(session.phase, .recording)
        XCTAssertNotNil(session.rawCaptureExportBlockReason(), "A take still recording is not stable evidence.")
    }

    func testRawExportPerformsNoLifecyclePublicationOrTrainingSideEffect() throws {
        var session = makeConfiguredTearSession()
        let artifacts = parkedArtifacts()
        let recordingHooks = hooks(artifacts: artifacts)
        _ = session.beginRecording(using: recordingHooks)
        _ = session.finishRecording(using: recordingHooks)

        let before = try XCTUnwrap(session.takeInReview)
        // Reading the export gate is the whole of the model-side export path.
        _ = session.rawCaptureExportBlockReason()
        _ = session.canExportRawCapture
        _ = session.latestRecordedTake
        let after = try XCTUnwrap(session.takeInReview)

        XCTAssertEqual(before.evidence.metadata.lifecycleState, .draft)
        XCTAssertEqual(after.evidence.metadata.lifecycleState, .draft)
        XCTAssertNil(after.evidence.metadata.reviewDecision)
        XCTAssertFalse(after.evidence.metadata.lifecycleState.isPlayableByLearner)
        XCTAssertNil(session.takeReadyForPublication(takeIndex: 0), "Nothing may become publishable by exporting.")
        XCTAssertEqual(before.evidence, after.evidence, "Export must not mutate the take's evidence.")
    }

    func testCanonicalApprovalRemainsBlockedUntilItsOwnGatesPass() throws {
        var session = makeConfiguredTearSession()
        let store = try makeStore()
        try store.save(calibration)
        _ = session.adoptPersistedCalibrationIfExact(
            store: store,
            openEnd: .right,
            activeDeck: .rightDeck,
            address: calibration.address
        )
        let artifacts = parkedArtifacts(
            takeStartState: parkedTakeStartState(),
            takeStartCorrelation: correlation()
        )
        let recordingHooks = hooks(artifacts: artifacts)
        _ = session.beginRecording(using: recordingHooks)
        _ = session.finishRecording(using: recordingHooks)

        // No repetition selected yet: still blocked, and never by accident.
        let blocked = try XCTUnwrap(session.approvalBlockReason())
        XCTAssertTrue(blocked.contains("repetition"), "Expected the repetition gate, got: \(blocked)")
        XCTAssertThrowsError(try session.approveTakeInReview(notes: "attempt"))
        let take = try XCTUnwrap(session.takeInReview)
        XCTAssertEqual(take.evidence.metadata.lifecycleState, .draft)
    }
}
