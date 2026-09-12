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
    private func watchUnreachableSnapshot(rawValue: Int = 1, audioPeak: Double = 0.5) -> ReferencePreflightSnapshot {
        ReferencePreflightSnapshot(
            controllerName: "Rane ONE MKII",
            controllerIdentifier: "Rane ONE MKII",
            observedCrossfaderAddress: calibration.address,
            latestCrossfaderRawValue: rawValue,
            calibration: calibration,
            crossfaderEventCount: 40,
            platterEventCount: 100,
            platterIsMoving: true,
            audioInputPeakLevel: audioPeak,
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
        watchEvidence: ReferenceWatchEvidence? = nil,
        mediaTimeOrigin: ReferenceMediaTimeOrigin? = nil,
        sourceState: ReferencePerTakeSourceState? = nil,
        sourceBinding: ReferenceTearEvidenceSourceBinding? = nil
    ) -> ReferenceRecordedTakeArtifacts {
        // This successful-workflow fixture must observe the complete declared
        // repetitions; 0.799s of readings cannot prove a later selected range.
        let samples: [CrossfaderPositionSample] = (0..<800).map { index in
            CrossfaderPositionSample(
                takeRelativeTime: Double(index) * 20 / 799,
                rawValue: crossfaderStaysOpen ? 1 : (index % 100 < 50 ? 1 : 104),
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
            ),
            tearEvidenceSourceBinding: sourceBinding,
            mediaTimeOrigin: mediaTimeOrigin,
            sourceState: sourceState
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

    func testCaptureIntentIsMintedOnceAndSurvivesReviewApprovalAndNextTake() throws {
        var session = makeConfiguredSession()
        try calibrateSession(&session)
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: { .success(self.goodArtifacts()) },
            currentPreflightSnapshot: { self.passingSnapshot() },
            latestCalibrationObservation: { nil }
        )

        let prepared = try session.prepareCaptureIntentForRecording()
        XCTAssertEqual(try session.prepareCaptureIntentForRecording(), prepared)
        guard case .success = session.beginRecording(using: hooks) else {
            return XCTFail("Expected recording to begin after capture intent was prepared")
        }
        _ = try session.finishRecording(using: hooks).get()
        XCTAssertEqual(session.takeInReview?.evidence.metadata.captureIntent, prepared)

        session.selectRepetitionForApproval(0)
        try session.approveTakeInReview(notes: "Intent remains immutable")
        let approvedID = try XCTUnwrap(session.latestRecordedTake?.id)
        try session.prepareNextTake(afterApprovedTakeID: approvedID)

        XCTAssertEqual(session.captureIntent, prepared)
        XCTAssertEqual(session.latestRecordedTake?.evidence.metadata.captureIntent, prepared)
        session.selectPattern(.init(id: "different", name: "Different", phraseBars: 2), bpm: 120)
        XCTAssertEqual(session.captureIntent, prepared)
        XCTAssertEqual(session.selectedPattern?.id, prepared.recipeID)
        XCTAssertEqual(session.selectedBPM, prepared.bpm)
    }

    // MARK: - Optional preferred repetition (CXL recommendation)

    func testPreferredRepetitionIsOptionalChangeableClearableAndNeverApproves() throws {
        var session = makeConfiguredSession()
        try calibrateSession(&session)
        let hooks = ReferenceAuthoringRecordingHooks(startRecording: { .success(()) },
            stopRecording: { .success(self.goodArtifacts()) },
            currentPreflightSnapshot: { self.passingSnapshot() }, latestCalibrationObservation: { nil })
        _ = try session.beginRecording(using: hooks).get()
        _ = try session.finishRecording(using: hooks).get()
        let initial = try XCTUnwrap(session.takeInReview)
        XCTAssertEqual(initial.evidence.boundaries.repetitions.map(\.index), [0, 1, 2, 3])
        XCTAssertNil(initial.evidence.boundaries.selectedRepetitionIndex, "No preference is ever defaulted.")
        XCTAssertNil(initial.preferenceMark)
        XCTAssertNotNil(session.approvalBlockReason())

        for index in 0..<4 {
            let markedAt = Date(timeIntervalSince1970: 1_788_100_000 + Double(index))
            XCTAssertTrue(session.markPreferredRepetition(index, now: markedAt))
            let take = try XCTUnwrap(session.takeInReview)
            XCTAssertEqual(take.evidence.boundaries.selectedRepetitionIndex, index)
            XCTAssertEqual(take.preferenceMark, ReferenceRepetitionPreferenceMark(markedBy: "Karl", markedAt: markedAt))
            XCTAssertEqual(take.evidence.metadata.lifecycleState, .draft)
            XCTAssertNil(take.evidence.metadata.reviewDecision)
            XCTAssertEqual(take.evidence.boundaries.repetitions, initial.evidence.boundaries.repetitions)
        }
        let beforeRefusals = try XCTUnwrap(session.takeInReview)
        for invalid in [-1, 4, 99] {
            XCTAssertFalse(session.markPreferredRepetition(invalid, now: Date(timeIntervalSince1970: 1_788_200_000)))
        }
        XCTAssertEqual(session.takeInReview, beforeRefusals, "Out-of-range choices change nothing.")

        XCTAssertTrue(session.clearPreferredRepetition())
        XCTAssertNil(session.takeInReview?.evidence.boundaries.selectedRepetitionIndex)
        XCTAssertNil(session.takeInReview?.preferenceMark)
        XCTAssertThrowsError(try session.approveTakeInReview(notes: "Clearing removes the approval choice"))
        XCTAssertEqual(session.takeInReview?.evidence.metadata.lifecycleState, .draft)

        XCTAssertTrue(session.markPreferredRepetition(2, now: Date(timeIntervalSince1970: 1_788_100_100)))
        try session.approveTakeInReview(notes: "Approval reads the one preferred selection")
        XCTAssertEqual(session.latestRecordedTake?.evidence.metadata.reviewDecision?.selectedRepetitionIndex, 2)
        XCTAssertFalse(session.markPreferredRepetition(1), "An approved take's selection is no longer editable.")
        XCTAssertFalse(session.clearPreferredRepetition())
        XCTAssertEqual(session.latestRecordedTake?.evidence.boundaries.selectedRepetitionIndex, 2)
    }

    func testMeasuredMediaOriginSurvivesFinalizationWatchRefreshApprovalAndNextTake() throws {
        let origin = ReferenceMediaTimeOrigin(clickStartHostTime: 100, recordingStartHostTime: 200,
            recordingStartOffsetSeconds: 4 * 60.0 / 95)
        var session = makeConfiguredSession()
        try calibrateSession(&session)
        let hooks = ReferenceAuthoringRecordingHooks(startRecording: { .success(()) },
            stopRecording: { .success(self.goodArtifacts(mediaTimeOrigin: origin)) },
            currentPreflightSnapshot: { self.passingSnapshot() }, latestCalibrationObservation: { nil })
        _ = try session.beginRecording(using: hooks).get()
        _ = try session.finishRecording(using: hooks).get()
        session.updateWatchEvidenceForTakeInReview(.linked(motionFileName: "watch-motion.json"))
        session.selectRepetitionForApproval(0)
        XCTAssertEqual(session.takeInReview?.evidence.metadata.mediaTimeOrigin, origin)
        try session.approveTakeInReview(notes: "Synthetic origin preservation")
        let takeID = try XCTUnwrap(session.latestRecordedTake?.id)
        try session.prepareNextTake(afterApprovedTakeID: takeID)
        XCTAssertEqual(session.latestRecordedTake?.evidence.metadata.mediaTimeOrigin, origin)
        XCTAssertEqual(session.latestRecordedTake?.evidence.metadata.lifecycleState, .approvedCanonical)
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

    /// After a commit the sweep is a spent DRAFT, and holding it made the
    /// panel untruthful: it kept asking the operator to "commit it before
    /// recording" for a calibration already saved to the store. Clearing it
    /// also closes a real hazard — `ingestCalibrationObservation` keeps
    /// feeding a held sweep, so fader motion after the commit could overwrite
    /// the value that was just committed.
    func testCommittingACalibrationClearsTheSpentSweepAndShowsTheCommittedCalibration() throws {
        var session = makeConfiguredSession()
        session.beginCalibration(address: calibration.address, openEnd: .left, activeDeck: .rightDeck)
        Self.sweepThroughAllThreePositions(&session)
        // Before the commit the panel is correctly asking for one.
        XCTAssertNotNil(session.calibrationSweep)
        XCTAssertEqual(session.calibrationSweep?.state.calibration?.isUsable, true)

        try session.commitCalibration(store: try makeStore())

        // The draft is gone, so the panel falls through to the committed
        // calibration instead of repeating "Commit it before recording".
        XCTAssertNil(session.calibrationSweep)
        let committed = try XCTUnwrap(session.confirmedCalibration)
        XCTAssertEqual(session.confirmedCalibrationSource, .sweptInThisSession)
        XCTAssertEqual(session.phase, .readyToRecord)

        // Fader motion after the commit no longer rewrites the committed value.
        session.ingestCalibrationObservation(
            CrossfaderCalibrationObservation(rawValue: 3, observationSequence: 9_999)
        )
        XCTAssertNil(session.calibrationSweep)
        XCTAssertEqual(session.confirmedCalibration, committed)
    }

    /// A committed calibration is superseded only by an EXPLICIT
    /// recalibration. Nothing is ever synthesized from a fader response curve.
    func testRecalibrationAfterACommitIsExplicitAndStartsAFreshSweep() throws {
        var session = makeConfiguredSession()
        session.beginCalibration(address: calibration.address, openEnd: .left, activeDeck: .rightDeck)
        Self.sweepThroughAllThreePositions(&session)
        try session.commitCalibration(store: try makeStore())
        XCTAssertNil(session.calibrationSweep)

        session.beginCalibration(address: calibration.address, openEnd: .left, activeDeck: .rightDeck)
        XCTAssertNotNil(session.calibrationSweep)
        XCTAssertNil(session.confirmedCalibration, "Recalibration must retire the superseded calibration.")
        XCTAssertNil(session.confirmedCalibrationSource)
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

    func testPreparingNextTakePreservesTheCompleteApprovedRecord() throws {
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
        session.selectRepetitionForApproval(2)
        session.revalidateTakeInReview()
        try session.approveTakeInReview(
            notes: "Approved take remains immutable.",
            now: Date(timeIntervalSince1970: 1_788_010_000)
        )

        let approvedID = try XCTUnwrap(session.latestRecordedTake?.id)
        var expected = session
        expected.phase = .readyToRecord

        XCTAssertTrue(session.canPrepareNextTake)
        try session.prepareNextTake(afterApprovedTakeID: approvedID)

        XCTAssertEqual(session, expected)
        XCTAssertFalse(session.canPrepareNextTake)
        XCTAssertEqual(session.takes.count, 1, "preparing must not allocate or record another take")
    }

    func testPreparingNextTakeRejectsInvalidPhaseOrApprovedIdentityWithoutMutation() throws {
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
        try session.approveTakeInReview(notes: "Approved")
        let approvedID = try XCTUnwrap(session.latestRecordedTake?.id)
        let complete = session

        let invalidPhases: [ReferenceAuthoringPhase] = [
            .configuring,
            .calibrating,
            .readyToRecord,
            .recording,
            .reviewing(takeIndex: 0),
        ]
        for phase in invalidPhases {
            var invalid = complete
            invalid.phase = phase
            let before = invalid
            XCTAssertThrowsError(try invalid.prepareNextTake(afterApprovedTakeID: approvedID))
            XCTAssertEqual(invalid, before, "Refusal from \(phase) must be mutation-free")
        }

        var emptyComplete = makeConfiguredSession()
        emptyComplete.phase = .complete
        let emptyBefore = emptyComplete
        XCTAssertThrowsError(try emptyComplete.prepareNextTake(afterApprovedTakeID: approvedID))
        XCTAssertEqual(emptyComplete, emptyBefore)

        var published = complete
        try published.markTakePublished(takeIndex: 0)
        let publishedBefore = published
        XCTAssertThrowsError(try published.prepareNextTake(afterApprovedTakeID: approvedID))
        XCTAssertEqual(published, publishedBefore)

        XCTAssertThrowsError(try session.prepareNextTake(afterApprovedTakeID: "stale-take"))
        XCTAssertEqual(session, complete)

        try session.prepareNextTake(afterApprovedTakeID: approvedID)
        let ready = session
        XCTAssertThrowsError(try session.prepareNextTake(afterApprovedTakeID: approvedID))
        XCTAssertEqual(session, ready)
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

    private func makeBeatSpec() -> ReferenceBeatSpecBinding {
        ReferenceBeatSpecBinding(
            id: "fixture-beat", version: 1, family: "fixture", bpm: 95, feel: .straight,
            countInFrameCount: 121_263, loopStartFrame: 121_263, loopFrameCount: 121_263,
            sampleRate: 48_000, productionMasterFileName: "master.wav",
            productionMasterSHA256: String(repeating: "a", count: 64),
            sparseAnalysisMixFileName: "analysis.wav",
            sparseAnalysisMixSHA256: String(repeating: "b", count: 64),
            availableStemSHA256: [:], rightsState: .procedurallyGeneratedOriginal, provenance: "Synthetic test fixture"
        )
    }

    private func makeFinalizedSession(
        watchEvidence: ReferenceWatchEvidence? = nil,
        sourceState: ReferencePerTakeSourceState? = nil,
        sourceBinding: ReferenceTearEvidenceSourceBinding? = nil
    ) throws -> ReferenceAuthoringSession {
        var session = makeConfiguredSession()
        try calibrateSession(&session)
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: { .success(self.goodArtifacts(watchEvidence: watchEvidence, sourceState: sourceState, sourceBinding: sourceBinding)) },
            currentPreflightSnapshot: { self.passingSnapshot() },
            latestCalibrationObservation: { nil }
        )
        try session.beginRecording(using: hooks).get()
        _ = try session.finishRecording(using: hooks).get()
        return session
    }

    func testRetakeReturnsToReadyToRecordWithoutRemovingThePriorTake() throws {
        var session = makeConfiguredSession()
        session.bindBeatSpec(makeBeatSpec())
        try calibrateSession(&session)
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: { .success(self.goodArtifacts()) },
            currentPreflightSnapshot: { self.passingSnapshot() },
            latestCalibrationObservation: { nil }
        )
        _ = session.beginRecording(using: hooks)
        _ = try session.finishRecording(using: hooks).get()
        let firstTake = try XCTUnwrap(session.latestRecordedTake)
        var expected = session
        expected.phase = .readyToRecord
        session.retake()
        XCTAssertEqual(session, expected, "Retake must retain the entire setup and finalized record.")
        XCTAssertEqual(session.phase, .readyToRecord)
        XCTAssertEqual(session.takes.count, 1, "Retake starts a new take; it must not delete the evidence of the old one.")

        _ = session.beginRecording(using: hooks)
        _ = try session.finishRecording(using: hooks).get()
        XCTAssertEqual(session.takes.count, 2)
        XCTAssertEqual(session.takes[0], firstTake)
        XCTAssertNotEqual(session.takes[1].id, firstTake.id)
        XCTAssertEqual(session.takes[1].evidence.metadata.captureIntent, firstTake.evidence.metadata.captureIntent)
        XCTAssertEqual(session.takes[1].evidence.metadata.captureIntent?.beatSpec, makeBeatSpec())
        XCTAssertNil(session.takes[1].evidence.metadata.reviewDecision)
    }

    func testRetakingUnboundCapturePreparesOnlyFutureIntentForExactBeatBinding() throws {
        var session = makeConfiguredSession()
        session.notes = "Repeat this setup"
        session.selectBeatEngineMode(.clickTrack)
        try calibrateSession(&session)
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: { .success(self.goodArtifacts()) },
            currentPreflightSnapshot: { self.passingSnapshot() },
            latestCalibrationObservation: { nil }
        )
        try session.beginRecording(using: hooks).get()
        _ = try session.finishRecording(using: hooks).get()
        let before = session
        let retained = try XCTUnwrap(session.latestRecordedTake)
        let originalIntent = try XCTUnwrap(session.captureIntent)
        XCTAssertNil(originalIntent.beatSpec)

        try session.retake(afterTakeID: retained.id)

        XCTAssertEqual(session.phase, .readyToRecord)
        XCTAssertNil(session.captureIntent)
        XCTAssertNil(session.selectedBeatSpec)
        XCTAssertEqual(session.takes, before.takes)
        XCTAssertEqual(session.selectedTechnique, before.selectedTechnique)
        XCTAssertEqual(session.selectedPattern, before.selectedPattern)
        XCTAssertEqual(session.selectedBPM, before.selectedBPM)
        XCTAssertEqual(session.selectedStartingDirection, before.selectedStartingDirection)
        XCTAssertEqual(session.selectedFaderVariant, before.selectedFaderVariant)
        XCTAssertEqual(session.selectedHandedness, before.selectedHandedness)
        XCTAssertEqual(session.selectedBeatEngineMode, before.selectedBeatEngineMode)
        XCTAssertEqual(session.notes, before.notes)
        XCTAssertEqual(session.confirmedCalibration, before.confirmedCalibration)
        XCTAssertEqual(session.latestPreflightSnapshot, before.latestPreflightSnapshot)
        let ready = session
        try session.retake(afterTakeID: retained.id)
        XCTAssertEqual(session, ready, "A duplicate retake must not advance the future intent identity again.")

        session.bindBeatSpec(makeBeatSpec())
        let boundIntent = try session.prepareCaptureIntentForRecording()
        XCTAssertNotEqual(boundIntent.id, originalIntent.id)
        XCTAssertEqual(boundIntent.variantID, originalIntent.variantID)
        XCTAssertEqual(boundIntent.beatSpec, makeBeatSpec())
        try session.beginRecording(using: hooks).get()
        _ = try session.finishRecording(using: hooks).get()
        XCTAssertEqual(session.takes[0], retained)
        XCTAssertEqual(session.takes[0].evidence.metadata.captureIntent, originalIntent)
        XCTAssertEqual(session.takes[1].evidence.metadata.captureIntent, boundIntent)
        XCTAssertNotEqual(session.takes[1].id, retained.id)
    }

    func testNewScratchSetupClearsFutureSelectionsAndPreservesFinalizedEvidenceAndHardware() throws {
        var session = makeConfiguredSession()
        session.declareVariant(startingDirection: .forward, faderVariant: .faderOpenThroughout, handedness: .left)
        session.notes = "Notes for the first scratch only"
        session.selectBeatEngineMode(.clickTrack)
        session.bindBeatSpec(makeBeatSpec())
        try calibrateSession(&session)
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: { .success(self.goodArtifacts()) },
            currentPreflightSnapshot: { self.passingSnapshot() },
            latestCalibrationObservation: { nil }
        )
        try session.beginRecording(using: hooks).get()
        _ = try session.finishRecording(using: hooks).get()
        _ = session.setTearReviewNotes("Retain this operator review history")
        let before = session
        let firstTake = try XCTUnwrap(session.latestRecordedTake)
        let firstIntent = try XCTUnwrap(firstTake.evidence.metadata.captureIntent)

        XCTAssertNil(session.newScratchSetupBlockReason())
        try session.prepareNewScratchSetup(afterTakeID: firstTake.id)

        XCTAssertEqual(session.phase, .configuring)
        XCTAssertEqual(session.takes, before.takes)
        XCTAssertEqual(session.latestRecordedTake, firstTake)
        XCTAssertEqual(session.authoringSessionID, before.authoringSessionID)
        XCTAssertEqual(session.operatorName, before.operatorName)
        XCTAssertEqual(session.confirmedCalibration, before.confirmedCalibration)
        XCTAssertEqual(session.confirmedCalibrationSource, before.confirmedCalibrationSource)
        XCTAssertEqual(session.calibrationSweep, before.calibrationSweep)
        XCTAssertEqual(session.lastIngestedCalibrationSequence, before.lastIngestedCalibrationSequence)
        XCTAssertEqual(session.latestPreflightSnapshot, before.latestPreflightSnapshot)
        XCTAssertEqual(session.selectedHandedness, .left)
        XCTAssertTrue(session.canExportRawCapture)
        XCTAssertNil(session.latestPreflight)
        XCTAssertNil(session.captureIntent)
        XCTAssertNil(session.selectedBeatSpec)
        XCTAssertNil(session.selectedTechnique)
        XCTAssertNil(session.selectedPattern)
        XCTAssertNil(session.selectedBPM)
        XCTAssertNil(session.selectedStartingDirection)
        XCTAssertNil(session.selectedFaderVariant)
        XCTAssertEqual(session.selectedBeatEngineMode, .boomBapTrainer)
        XCTAssertEqual(session.notes, "")
        XCTAssertFalse(session.configurationIsComplete)
        XCTAssertThrowsError(try session.prepareCaptureIntentForRecording())

        session.selectTechnique(.chirp)
        session.selectPattern(ReferencePatternIdentity(id: "eighths", name: "Eighths", phraseBars: 1), bpm: 110)
        session.declareVariant(startingDirection: .backward, faderVariant: .crossfader, handedness: .left)
        let secondIntent = try session.prepareCaptureIntentForRecording()
        XCTAssertNotEqual(secondIntent.id, firstIntent.id)
        XCTAssertEqual(secondIntent.parentTechniqueID, ReferenceTechnique.chirp.id)
        XCTAssertNil(secondIntent.beatSpec)
        XCTAssertEqual(try session.prepareCaptureIntentForRecording(), secondIntent)
        try session.beginRecording(using: hooks).get()
        _ = try session.finishRecording(using: hooks).get()
        XCTAssertEqual(session.takes.count, 2)
        XCTAssertEqual(session.takes[0], firstTake)
        XCTAssertEqual(session.takes[1].evidence.metadata.takeNumber, 2)
        XCTAssertNotEqual(session.takes[1].id, firstTake.id)
        XCTAssertEqual(session.takes[1].evidence.metadata.captureIntent, secondIntent)
        XCTAssertEqual(session.takes[1].evidence.metadata.lifecycleState, .draft)
        XCTAssertNil(session.takes[1].evidence.metadata.reviewDecision)
    }

    func testNewScratchSetupAcceptsFinalizedReviewLifecyclesWithoutChangingTheirDecisions() throws {
        let draft = try makeFinalizedSession()
        for state in [ReferenceLifecycleState.draft, .reviewed, .rejected, .approvedCanonical, .published] {
            var session = draft
            switch state {
            case .draft: break
            case .reviewed: try session.markTakeReviewed()
            case .rejected: try session.rejectTakeInReview(notes: "Rejected by operator")
            case .approvedCanonical, .published:
                session.selectRepetitionForApproval(0)
                try session.approveTakeInReview(notes: "Approved by operator")
                if state == .published { try session.markTakePublished(takeIndex: 0) }
            case .diagnostic, .deprecated:
                return XCTFail("This fixture does not create diagnostic or deprecated takes.")
            }
            let retained = try XCTUnwrap(session.latestRecordedTake)
            XCTAssertEqual(retained.evidence.metadata.lifecycleState, state)
            try session.prepareNewScratchSetup(afterTakeID: retained.id)
            XCTAssertEqual(session.takes, [retained], "Starting another scratch must preserve \(state).")
            XCTAssertEqual(session.phase, .configuring)
        }
    }

    func testNewScratchSetupAndRetakeRefuseInvalidPhaseOrStaleIdentityWithoutMutation() throws {
        let finalized = try makeFinalizedSession()
        let takeID = try XCTUnwrap(finalized.latestRecordedTake?.id)
        for phase in [ReferenceAuthoringPhase.configuring, .calibrating, .recording, .reviewing(takeIndex: -1)] {
            var session = finalized
            session.phase = phase
            let before = session
            XCTAssertNotNil(session.newScratchSetupBlockReason())
            XCTAssertNotNil(session.retakeBlockReason())
            XCTAssertThrowsError(try session.prepareNewScratchSetup(afterTakeID: takeID))
            XCTAssertThrowsError(try session.retake(afterTakeID: takeID))
            session.retake()
            XCTAssertEqual(session, before, "A refused action from \(phase) must preserve in-progress state.")
        }
        var session = finalized
        XCTAssertThrowsError(try session.prepareNewScratchSetup(afterTakeID: "stale-take"))
        XCTAssertThrowsError(try session.retake(afterTakeID: "stale-take"))
        XCTAssertEqual(session, finalized)
        try session.prepareNewScratchSetup(afterTakeID: takeID)
        let configuring = session
        XCTAssertThrowsError(try session.prepareNewScratchSetup(afterTakeID: takeID))
        XCTAssertThrowsError(try session.retake(afterTakeID: takeID))
        XCTAssertEqual(session, configuring, "A duplicate action cannot reset a new setup.")

        var empty = makeConfiguredSession()
        empty.phase = .readyToRecord
        let emptyBefore = empty
        XCTAssertThrowsError(try empty.prepareNewScratchSetup(afterTakeID: takeID))
        XCTAssertThrowsError(try empty.retake(afterTakeID: takeID))
        empty.retake()
        XCTAssertEqual(empty, emptyBefore)
    }

    func testNewScratchSetupAndRetakeWaitForPendingEvidenceButAllowTerminalMissingEvidence() throws {
        let identity = ReferenceTakeSourceIdentity(sessionID: "capture", takeID: "take-001", takeNumber: 1, takeToken: "token")
        let pendingStates: [(ReferenceWatchEvidence, ReferencePerTakeSourceState?)] = [
            (.acknowledgedTransferPending, nil),
            (.linked(motionFileName: "watch.json"), .waitingForLateTransfer(identity: identity, deadline: .distantFuture)),
        ]
        for (watch, source) in pendingStates {
            var session = try makeFinalizedSession(watchEvidence: watch, sourceState: source)
            let before = session
            let takeID = try XCTUnwrap(session.latestRecordedTake?.id)
            XCTAssertNotNil(session.newScratchSetupBlockReason())
            XCTAssertNotNil(session.retakeBlockReason())
            XCTAssertThrowsError(try session.prepareNewScratchSetup(afterTakeID: takeID))
            XCTAssertThrowsError(try session.retake(afterTakeID: takeID))
            XCTAssertThrowsError(try session.rejectTakeInReview(notes: "Wait for the pending evidence"))
            session.retake()
            XCTAssertEqual(session, before)
        }
        for watch in [ReferenceWatchEvidence.missing(syncState: "unavailable"), .transferFailed(detail: "Transfer timed out")] {
            let finalized = try makeFinalizedSession(watchEvidence: watch, sourceState: .timedOut(identity: identity))
            let retained = try XCTUnwrap(finalized.latestRecordedTake)
            var retake = finalized
            try retake.retake(afterTakeID: retained.id)
            XCTAssertEqual(retake.phase, .readyToRecord)
            XCTAssertEqual(retake.takes, finalized.takes)
            var newScratch = finalized
            try newScratch.prepareNewScratchSetup(afterTakeID: retained.id)
            XCTAssertEqual(newScratch.phase, .configuring)
            XCTAssertEqual(newScratch.takes, finalized.takes)
        }
    }

    func testRejectRemainsInReviewUntilPendingWatchEvidenceHasATerminalOutcome() throws {
        let identity = ReferenceTakeSourceIdentity(sessionID: "capture", takeID: "take-001", takeNumber: 1, takeToken: "token")
        var session = try makeFinalizedSession(
            watchEvidence: .acknowledgedTransferPending,
            sourceState: .waitingForLateTransfer(identity: identity, deadline: .distantFuture)
        )
        let pending = session
        XCTAssertThrowsError(try session.rejectTakeInReview(notes: "Rejected by operator"))
        XCTAssertEqual(session, pending)
        XCTAssertNotNil(session.takeInReview, "The existing refresh must still be able to address this take.")

        session.updateWatchEvidenceForTakeInReview(.transferFailed(detail: "Watch transfer timeout"))
        let resolved = try XCTUnwrap(session.takeInReview)
        XCTAssertEqual(resolved.evidence.metadata.sourceState, .timedOut(identity: identity))
        try session.rejectTakeInReview(notes: "Rejected by operator")

        let rejected = try XCTUnwrap(session.latestRecordedTake)
        XCTAssertEqual(session.phase, .readyToRecord)
        XCTAssertEqual(rejected.evidence.watchEvidence, resolved.evidence.watchEvidence)
        XCTAssertEqual(rejected.evidence.metadata.sourceState, resolved.evidence.metadata.sourceState)
        XCTAssertEqual(rejected.evidence.metadata.captureIntent, resolved.evidence.metadata.captureIntent)
        XCTAssertEqual(rejected.evidence.metadata.lifecycleState, .rejected)
        XCTAssertEqual(rejected.evidence.metadata.reviewDecision?.outcome, .rejected)
        XCTAssertEqual(rejected.evidence.metadata.reviewDecision?.notes, "Rejected by operator")
    }

    func testRepeatedSetupWithIdenticalSelectionsStillGetsANewIntentIdentity() throws {
        var session = try makeFinalizedSession()
        let firstTake = try XCTUnwrap(session.latestRecordedTake)
        let firstIntent = try XCTUnwrap(session.captureIntent)
        try session.prepareNewScratchSetup(afterTakeID: firstTake.id)
        session.selectTechnique(.babyScratch)
        session.selectPattern(firstTake.evidence.metadata.pattern, bpm: firstTake.evidence.metadata.bpm)
        session.declareVariant(startingDirection: .forward, faderVariant: .faderOpenThroughout, handedness: .right)
        let nextIntent = try session.prepareCaptureIntentForRecording()
        XCTAssertNotEqual(nextIntent.id, firstIntent.id)
        XCTAssertEqual(nextIntent.variantID, firstIntent.variantID)
        XCTAssertEqual(session.takes, [firstTake])
    }

    func testFailedFinalizationCannotBeAbandonedThroughRetakeOrNewScratchSetup() throws {
        var session = try makeFinalizedSession()
        let retainedID = try XCTUnwrap(session.latestRecordedTake?.id)
        try session.retake(afterTakeID: retainedID)
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: { .failure(.recordingFailed("Media is still finalizing.")) },
            currentPreflightSnapshot: { self.passingSnapshot() },
            latestCalibrationObservation: { nil }
        )
        try session.beginRecording(using: hooks).get()
        XCTAssertThrowsError(try session.finishRecording(using: hooks).get())
        let finalizing = session
        XCTAssertEqual(session.phase, .recording)
        XCTAssertThrowsError(try session.retake(afterTakeID: retainedID))
        XCTAssertThrowsError(try session.prepareNewScratchSetup(afterTakeID: retainedID))
        session.retake()
        XCTAssertEqual(session, finalizing)
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
    func testOptionalWatchAbsenceDoesNotRemoveRepetitionSelectionRequirement() throws {
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
        XCTAssertTrue(report.warnings.contains(.watchEvidenceMissing))
        XCTAssertTrue(report.failureMessages.contains { $0.contains("No repetition") })
        session.selectRepetitionForApproval(1)
        session.revalidateTakeInReview()
        XCTAssertNoThrow(try session.approveTakeInReview(notes: ""))
        XCTAssertEqual(
            session.takes.last?.evidence.metadata.lifecycleState,
            .approvedCanonical,
            "An otherwise valid selected reference does not require optional wrist motion."
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

    func testDiagnosticTakeRecordsWithAClosedFaderQuietAudioAndNoWatch() throws {
        var session = makeConfiguredSession()
        session.selectCapturePurpose(.movementCheck)
        try calibrateSession(&session)
        var startCount = 0
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { startCount += 1; return .success(()) },
            stopRecording: { .success(self.goodArtifacts(crossfaderStaysOpen: false, watchEvidence: .missing(syncState: "unavailable"))) },
            currentPreflightSnapshot: { self.watchUnreachableSnapshot(rawValue: 52, audioPeak: 0) },
            latestCalibrationObservation: { nil }
        )
        try session.beginRecording(using: hooks).get()
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(session.phase, .recording)
        _ = try session.finishRecording(using: hooks).get()
        let take = try XCTUnwrap(session.takeInReview)
        XCTAssertFalse(take.evidence.metadata.deviceInfo.watchLinked)
        XCTAssertEqual(take.evidence.watchEvidence, .missing(syncState: "unavailable"))
        session.selectRepetitionForApproval(1)
        XCTAssertFalse(session.canApproveTakeInReview(), "Diagnostic capture must not imply canonical eligibility.")
        XCTAssertNotNil(session.approvalBlockReason())
    }

    func testReferenceCanBeApprovedWithoutOptionalWatchAndKeepsAbsence() throws {
        var session = makeConfiguredSession()
        try calibrateSession(&session)
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: { .success(self.goodArtifacts(watchEvidence: .missing(syncState: "notRequested"),
                sourceState: .notRequested(policy: "Optional wrist motion not requested"))) },
            currentPreflightSnapshot: { self.passingSnapshot() }, latestCalibrationObservation: { nil })
        try session.beginRecording(using: hooks).get()
        _ = try session.finishRecording(using: hooks).get()
        session.selectRepetitionForApproval(1)
        XCTAssertNil(session.approvalBlockReason())
        try session.approveTakeInReview(notes: "Scratch reference without wrist motion")
        let take = try XCTUnwrap(session.takes.last)
        XCTAssertEqual(take.evidence.metadata.lifecycleState, .approvedCanonical)
        XCTAssertFalse(take.evidence.metadata.deviceInfo.watchLinked)
        XCTAssertEqual(take.evidence.watchEvidence, .missing(syncState: "notRequested"))
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

    func testPendingWatchTransferBlocksRawSaveWithSpecificReason() throws {
        let session = try reviewedSessionWithPendingWatch()

        XCTAssertEqual(
            session.rawCaptureExportBlockReason(),
            "Apple Watch motion is still transferring. Save Capture will become available when it is linked."
        )
        XCTAssertFalse(session.canExportRawCapture)
    }

    func testLateVerifiedWatchHashSurvivesRefreshAndApproval() throws {
        let identity = ReferenceTakeSourceIdentity(sessionID: "capture-session", takeID: "take-001", takeNumber: 1, takeToken: "token")
        let beforeBinding = ReferenceTearEvidenceSourceBinding(
            capturedSessionID: identity.sessionID, capturedTakeID: identity.takeID, capturedTakeNumber: identity.takeNumber,
            rawSidecarFileName: "take-001.json", rawSidecarData: Data("before-watch".utf8), rawSidecarSHA256: "before")
        let afterBinding = ReferenceTearEvidenceSourceBinding(
            capturedSessionID: identity.sessionID, capturedTakeID: identity.takeID, capturedTakeNumber: identity.takeNumber,
            rawSidecarFileName: "take-001.json", rawSidecarData: Data("after-watch".utf8), rawSidecarSHA256: "after")
        let verifiedState = ReferencePerTakeSourceState.linked(
            identity: identity, motionFileName: "watch.json", sha256: String(repeating: "a", count: 64))
        var session = try makeFinalizedSession(watchEvidence: .acknowledgedTransferPending,
            sourceState: .waitingForLateTransfer(identity: identity, deadline: .distantFuture), sourceBinding: beforeBinding)
        let refresh = ReferenceWatchEvidenceRefresh(evidence: .linked(motionFileName: "watch.json"),
            sourceBinding: afterBinding, sourceState: verifiedState)
        session.updateWatchEvidenceForTakeInReview(refresh.evidence,
            refreshedSourceBinding: refresh.sourceBinding, sourceState: refresh.sourceState)
        XCTAssertEqual(session.takeInReview?.evidence.metadata.sourceState, verifiedState)
        XCTAssertEqual(session.takeInReview?.tearEvidenceSourceBinding, afterBinding)
        XCTAssertTrue(session.takeInReview?.evidence.metadata.deviceInfo.watchLinked == true)

        // Legacy refreshes and same-file results without a hash cannot erase
        // the verified digest needed by approved-package export.
        session.updateWatchEvidenceForTakeInReview(.linked(motionFileName: "watch.json"))
        session.updateWatchEvidenceForTakeInReview(.linked(motionFileName: "watch.json"),
            sourceState: .linked(identity: identity, motionFileName: "watch.json", sha256: nil))
        XCTAssertEqual(session.takeInReview?.evidence.metadata.sourceState, verifiedState)
        session.selectRepetitionForApproval(0)
        try session.approveTakeInReview(notes: "Verified Watch file retained")
        XCTAssertEqual(session.latestRecordedTake?.evidence.metadata.lifecycleState, .approvedCanonical)
        XCTAssertEqual(session.latestRecordedTake?.evidence.metadata.sourceState, verifiedState)
        XCTAssertEqual(session.latestRecordedTake?.tearEvidenceSourceBinding, afterBinding)
    }

    func testMismatchedVerifiedWatchSourceCannotAttachOrReplaceItsHash() throws {
        let identity = ReferenceTakeSourceIdentity(sessionID: "capture-session", takeID: "take-001", takeNumber: 1, takeToken: "token")
        let binding = ReferenceTearEvidenceSourceBinding(
            capturedSessionID: identity.sessionID, capturedTakeID: identity.takeID, capturedTakeNumber: identity.takeNumber,
            rawSidecarFileName: "take-001.json", rawSidecarData: Data("pending".utf8), rawSidecarSHA256: "pending")
        let pending = try makeFinalizedSession(watchEvidence: .acknowledgedTransferPending,
            sourceState: .waitingForLateTransfer(identity: identity, deadline: .distantFuture), sourceBinding: binding)
        let wrongIdentities = [
            ReferenceTakeSourceIdentity(sessionID: "other", takeID: identity.takeID, takeNumber: 1, takeToken: "token"),
            ReferenceTakeSourceIdentity(sessionID: identity.sessionID, takeID: "other", takeNumber: 1, takeToken: "token"),
            ReferenceTakeSourceIdentity(sessionID: identity.sessionID, takeID: identity.takeID, takeNumber: 2, takeToken: "token"),
            ReferenceTakeSourceIdentity(sessionID: identity.sessionID, takeID: identity.takeID, takeNumber: 1, takeToken: "other"),
        ]
        for wrongIdentity in wrongIdentities {
            var session = pending
            session.updateWatchEvidenceForTakeInReview(.linked(motionFileName: "watch.json"),
                refreshedSourceBinding: binding,
                sourceState: .linked(identity: wrongIdentity, motionFileName: "watch.json", sha256: String(repeating: "a", count: 64)))
            XCTAssertEqual(session, pending, "A source identity mismatch must refuse the entire refresh.")
        }
        var session = pending
        let wrongBinding = ReferenceTearEvidenceSourceBinding(
            capturedSessionID: identity.sessionID, capturedTakeID: "other", capturedTakeNumber: identity.takeNumber,
            rawSidecarFileName: "take-001.json", rawSidecarData: Data("other".utf8), rawSidecarSHA256: "other")
        session.updateWatchEvidenceForTakeInReview(.linked(motionFileName: "watch.json"), refreshedSourceBinding: wrongBinding,
            sourceState: .linked(identity: identity, motionFileName: "watch.json", sha256: String(repeating: "a", count: 64)))
        XCTAssertEqual(session, pending, "The refreshed sidecar and verified Watch source must name the same capture.")
        session.updateWatchEvidenceForTakeInReview(.linked(motionFileName: "watch.json"),
            sourceState: .linked(identity: identity, motionFileName: "other.json", sha256: String(repeating: "a", count: 64)))
        XCTAssertEqual(session, pending)
        session.updateWatchEvidenceForTakeInReview(.linked(motionFileName: "watch.json"),
            sourceState: .linked(identity: identity, motionFileName: "watch.json", sha256: String(repeating: "a", count: 64)))
        let linked = session
        session.updateWatchEvidenceForTakeInReview(.linked(motionFileName: "watch.json"),
            sourceState: .linked(identity: identity, motionFileName: "watch.json", sha256: String(repeating: "b", count: 64)))
        XCTAssertEqual(session, linked, "A different digest cannot silently replace an already verified file.")
    }

    func testMatchingLinkedWatchRefreshRebindsTheFinalSidecarSnapshotForExport() throws {
        let initial = ReferenceTearEvidenceSourceBinding(
            capturedSessionID: "capture-session",
            capturedTakeID: "take-001",
            capturedTakeNumber: 1,
            rawSidecarFileName: "take-001.json",
            rawSidecarData: Data("before-watch".utf8),
            rawSidecarSHA256: "before"
        )
        let refreshed = ReferenceTearEvidenceSourceBinding(
            capturedSessionID: "capture-session",
            capturedTakeID: "take-001",
            capturedTakeNumber: 1,
            rawSidecarFileName: "take-001.json",
            rawSidecarData: Data("after-watch".utf8),
            rawSidecarSHA256: "after"
        )
        var session = makeConfiguredSession()
        try calibrateSession(&session)
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: {
                .success(ReferenceRecordedTakeArtifacts(
                    audio: ReferenceArtifactMeasurement(fileName: "reference.wav", exists: true, byteCount: 500_000),
                    video: nil,
                    sidecar: ReferenceArtifactMeasurement(fileName: "take-001.json", exists: true, byteCount: 2_048),
                    actualMediaFileName: nil,
                    crossfaderRawSamples: [],
                    observedCrossfaderAddress: self.calibration.address,
                    platterMovementEventCount: 60,
                    recordedAt: Date(timeIntervalSince1970: 1_788_000_500),
                    autoDetectedTechnique: nil,
                    watchEvidence: .acknowledgedTransferPending,
                    tearEvidenceSourceBinding: initial,
                    rawSidecarURL: URL(fileURLWithPath: "/tmp/take-001.json")
                ))
            },
            currentPreflightSnapshot: { self.passingSnapshot() },
            latestCalibrationObservation: { nil }
        )
        _ = session.beginRecording(using: hooks)
        _ = try session.finishRecording(using: hooks).get()

        session.updateWatchEvidenceForTakeInReview(
            .linked(motionFileName: "scratch-motion.json"),
            refreshedSourceBinding: refreshed
        )

        XCTAssertEqual(session.takeInReview?.tearEvidenceSourceBinding, refreshed)
        XCTAssertNil(session.rawCaptureExportBlockReason())
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
                takeRelativeTime: Double(index) * 20 / 799,
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
            deviceIdentifier: "midi_rane_one_mkii",
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
                deviceIdentifier: "midi_pioneer_ddj_grv6",
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
            controllerIdentifier: calibration.address.deviceIdentifier,
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
        calibrationID: String? = "midi_rane_one_mkii#15#8",
        observedTakeRelativeTime: Double? = -0.4,
        provenance: CaptureCore.CrossfaderTakeStartState.Provenance = .preTakeSnapshot,
        curveResponse: FaderCurveResponse? = nil
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
            crossfaderCurveResponse: curveResponse,
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
        crossfaderRawSamples: [CrossfaderPositionSample] = [],
        measuredAudioDuration: Double? = nil
    ) -> ReferenceRecordedTakeArtifacts {
        ReferenceRecordedTakeArtifacts(
            audio: ReferenceArtifactMeasurement(
                fileName: "reference.wav",
                exists: true,
                byteCount: 500_000,
                peakLevel: 0.8,
                frameCount: measuredAudioDuration.map { Int64(($0 * 44_100).rounded()) } ?? 100_000,
                sampleRate: measuredAudioDuration == nil ? nil : 44_100
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

    // MARK: A parked baseline never becomes a recorded sample

    /// The parked-fader path end to end: the snapshot is adopted for the
    /// derivation ONLY, and the take's recorded samples are handed through
    /// untouched. No synthetic CC8 is appended to stand in for it.
    func testAnAdoptedParkedBaselineAddsNoRecordedCrossfaderSample() throws {
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
        XCTAssertEqual(
            take.evidence.crossfaderTakeStartOutcome,
            .adopted(rawValue: 127, observedTakeRelativeTime: -0.4)
        )
        XCTAssertTrue(
            take.evidence.crossfaderRawSamples.isEmpty,
            "A pre-take snapshot must never be persisted as an in-take measurement."
        )
    }

    /// A REAL in-take message is the stronger evidence and the only one
    /// allowed to speak for the take's start. The snapshot stands down rather
    /// than minting a duplicate, potentially contradictory, claim.
    func testARealInTakeSampleSupersedesTheParkedBaselineWithoutDuplicatingIt() throws {
        var session = makeConfiguredTearSession()
        let store = try makeStore()
        try store.save(calibration)
        _ = session.adoptPersistedCalibrationIfExact(
            store: store,
            openEnd: .right,
            activeDeck: .rightDeck,
            address: calibration.address
        )
        let inTakeSample = CrossfaderPositionSample(
            takeRelativeTime: 0,
            rawValue: 127,
            normalizedPosition: 1
        )
        let artifacts = parkedArtifacts(
            takeStartState: parkedTakeStartState(),
            takeStartCorrelation: correlation(),
            crossfaderRawSamples: [inTakeSample]
        )
        let recordingHooks = hooks(artifacts: artifacts)
        guard case .success = session.beginRecording(using: recordingHooks) else {
            return XCTFail("Expected recording to start.")
        }
        guard case .success = session.finishRecording(using: recordingHooks) else {
            return XCTFail("Expected the take to finalize.")
        }
        let take = try XCTUnwrap(session.takeInReview)
        XCTAssertEqual(take.evidence.crossfaderTakeStartOutcome, .notNeeded)
        XCTAssertEqual(
            take.evidence.crossfaderRawSamples,
            [inTakeSample],
            "The take's own MIDI stream must be handed through exactly as recorded."
        )
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
        XCTAssertNil(
            reason(parkedTakeStartState(deviceName: "Renamed RANE source"), calibration: calibration),
            "A cosmetic Core MIDI display-name change must not break stable source identity."
        )
        XCTAssertEqual(
            reason(parkedTakeStartState(calibrationID: "midi_rane_one_mkii#15#9"), calibration: calibration),
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

    func testLegacyParkedBaselineAloneCannotProveTheWholeRepetition() throws {
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
        guard case .unknown = ReferenceValidator.faderOpenEvidence(for: take.evidence) else {
            return XCTFail("An adopted historical baseline does not prove how long its connection remained valid.")
        }
    }

    func testSealedParkedHoldProvesOpenCoverageWithoutInventingMIDIPackets() throws {
        var session = makeConfiguredTearSession()
        let store = try makeStore()
        try store.save(calibration)
        _ = session.adoptPersistedCalibrationIfExact(store: store, openEnd: .right,
            activeDeck: .rightDeck, address: calibration.address)
        var state = parkedTakeStartState(curveResponse: FaderCurveResponse(zeroAt: 0,
            oneAt: MIDIFaderCurveConstants.sharpScratchCutInWidth, shape: .linear))
        state.parkedHold = .init(sessionID: state.sessionID, takeID: state.takeID, takeGeneration: 8,
            midiSourceID: calibration.address.deviceIdentifier, midiConnectionGeneration: 3,
            observationSequence: 412, rawValue: 127, calibration: calibration,
            mediaStartHostTime: 100, captureEndHostTime: 120)
        let recordingHooks = hooks(artifacts: parkedArtifacts(takeStartState: state,
            takeStartCorrelation: correlation(), measuredAudioDuration: 15))
        try session.beginRecording(using: recordingHooks).get()
        _ = try session.finishRecording(using: recordingHooks).get()
        session.selectRepetitionForApproval(0)
        let take = try XCTUnwrap(session.takeInReview)
        XCTAssertTrue(take.evidence.crossfaderRawSamples.isEmpty)
        let intervals = try XCTUnwrap(take.evidence.derivation).intervals
        XCTAssertEqual(intervals.count, 1)
        XCTAssertEqual(intervals.first?.state, .open)
        XCTAssertEqual(intervals.first?.startTime, 0)
        XCTAssertEqual(intervals.first?.endTime, 15, "Held coverage is bounded by actual measured WAV frames.")
        XCTAssertTrue(take.evidence.derivation?.events.isEmpty == true)
        XCTAssertEqual(ReferenceValidator.faderOpenEvidence(for: take.evidence), .provenContinuouslyOpen)
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

    // MARK: The calibration at Record owns the entire take

    private func snapshotForCalibrationHandoff(
        calibration candidate: CrossfaderCalibration?,
        sourceID: String = "midi_rane_one_mkii"
    ) -> ReferencePreflightSnapshot {
        ReferencePreflightSnapshot(controllerName: "Rane ONE MKII", controllerIdentifier: sourceID,
            observedCrossfaderAddress: calibration.address, latestCrossfaderRawValue: 127,
            calibration: candidate, crossfaderEventCount: 40, platterEventCount: 100,
            platterIsMoving: true, audioInputPeakLevel: 0.5, audioDeviceName: "Rane ONE MKII",
            watchIsReachable: true, watchMotionIsStreaming: true,
            cameraDeviceName: "Studio Camera", cameraIsActive: true)
    }

    private func requestCalibrationBeforeFirstCC8(
        session: inout ReferenceAuthoringSession,
        openEnd: CrossfaderOpenEnd = .right,
        activeDeck: CrossfaderActiveDeck = .rightDeck
    ) throws {
        let store = try makeStore()
        try store.save(calibration)
        XCTAssertEqual(session.adoptPersistedCalibrationIfExact(store: store,
            openEnd: openEnd, activeDeck: activeDeck, address: nil), .noObservedAddress)
        XCTAssertNil(session.confirmedCalibration)
    }

    private func handoffHooks(
        snapshot: ReferencePreflightSnapshot,
        artifacts: ReferenceRecordedTakeArtifacts
    ) -> ReferenceAuthoringRecordingHooks {
        ReferenceAuthoringRecordingHooks(startRecording: { .success(()) },
            stopRecording: { .success(artifacts) }, currentPreflightSnapshot: { snapshot },
            latestCalibrationObservation: { nil })
    }

    func testCalibrationArrivingAfterApplyIsFrozenBeforeParkedFaderRecording() throws {
        var session = makeConfiguredTearSession()
        try requestCalibrationBeforeFirstCC8(session: &session)
        let artifacts = parkedArtifacts(takeStartState: parkedTakeStartState(), takeStartCorrelation: correlation())
        let recordingHooks = handoffHooks(snapshot: snapshotForCalibrationHandoff(calibration: calibration),
            artifacts: artifacts)
        try session.beginRecording(using: recordingHooks).get()
        XCTAssertEqual(session.confirmedCalibration, calibration)
        XCTAssertTrue(session.confirmedCalibrationSource?.isReused == true)
        _ = try session.finishRecording(using: recordingHooks).get()
        let take = try XCTUnwrap(session.takeInReview)
        XCTAssertEqual(take.evidence.metadata.crossfaderCalibration, calibration)
        XCTAssertEqual(take.evidence.metadata.deviceInfo.controllerIdentifier, calibration.address.deviceIdentifier)
        XCTAssertEqual(take.evidence.metadata.deviceInfo.controllerName, calibration.address.deviceName)
        XCTAssertTrue(take.evidence.crossfaderRawSamples.isEmpty, "A parked baseline must not fabricate CC8 packets.")
        XCTAssertEqual(take.evidence.crossfaderTakeStartOutcome?.adoptedRawValue, 127)
        guard case .unknown = ReferenceValidator.faderOpenEvidence(for: take.evidence) else {
            return XCTFail("A calibration and start snapshot without a terminal seal cannot prove duration.")
        }
    }

    func testLaterCalibrationMutationCannotReinterpretTheRecordingTake() throws {
        var session = makeConfiguredTearSession()
        try requestCalibrationBeforeFirstCC8(session: &session)
        let artifacts = parkedArtifacts(takeStartState: parkedTakeStartState(), takeStartCorrelation: correlation())
        let recordingHooks = handoffHooks(snapshot: snapshotForCalibrationHandoff(calibration: calibration),
            artifacts: artifacts)
        try session.beginRecording(using: recordingHooks).get()
        session.confirmedCalibration = otherDeviceCalibration
        session.latestPreflightSnapshot = snapshotForCalibrationHandoff(calibration: otherDeviceCalibration)
        _ = try session.finishRecording(using: recordingHooks).get()
        let take = try XCTUnwrap(session.takeInReview)
        XCTAssertEqual(take.evidence.metadata.crossfaderCalibration, calibration)
        guard case .unknown = ReferenceValidator.faderOpenEvidence(for: take.evidence) else {
            return XCTFail("Freezing calibration does not manufacture missing held-state coverage.")
        }
    }

    func testMissingCalibrationStillBlocksTheRecordBoundary() throws {
        var session = makeConfiguredTearSession()
        try requestCalibrationBeforeFirstCC8(session: &session)
        let recordingHooks = handoffHooks(snapshot: snapshotForCalibrationHandoff(calibration: nil),
            artifacts: parkedArtifacts())
        guard case .failure(.preflightBlocked) = session.beginRecording(using: recordingHooks) else {
            return XCTFail("Missing calibration remains a separate blocking input condition.")
        }
        session.confirmedCalibration = calibration
        guard case .failure(.noActiveRecording) = session.finishRecording(using: recordingHooks) else {
            return XCTFail("A later calibration must not manufacture an earlier recorded take.")
        }
        XCTAssertTrue(session.takes.isEmpty)
    }

    func testStartCalibrationAdoptionRejectsWrongSourceDeckOpenEndAndAddress() throws {
        let wrongAddress = CrossfaderCalibration(address: .init(deviceIdentifier: calibration.address.deviceIdentifier,
            deviceName: calibration.address.deviceName, channel: 15, controller: 9),
            fullLeftRawValue: 0, centerRawValue: 63, fullRightRawValue: 127,
            openEnd: .right, activeDeck: .rightDeck, calibratedAt: calibration.calibratedAt)
        let cases: [(CrossfaderCalibration, String, CrossfaderOpenEnd, CrossfaderActiveDeck)] = [
            (calibration, "different-controller", .right, .rightDeck),
            (calibration, calibration.address.deviceIdentifier, .left, .rightDeck),
            (calibration, calibration.address.deviceIdentifier, .right, .leftDeck),
            (wrongAddress, calibration.address.deviceIdentifier, .right, .rightDeck)
        ]
        for (candidate, sourceID, openEnd, deck) in cases {
            var session = makeConfiguredTearSession()
            try requestCalibrationBeforeFirstCC8(session: &session, openEnd: openEnd, activeDeck: deck)
            let recordingHooks = handoffHooks(
                snapshot: snapshotForCalibrationHandoff(calibration: candidate, sourceID: sourceID),
                artifacts: parkedArtifacts())
            let result = session.beginRecording(using: recordingHooks)
            XCTAssertNil(session.confirmedCalibration)
            if candidate.address.controller != calibration.address.controller {
                guard case .failure(.preflightBlocked) = result else {
                    return XCTFail("A calibration for another MIDI address must fail preflight.")
                }
                XCTAssertTrue(session.takes.isEmpty)
            } else {
                guard case .success = result else { return XCTFail("Expected diagnostic capture.") }
                _ = try session.finishRecording(using: recordingHooks).get()
                XCTAssertNil(session.takeInReview?.evidence.metadata.crossfaderCalibration)
            }
        }
    }

    func testControllerChangeDuringCaptureRejectsTheFrozenCalibration() throws {
        var session = makeConfiguredTearSession()
        try requestCalibrationBeforeFirstCC8(session: &session)
        let artifacts = parkedArtifacts(takeStartState: parkedTakeStartState(),
            takeStartCorrelation: correlation(midiSourceID: "different-controller"))
        let recordingHooks = handoffHooks(snapshot: snapshotForCalibrationHandoff(calibration: calibration),
            artifacts: artifacts)
        try session.beginRecording(using: recordingHooks).get()
        _ = try session.finishRecording(using: recordingHooks).get()
        let take = try XCTUnwrap(session.takeInReview)
        XCTAssertNil(take.evidence.metadata.crossfaderCalibration)
        XCTAssertNil(take.evidence.derivation)
        XCTAssertEqual(take.evidence.metadata.deviceInfo.controllerIdentifier, "different-controller")
        XCTAssertNotNil(session.approvalBlockReason())
    }

}
