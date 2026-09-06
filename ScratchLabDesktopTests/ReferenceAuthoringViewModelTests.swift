// ReferenceAuthoringViewModelTests.swift
// ScratchLabDesktopTests

import XCTest
@testable import ScratchLab

@MainActor
final class ReferenceAuthoringViewModelTests: XCTestCase {
    private final class LockedBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Value

        init(_ value: Value) { storage = value }

        func read() -> Value {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func update(_ body: (inout Value) -> Void) {
            lock.lock()
            defer { lock.unlock() }
            body(&storage)
        }
    }

    private let calibration = CrossfaderCalibration(
        address: CrossfaderMIDIAddress(
            deviceIdentifier: "synthetic-controller",
            deviceName: "Synthetic Controller",
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

    func testWorkflowStatusDistinguishesSetupProgressFromPersistentPhase() {
        XCTAssertEqual(
            ReferenceAuthoringViewModel.workflowStatusText(
                phase: .configuring,
                configurationIsComplete: false,
                isApplyingSetup: false
            ),
            "Setup required"
        )
        XCTAssertEqual(
            ReferenceAuthoringViewModel.workflowStatusText(
                phase: .configuring,
                configurationIsComplete: false,
                isApplyingSetup: true
            ),
            "Applying setup…"
        )
        XCTAssertEqual(
            ReferenceAuthoringViewModel.workflowStatusText(
                phase: .configuring,
                configurationIsComplete: true,
                isApplyingSetup: false
            ),
            "Setup applied — calibrate crossfader"
        )
        XCTAssertEqual(
            ReferenceAuthoringViewModel.workflowStatusText(
                phase: .calibrating,
                configurationIsComplete: true,
                isApplyingSetup: false
            ),
            "Calibrating"
        )
        XCTAssertEqual(
            ReferenceAuthoringViewModel.workflowStatusText(
                phase: .readyToRecord,
                configurationIsComplete: true,
                isApplyingSetup: false
            ),
            "Ready to record"
        )
        XCTAssertEqual(
            ReferenceAuthoringViewModel.workflowStatusText(
                phase: .recording,
                configurationIsComplete: true,
                isApplyingSetup: false
            ),
            "Recording"
        )
        XCTAssertEqual(
            ReferenceAuthoringViewModel.workflowStatusText(
                phase: .reviewing(takeIndex: 0),
                configurationIsComplete: true,
                isApplyingSetup: false
            ),
            "Reviewing"
        )
        XCTAssertEqual(
            ReferenceAuthoringViewModel.workflowStatusText(
                phase: .complete,
                configurationIsComplete: true,
                isApplyingSetup: false
            ),
            "Approved draft"
        )
    }

    func testApplySetupBehindInFlightPreflightRefreshClearsBusyPresentationAndPollingContinues() async {
        let firstRefreshEntered = expectation(description: "first preflight refresh entered")
        let releaseFirstRefresh = DispatchSemaphore(value: 0)
        let refreshCount = LockedBox(0)
        let address = calibration.address
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: { .success(self.goodArtifacts()) },
            currentPreflightSnapshot: {
                refreshCount.update { $0 += 1 }
                let count = refreshCount.read()
                if count == 1 {
                    firstRefreshEntered.fulfill()
                    _ = releaseFirstRefresh.wait(timeout: .now() + 2)
                }
                return ReferencePreflightSnapshot(
                    controllerName: "Synthetic Controller",
                    controllerIdentifier: "synthetic-controller",
                    observedCrossfaderAddress: address,
                    latestCrossfaderRawValue: 32,
                    calibration: nil,
                    crossfaderEventCount: count,
                    platterEventCount: 20_440,
                    platterIsMoving: true,
                    audioInputPeakLevel: 0.1794,
                    audioDeviceName: "Synthetic Audio",
                    watchIsReachable: false,
                    watchMotionIsStreaming: false,
                    cameraDeviceName: "Synthetic Camera",
                    cameraIsActive: true
                )
            },
            latestCalibrationObservation: { nil }
        )
        var initialSession = ReferenceAuthoringSession(
            authoringSessionID: "synthetic-configuring-session",
            operatorName: "Karl"
        )
        initialSession.selectTechnique(.babyScratch)
        let worker = makeWorker(session: initialSession, hooks: hooks)
        let viewModel = ReferenceAuthoringViewModel(
            worker: worker,
            initialState: await worker.snapshot()
        )
        viewModel.selectedTechnique = .babyScratch
        viewModel.patternID = "baby-scratch-hardware-smoke"
        viewModel.patternName = "Baby Scratch Hardware Smoke"
        viewModel.bpm = 95
        viewModel.startingDirectionRawValue = ReferenceStartingPlatterDirection.forward.rawValue
        viewModel.faderVariantRawValue = ReferenceFaderVariant.crossfader.rawValue
        viewModel.handednessRawValue = CaptureSessionHandedness.right.rawValue

        viewModel.startPreflightPolling(intervalNanoseconds: 5_000_000)
        await fulfillment(of: [firstRefreshEntered], timeout: 2)
        viewModel.applySetup()

        XCTAssertTrue(viewModel.isWorking)
        XCTAssertEqual(viewModel.workflowStatusText, "Applying setup…")

        releaseFirstRefresh.signal()
        let setupCompleted = await waitUntil {
            !viewModel.isWorking
                && viewModel.session.configurationIsComplete
                && viewModel.session.latestPreflight != nil
        }
        let refreshesAtSetupCompletion = refreshCount.read()
        let pollingContinued = await waitUntil {
            refreshCount.read() > refreshesAtSetupCompletion
        }
        viewModel.cancelPreflightPolling()

        XCTAssertTrue(setupCompleted)
        XCTAssertTrue(pollingContinued)
        XCTAssertFalse(viewModel.isWorking)
        XCTAssertTrue(viewModel.session.configurationIsComplete)
        XCTAssertEqual(viewModel.session.phase, .configuring)
        XCTAssertEqual(viewModel.visibleMessage, "Authoring setup applied.")
        XCTAssertEqual(viewModel.workflowStatusText, "Setup applied — calibrate crossfader")
        XCTAssertNotNil(viewModel.session.latestPreflight)
        XCTAssertGreaterThan(refreshCount.read(), 1)
    }

    func testRecordingAndFinalizationRunOffMainAndReturnSnapshotsToMainActor() async {
        let threadFlags = LockedBox<[Bool]>([])
        let artifacts = goodArtifacts()
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: {
                threadFlags.update { $0.append(Thread.isMainThread) }
                return .success(())
            },
            stopRecording: {
                threadFlags.update { $0.append(Thread.isMainThread) }
                return .success(artifacts)
            },
            currentPreflightSnapshot: { self.passingSnapshot() },
            latestCalibrationObservation: { nil }
        )
        let worker = makeWorker(session: readySession(), hooks: hooks)

        let start = await worker.startRecording()
        XCTAssertNil(start.errorMessage)
        let stop = await worker.stopRecording()
        XCTAssertNil(stop.errorMessage)
        XCTAssertEqual(threadFlags.read(), [false, false])

        let viewModel = ReferenceAuthoringViewModel(
            worker: worker,
            initialState: await worker.snapshot()
        )
        await viewModel.refreshPreflightOnce()
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertNotNil(viewModel.state.session.latestPreflight)
        XCTAssertEqual(viewModel.state.session.phase, .reviewing(takeIndex: 0))
    }

