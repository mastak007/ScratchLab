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