    func testPreflightAndCalibrationPollingCanBeCancelled() async throws {
        let preflightCount = LockedBox(0)
        let calibrationCount = LockedBox(0)
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: { .success(self.goodArtifacts()) },
            currentPreflightSnapshot: {
                preflightCount.update { $0 += 1 }
                return self.passingSnapshot()
            },
            latestCalibrationObservation: {
                var next = 0
                calibrationCount.update {
                    $0 += 1
                    next = $0
                }
                return CrossfaderCalibrationObservation(rawValue: 0, observationSequence: next)
            }
        )
        let worker = makeWorker(session: readySession(), hooks: hooks)
        let viewModel = ReferenceAuthoringViewModel(
            worker: worker,
            initialState: await worker.snapshot()
        )

        viewModel.startPreflightPolling(intervalNanoseconds: 5_000_000)
        viewModel.startCalibrationPolling(intervalNanoseconds: 5_000_000)
        try await Task.sleep(nanoseconds: 40_000_000)
        viewModel.stopPolling()
        try await Task.sleep(nanoseconds: 20_000_000)
        let stablePreflightCount = preflightCount.read()
        let stableCalibrationCount = calibrationCount.read()
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertGreaterThan(stablePreflightCount, 0)
        XCTAssertGreaterThan(stableCalibrationCount, 0)
        XCTAssertEqual(preflightCount.read(), stablePreflightCount)
        XCTAssertEqual(calibrationCount.read(), stableCalibrationCount)
        XCTAssertFalse(viewModel.isPreflightPolling)
        XCTAssertFalse(viewModel.isCalibrationPolling)
    }

    func testViewDisappearanceCancelsFinalizationWaitWithoutApplyingArtifacts() async {
        let stopEntered = expectation(description: "stop hook entered")
        let cancellationObserved = expectation(description: "finalization wait cancellation observed")
        let releaseStop = DispatchSemaphore(value: 0)
        let startCount = LockedBox(0)
        let stopCount = LockedBox(0)
        let cancellationCount = LockedBox(0)
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: {
                startCount.update { $0 += 1 }
                return .success(())
            },
            stopRecording: {
                stopCount.update { $0 += 1 }
                stopEntered.fulfill()
                _ = releaseStop.wait(timeout: .now() + 2)
                return .failure(.recordingFailed("Synthetic cancelled finalization wait."))
            },
            currentPreflightSnapshot: { self.passingSnapshot() },
            latestCalibrationObservation: { nil }
        )
        let driver = ReferenceAuthoringWorkerDriver(
            hooks: hooks,
            finalizationWaitCancellationHandler: {
                cancellationCount.update { $0 += 1 }
                releaseStop.signal()
                cancellationObserved.fulfill()
            }
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReferenceAuthoringViewModelTests-\(UUID().uuidString)")
        let worker = ReferenceAuthoringWorker(
            session: readySession(),
            driver: driver,
            calibrationStore: CrossfaderCalibrationStore(directoryURL: directory),
            queueLabel: "com.machelpnz.scratchlab.reference-authoring.tests.\(UUID().uuidString)"
        )
        _ = await worker.startRecording()
        let viewModel = ReferenceAuthoringViewModel(
            worker: worker,
            initialState: await worker.snapshot()
        )

        viewModel.stopRecording()
        await fulfillment(of: [stopEntered], timeout: 2)
        viewModel.cancelTransientWorkForViewDisappearance()
        await fulfillment(of: [cancellationObserved], timeout: 2)
        let workerState = await worker.snapshot()

        XCTAssertEqual(startCount.read(), 1)
        XCTAssertEqual(stopCount.read(), 1)
        XCTAssertEqual(cancellationCount.read(), 1)
        XCTAssertEqual(workerState.session.phase, .recording)
        XCTAssertTrue(workerState.session.takes.isEmpty)
        XCTAssertEqual(viewModel.state.session.phase, .recording)
        XCTAssertFalse(viewModel.isWorking)
    }

    func testBridgeErrorAndInvalidStopTransitionAreSurfacedWithoutChangingPhase() async {
        let startFailureHooks = ReferenceAuthoringRecordingHooks(
            startRecording: { .failure(.recordingFailed("Synthetic bridge failure.")) },
            stopRecording: { .success(self.goodArtifacts()) },
            currentPreflightSnapshot: { self.passingSnapshot() },
            latestCalibrationObservation: { nil }
        )
        let failingWorker = makeWorker(session: readySession(), hooks: startFailureHooks)
        let failedStart = await failingWorker.startRecording()
        XCTAssertEqual(failedStart.errorMessage, "Recording failed: Synthetic bridge failure.")
        XCTAssertEqual(failedStart.state.session.phase, .readyToRecord)

        let invalidStop = await failingWorker.stopRecording()
        XCTAssertEqual(invalidStop.errorMessage, "No recording is in progress.")
        XCTAssertEqual(invalidStop.state.session.phase, .readyToRecord)
    }

    func testAutoDetectionNeverOverwritesCXLTechniqueSelection() async {
        let artifacts = goodArtifacts(autoDetectedTechnique: .chirp)
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: { .success(artifacts) },
            currentPreflightSnapshot: { self.passingSnapshot() },
            latestCalibrationObservation: { nil }
        )
        let worker = makeWorker(session: readySession(), hooks: hooks)
        _ = await worker.startRecording()
        let stopped = await worker.stopRecording()
        let take = stopped.state.session.takeInReview

        XCTAssertEqual(take?.evidence.metadata.technique, .babyScratch)
        XCTAssertEqual(take?.autoDetectedTechnique, .chirp)
        XCTAssertEqual(take?.autoDetectionDisagreesWithSelection, true)
    }

    func testApprovalRemainsUnpublishedAndLegacyDataRemainsUnavailable() async {
        let artifacts = goodArtifacts()
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: { .success(artifacts) },
            currentPreflightSnapshot: { self.passingSnapshot() },
            latestCalibrationObservation: { nil }
        )
        let worker = makeWorker(session: readySession(), hooks: hooks)
        _ = await worker.startRecording()
        _ = await worker.stopRecording()
        _ = await worker.selectRepetitionForApproval(0)
        let approved = await worker.approveCanonical(notes: "Synthetic approval fixture only.")
        let take = approved.state.session.takes[0]

        XCTAssertNil(approved.errorMessage)
        XCTAssertEqual(take.evidence.metadata.lifecycleState, .approvedCanonical)
        XCTAssertFalse(take.evidence.metadata.lifecycleState.isPlayableByLearner)
        XCTAssertNotEqual(take.evidence.metadata.lifecycleState, .published)

        let registry = LegacyReferenceInventory.withdrawnBaselineRegistry(
            now: Date(timeIntervalSince1970: 1_788_000_900)
        )
        if case .available = registry.resolve(technique: .babyScratch) {
            XCTFail("Withdrawn legacy data must never resolve as trainable.")
        }
    }

    private func makeWorker(
        session: ReferenceAuthoringSession,
        hooks: ReferenceAuthoringRecordingHooks
    ) -> ReferenceAuthoringWorker {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReferenceAuthoringViewModelTests-\(UUID().uuidString)")
        return ReferenceAuthoringWorker(
            session: session,
            driver: ReferenceAuthoringWorkerDriver(hooks: hooks),
            calibrationStore: CrossfaderCalibrationStore(directoryURL: directory),
            queueLabel: "com.machelpnz.scratchlab.reference-authoring.tests.\(UUID().uuidString)"
        )
    }

    private func waitUntil(
        attempts: Int = 200,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    private func readySession() -> ReferenceAuthoringSession {
        var session = ReferenceAuthoringSession(authoringSessionID: "synthetic-session", operatorName: "Karl")
        session.selectTechnique(.babyScratch)
        session.selectPattern(
            ReferencePatternIdentity(id: "synthetic-pattern", name: "Synthetic Pattern", phraseBars: 1),
            bpm: 95
        )
        session.declareVariant(
            startingDirection: .forward,
            faderVariant: .faderOpenThroughout,
            handedness: .right
        )
        session.confirmedCalibration = calibration
        session.phase = .readyToRecord
        return session
    }

    private func passingSnapshot() -> ReferencePreflightSnapshot {
        ReferencePreflightSnapshot(
            controllerName: "Synthetic Controller",
            controllerIdentifier: "synthetic-controller",
            observedCrossfaderAddress: calibration.address,
            latestCrossfaderRawValue: 0,
            calibration: calibration,
            crossfaderEventCount: 40,
            platterEventCount: 80,
            platterIsMoving: true,
            audioInputPeakLevel: 0.5,
            audioDeviceName: "Synthetic Audio",
            watchIsReachable: true,
            watchMotionIsStreaming: true,
            cameraDeviceName: "Synthetic Camera",
            cameraIsActive: true,
            crossfaderSecondsSinceLastMessage: 0.1
        )
    }

    private func goodArtifacts(
        autoDetectedTechnique: ReferenceTechnique? = nil,
        watchEvidence: ReferenceWatchEvidence = .linked(motionFileName: "synthetic-watch-motion.json")
    ) -> ReferenceRecordedTakeArtifacts {
        let samples = (0..<800).map { index in
            CrossfaderPositionSample(
                takeRelativeTime: Double(index) * 0.001,
                rawValue: 0,
                normalizedPosition: 1
            )
        }
        return ReferenceRecordedTakeArtifacts(
            audio: ReferenceArtifactMeasurement(
                fileName: "synthetic-reference.wav",
                exists: true,
                byteCount: 500_000,
                peakLevel: 0.8,
                frameCount: 100_000
            ),
            video: ReferenceArtifactMeasurement(
                fileName: "synthetic-reference.mov",
                exists: true,
                byteCount: 750_000
            ),
            sidecar: ReferenceArtifactMeasurement(
                fileName: "synthetic-reference.json",
                exists: true,
                byteCount: 2_048
            ),
            actualMediaFileName: "synthetic-reference.mov",
            crossfaderRawSamples: samples,
            observedCrossfaderAddress: calibration.address,
            platterMovementEventCount: 60,
            recordedAt: Date(timeIntervalSince1970: 1_788_000_500),
            autoDetectedTechnique: autoDetectedTechnique,
            // Linked wrist motion is required evidence for a canonical
            // reference; the missing-Watch case is covered in
            // `ReferenceAuthoringSessionTests`.
            watchEvidence: watchEvidence
        )
    }

    // MARK: - Bounded, cancellable Watch-transfer wait (D1)

    private func pendingWatchHooks(
        refreshCount: LockedBox<Int>,
        landsAfter: Int
    ) -> ReferenceAuthoringRecordingHooks {
        ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: {
                .success(self.goodArtifacts(watchEvidence: .acknowledgedTransferPending))
            },
            currentPreflightSnapshot: { self.passingSnapshot() },
            latestCalibrationObservation: { nil },
            refreshWatchEvidence: {
                var seen = 0
                refreshCount.update {
                    $0 += 1
                    seen = $0
                }
                return seen >= landsAfter
                    ? .linked(motionFileName: "synthetic-watch-motion.json")
                    : .acknowledgedTransferPending
            }
        )
    }

    /// A take finalized while the transfer is pending must not be approvable,
    /// and must say why. This is the 2026-09-05 take-003 state.
    func testAPendingWatchTransferBlocksApprovalAndIsExplained() async throws {
        let refreshCount = LockedBox(0)
        let worker = makeWorker(
            session: readySession(),
            hooks: pendingWatchHooks(refreshCount: refreshCount, landsAfter: .max)
        )
        let viewModel = ReferenceAuthoringViewModel(worker: worker, initialState: await worker.snapshot())

        viewModel.startRecording()
        try await Task.sleep(nanoseconds: 60_000_000)
        viewModel.stopRecording()
        try await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertEqual(viewModel.reviewedTake?.evidence.watchEvidence, .acknowledgedTransferPending)
        XCTAssertFalse(viewModel.canApprove)
        XCTAssertNotNil(viewModel.approvalBlockReason)
        viewModel.cancelWatchTransferWait()
    }

    /// The transfer landing AFTER macOS finalization must update the take in
    /// place and make it approvable, without re-recording.
    func testAMatchingTransferLandingAfterFinalizationUnblocksApproval() async throws {
        let refreshCount = LockedBox(0)
        let worker = makeWorker(
            session: readySession(),
            hooks: pendingWatchHooks(refreshCount: refreshCount, landsAfter: 1)
        )
        let viewModel = ReferenceAuthoringViewModel(worker: worker, initialState: await worker.snapshot())

        viewModel.startRecording()
        try await Task.sleep(nanoseconds: 60_000_000)
        viewModel.stopRecording()
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertTrue(
            viewModel.reviewedTake?.evidence.watchEvidence.isLinked ?? false,
            "the matching transfer must attach once it lands"
        )
        XCTAssertTrue(
            viewModel.reviewedTake?.evidence.metadata.deviceInfo.watchLinked ?? false
        )
        XCTAssertFalse(viewModel.isWaitingForWatchTransfer, "a terminal state ends the wait")
        // Still needs a repetition selection — approval has more than one gate.
        XCTAssertFalse(viewModel.canApprove)
        viewModel.selectRepetitionForApproval(1)
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertTrue(viewModel.canApprove, viewModel.approvalBlockReason ?? "")
    }

    /// Leaving the screen abandons the wait and touches nothing else.
    func testViewDisappearanceCancelsTheWatchTransferWait() async throws {
        let refreshCount = LockedBox(0)
        let worker = makeWorker(
            session: readySession(),
            hooks: pendingWatchHooks(refreshCount: refreshCount, landsAfter: .max)
        )
        let viewModel = ReferenceAuthoringViewModel(worker: worker, initialState: await worker.snapshot())

        viewModel.startRecording()
        try await Task.sleep(nanoseconds: 60_000_000)
        viewModel.stopRecording()
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertTrue(viewModel.isWaitingForWatchTransfer)

        viewModel.cancelTransientWorkForViewDisappearance()
        XCTAssertFalse(viewModel.isWaitingForWatchTransfer)
        let afterCancel = refreshCount.read()
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(
            refreshCount.read(),
            afterCancel,
            "a cancelled wait must stop polling"
        )
        XCTAssertEqual(
            viewModel.reviewedTake?.evidence.metadata.lifecycleState,
            .draft,
            "cancellation must not approve, publish or install anything"
        )
    }

    /// No hook at all (no finalized take to ask about) must end the wait
    /// immediately rather than spinning.
    func testAWaitWithNoWatchEvidenceSourceEndsImmediately() async throws {
        let worker = makeWorker(
            session: readySession(),
            hooks: ReferenceAuthoringRecordingHooks(
                startRecording: { .success(()) },
                stopRecording: {
                    .success(self.goodArtifacts(watchEvidence: .acknowledgedTransferPending))
                },
                currentPreflightSnapshot: { self.passingSnapshot() },
                latestCalibrationObservation: { nil },
                refreshWatchEvidence: { nil }
            )
        )
        let viewModel = ReferenceAuthoringViewModel(worker: worker, initialState: await worker.snapshot())
        viewModel.startRecording()
        try await Task.sleep(nanoseconds: 60_000_000)
        viewModel.stopRecording()
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertFalse(viewModel.isWaitingForWatchTransfer)
        XCTAssertFalse(viewModel.canApprove)
    }
}

// MARK: - Tear segmentation review

/// Concurrency and presentation tests for the macOS tear-segmentation review
/// surface.
///
/// Two properties are under test here and nothing else: every correction runs
/// on the session's single owner (the serial worker) with no lost updates,
/// and no correction can approve, validate or publish a take.
@MainActor
final class ReferenceTearSegmentationViewModelTests: XCTestCase {

    private let calibration = CrossfaderCalibration(
        address: CrossfaderMIDIAddress(
            deviceIdentifier: "synthetic-controller",
            deviceName: "Synthetic Controller",
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

    // MARK: Fixtures

    private func movement(
        _ startTime: Double,
        _ endTime: Double,
        _ direction: String
    ) -> CaptureCore.DetectedNotationRecordMovementEvent {
        CaptureCore.DetectedNotationRecordMovementEvent(
            startTime: startTime,
            endTime: endTime,
            startPosition: 0,
            endPosition: 1,
            direction: direction,
            movementKind: direction == "forward" ? .normalPush : .normalPull,
            speed: 1,
            confidence: 0.9,
            source: "controller"
        )
    }

    private func twoTearMovementEvents() -> [CaptureCore.DetectedNotationRecordMovementEvent] {
        [
            movement(0.00, 0.20, "backward"),
            movement(0.35, 0.55, "backward"),
            movement(0.75, 0.95, "backward"),
            movement(1.10, 1.40, "forward")
        ]
    }

    private func artifacts() -> ReferenceRecordedTakeArtifacts {
        let samples = (0..<800).map { index in
            CrossfaderPositionSample(
                takeRelativeTime: Double(index) * 0.001,
                rawValue: 0,
                normalizedPosition: 1
            )
        }
        return ReferenceRecordedTakeArtifacts(
            audio: ReferenceArtifactMeasurement(
                fileName: "synthetic-reference.wav",
                exists: true,
                byteCount: 500_000,
                peakLevel: 0.8,
                frameCount: 100_000
            ),
            video: ReferenceArtifactMeasurement(
                fileName: "synthetic-reference.mov",
                exists: true,
                byteCount: 750_000
            ),
            sidecar: ReferenceArtifactMeasurement(
                fileName: "synthetic-reference.json",
                exists: true,
                byteCount: 2_048
            ),
            actualMediaFileName: "synthetic-reference.mov",
            crossfaderRawSamples: samples,
            observedCrossfaderAddress: calibration.address,
            platterMovementEventCount: 4,
            recordedAt: Date(timeIntervalSince1970: 1_788_000_500),
            autoDetectedTechnique: nil,
            watchEvidence: .linked(motionFileName: "synthetic-watch-motion.json"),
            platterMovementEvents: twoTearMovementEvents(),
            platterEvidenceIntervals: syntheticObservedPlatterStillness(twoTearMovementEvents())
        )
    }

    private func passingSnapshot() -> ReferencePreflightSnapshot {
        ReferencePreflightSnapshot(
            controllerName: "Synthetic Controller",
            controllerIdentifier: "synthetic-controller",
            observedCrossfaderAddress: calibration.address,
            latestCrossfaderRawValue: 0,
            calibration: calibration,
            crossfaderEventCount: 40,
            platterEventCount: 80,
            platterIsMoving: true,
            audioInputPeakLevel: 0.5,
            audioDeviceName: "Synthetic Audio",
            watchIsReachable: true,
            watchMotionIsStreaming: true,
            cameraDeviceName: "Synthetic Camera",
            cameraIsActive: true,
            crossfaderSecondsSinceLastMessage: 0.1
        )
    }

    private func readySession() -> ReferenceAuthoringSession {
        var session = ReferenceAuthoringSession(authoringSessionID: "synthetic-session", operatorName: "Karl")
        session.selectTechnique(.babyScratch)
        session.selectPattern(
            ReferencePatternIdentity(id: "synthetic-pattern", name: "Synthetic Pattern", phraseBars: 1),
            bpm: 95
        )
        session.declareVariant(
            startingDirection: .forward,
            faderVariant: .faderOpenThroughout,
            handedness: .right
        )
        session.confirmedCalibration = calibration
        session.phase = .readyToRecord
        return session
    }

    private func makeWorker() -> ReferenceAuthoringWorker {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReferenceTearReviewTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let hooks = ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: { .success(self.artifacts()) },
            currentPreflightSnapshot: { self.passingSnapshot() },
            latestCalibrationObservation: { nil }
        )
        return ReferenceAuthoringWorker(
            session: readySession(),
            driver: ReferenceAuthoringWorkerDriver(hooks: hooks),
            calibrationStore: CrossfaderCalibrationStore(directoryURL: directory),
            queueLabel: "com.machelpnz.scratchlab.reference-authoring.tear-tests.\(UUID().uuidString)"
        )
    }

    /// A worker already holding one finalized take in review.
    private func reviewingWorker() async -> ReferenceAuthoringWorker {
        let worker = makeWorker()
        _ = await worker.startRecording()
        _ = await worker.stopRecording()
        return worker
    }

    private func makeViewModel() async -> ReferenceAuthoringViewModel {
        let worker = await reviewingWorker()
        return ReferenceAuthoringViewModel(worker: worker, initialState: await worker.snapshot())
    }

    private func tearReview(of worker: ReferenceAuthoringWorker) async -> ReferenceTearSegmentationReview {
        await worker.snapshot().session.takes.last!.tearReview
    }

    // MARK: Concurrency

    /// The worker is the session's single owner. Twenty corrections issued
    /// concurrently must all land, in some order, with none lost.
    func testConcurrentTearCorrectionsAreSerialisedWithNoLostUpdates() async {
        let worker = await reviewingWorker()
        let review = await tearReview(of: worker)
        let candidateID = review.candidates[0].id
        let boundaryID = review.candidates[0].boundaries[0].id

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    _ = await worker.setTearBoundaryKind(
                        candidateID: candidateID,
                        boundaryID: boundaryID,
                        kind: index.isMultiple(of: 2) ? .faderClick : .hold,
                        notes: "correction-\(index)"
                    )
                }
            }
        }

        let corrected = await tearReview(of: worker)
        let boundary = corrected.candidate(id: candidateID)!.boundaries.first { $0.id == boundaryID }!
        XCTAssertEqual(
            boundary.corrections.count, 20,
            "a serialised owner must lose no correction under concurrent writes"
        )
        XCTAssertEqual(
            corrected.candidate(id: candidateID)!.boundaries.count, 2,
            "concurrent corrections must not duplicate or drop a boundary"
        )
        XCTAssertEqual(
            corrected.rawMovementEvents.count, 4,
            "no correction path may touch the take's raw motion evidence"
        )
    }

    /// Corrections of different kinds, interleaved, must all be recorded
    /// against the correct candidate.
    func testInterleavedCorrectionsOfDifferentKindsAllLand() async {
        let worker = await reviewingWorker()
        let review = await tearReview(of: worker)
        let tearID = review.candidates[0].id
        let plainID = review.candidates[1].id
        let boundaryID = review.candidates[0].boundaries[1].id

        async let classify = worker.classifyTearCandidate(tearID, as: .tear1, notes: "one hold")
        async let quality = worker.setTearBoundaryEvidenceQuality(
            candidateID: tearID,
            boundaryID: boundaryID,
            quality: .ambiguous,
            notes: "unclear"
        )
        async let removal = worker.setTearBoundaryRemoved(
            candidateID: tearID,
            boundaryID: boundaryID,
            removed: true,
            notes: "not a hold"
        )
        async let added = worker.addTearBoundary(
            candidateID: plainID,
            startTime: 1.20,
            endTime: 1.25,
            kind: .hold,
            evidenceQuality: .clear,
            notes: "missed pause"
        )
        _ = await (classify, quality, removal, added)

        let corrected = await tearReview(of: worker)
        let tear = corrected.candidate(id: tearID)!
        XCTAssertEqual(tear.manualClassification, .tear1)
        XCTAssertEqual(tear.countedTearHoldCount, 1)
        XCTAssertEqual(tear.boundaries.count, 2, "a struck-out boundary is retained")
        XCTAssertEqual(corrected.candidate(id: plainID)!.boundaries.count, 1)
        XCTAssertEqual(corrected.candidate(id: plainID)!.boundaries[0].origin, .operatorAdded)
    }

    // MARK: View-model state

    func testTheViewModelPublishesTheTearReviewBuiltForTheTakeOnScreen() async {
        let viewModel = await makeViewModel()
        let review = viewModel.tearReview

        XCTAssertEqual(review?.candidates.count, 2)
        XCTAssertEqual(review?.candidates.first?.proposedClassification, .tear2)
        XCTAssertEqual(review?.rawMovementEvents.count, 4)
        XCTAssertTrue(viewModel.canCorrectTearReview)
        XCTAssertNil(viewModel.tearReviewBlockReason)
    }

    func testAViewModelCorrectionIsPublishedAndApprovesNothing() async {
        let viewModel = await makeViewModel()
        let candidateID = viewModel.tearReview!.candidates[0].id
        let lifecycleBefore = viewModel.reviewedTake!.evidence.metadata.lifecycleState
        let approvalBefore = viewModel.approvalBlockReason

        viewModel.tearReviewNotes = "second pause is fader work"
        viewModel.classifyTearCandidate(candidateID, as: .tear1)
        let landed = await waitUntil {
            viewModel.tearReview?.candidate(id: candidateID)?.manualClassification == .tear1
        }

        XCTAssertTrue(landed, "the correction must reach published state")
        let candidate = viewModel.tearReview!.candidate(id: candidateID)!
        XCTAssertEqual(candidate.proposedClassification, .tear2, "the proposal is retained")
        XCTAssertEqual(candidate.latestClassificationCorrection?.correctedBy, "Karl")
        XCTAssertEqual(candidate.latestClassificationCorrection?.notes, "second pause is fader work")
        XCTAssertEqual(viewModel.reviewedTake?.evidence.metadata.lifecycleState, lifecycleBefore)
        XCTAssertNil(viewModel.reviewedTake?.evidence.metadata.reviewDecision)
        XCTAssertEqual(
            viewModel.approvalBlockReason, approvalBefore,
            "a tear correction must not move the approval gate in either direction"
        )
    }

    func testACorrectionIsRefusedAndExplainedOnceTheTakeLeavesReview() async {
        let viewModel = await makeViewModel()
        let candidateID = viewModel.tearReview!.candidates[0].id

        viewModel.retake()
        let leftReview = await waitUntil { viewModel.session.phase == .readyToRecord }
        XCTAssertTrue(leftReview)

        XCTAssertFalse(viewModel.canCorrectTearReview)
        viewModel.classifyTearCandidate(candidateID, as: .tear3)
        XCTAssertNotNil(viewModel.tearReviewBlockReason)
        XCTAssertEqual(viewModel.visibleMessage, viewModel.tearReviewBlockReason)
        XCTAssertNil(
            viewModel.reviewedTake?.tearReview.candidate(id: candidateID)?.manualClassification,
            "a refused correction changes nothing on the retained take"
        )
    }

    func testAnUnknownBoundaryIsReportedRatherThanSilentlyDropped() async {
        let viewModel = await makeViewModel()
        let candidateID = viewModel.tearReview!.candidates[0].id

        viewModel.setTearBoundaryKind(inCandidate: candidateID, boundaryID: "no-such-boundary", to: .faderClick)
        let reported = await waitUntil {
            viewModel.visibleMessage == ReferenceAuthoringWorker.tearCorrectionRefused
        }
        XCTAssertTrue(reported, "a correction that matched nothing must say so")
    }

    // MARK: Presentation

    func testTearReviewStatusTextAlwaysStatesThatTheReviewApprovesNothing() {
        let review = ReferenceTearSegmentationReviewBuilder.build(
            referenceTakeID: "take-001",
            movementEvents: twoTearMovementEvents(),
            platterEvidenceIntervals: syntheticObservedPlatterStillness(twoTearMovementEvents()),
            derivation: nil
        )
        let text = ReferenceAuthoringViewModel.tearReviewStatusText(review)
        XCTAssertTrue(text.contains("2 gestures"), text)
        XCTAssertTrue(text.contains("2 counted platter holds"), text)
        XCTAssertTrue(text.contains("approves nothing"), text)

        XCTAssertEqual(
            ReferenceAuthoringViewModel.tearReviewStatusText(nil),
            "No take is under review."
        )
        let empty = ReferenceTearSegmentationReviewBuilder.build(
            referenceTakeID: "take-002",
            movementEvents: [],
            derivation: nil
        )
        XCTAssertEqual(
            ReferenceAuthoringViewModel.tearReviewStatusText(empty),
            "No platter motion was recorded for this take, so there is nothing to segment."
        )
    }

    func testTearCandidateHeadlineShowsBothTheProposalAndTheOperatorReading() {
        var review = ReferenceTearSegmentationReviewBuilder.build(
            referenceTakeID: "take-001",
            movementEvents: twoTearMovementEvents(),
            platterEvidenceIntervals: syntheticObservedPlatterStillness(twoTearMovementEvents()),
            derivation: nil
        )
        let candidateID = review.candidates[0].id
        XCTAssertEqual(
            ReferenceAuthoringViewModel.tearCandidateHeadline(review.candidates[0]),
            "Gesture 1 · backward · proposed 2-tear (confidence 0.90)"
        )

        review.classifyCandidate(
            id: candidateID,
            as: .tear1,
            correction: ReferenceTearCorrection(
                correctedBy: "Karl",
                correctedAt: Date(timeIntervalSince1970: 1_788_001_000),
                notes: "",
                reason: "test"
            )
        )
        XCTAssertEqual(
            ReferenceAuthoringViewModel.tearCandidateHeadline(review.candidate(id: candidateID)!),
            "Gesture 1 · backward · proposed 2-tear (confidence 0.90) · operator 1-tear"
        )
    }

    func testTearBoundaryHeadlineDistinguishesHoldClickAmbiguityAndStrikeOut() {
        var review = ReferenceTearSegmentationReviewBuilder.build(
            referenceTakeID: "take-001",
            movementEvents: twoTearMovementEvents(),
            platterEvidenceIntervals: syntheticObservedPlatterStillness(twoTearMovementEvents()),
            derivation: nil
        )
        let candidateID = review.candidates[0].id
        let boundaryID = review.candidates[0].boundaries[0].id
        let correction = ReferenceTearCorrection(
            correctedBy: "Karl",
            correctedAt: Date(timeIntervalSince1970: 1_788_001_000),
            notes: "",
            reason: "test"
        )

        let proposed = ReferenceAuthoringViewModel.tearBoundaryHeadline(review.candidates[0].boundaries[0])
        XCTAssertTrue(proposed.contains("0.200–0.350 s"), proposed)
        XCTAssertTrue(proposed.contains("Platter hold"), proposed)
        XCTAssertTrue(proposed.contains("Proposed automatically"), proposed)

        review.setBoundaryKind(
            inCandidate: candidateID,
            boundaryID: boundaryID,
            to: .faderClick,
            correction: correction
        )
        let click = ReferenceAuthoringViewModel.tearBoundaryHeadline(
            review.candidate(id: candidateID)!.boundaries.first { $0.id == boundaryID }!
        )
        XCTAssertTrue(click.contains("Fader click"), click)
        XCTAssertTrue(click.contains("not counted"), click)

        review.setBoundaryRemoved(
            inCandidate: candidateID,
            boundaryID: boundaryID,
            removed: true,
            correction: correction
        )
        let removed = ReferenceAuthoringViewModel.tearBoundaryHeadline(
            review.candidate(id: candidateID)!.boundaries.first { $0.id == boundaryID }!
        )
        XCTAssertTrue(removed.contains("struck out (retained)"), removed)
    }

    func testTearCorrectionSummaryNamesTheOperatorAndAnUnambiguousInstant() {
        let correction = ReferenceTearCorrection(
            correctedBy: "Karl",
            correctedAt: Date(timeIntervalSince1970: 1_788_001_000),
            notes: "second pause is fader work",
            reason: "test"
        )
        XCTAssertEqual(
            ReferenceAuthoringViewModel.tearCorrectionSummary(correction),
            "Corrected by Karl at 2026-08-29T10:56:40Z — second pause is fader work"
        )
    }

    func testTearDisagreementTextAppearsOnlyWhenTheTwoAssertionsDisagree() {
        var review = ReferenceTearSegmentationReviewBuilder.build(
            referenceTakeID: "take-001",
            movementEvents: twoTearMovementEvents(),
            platterEvidenceIntervals: syntheticObservedPlatterStillness(twoTearMovementEvents()),
            derivation: nil
        )
        let candidateID = review.candidates[0].id
        XCTAssertNil(ReferenceAuthoringViewModel.tearDisagreementText(review.candidates[0]))

        review.classifyCandidate(
            id: candidateID,
            as: .tear1,
            correction: ReferenceTearCorrection(
                correctedBy: "Karl",
                correctedAt: Date(timeIntervalSince1970: 1_788_001_000),
                notes: "",
                reason: "test"
            )
        )
        let text = ReferenceAuthoringViewModel.tearDisagreementText(review.candidate(id: candidateID)!)
        XCTAssertEqual(text, "1-tear does not match the 2 counted platter holds (2-tear).")
    }

    private func waitUntil(
        attempts: Int = 200,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }
}

// MARK: - Calibration reuse and raw export wiring

/// The view-model wiring for the 2026-09-06 slice: adopting an already-stored
/// crossfader calibration instead of re-sweeping it, and offering the RAW
/// diagnostic export independently of canonical approval.
///
/// Synthetic throughout. Nothing is approved, published, installed or made
/// training eligible by any test here.
@MainActor
final class ReferenceAuthoringCalibrationReuseAndExportTests: XCTestCase {

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

    private func passingSnapshot() -> ReferencePreflightSnapshot {
        ReferencePreflightSnapshot(
            controllerName: "Rane ONE MKII",
            controllerIdentifier: "Rane ONE MKII",
            observedCrossfaderAddress: calibration.address,
            latestCrossfaderRawValue: 127,
            calibration: calibration,
            crossfaderEventCount: 40,
            platterEventCount: 80,
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

    private func artifacts() -> ReferenceRecordedTakeArtifacts {
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
            crossfaderRawSamples: [],
            observedCrossfaderAddress: nil,
            platterMovementEventCount: 55,
            recordedAt: Date(timeIntervalSince1970: 1_788_000_500),
            autoDetectedTechnique: .babyScratch,
            watchEvidence: .linked(motionFileName: "watch-motion.json")
        )
    }

    private func hooks() -> ReferenceAuthoringRecordingHooks {
        ReferenceAuthoringRecordingHooks(
            startRecording: { .success(()) },
            stopRecording: { .success(self.artifacts()) },
            currentPreflightSnapshot: { self.passingSnapshot() },
            latestCalibrationObservation: { nil }
        )
    }

    private func makeViewModel(
        store: CrossfaderCalibrationStore,
        finalizedURL: URL? = nil
    ) -> ReferenceAuthoringViewModel {
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
        let worker = ReferenceAuthoringWorker(
            session: session,
            driver: ReferenceAuthoringWorkerDriver(
                hooks: hooks(),
                lastFinalizedRecordingURLProvider: { finalizedURL }
            ),
            calibrationStore: store,
            queueLabel: "com.machelpnz.scratchlab.reference-authoring.tests.\(UUID().uuidString)"
        )
        let viewModel = ReferenceAuthoringViewModel(
            worker: worker,
            initialState: ReferenceAuthoringViewState(session: session, latestCalibrationRawValue: nil)
        )
        viewModel.selectedTechnique = .tear
        viewModel.crossfaderOpenEndRawValue = CrossfaderOpenEnd.right.rawValue
        viewModel.activeDeckRawValue = CrossfaderActiveDeck.rightDeck.rawValue
        return viewModel
    }

    private func makeStore() throws -> CrossfaderCalibrationStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RefAuthReuseTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return CrossfaderCalibrationStore(directoryURL: directory)
    }

    private func waitUntil(
        attempts: Int = 200,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    func testAnExactStoredCalibrationIsAdoptedWithoutStartingASweep() async throws {
        let store = try makeStore()
        try store.save(calibration)
        let viewModel = makeViewModel(store: store)

        viewModel.adoptPersistedCalibrationIfAvailable(announce: true)
        let adopted = await waitUntil { viewModel.session.confirmedCalibration != nil }
        XCTAssertTrue(adopted, "An exact stored calibration must be reused automatically.")
        XCTAssertEqual(viewModel.session.confirmedCalibration, calibration)
        XCTAssertTrue(viewModel.isReusingPersistedCalibration)
        XCTAssertNil(viewModel.session.calibrationSweep, "Reuse must never start a sweep.")
        XCTAssertEqual(viewModel.session.phase, .readyToRecord)
        XCTAssertNotNil(viewModel.calibrationSourceSummary)
    }

    func testAStoredCalibrationForADifferentOpenEndIsNeverAdopted() async throws {
        let store = try makeStore()
        try store.save(calibration)
        let viewModel = makeViewModel(store: store)
        viewModel.crossfaderOpenEndRawValue = CrossfaderOpenEnd.left.rawValue

        viewModel.adoptPersistedCalibrationIfAvailable(announce: true)
        _ = await waitUntil { viewModel.visibleMessage != nil }
        XCTAssertNil(
            viewModel.session.confirmedCalibration,
            "A calibration measured for the other open end describes a different rig."
        )
        XCTAssertFalse(viewModel.isReusingPersistedCalibration)
    }

    func testRawExportIsBlockedBeforeATakeAndAvailableAfterFinalization() async throws {
        let store = try makeStore()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-008_take-008_routine.mov")
        let viewModel = makeViewModel(store: store, finalizedURL: url)

        XCTAssertNotNil(viewModel.rawCaptureExportBlockReason)
        XCTAssertFalse(viewModel.canExportRawCapture)

        viewModel.startRecording()
        _ = await waitUntil { viewModel.session.phase == .recording }
        viewModel.stopRecording()
        let reviewed = await waitUntil { viewModel.reviewedTake != nil && !viewModel.isWorking }
        XCTAssertTrue(reviewed)

        // No calibration, no selected repetition, failing validation — and the
        // RAW capture is still exportable.
        XCTAssertNil(viewModel.session.confirmedCalibration)
        XCTAssertNil(viewModel.reviewedTake?.evidence.boundaries.selectedRepetitionIndex)
        XCTAssertNotNil(viewModel.approvalBlockReason)
        XCTAssertNil(viewModel.rawCaptureExportBlockReason)
        XCTAssertTrue(viewModel.canExportRawCapture)
        XCTAssertNotNil(viewModel.rawCaptureExportSource(config: nil))
        XCTAssertEqual(viewModel.lastFinalizedRecordingURL, url)
    }

    func testAdvisoryDetectionNeverOverwritesTheSelectedTearInTheViewModel() async throws {
        let store = try makeStore()
        let viewModel = makeViewModel(store: store)
        viewModel.startRecording()
        _ = await waitUntil { viewModel.session.phase == .recording }
        viewModel.stopRecording()
        _ = await waitUntil { viewModel.reviewedTake != nil }

        XCTAssertEqual(viewModel.session.selectedTechnique, .tear)
        XCTAssertEqual(viewModel.reviewedTake?.evidence.metadata.technique, .tear)
        XCTAssertEqual(viewModel.reviewedTake?.autoDetectedTechnique, .babyScratch)
    }

    func testTheRawExportDisclaimerStatesThatExportIsNotApproval() {
        let text = ReferenceAuthoringViewModel.rawCaptureExportDisclaimer.lowercased()
        XCTAssertTrue(text.contains("does not approve"))
        XCTAssertTrue(text.contains("publish"))
        XCTAssertTrue(text.contains("install"))
        XCTAssertTrue(text.contains("training"))
    }
}
