import SwiftUI
import AVFoundation
import UIKit
import Combine

struct CompanionCameraView: View {
    @StateObject private var captureStore = GuidedCaptureStore()
    @StateObject private var beatEngine = ScratchLabBeatEngine()
    @StateObject private var sessionExportCoordinator = SessionExportCoordinator()
    @State private var exportMixMode: ExportMixMode = .scratchOnly

    @EnvironmentObject private var audioEngine: AudioEngine
    @EnvironmentObject private var practiceBeatStore: PracticeBeatStore
    @EnvironmentObject private var broadcaster: CompanionCameraBroadcaster
    @EnvironmentObject private var progressManager: ProgressManager
    @EnvironmentObject private var sessionUploadManager: SessionUploadManager
    @EnvironmentObject private var watchMotionCaptureStore: WatchMotionCaptureStore
    @Environment(\.dismiss) private var dismiss
    #if DEBUG
    @State private var isShowingStagingInspector = false
    #endif

    private let scratches = ScratchLibrary.shared.allScratches.sorted { $0.name < $1.name }

    private var stagingInspectorContexts: [StagingInspectorContext] {
        [
            StagingInspectorContext(
                storageKind: .companion,
                title: "Companion Capture",
                actionTitle: "Re-scan",
                captureDirectoryURLProvider: { broadcaster.stagedCaptureDirectoryURL },
                statusTextProvider: { broadcaster.recordingStatus },
                runAction: { broadcaster.rescanStagedCaptures() },
                validationReportProvider: nil
            ),
            StagingInspectorContext(
                storageKind: .importedWatch,
                title: "Watch Capture",
                actionTitle: "Reconcile",
                captureDirectoryURLProvider: { watchMotionCaptureStore.captureDirectoryURL },
                statusTextProvider: { watchMotionCaptureStore.lastImportStatus },
                runAction: { watchMotionCaptureStore.reconcileStoredCapturesNow() },
                validationReportProvider: nil
            )
        ]
    }

    var body: some View {
        makeBody()
    }

    private var contentView: some View {
        GeometryReader { proxy in
            let topPadding = max(20, proxy.safeAreaInsets.top + 12)
            let bottomPadding = max(20, proxy.safeAreaInsets.bottom + 12)

            ZStack(alignment: .top) {
                LinearGradient(
                    colors: [Color(hex: "05070B"), Color(hex: "101826"), Color(hex: "05070B")],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                currentScreen
                    .padding(.horizontal, 20)
                    .padding(.bottom, bottomPadding)
                    .padding(.top, topPadding)

                if let banner = captureStore.banner {
                    CaptureBannerView(banner: banner)
                        .padding(.top, topPadding)
                        .padding(.horizontal, 20)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .toolbar(.visible, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .alert("Start a new scratch block?", isPresented: $captureStore.showDrillChangeConfirmation) {
            Button("Continue with New Scratch Type", role: .destructive) {
                captureStore.confirmDrillChange()
            }
            Button("Cancel", role: .cancel) {
                captureStore.cancelDrillChange()
            }
        } message: {
            Text("This will return to session setup and keep the current take loop ready for a new scratch type.")
        }
        #if DEBUG
        .sheet(isPresented: $isShowingStagingInspector) {
            StagingInspectorView(contexts: stagingInspectorContexts)
        }
        #endif
        .background(
            SessionSharePresenter(
                request: exportShareRequestBinding,
                onPresented: {
                    sessionExportCoordinator.markSharePresented()
                },
                onOutcome: { outcome in
                    sessionExportCoordinator.handleShareOutcome(outcome)
                }
            )
        )
    }

    private func makeBody() -> AnyView {
        var view = AnyView(contentView)
        view = AnyView(view.onAppear { prepareFlow() })
        view = AnyView(view.onDisappear { cleanupFlow() })
        view = AnyView(view.onChange(of: captureStore.sessionSetup.scratchTypeID) { _, _ in syncAnalyzerTarget() })
        view = AnyView(view.onChange(of: captureStore.sessionSetup.config.sessionID) { _, sessionID in
            broadcaster.recordingSessionID = sessionID
        })
        view = AnyView(view.onChange(of: captureStore.sessionDraft.cameraProfile) { _, profile in
            applyCameraProfile(profile)
        })
        view = AnyView(view.onChange(of: captureStore.sessionDraft.deckProfile) { _, _ in
            captureStore.refreshCalibrationDefaults()
            refreshReadiness()
        })
        view = AnyView(view.onChange(of: captureStore.isCalibrationConfirmed) { _, _ in refreshReadiness() })
        view = AnyView(view.onChange(of: captureStore.motionSkipped) { _, _ in refreshReadiness() })
        view = AnyView(view.onChange(of: broadcaster.isCameraReady) { _, _ in refreshReadiness() })
        view = AnyView(view.onChange(of: broadcaster.isStorageReady) { _, _ in refreshReadiness() })
        view = AnyView(view.onChange(of: audioEngine.inputMonitorState) { _, _ in refreshReadiness() })
        view = AnyView(view.onChange(of: watchMotionCaptureStore.isWatchReachable) { _, _ in refreshReadiness() })
        view = AnyView(view.onChange(of: watchMotionCaptureStore.isWatchAppInstalled) { _, _ in refreshReadiness() })
        view = AnyView(view.onChange(of: watchMotionCaptureStore.importedSessions.count) { _, _ in refreshReadiness() })
        view = AnyView(view.onChange(of: broadcaster.lastRecordingSummary?.id) { _, _ in
            handleFinishedRecording()
        })
        view = AnyView(view.animation(.easeInOut(duration: 0.2), value: captureStore.flowState))
        view = AnyView(view.animation(.easeInOut(duration: 0.2), value: captureStore.banner?.id))
        return view
    }

    @ViewBuilder
    private var currentScreen: some View {
        switch captureStore.flowState {
        case .idle, .sessionSetup:
            CaptureScreen(
                title: "Capture Session",
                subtitle: "Review the active session or start a new one before you capture the next take.",
                onBack: { dismiss() },
                trailingAction: stagingInspectorAction
            ) {
                SessionSetupView(
                    performerName: performerNameBinding,
                    drillID: drillIDBinding,
                    bpmText: bpmTextBinding,
                    allowedBPMList: captureStore.sessionSetup.allowedBPMList,
                    captureMode: captureModeBinding,
                    beatEngineMode: beatEngineModeBinding,
                    handedness: handednessBinding,
                    deckProfile: deckProfileBinding,
                    cameraProfile: cameraProfileBinding,
                    watchWrist: watchWristBinding,
                    practiceMode: practiceModeBinding,
                    notes: notesBinding,
                    scratches: scratches,
                    sessionListPresentation: captureStore.sessionListPresentation,
                    validationMessage: captureStore.sessionSetup.firstValidationMessage,
                    onOpenSession: { sessionID in
                        captureStore.openSession(id: sessionID)
                        refreshReadiness()
                    },
                    onStartNewSession: {
                        captureStore.startNewSession()
                        refreshReadiness()
                    },
                    onContinue: {
                        captureStore.continueFromSessionSetup()
                        refreshReadiness()
                    }
                )
            }

        case .systemCheck:
            CaptureScreen(
                title: "System Check",
                subtitle: "Confirm the capture path before you roll the next take.",
                onBack: { dismiss() },
                trailingAction: stagingInspectorAction
            ) {
                SystemCheckView(
                    results: captureStore.readinessResults,
                    hasRunCheck: captureStore.hasRunSystemCheck,
                    canBeginCapture: captureStore.canBeginCapture,
                    canSkipMotion: captureStore.canSkipMotion,
                    configurationMessage: captureStore.sessionSetup.firstValidationMessage,
                    onStartCheck: {
                        runSystemCheck()
                    },
                    onRecheck: {
                        runSystemCheck()
                    },
                    onFixIssues: {
                        captureStore.openFocusedSetupForFirstIssue()
                    },
                    onCompleteSessionSetup: {
                        captureStore.flowState = .sessionSetup
                    },
                    onBeginCapture: {
                        captureStore.flowState = .ready
                    },
                    onSkipMotion: {
                        captureStore.skipMotionForNow()
                        refreshReadiness()
                    }
                )
            }

        case .cameraSetup:
            CaptureScreen(
                title: "Align Camera",
                subtitle: "Fit the decks and mixer inside the guides.",
                onBack: { captureStore.flowState = .systemCheck },
                trailingAction: stagingInspectorAction
            ) {
                CameraSetupView(
                    session: broadcaster.captureSession,
                    videoRotationAngle: broadcaster.videoRotationAngle,
                    calibrationProfile: calibrationBinding,
                    isCameraReady: broadcaster.isCameraReady,
                    onAdjustGuides: {
                        captureStore.flowState = .calibrationSetup
                    },
                    onConfirmCamera: {
                        captureStore.saveCalibration()
                        captureStore.flowState = .systemCheck
                        runSystemCheck()
                    }
                )
            }

        case .audioSetup:
            CaptureScreen(
                title: "Check Audio",
                subtitle: "Scratch the record to confirm audio is reaching ScratchLab.",
                onBack: { captureStore.flowState = .systemCheck },
                trailingAction: stagingInspectorAction
            ) {
                AudioSetupView(
                    selectedInputName: broadcaster.selectedAudioInputName,
                    availableInputs: broadcaster.availableAudioInputs,
                    selectedAudioInputID: Binding(
                        get: { broadcaster.selectedAudioInputID },
                        set: { broadcaster.selectedAudioInputID = $0 }
                    ),
                    inputMonitorState: audioEngine.inputMonitorState,
                    inputLevel: audioEngine.inputLevel,
                    isClipping: audioEngine.inputLevel > 0.18,
                    onUseThisInput: {
                        captureStore.flowState = .systemCheck
                        runSystemCheck()
                    },
                    onTestAgain: {
                        runSystemCheck()
                    }
                )
            }

        case .motionSetup:
            CaptureScreen(
                title: "Check Motion",
                subtitle: "Make one quick test movement.",
                onBack: { captureStore.flowState = .systemCheck },
                trailingAction: stagingInspectorAction
            ) {
                MotionSetupView(
                    connectionSummary: watchMotionCaptureStore.connectionSummary,
                    isConnected: watchMotionCaptureStore.isWatchReachable,
                    lastSampleDate: watchMotionCaptureStore.importedSessions.first?.session.startedAt,
                    activityLevel: motionActivityLevel,
                    canSkip: captureStore.canSkipMotion,
                    onTestMotion: {
                        runSystemCheck()
                    },
                    onReconnect: {
                        watchMotionCaptureStore.activateIfNeeded()
                        runSystemCheck()
                    },
                    onSkip: {
                        captureStore.skipMotionForNow()
                        refreshReadiness()
                    }
                )
            }

        case .calibrationSetup:
            CaptureScreen(
                title: "Calibrate Deck Layout",
                subtitle: "Match the guides to the real deck and mixer positions.",
                onBack: { captureStore.flowState = .systemCheck },
                trailingAction: stagingInspectorAction
            ) {
                CalibrationSetupView(
                    session: broadcaster.captureSession,
                    videoRotationAngle: broadcaster.videoRotationAngle,
                    calibrationProfile: calibrationBinding,
                    hasStoredCalibration: captureStore.hasStoredCalibration,
                    onSave: {
                        captureStore.saveCalibration()
                        runSystemCheck()
                    },
                    onReset: {
                        captureStore.resetCalibration()
                    },
                    onUsePrevious: {
                        captureStore.useStoredCalibration()
                        runSystemCheck()
                    }
                )
            }

        case .ready, .preRoll, .recording, .saving:
            CaptureScreen(title: "Capture Take", subtitle: nil, onBack: { dismiss() }, trailingAction: stagingInspectorAction) {
                CaptureHubView(
                    flowState: captureStore.flowState,
                    sessionLabel: captureStore.sessionSetup.takeHeader,
                    readinessSummary: captureStore.readinessSummaryText,
                    canStartTake: captureStore.canBeginCapture,
                    takeNumber: captureStore.currentTakeNumber(fallback: broadcaster.nextTakeNumberPreview),
                    session: broadcaster.captureSession,
                    videoRotationAngle: broadcaster.videoRotationAngle,
                    calibrationProfile: captureTakeCalibrationBinding,
                    preRollCount: captureStore.preRollCountdown,
                    recordingStartedAt: captureStore.activeTake?.startedAt,
                    audioStateText: audioStateText,
                    motionStateText: motionStateText,
                    captureHealthText: captureHealthText,
                    clickTrackStatusText: captureStore.sessionSetup.clickEnabled ? "Click track on" : nil,
                    warningText: recordingWarningText,
                    onStart: {
                        startTake()
                    },
                    onStop: {
                        stopTake()
                    },
                    onRecheck: {
                        captureStore.flowState = .systemCheck
                        runSystemCheck()
                    }
                )
            }

        case .review:
            if let review = captureStore.review {
                CaptureScreen(title: "Review Take", subtitle: nil, onBack: { dismiss() }, trailingAction: stagingInspectorAction) {
                    TakeReviewView(
                        review: review,
                        onSelectQuality: { quality in
                            captureStore.setQuality(quality)
                        },
                        onToggleCombo: {
                            captureStore.toggleComboTag()
                        },
                        onKeep: {
                            captureStore.keepTake()
                        },
                        onKeepAndNext: {
                            captureStore.keepAndNext()
                        },
                        onRetry: {
                            captureStore.retryTake { summary in
                                broadcaster.discardRecording(summary)
                            }
                        },
                        onDiscard: {
                            captureStore.discardTake { summary in
                                broadcaster.discardRecording(summary)
                            }
                        }
                    )
                }
            }

        case .sessionComplete:
            let currentSessionPackage = makeSessionExportPackage()
            CaptureScreen(
                title: "Session Ready",
                subtitle: captureStore.banner?.message ?? "Take saved.",
                onBack: { dismiss() },
                trailingAction: stagingInspectorAction
            ) {
                SessionCompleteView(
                    sessionName: currentSessionPackage?.metadata.sessionName ?? "ScratchLab Session",
                    takeCount: currentSessionPackage?.takes.count ?? captureStore.keptReviews.count,
                    uploadAvailable: sessionUploadManager.isUploadAvailable,
                    uploadAvailabilityText: sessionUploadManager.availabilityMessage,
                    uploadJob: sessionUploadManager.job(for: currentSessionPackage?.metadata.sessionID),
                    onUploadSession: {
                        uploadCurrentSession(currentSessionPackage)
                    },
                    onRetryUpload: {
                        if let localSessionID = currentSessionPackage?.metadata.sessionID {
                            sessionUploadManager.retry(localSessionID: localSessionID)
                        }
                    },
                    canShare: !captureStore.keptReviews.isEmpty,
                    isExporting: sessionExportCoordinator.isPreparing,
                    exportStatusText: sessionExportCoordinator.statusMessage,
                    exportBlockingIssues: sessionExportCoordinator.validationReport?.issues ?? [],
                    exportSummaryText: sessionExportCoordinator.lastResult.map { "\($0.displayName) · \($0.formattedArchiveSize)" },
                    exportWarningText: sessionExportCoordinator.sizeWarning,
                    exportMixMode: $exportMixMode,
                    timingWarningText: captureStore.sessionSetup.timingPrintedToRecording.needsWarning
                        ? "Timing may be present in this recording."
                        : nil,
                    onShareSession: {
                        shareCurrentSession(currentSessionPackage)
                    },
                    onNextTake: {
                        captureStore.prepareNextTake()
                    },
                    onChangeDrill: {
                        captureStore.requestDrillChange()
                    },
                    onRecheckSetup: {
                        captureStore.recheckSetup()
                        runSystemCheck()
                    },
                    onEndSession: {
                        dismiss()
                    }
                )
            }
        }
    }

    private var stagingInspectorAction: CaptureScreenAction? {
        #if DEBUG
        CaptureScreenAction(
            title: "Staging",
            systemImage: "checklist",
            action: { isShowingStagingInspector = true }
        )
        #else
        nil
        #endif
    }

    private func prepareFlow() {
        practiceBeatStore.handleRecordingFlowStarted()
        captureStore.bootstrap(
            performerName: progressManager.playerProfile?.displayName ?? "Operator",
            defaultDrillID: scratches.first?.id ?? "baby_scratch"
        )
        if !captureStore.hasStoredSessionDefaults {
            practiceBeatStore.applyToRecordSetup(captureStore.sessionSetup)
            captureStore.sessionDraft.config = captureStore.sessionSetup.config
        }
        broadcaster.start()
        broadcaster.recordingSessionID = captureStore.sessionSetup.config.sessionID
        broadcaster.recordingSessionConfig = captureStore.sessionSetup.config
        _ = broadcaster.validateStorageLocation()
        applyCameraProfile(captureStore.sessionDraft.cameraProfile)

        audioEngine.start()
        syncAnalyzerTarget()
        watchMotionCaptureStore.activateIfNeeded()
        refreshReadiness()
    }

    private func cleanupFlow() {
        beatEngine.stop()
        audioEngine.stopAnalyzing()
        audioEngine.stop()
        broadcaster.stopCaptureServices()
    }

    private func applyCameraProfile(_ profile: CaptureCameraProfile) {
        broadcaster.selectedCameraPosition = profile.preferredCameraPosition
    }

    private func syncAnalyzerTarget() {
        audioEngine.stopAnalyzing()
        guard let scratch = currentScratch else { return }
        audioEngine.startAnalyzing(for: scratch)
    }

    private var currentScratch: Scratch? {
        ScratchLibrary.shared.scratch(byID: captureStore.sessionSetup.scratchTypeID)
            ?? scratches.first
    }

    private func refreshReadiness() {
        captureStore.refreshReadiness(
            with: CaptureReadinessContext(
                sessionDefaultsComplete: captureStore.sessionSetup.isComplete,
                cameraReady: broadcaster.isCameraReady,
                audioMonitorState: audioEngine.inputMonitorState,
                audioLevel: audioEngine.inputLevel,
                motionConnected: watchMotionCaptureStore.isWatchReachable,
                hasRecentMotionImport: hasRecentMotionImport,
                motionOptional: captureStore.sessionSetup.drillMode.motionOptional,
                motionSkipped: captureStore.motionSkipped,
                calibrationConfirmed: captureStore.isCalibrationConfirmed,
                storageReady: broadcaster.isStorageReady
            )
        )
    }

    private func runSystemCheck() {
        refreshReadiness()
        captureStore.runSystemCheck()
    }

    private func startTake() {
        practiceBeatStore.handleRecordingFlowStarted()
        captureStore.persistConfirmedCalibration()
        refreshReadiness()
        guard captureStore.canBeginCapture else {
            captureStore.handleBlockedCaptureAttempt()
            return
        }

        captureStore.prepareSessionForRecordingIfNeeded()
        broadcaster.recordingSessionConfig = captureStore.sessionSetup.config
        broadcaster.recordingSessionID = captureStore.sessionSetup.config.sessionID
        if captureStore.sessionSetup.captureMode == .timedClick {
            captureStore.beginTimedCapture(nextTakeNumber: broadcaster.nextTakeNumberPreview)

            do {
                var beatStartMetadata: BeatEngineStartMetadata?
                let startedBeat = try beatEngine.start(
                    mode: captureStore.sessionSetup.beatEngineMode,
                    bpm: captureStore.sessionSetup.bpmValue ?? CaptureClickTrackDefaults.defaultTimedBPM,
                    onCountInBeat: { beat in
                        Task { @MainActor in
                            captureStore.updateCountInBeat(beat)
                        }
                    },
                    onRecordingStart: {
                        let captureTiming = CaptureTimingMetadata(
                            clickStartHostTime: beatStartMetadata?.clickStartHostTime,
                            recordingStartHostTime: beatStartMetadata?.recordingStartHostTime
                                ?? ScratchLabBeatEngine.currentHostTime()
                        )
                        Task { @MainActor in
                            captureStore.startTimedRecording {
                                broadcaster.recordingSessionConfig = captureStore.sessionSetup.config
                                broadcaster.beginRecording(captureTiming: captureTiming)
                            }
                        }
                    }
                )
                beatStartMetadata = startedBeat
            } catch {
                beatEngine.stop()
                captureStore.cancelPendingCapture(message: error.localizedDescription)
            }
            return
        }

        let captureTiming = CaptureTimingMetadata(
            clickStartHostTime: nil,
            recordingStartHostTime: ScratchLabBeatEngine.currentHostTime()
        )
        captureStore.beginCalibrationCapture(nextTakeNumber: broadcaster.nextTakeNumberPreview) {
            broadcaster.recordingSessionConfig = captureStore.sessionSetup.config
            broadcaster.beginRecording(captureTiming: captureTiming)
        }
    }

    private func stopTake() {
        beatEngine.stop()
        captureStore.requestStopRecording()
        broadcaster.endRecording()
    }

    private func handleFinishedRecording() {
        beatEngine.stop()
        guard let summary = broadcaster.lastRecordingSummary else { return }
        let linkedWatchCapture = watchMotionCaptureStore.linkedCapture(
            sessionID: summary.sidecar.sessionID,
            takeID: summary.sidecar.takeID
        )
        let motionPresent = linkedWatchCapture != nil
        let calibrationValid = captureStore.isCalibrationConfirmed

        Task {
            let audioPresent = await Self.mediaContainsAudio(summary.mediaURL)
            guard broadcaster.lastRecordingSummary?.id == summary.id else { return }
            captureStore.handleRecordingFinished(
                summary: summary,
                audioPresent: audioPresent,
                motionPresent: motionPresent,
                calibrationValid: calibrationValid
            )
        }
    }

    private var hasRecentMotionImport: Bool {
        guard let date = watchMotionCaptureStore.importedSessions.first?.session.deviceRecordedAtStart else { return false }
        return Date().timeIntervalSince(date) < 900
    }

    private var motionActivityLevel: Double {
        guard let latestCapture = watchMotionCaptureStore.importedSessions.first else {
            return watchMotionCaptureStore.isWatchReachable ? 0.35 : 0.0
        }
        return min(1.0, Double(latestCapture.session.samples.count) / 1500.0)
    }

    private var audioStateText: String {
        switch audioEngine.inputMonitorState {
        case .micOff:
            return "Audio Off"
        case .micLive:
            return "Audio Live"
        case .listening:
            return "Audio Active"
        case .noSignal:
            return "Audio Missing"
        }
    }

    private var motionStateText: String {
        if captureStore.motionSkipped {
            return "Motion Skipped"
        }
        if watchMotionCaptureStore.isWatchReachable || hasRecentMotionImport {
            return "Motion Active"
        }
        return captureStore.sessionSetup.drillMode.motionOptional ? "Motion Optional" : "Motion Missing"
    }

    private var captureHealthText: String {
        if broadcaster.isRecording && audioEngine.inputLevel > 0.18 {
            return "Check Levels"
        }
        if broadcaster.isRecording && !broadcaster.isCameraReady {
            return "Camera Check"
        }
        return captureStore.canBeginCapture ? "Stable" : "Needs Check"
    }

    private var recordingWarningText: String? {
        guard captureStore.flowState == .recording else { return nil }
        if audioEngine.inputLevel > 0.18 {
            return "Audio clipping"
        }
        if !broadcaster.isCameraReady {
            return "Camera obstructed"
        }
        if !captureStore.motionSkipped && !captureStore.sessionSetup.drillMode.motionOptional && !watchMotionCaptureStore.isWatchReachable && !hasRecentMotionImport {
            return "Motion paused"
        }
        return nil
    }

    private static func mediaContainsAudio(_ url: URL) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            do {
                let tracks = try await asset.loadTracks(withMediaType: .audio)
                return !tracks.isEmpty
            } catch {
                return false
            }
        }.value
    }

    private var performerNameBinding: Binding<String> {
        Binding(
            get: { captureStore.sessionSetup.performerName },
            set: { captureStore.sessionSetup.performerName = $0 }
        )
    }

    private var drillIDBinding: Binding<String> {
        Binding(
            get: { captureStore.sessionSetup.scratchTypeID },
            set: { captureStore.sessionSetup.scratchTypeID = $0 }
        )
    }

    private var bpmTextBinding: Binding<String> {
        Binding(
            get: { captureStore.sessionSetup.bpmText },
            set: { captureStore.sessionSetup.bpmText = $0 }
        )
    }

    private var handednessBinding: Binding<CaptureHandedness> {
        Binding(
            get: { captureStore.sessionSetup.handedness },
            set: { captureStore.sessionSetup.handedness = $0 }
        )
    }

    private var deckProfileBinding: Binding<CaptureDeckProfile> {
        Binding(
            get: { captureStore.sessionDraft.deckProfile },
            set: { captureStore.sessionDraft.deckProfile = $0 }
        )
    }

    private var cameraProfileBinding: Binding<CaptureCameraProfile> {
        Binding(
            get: { captureStore.sessionDraft.cameraProfile },
            set: { captureStore.sessionDraft.cameraProfile = $0 }
        )
    }

    private var watchWristBinding: Binding<CaptureWrist> {
        Binding(
            get: { captureStore.sessionDraft.watchWrist },
            set: { captureStore.sessionDraft.watchWrist = $0 }
        )
    }

    private var practiceModeBinding: Binding<CapturePracticeMode> {
        Binding(
            get: { captureStore.sessionSetup.drillMode },
            set: { captureStore.sessionSetup.drillMode = $0 }
        )
    }

    private var captureModeBinding: Binding<CaptureSessionCaptureMode> {
        Binding(
            get: { captureStore.sessionSetup.captureMode },
            set: { captureStore.sessionSetup.captureMode = $0 }
        )
    }

    private var beatEngineModeBinding: Binding<BeatEngineMode> {
        Binding(
            get: { captureStore.sessionSetup.beatEngineMode },
            set: { captureStore.sessionSetup.beatEngineMode = $0 }
        )
    }

    private var notesBinding: Binding<String> {
        Binding(
            get: { captureStore.sessionSetup.notes },
            set: { captureStore.sessionSetup.notes = $0 }
        )
    }

    private var calibrationBinding: Binding<CaptureCalibrationProfile> {
        Binding(
            get: { captureStore.calibrationProfile },
            set: {
                captureStore.calibrationProfile = $0
                captureStore.markCalibrationEdited()
            }
        )
    }

    private var captureTakeCalibrationBinding: Binding<CaptureCalibrationProfile> {
        Binding(
            get: { captureStore.calibrationProfile },
            set: { captureStore.updateLiveCalibration($0) }
        )
    }

    private var exportShareRequestBinding: Binding<SessionShareRequest?> {
        Binding(
            get: { sessionExportCoordinator.shareRequest },
            set: { sessionExportCoordinator.shareRequest = $0 }
        )
    }

    private func shareCurrentSession(_ exportPackage: SessionExportPackage?) {
        guard let exportPackage else {
            sessionExportCoordinator.showFailure(.missingRequiredFiles)
            return
        }
        sessionExportCoordinator.prepareShare(
            for: .package(exportPackage),
            options: SessionExportOptions(mixMode: exportMixMode)
        )
    }

    private func uploadCurrentSession(_ exportPackage: SessionExportPackage?) {
        guard let exportPackage else { return }
        sessionUploadManager.startUpload(
            for: .package(exportPackage),
            djID: progressManager.playerProfile?.id
        )
    }

    private func makeSessionExportPackage() -> SessionExportPackage? {
        guard !captureStore.keptReviews.isEmpty else { return nil }

        let sessionName = captureStore.sessionSetup.sessionName(defaultAppName: "ScratchLab")
        let calibrationData = try? JSONEncoder().encode(captureStore.calibrationProfile)
        let totalDurationSeconds = captureStore.keptReviews.reduce(0) { $0 + $1.duration }
        let sidecars = captureStore.keptReviews.map(\.summary.sidecar)
        guard let seedSidecar = captureStore.keptReviews.first?.summary.sidecar else { return nil }
        let earliestTakeDate = sidecars.map(\.startedAt).min() ?? captureStore.sessionStartedAt
        let latestTakeDate = sidecars.map { $0.endedAt ?? $0.startedAt }.max() ?? captureStore.sessionStartedAt
        let deviceInfo = captureStore.keptReviews.first.map { review in
            SessionExportDeviceInfo(
                sourceDeviceName: review.summary.sidecar.sourceDeviceName,
                appSurface: review.summary.sidecar.appSurface,
                cameraPosition: review.summary.sidecar.cameraPosition,
                audioInputName: review.summary.sidecar.audioInputName,
                videoDeviceUniqueID: review.summary.sidecar.videoDeviceUniqueID,
                videoDeviceName: review.summary.sidecar.videoDeviceName,
                audioDeviceUniqueID: review.summary.sidecar.audioDeviceUniqueID,
                audioDeviceName: review.summary.sidecar.audioDeviceName
            )
        }

        let config = SessionExportMetadataResolver.mergedConfig(
            preferredConfig: captureStore.sessionSetup.config,
            seedSidecar: seedSidecar,
            sidecars: sidecars,
            fallbackSessionID: seedSidecar.sessionID,
            createdAt: earliestTakeDate,
            updatedAt: latestTakeDate,
            takeCount: captureStore.keptReviews.count,
            totalDurationSeconds: totalDurationSeconds
        )

        let metadata = SessionExportMetadata(
            config: config,
            workflow: "guided_capture",
            platform: currentPlatformName,
            sessionName: sessionName,
            totalDurationSeconds: totalDurationSeconds,
            deckProfile: captureStore.sessionDraft.deckProfile.rawValue,
            cameraProfile: captureStore.sessionDraft.cameraProfile.rawValue,
            watchWrist: captureStore.sessionDraft.watchWrist.rawValue,
            deviceInfo: deviceInfo
        )

        let takes = captureStore.keptReviews.map { review in
            let linkedWatchCapture = watchMotionCaptureStore.linkedCapture(
                sessionID: review.summary.sidecar.sessionID,
                takeID: review.summary.sidecar.takeID
            )
            let exportMotionPresent = linkedWatchCapture != nil
            return SessionExportTake(
                takeID: review.summary.sidecar.takeID,
                takeNumber: review.summary.sidecar.appLocalTakeNumber,
                bpm: review.summary.sidecar.sessionConfig?.bpm ?? config.bpm ?? 0,
                mediaURL: review.summary.mediaURL,
                audioArtifactURL: nil,
                sidecarURL: review.summary.sidecarURL,
                watchCaptureSession: linkedWatchCapture?.session,
                drillName: review.drillName,
                duration: review.duration,
                quality: review.quality?.title,
                comboTagged: review.isComboTagged,
                audioPresent: review.audioPresent,
                motionPresent: exportMotionPresent,
                syncStatus: review.syncStatus,
                recordingStatus: review.summary.sidecar.recordingStatus,
                verbalSlateUsed: nil,
                syncClapUsed: nil,
                note: review.operatorMessage,
                captureTiming: review.summary.sidecar.captureTiming
            )
        }

        return SessionExportPackage(
            metadata: metadata,
            takes: takes,
            calibrationData: calibrationData
        )
    }

    private var currentPlatformName: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
    }

}

private enum CaptureFlowState: Equatable {
    case idle
    case sessionSetup
    case systemCheck
    case cameraSetup
    case audioSetup
    case motionSetup
    case calibrationSetup
    case ready
    case preRoll
    case recording
    case review
    case saving
    case sessionComplete
}

private enum CaptureCheckKind: String, CaseIterable, Identifiable {
    case camera
    case audio
    case motion
    case calibration
    case storage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .camera: return "Camera"
        case .audio: return "Audio"
        case .motion: return "Motion"
        case .calibration: return "Calibration"
        case .storage: return "Storage"
        }
    }
}

private enum CaptureReadinessStatus: String {
    case ready
    case warning
    case blocked

    var label: String {
        switch self {
        case .ready: return "Ready"
        case .warning: return "Warning"
        case .blocked: return "Not Ready"
        }
    }

    var color: Color {
        switch self {
        case .ready: return Color(hex: "22C55E")
        case .warning: return Color(hex: "F59E0B")
        case .blocked: return Color(hex: "EF4444")
        }
    }
}

private struct CaptureCheckResult: Identifiable, Equatable {
    let kind: CaptureCheckKind
    let status: CaptureReadinessStatus
    let detail: String

    var id: CaptureCheckKind { kind }

    static func placeholder(for kind: CaptureCheckKind) -> CaptureCheckResult {
        CaptureCheckResult(kind: kind, status: .warning, detail: "Not checked")
    }
}

private typealias CaptureHandedness = CaptureSessionHandedness

private enum CaptureDeckProfile: String, CaseIterable, Codable, Identifiable {
    case battle
    case club
    case compact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .battle: return "Battle"
        case .club: return "Club"
        case .compact: return "Compact"
        }
    }
}

private enum CaptureCameraProfile: String, CaseIterable, Codable, Identifiable {
    case rear
    case front

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rear: return "Back Camera"
        case .front: return "Front Camera"
        }
    }

    var preferredCameraPosition: CompanionCameraBroadcaster.CameraPosition {
        switch self {
        case .front: return .front
        case .rear: return .rear
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        switch rawValue {
        case "front", "selfReference":
            self = .front
        case "rear", "deckWide", "deckClose":
            self = .rear
        default:
            self = .rear
        }
    }
}

private enum CaptureWrist: String, CaseIterable, Codable, Identifiable {
    case left
    case right
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        case .none: return "None"
        }
    }
}

private typealias CapturePracticeMode = CaptureSessionDrillMode

private enum CaptureQualityTag: String, CaseIterable, Identifiable {
    case clean
    case usable
    case messy
    case failed

    var id: String { rawValue }

    var title: String {
        rawValue.capitalized
    }
}

private struct CaptureSessionDraft: Codable, Equatable {
    var config = CaptureSessionConfig.guidedCaptureDefaults()
    var deckProfile: CaptureDeckProfile = .battle
    var cameraProfile: CaptureCameraProfile = .rear
    var watchWrist: CaptureWrist = .right
}

private enum CaptureCalibrationRole: String, CaseIterable, Codable, Identifiable {
    case leftDeck
    case mixer
    case rightDeck

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leftDeck: return "Left Deck"
        case .mixer: return "Mixer"
        case .rightDeck: return "Right Deck"
        }
    }

    var color: Color {
        switch self {
        case .leftDeck: return Color(hex: "F59E0B")
        case .mixer: return Color(hex: "06B6D4")
        case .rightDeck: return Color(hex: "22C55E")
        }
    }
}

private struct CaptureCalibrationZone: Codable, Equatable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat

    func rect(in size: CGSize) -> CGRect {
        CGRect(
            x: x * size.width,
            y: y * size.height,
            width: width * size.width,
            height: height * size.height
        )
    }

    func clamped() -> CaptureCalibrationZone {
        let clampedWidth = min(max(width, 0.12), 0.5)
        let clampedHeight = min(max(height, 0.16), 0.72)
        let clampedX = min(max(x, 0.02), 0.98 - clampedWidth)
        let clampedY = min(max(y, 0.02), 0.98 - clampedHeight)
        return CaptureCalibrationZone(x: clampedX, y: clampedY, width: clampedWidth, height: clampedHeight)
    }
}

private struct CaptureCalibrationProfile: Codable, Equatable {
    var leftDeck: CaptureCalibrationZone
    var mixer: CaptureCalibrationZone
    var rightDeck: CaptureCalibrationZone

    subscript(role: CaptureCalibrationRole) -> CaptureCalibrationZone {
        get {
            switch role {
            case .leftDeck: return leftDeck
            case .mixer: return mixer
            case .rightDeck: return rightDeck
            }
        }
        set {
            switch role {
            case .leftDeck: leftDeck = newValue.clamped()
            case .mixer: mixer = newValue.clamped()
            case .rightDeck: rightDeck = newValue.clamped()
            }
        }
    }

    static func defaultProfile(for deckProfile: CaptureDeckProfile) -> CaptureCalibrationProfile {
        switch deckProfile {
        case .battle:
            return CaptureCalibrationProfile(
                leftDeck: CaptureCalibrationZone(x: 0.05, y: 0.22, width: 0.27, height: 0.42),
                mixer: CaptureCalibrationZone(x: 0.36, y: 0.2, width: 0.26, height: 0.46),
                rightDeck: CaptureCalibrationZone(x: 0.66, y: 0.22, width: 0.27, height: 0.42)
            )
        case .club:
            return CaptureCalibrationProfile(
                leftDeck: CaptureCalibrationZone(x: 0.03, y: 0.2, width: 0.29, height: 0.45),
                mixer: CaptureCalibrationZone(x: 0.35, y: 0.18, width: 0.28, height: 0.5),
                rightDeck: CaptureCalibrationZone(x: 0.66, y: 0.2, width: 0.29, height: 0.45)
            )
        case .compact:
            return CaptureCalibrationProfile(
                leftDeck: CaptureCalibrationZone(x: 0.08, y: 0.24, width: 0.24, height: 0.38),
                mixer: CaptureCalibrationZone(x: 0.36, y: 0.22, width: 0.24, height: 0.42),
                rightDeck: CaptureCalibrationZone(x: 0.64, y: 0.24, width: 0.24, height: 0.38)
            )
        }
    }
}

private struct CaptureReadinessContext {
    let sessionDefaultsComplete: Bool
    let cameraReady: Bool
    let audioMonitorState: AudioMonitorState
    let audioLevel: Float
    let motionConnected: Bool
    let hasRecentMotionImport: Bool
    let motionOptional: Bool
    let motionSkipped: Bool
    let calibrationConfirmed: Bool
    let storageReady: Bool
}

private enum CaptureReadinessValidator {
    static func validate(_ context: CaptureReadinessContext) -> [CaptureCheckResult] {
        let cameraResult = CaptureCheckResult(
            kind: .camera,
            status: context.cameraReady ? .ready : .blocked,
            detail: context.cameraReady ? "Camera ready" : "Camera not ready"
        )

        let audioStatus: CaptureReadinessStatus
        let audioDetail: String
        if context.audioMonitorState == .listening || context.audioLevel > 0.02 {
            audioStatus = .ready
            audioDetail = "Audio detected"
        } else if context.audioMonitorState == .micLive {
            audioStatus = .warning
            audioDetail = "Waiting for audio"
        } else {
            audioStatus = .blocked
            audioDetail = "No usable audio"
        }

        let motionStatus: CaptureReadinessStatus
        let motionDetail: String
        if context.motionSkipped {
            motionStatus = .ready
            motionDetail = "Motion skipped"
        } else if context.motionConnected || context.hasRecentMotionImport {
            motionStatus = .ready
            motionDetail = "Motion ready"
        } else {
            motionStatus = .warning
            motionDetail = "Motion not connected"
        }

        let calibrationResult = CaptureCheckResult(
            kind: .calibration,
            status: context.calibrationConfirmed ? .ready : .blocked,
            detail: context.calibrationConfirmed ? "Calibration ready" : "Calibration needed"
        )

        let storageResult = CaptureCheckResult(
            kind: .storage,
            status: context.storageReady ? .ready : .blocked,
            detail: context.storageReady ? "Storage ready" : "Storage unavailable"
        )

        return [
            cameraResult,
            CaptureCheckResult(kind: .audio, status: audioStatus, detail: audioDetail),
            CaptureCheckResult(kind: .motion, status: motionStatus, detail: motionDetail),
            calibrationResult,
            storageResult
        ]
    }
}

private struct CaptureTakeContext: Equatable {
    let takeNumber: Int
    var startedAt: Date?
}

private struct CaptureBanner: Identifiable, Equatable {
    enum Tone {
        case success
        case warning

        var color: Color {
            switch self {
            case .success: return Color(hex: "22C55E")
            case .warning: return Color(hex: "F59E0B")
            }
        }
    }

    let id = UUID()
    let message: String
    let tone: Tone
}

private struct CaptureReview: Equatable {
    let summary: CompanionCameraBroadcaster.RecordingSummary
    let drillName: String
    let duration: TimeInterval
    let syncStatus: String
    let audioPresent: Bool
    let motionStatusTitle: String
    let motionPresent: Bool
    let operatorMessage: String
    var quality: CaptureQualityTag?
    var isComboTagged: Bool = false
}

@MainActor
private final class GuidedCaptureStore: ObservableObject {
    @Published var flowState: CaptureFlowState = .idle
    @Published var sessionDraft = CaptureSessionDraft()
    @Published private(set) var persistedSessionDraft: CaptureSessionDraft?
    @Published var readinessResults: [CaptureCheckResult] = CaptureCheckKind.allCases.map(CaptureCheckResult.placeholder(for:))
    @Published var activeTake: CaptureTakeContext?
    @Published var review: CaptureReview?
    @Published var banner: CaptureBanner?
    @Published var preRollCountdown = 1
    @Published var calibrationProfile = CaptureCalibrationProfile.defaultProfile(for: .battle)
    @Published var isCalibrationConfirmed = false
    @Published var hasStoredCalibration = false
    @Published var hasStoredSessionDefaults = false
    @Published var hasRunSystemCheck = false
    @Published var motionSkipped = false
    @Published var showDrillChangeConfirmation = false
    @Published private(set) var keptReviews: [CaptureReview] = []

    let sessionSetup = SessionSetupViewModel(surface: .iosCompanion)

    private let defaults = UserDefaults.standard
    private let sessionDraftKey = "guidedCapture.lastSessionDraft"
    private let calibrationProfileKey = "guidedCapture.calibrationProfile"
    private let calibrationConfirmedKey = "guidedCapture.calibrationConfirmed"
    private let sessionOpenHistoryStore = SessionOpenHistoryStore(
        defaultsKey: "guidedCapture.sessionLastOpenedAt"
    )
    private var didBootstrap = false
    private var lastHandledRecordingID: String?
    private var needsNewSessionIdentity = false
    private var cancellables: Set<AnyCancellable> = []
    var sessionStartedAt: Date {
        sessionSetup.config.createdAt
    }

    init() {
        sessionSetup.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        sessionOpenHistoryStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    var canBeginCapture: Bool {
        sessionSetup.isComplete && !readinessResults.contains(where: { $0.status == .blocked })
    }

    var canSkipMotion: Bool {
        sessionSetup.drillMode.motionOptional && !motionSkipped
    }

    var readinessSummaryText: String {
        readinessResults.map { result in
            switch result.kind {
            case .motion where motionSkipped:
                return "Motion Skipped"
            default:
                return "\(result.kind.title) \(result.status == .ready ? "Ready" : result.status == .warning ? "Warning" : "Check")"
            }
        }
        .joined(separator: " · ")
    }

    var sessionListPresentation: SessionListPresentationModel<CaptureSessionConfig> {
        var sessions = [sessionSetup.config]
        if let persistedSessionDraft,
           persistedSessionDraft.config.sessionID != sessionSetup.config.sessionID {
            sessions.append(persistedSessionDraft.config)
        }

        return SessionListPresentationModel(
            sessions: sessions,
            activeSessionID: sessionSetup.config.sessionID,
            lastOpenedAtBySessionID: sessionOpenHistoryStore.lastOpenedAtBySessionID
        )
    }

    func bootstrap(performerName: String, defaultDrillID: String) {
        guard !didBootstrap else { return }
        didBootstrap = true

        if let persistedDraft = loadDraft() {
            persistedSessionDraft = persistedDraft
            sessionDraft = persistedDraft
            sessionSetup.applyPersistedConfig(persistedDraft.config)
            hasStoredSessionDefaults = true
            sessionOpenHistoryStore.updateLastOpenedAt(sessionID: persistedDraft.config.sessionID)
        } else {
            sessionSetup.performerName = performerName
            sessionSetup.scratchTypeID = defaultDrillID
        }

        sessionSetup.bootstrapDefaults(
            performerName: performerName,
            defaultScratchType: CaptureSessionScratchType(rawValue: defaultDrillID) ?? .babyScratch
        )

        if let storedCalibration = loadCalibration() {
            calibrationProfile = storedCalibration
            hasStoredCalibration = true
            isCalibrationConfirmed = defaults.bool(forKey: calibrationConfirmedKey)
        } else {
            calibrationProfile = CaptureCalibrationProfile.defaultProfile(for: sessionDraft.deckProfile)
        }

        sessionDraft.config = sessionSetup.config
        flowState = .sessionSetup
    }

    func openSession(id: String) {
        if sessionSetup.config.sessionID == id {
            sessionOpenHistoryStore.updateLastOpenedAt(sessionID: id)
            return
        }

        guard let persistedSessionDraft,
              persistedSessionDraft.config.sessionID == id else {
            return
        }

        sessionDraft = persistedSessionDraft
        sessionSetup.applyPersistedConfig(persistedSessionDraft.config)
        sessionDraft.config = sessionSetup.config
        needsNewSessionIdentity = false
        sessionOpenHistoryStore.updateLastOpenedAt(sessionID: id)
    }

    func startNewSession() {
        review = nil
        activeTake = nil
        keptReviews.removeAll()
        showDrillChangeConfirmation = false
        needsNewSessionIdentity = false
        sessionSetup.refreshSessionIdentity(now: Date())
        sessionDraft.config = sessionSetup.config
        flowState = .sessionSetup
        hasRunSystemCheck = false
        motionSkipped = false
        sessionOpenHistoryStore.updateLastOpenedAt(sessionID: sessionSetup.config.sessionID)
    }

    func continueFromSessionSetup() {
        guard sessionSetup.isComplete else { return }
        persistDraft()
        flowState = .systemCheck
        hasRunSystemCheck = false
        motionSkipped = false
        sessionOpenHistoryStore.updateLastOpenedAt(sessionID: sessionSetup.config.sessionID)
    }

    func refreshReadiness(with context: CaptureReadinessContext) {
        readinessResults = CaptureReadinessValidator.validate(context)
    }

    func runSystemCheck() {
        hasRunSystemCheck = true
    }

    func openFocusedSetupForFirstIssue() {
        if let firstBlocked = readinessResults.first(where: { $0.status == .blocked }) {
            openSetup(for: firstBlocked.kind)
            return
        }
        if canSkipMotion == false, let motionIssue = readinessResults.first(where: { $0.kind == .motion && $0.status == .warning }) {
            openSetup(for: motionIssue.kind)
        }
    }

    func openSetup(for kind: CaptureCheckKind) {
        switch kind {
        case .camera:
            flowState = .cameraSetup
        case .audio:
            flowState = .audioSetup
        case .motion:
            flowState = .motionSetup
        case .calibration:
            flowState = .calibrationSetup
        case .storage:
            flowState = .systemCheck
        }
    }

    func refreshCalibrationDefaults() {
        guard !isCalibrationConfirmed else { return }
        calibrationProfile = CaptureCalibrationProfile.defaultProfile(for: sessionDraft.deckProfile)
    }

    func markCalibrationEdited() {
        isCalibrationConfirmed = false
    }

    func persistConfirmedCalibration() {
        guard let data = try? JSONEncoder().encode(calibrationProfile) else { return }
        defaults.set(data, forKey: calibrationProfileKey)
        defaults.set(true, forKey: calibrationConfirmedKey)
        hasStoredCalibration = true
        isCalibrationConfirmed = true
    }

    func saveCalibration() {
        persistConfirmedCalibration()
        flowState = .systemCheck
    }

    func updateLiveCalibration(_ profile: CaptureCalibrationProfile) {
        calibrationProfile = profile
        isCalibrationConfirmed = true
    }

    func useStoredCalibration() {
        guard let stored = loadCalibration() else { return }
        calibrationProfile = stored
        hasStoredCalibration = true
        isCalibrationConfirmed = true
        defaults.set(true, forKey: calibrationConfirmedKey)
        flowState = .systemCheck
    }

    func resetCalibration() {
        calibrationProfile = CaptureCalibrationProfile.defaultProfile(for: sessionDraft.deckProfile)
        defaults.removeObject(forKey: calibrationConfirmedKey)
        isCalibrationConfirmed = false
    }

    func skipMotionForNow() {
        guard canSkipMotion else { return }
        motionSkipped = true
        flowState = .systemCheck
    }

    func beginTimedCapture(nextTakeNumber: Int) {
        guard canBeginCapture else { return }
        activeTake = CaptureTakeContext(takeNumber: nextTakeNumber, startedAt: nil)
        preRollCountdown = 1
        flowState = .preRoll
    }

    func updateCountInBeat(_ beat: Int) {
        guard flowState == .preRoll else { return }
        preRollCountdown = beat
    }

    func startTimedRecording(onRecordingStart: @escaping () -> Void) {
        guard flowState == .preRoll else { return }
        guard let activeTake else { return }
        self.activeTake = CaptureTakeContext(takeNumber: activeTake.takeNumber, startedAt: Date())
        flowState = .recording
        onRecordingStart()
    }

    func beginCalibrationCapture(nextTakeNumber: Int, onRecordingStart: @escaping () -> Void) {
        guard canBeginCapture else { return }
        activeTake = CaptureTakeContext(takeNumber: nextTakeNumber, startedAt: Date())
        flowState = .recording
        onRecordingStart()
    }

    func cancelPendingCapture(message: String? = nil) {
        if let message {
            showBanner(message: message, tone: .warning)
        }
        preRollCountdown = 1
        activeTake = nil
        flowState = .ready
    }

    func handleBlockedCaptureAttempt() {
        if let firstBlocked = readinessResults.first(where: { $0.status == .blocked }) {
            showBanner(message: firstBlocked.detail, tone: .warning)
            openSetup(for: firstBlocked.kind)
            return
        }

        if let validationMessage = sessionSetup.firstValidationMessage {
            showBanner(message: validationMessage, tone: .warning)
            flowState = .sessionSetup
            return
        }

        showBanner(message: "Finish setup before recording", tone: .warning)
        flowState = .systemCheck
    }

    func requestStopRecording() {
        flowState = .saving
    }

    func handleRecordingFinished(
        summary: CompanionCameraBroadcaster.RecordingSummary,
        audioPresent: Bool,
        motionPresent: Bool,
        calibrationValid: Bool
    ) {
        guard lastHandledRecordingID != summary.id else { return }
        lastHandledRecordingID = summary.id

        let duration = max(0, (summary.sidecar.endedAt ?? Date()).timeIntervalSince(summary.sidecar.startedAt))
        let operatorMessage: String
        if summary.sidecar.recordingStatus == "failed" {
            operatorMessage = "Recording interrupted"
        } else if duration < 1.0 {
            operatorMessage = "Take too short"
        } else if !audioPresent {
            operatorMessage = "Missing audio"
        } else if !calibrationValid {
            operatorMessage = "Calibration invalid"
        } else {
            operatorMessage = "Ready to keep"
        }

        let drillName = ScratchLibrary.shared.scratch(byID: sessionSetup.scratchTypeID)?.name ?? sessionSetup.scratchTypeName
        let motionAssessment = GuidedCaptureReviewStateResolver.motionAssessment(
            calibrationValid: calibrationValid,
            audioPresent: audioPresent,
            motionPresent: motionPresent,
            motionSkipped: motionSkipped,
            motionOptional: sessionSetup.drillMode.motionOptional
        )

        review = CaptureReview(
            summary: summary,
            drillName: drillName,
            duration: duration,
            syncStatus: motionAssessment.syncStatus,
            audioPresent: audioPresent,
            motionStatusTitle: motionAssessment.motionStatusTitle,
            motionPresent: motionAssessment.motionPresent,
            operatorMessage: operatorMessage
        )
        flowState = .review
    }

    func setQuality(_ quality: CaptureQualityTag) {
        guard var review else { return }
        review.quality = quality
        self.review = review
    }

    func toggleComboTag() {
        guard var review else { return }
        review.isComboTagged.toggle()
        self.review = review
    }

    func keepTake() {
        appendCurrentReviewIfNeeded()
        showBanner(message: "Take \(formattedCurrentTakeNumber) saved", tone: .success)
        flowState = .sessionComplete
    }

    func keepAndNext() {
        appendCurrentReviewIfNeeded()
        showBanner(message: "Take \(formattedCurrentTakeNumber) saved", tone: .success)
        review = nil
        activeTake = nil
        flowState = .ready
    }

    func discardTake(onDiscard: (CompanionCameraBroadcaster.RecordingSummary) -> Void) {
        if let summary = review?.summary {
            onDiscard(summary)
        }
        review = nil
        activeTake = nil
        showBanner(message: "Take discarded", tone: .warning)
        flowState = .ready
    }

    func retryTake(onDiscard: (CompanionCameraBroadcaster.RecordingSummary) -> Void) {
        if let summary = review?.summary {
            onDiscard(summary)
        }
        review = nil
        activeTake = nil
        showBanner(message: "Ready for another pass", tone: .warning)
        flowState = .ready
    }

    func prepareNextTake() {
        review = nil
        activeTake = nil
        flowState = .ready
    }

    func requestDrillChange() {
        showDrillChangeConfirmation = true
    }

    func confirmDrillChange() {
        showDrillChangeConfirmation = false
        review = nil
        activeTake = nil
        keptReviews.removeAll()
        sessionDraft.config = sessionSetup.config
        needsNewSessionIdentity = true
        flowState = .sessionSetup
        hasRunSystemCheck = false
        motionSkipped = false
    }

    func cancelDrillChange() {
        showDrillChangeConfirmation = false
    }

    func recheckSetup() {
        flowState = .systemCheck
        hasRunSystemCheck = true
    }

    func currentTakeNumber(fallback: Int) -> Int {
        activeTake?.takeNumber ?? review?.summary.sidecar.appLocalTakeNumber ?? fallback
    }

    private var formattedCurrentTakeNumber: String {
        let takeNumber = review?.summary.sidecar.appLocalTakeNumber ?? activeTake?.takeNumber ?? 0
        return String(format: "%03d", takeNumber)
    }

    private func showBanner(message: String, tone: CaptureBanner.Tone) {
        let banner = CaptureBanner(message: message, tone: tone)
        self.banner = banner
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in
            guard self?.banner == banner else { return }
            self?.banner = nil
        }
    }

    private func persistDraft() {
        guard sessionSetup.isComplete else { return }
        var persistedDraft = sessionDraft
        persistedDraft.config = sessionSetup.config
        guard let data = try? JSONEncoder().encode(persistedDraft) else { return }
        defaults.set(data, forKey: sessionDraftKey)
        persistedSessionDraft = persistedDraft
        hasStoredSessionDefaults = true
    }

    private func loadDraft() -> CaptureSessionDraft? {
        guard let data = defaults.data(forKey: sessionDraftKey) else { return nil }
        return try? JSONDecoder().decode(CaptureSessionDraft.self, from: data)
    }

    private func loadCalibration() -> CaptureCalibrationProfile? {
        guard let data = defaults.data(forKey: calibrationProfileKey) else { return nil }
        return try? JSONDecoder().decode(CaptureCalibrationProfile.self, from: data)
    }

    private func appendCurrentReviewIfNeeded() {
        guard let review else { return }
        guard !keptReviews.contains(where: { $0.summary.id == review.summary.id }) else { return }
        keptReviews.append(review)
        let updatedAt = review.summary.sidecar.endedAt ?? review.summary.sidecar.startedAt
        let totalDurationSeconds = keptReviews.reduce(0) { $0 + $1.duration }
        sessionSetup.applyCapturedTakeMetrics(
            takeCount: keptReviews.count,
            totalDurationSeconds: totalDurationSeconds,
            updatedAt: updatedAt
        )
        sessionDraft.config = sessionSetup.config
    }

    func prepareSessionForRecordingIfNeeded() {
        guard needsNewSessionIdentity else { return }
        needsNewSessionIdentity = false
        sessionSetup.refreshSessionIdentity(now: Date())
        sessionDraft.config = sessionSetup.config
        sessionOpenHistoryStore.updateLastOpenedAt(sessionID: sessionSetup.config.sessionID)
    }
}

private struct CaptureScreen<Content: View>: View {
    let title: String
    let subtitle: String?
    let onBack: () -> Void
    let trailingAction: CaptureScreenAction?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(.white)

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.68))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.left")
                }
            }

            if let trailingAction {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: trailingAction.action) {
                        Label(trailingAction.title, systemImage: trailingAction.systemImage)
                    }
                }
            }
        }
    }
}

private struct CaptureScreenAction {
    let title: String
    let systemImage: String
    let action: () -> Void
}

private struct SessionSetupView: View {
    @Binding var performerName: String
    @Binding var drillID: String
    @Binding var bpmText: String
    let allowedBPMList: [Int]
    @Binding var captureMode: CaptureSessionCaptureMode
    @Binding var beatEngineMode: BeatEngineMode
    @Binding var handedness: CaptureHandedness
    @Binding var deckProfile: CaptureDeckProfile
    @Binding var cameraProfile: CaptureCameraProfile
    @Binding var watchWrist: CaptureWrist
    @Binding var practiceMode: CapturePracticeMode
    @Binding var notes: String

    let scratches: [Scratch]
    let sessionListPresentation: SessionListPresentationModel<CaptureSessionConfig>
    let validationMessage: String?
    let onOpenSession: (String) -> Void
    let onStartNewSession: () -> Void
    let onContinue: () -> Void

    @State private var activePicker: ActivePicker?
    @State private var isShowingAllSessions = false

    private enum ActivePicker: Identifiable {
        case scratchType
        case captureMode
        case beatEngineMode
        case handedness
        case deckProfile
        case cameraProfile
        case watchWrist
        case practiceMode

        var id: String {
            switch self {
            case .scratchType: return "scratchType"
            case .captureMode: return "captureMode"
            case .beatEngineMode: return "beatEngineMode"
            case .handedness: return "handedness"
            case .deckProfile: return "deckProfile"
            case .cameraProfile: return "cameraProfile"
            case .watchWrist: return "watchWrist"
            case .practiceMode: return "practiceMode"
            }
        }
    }

    private var isContinueEnabled: Bool {
        !performerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !drillID.isEmpty
            && (captureMode == .calibrationNoClick || (Int(bpmText) ?? 0) > 0)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                if let activeSession = sessionListPresentation.activeSession {
                    CaptureCard {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text("Current Session")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.white)

                                Spacer()

                                Button(action: onStartNewSession) {
                                    Text("New Session")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(Color.white.opacity(0.08), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }

                            CaptureSessionSummaryRow(
                                title: sessionTitle(for: activeSession.session),
                                subtitle: sessionSubtitle(for: activeSession.session),
                                detail: sessionDetail(for: activeSession.session),
                                actionLabel: nil
                            )
                        }
                    }
                }

                if !sessionListPresentation.recentSessions.isEmpty {
                    CaptureCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Recent Sessions")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)

                            ForEach(sessionListPresentation.recentSessions) { session in
                                Button(action: { onOpenSession(session.id) }) {
                                    CaptureSessionSummaryRow(
                                        title: sessionTitle(for: session.session),
                                        subtitle: sessionSubtitle(for: session.session),
                                        detail: sessionDetail(for: session.session),
                                        actionLabel: "Continue Last Session"
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                CaptureCard {
                    DisclosureGroup("All Sessions", isExpanded: $isShowingAllSessions) {
                        VStack(spacing: 10) {
                            ForEach(sessionListPresentation.allSessions) { session in
                                Button(action: { onOpenSession(session.id) }) {
                                    CaptureSessionSummaryRow(
                                        title: sessionTitle(for: session.session),
                                        subtitle: sessionSubtitle(for: session.session),
                                        detail: sessionDetail(for: session.session),
                                        actionLabel: session.id == sessionListPresentation.activeSession?.id ? "Current" : "Open"
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 10)
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .tint(.white)
                }

                CaptureCard {
                    VStack(alignment: .leading, spacing: 16) {
                        CaptureTextField(title: "Performer name", text: $performerName)

                        CapturePickerField(
                            title: "Scratch Type",
                            selectionTitle: scratches.first(where: { $0.id == drillID })?.name ?? "Choose scratch type",
                            action: { activePicker = .scratchType }
                        )

                        CapturePickerField(
                            title: "Click track",
                            selectionTitle: captureMode.title,
                            action: { activePicker = .captureMode }
                        )

                        if captureMode == .timedClick {
                            CapturePickerField(
                                title: "Practice beat",
                                selectionTitle: beatEngineMode.title,
                                action: { activePicker = .beatEngineMode }
                            )
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Practice beat")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.72))

                                Text(BeatEngineMode.silent.title)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(14)
                                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                        }

                        if captureMode == .timedClick {
                            CaptureTempoEditor(
                                bpmText: $bpmText,
                                presetBPMs: allowedBPMList
                            )
                        }

                        CapturePickerField(
                            title: "Handedness",
                            selectionTitle: handedness.title,
                            action: { activePicker = .handedness }
                        )

                        CapturePickerField(
                            title: "Deck / mixer",
                            selectionTitle: deckProfile.title,
                            action: { activePicker = .deckProfile }
                        )

                        CapturePickerField(
                            title: "Camera",
                            selectionTitle: cameraProfile.title,
                            action: { activePicker = .cameraProfile }
                        )

                        CapturePickerField(
                            title: "Watch wrist",
                            selectionTitle: watchWrist.title,
                            action: { activePicker = .watchWrist }
                        )

                        CapturePickerField(
                            title: "Capture Mode",
                            selectionTitle: practiceMode.title,
                            action: { activePicker = .practiceMode }
                        )

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Notes (optional)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white.opacity(0.72))

                            TextField("Add a short note", text: $notes, axis: .vertical)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.white)
                                .padding(14)
                                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .lineLimit(3...5)
                        }
                    }
                }

                if let validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(hex: "F59E0B"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button(action: onContinue) {
                    Text("Continue")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(isContinueEnabled ? Color(hex: "22C55E") : Color.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .disabled(!isContinueEnabled)
            }
            .padding(.bottom, 32)
        }
        .sheet(item: $activePicker) { picker in
            switch picker {
            case .scratchType:
                CaptureSelectionSheet(title: "Scratch Type") {
                    ForEach(scratches, id: \.id) { scratch in
                        CaptureSelectionRow(
                            title: scratch.name,
                            isSelected: drillID == scratch.id,
                            action: {
                                drillID = scratch.id
                                activePicker = nil
                            }
                        )
                    }
                }
            case .captureMode:
                CaptureSelectionSheet(title: "Click track") {
                    ForEach(CaptureSessionCaptureMode.allCases) { option in
                        CaptureSelectionRow(
                            title: option.title,
                            isSelected: captureMode == option,
                            action: {
                                captureMode = option
                                activePicker = nil
                            }
                        )
                    }
                }
            case .beatEngineMode:
                CaptureSelectionSheet(title: "Practice beat") {
                    ForEach(BeatEngineMode.practiceModes) { option in
                        CaptureSelectionRow(
                            title: option.title,
                            isSelected: beatEngineMode == option,
                            action: {
                                beatEngineMode = option
                                activePicker = nil
                            }
                        )
                    }
                }
            case .handedness:
                CaptureSelectionSheet(title: "Handedness") {
                    ForEach(CaptureHandedness.allCases) { option in
                        CaptureSelectionRow(
                            title: option.title,
                            isSelected: handedness == option,
                            action: {
                                handedness = option
                                activePicker = nil
                            }
                        )
                    }
                }
            case .deckProfile:
                CaptureSelectionSheet(title: "Deck / Mixer") {
                    ForEach(CaptureDeckProfile.allCases) { option in
                        CaptureSelectionRow(
                            title: option.title,
                            isSelected: deckProfile == option,
                            action: {
                                deckProfile = option
                                activePicker = nil
                            }
                        )
                    }
                }
            case .cameraProfile:
                CaptureSelectionSheet(title: "Camera") {
                    ForEach(CaptureCameraProfile.allCases) { option in
                        CaptureSelectionRow(
                            title: option.title,
                            isSelected: cameraProfile == option,
                            action: {
                                cameraProfile = option
                                activePicker = nil
                            }
                        )
                    }
                }
            case .watchWrist:
                CaptureSelectionSheet(title: "Watch Wrist") {
                    ForEach(CaptureWrist.allCases) { option in
                        CaptureSelectionRow(
                            title: option.title,
                            isSelected: watchWrist == option,
                            action: {
                                watchWrist = option
                                activePicker = nil
                            }
                        )
                    }
                }
            case .practiceMode:
                CaptureSelectionSheet(title: "Capture Mode") {
                    ForEach(CapturePracticeMode.allCases) { option in
                        CaptureSelectionRow(
                            title: option.title,
                            isSelected: practiceMode == option,
                            action: {
                                practiceMode = option
                                activePicker = nil
                            }
                        )
                    }
                }
            }
        }
    }

    private func sessionTitle(for config: CaptureSessionConfig) -> String {
        let performerName = config.performerName.trimmingCharacters(in: .whitespacesAndNewlines)
        return performerName.isEmpty ? "Untitled Session" : performerName
    }

    private func sessionSubtitle(for config: CaptureSessionConfig) -> String {
        let scratchLabel = config.scratchType?.title ?? "Scratch type later"
        let bpmLabel = config.bpm.map { "\($0) BPM" } ?? "BPM later"
        return "\(scratchLabel) · \(bpmLabel)"
    }

    private func sessionDetail(for config: CaptureSessionConfig) -> String {
        config.sessionID
    }
}

private struct CaptureSessionSummaryRow: View {
    let title: String
    let subtitle: String
    let detail: String
    let actionLabel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)

                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.72))
                }

                Spacer(minLength: 12)

                if let actionLabel {
                    Text(actionLabel)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color(hex: "22C55E"))
                }
            }

            Text(detail)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.62))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct CaptureTempoEditor: View {
    @Binding var bpmText: String

    let presetBPMs: [Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Timed capture")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.72))

            HStack(spacing: 8) {
                ForEach(presetBPMs, id: \.self) { bpm in
                    Button {
                        bpmText = String(bpm)
                    } label: {
                        Text("\(bpm)")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(Int(bpmText) == bpm ? .black : .white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                Int(bpmText) == bpm ? Color(hex: "22C55E") : Color.white.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                    }
                }
            }

            TextField("Custom BPM (60–140)", text: $bpmText)
                .keyboardType(.numberPad)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white)
                .padding(14)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

private struct SystemCheckView: View {
    let results: [CaptureCheckResult]
    let hasRunCheck: Bool
    let canBeginCapture: Bool
    let canSkipMotion: Bool
    let configurationMessage: String?
    let onStartCheck: () -> Void
    let onRecheck: () -> Void
    let onFixIssues: () -> Void
    let onCompleteSessionSetup: () -> Void
    let onBeginCapture: () -> Void
    let onSkipMotion: () -> Void

    private var hasBlockingIssue: Bool {
        results.contains { $0.status == .blocked }
    }

    private var needsSessionSetup: Bool {
        !hasBlockingIssue && !canBeginCapture && configurationMessage != nil
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                ForEach(results) { result in
                    CaptureStatusCard(result: result)
                }

                VStack(spacing: 12) {
                    if let configurationMessage, needsSessionSetup {
                        Label(configurationMessage, systemImage: "exclamationmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(hex: "F59E0B"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button(action: hasRunCheck ? onRecheck : onStartCheck) {
                        Text(hasRunCheck ? "Recheck" : "Start Setup Check")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(Color(hex: "22C55E"), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                    if hasBlockingIssue {
                        CaptureSecondaryButton(title: "Fix Issues", action: onFixIssues)
                    } else if needsSessionSetup {
                        CaptureSecondaryButton(title: "Complete Session Setup", action: onCompleteSessionSetup)
                    }

                    Button(action: onBeginCapture) {
                        Text("Open Record Controls")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(Color(hex: "0EA5E9"), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                    if canSkipMotion {
                        CaptureSecondaryButton(title: "Skip Motion", action: onSkipMotion)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct CameraSetupView: View {
    let session: AVCaptureSession
    let videoRotationAngle: CGFloat
    @Binding var calibrationProfile: CaptureCalibrationProfile
    let isCameraReady: Bool
    let onAdjustGuides: () -> Void
    let onConfirmCamera: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            CalibrationPreviewCard(
                session: session,
                videoRotationAngle: videoRotationAngle,
                calibrationProfile: $calibrationProfile,
                allowsEditing: true
            )

            HStack(spacing: 12) {
                CaptureSecondaryButton(title: "Adjust Guides", action: onAdjustGuides)

                Button(action: onConfirmCamera) {
                    Text("Confirm Camera")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background((isCameraReady ? Color(hex: "22C55E") : Color.white.opacity(0.24)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .disabled(!isCameraReady)
            }
        }
    }
}

private struct AudioSetupView: View {
    let selectedInputName: String
    let availableInputs: [CompanionCameraBroadcaster.AudioInputOption]
    @Binding var selectedAudioInputID: String
    let inputMonitorState: AudioMonitorState
    let inputLevel: Float
    let isClipping: Bool
    let onUseThisInput: () -> Void
    let onTestAgain: () -> Void

    private var normalizedLevel: Double {
        min(1.0, max(0.0, Double(inputLevel) * 12.0))
    }

    private var canUseInput: Bool {
        inputMonitorState == .listening || inputLevel > 0.02
    }

    var body: some View {
        VStack(spacing: 16) {
            CaptureCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Selected input")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))

                    Text(selectedInputName)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Live meter")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.7))

                        ProgressView(value: normalizedLevel)
                            .tint(isClipping ? Color(hex: "EF4444") : Color(hex: "22C55E"))

                        HStack {
                            Text(canUseInput ? "Signal present" : "No signal yet")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white.opacity(0.78))

                            Spacer()

                            Text(isClipping ? "Clipping" : "Healthy")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(isClipping ? Color(hex: "FCA5A5") : Color(hex: "86EFAC"))
                        }
                    }
                }
            }

            Menu {
                if availableInputs.isEmpty {
                    Text("No alternate inputs").disabled(true)
                } else {
                    ForEach(availableInputs) { option in
                        Button(option.displayName) {
                            selectedAudioInputID = option.id
                        }
                    }
                }
            } label: {
                Text("Choose Input")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            HStack(spacing: 12) {
                Button(action: onUseThisInput) {
                    Text("Use This Input")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background((canUseInput ? Color(hex: "22C55E") : Color.white.opacity(0.24)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .disabled(!canUseInput)

                CaptureSecondaryButton(title: "Test Again", action: onTestAgain)
            }
        }
    }
}

private struct MotionSetupView: View {
    let connectionSummary: String
    let isConnected: Bool
    let lastSampleDate: Date?
    let activityLevel: Double
    let canSkip: Bool
    let onTestMotion: () -> Void
    let onReconnect: () -> Void
    let onSkip: () -> Void

    private var lastSampleText: String {
        guard let lastSampleDate else { return "No recent motion" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: lastSampleDate, relativeTo: Date())
    }

    var body: some View {
        VStack(spacing: 16) {
            CaptureCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(isConnected ? "Device paired" : "Waiting for device")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.white)

                        Spacer()

                        Text(isConnected ? "Ready" : "Warning")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(isConnected ? Color(hex: "86EFAC") : Color(hex: "FDE68A"))
                    }

                    Text(connectionSummary)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.76))
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Last sample")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.68))

                        Text(lastSampleText)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.white)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Movement activity")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.68))

                        ProgressView(value: activityLevel)
                            .tint(Color(hex: "6366F1"))
                    }
                }
            }

            HStack(spacing: 12) {
                CaptureSecondaryButton(title: "Reconnect", action: onReconnect)
                CaptureSecondaryButton(title: "Test Motion", action: onTestMotion)
            }

            if canSkip {
                CaptureSecondaryButton(title: "Skip for Now", action: onSkip)
            }
        }
    }
}

private struct CalibrationSetupView: View {
    let session: AVCaptureSession
    let videoRotationAngle: CGFloat
    @Binding var calibrationProfile: CaptureCalibrationProfile
    let hasStoredCalibration: Bool
    let onSave: () -> Void
    let onReset: () -> Void
    let onUsePrevious: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            CalibrationPreviewCard(
                session: session,
                videoRotationAngle: videoRotationAngle,
                calibrationProfile: $calibrationProfile,
                allowsEditing: true
            )

            HStack(spacing: 12) {
                Button(action: onSave) {
                    Text("Save Calibration")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(Color(hex: "22C55E"), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                CaptureSecondaryButton(title: "Reset", action: onReset)
            }

            if hasStoredCalibration {
                CaptureSecondaryButton(title: "Use Previous Calibration", action: onUsePrevious)
            }
        }
    }
}

private struct CaptureHubView: View {
    let flowState: CaptureFlowState
    let sessionLabel: String
    let readinessSummary: String
    let canStartTake: Bool
    let takeNumber: Int
    let session: AVCaptureSession
    let videoRotationAngle: CGFloat
    @Binding var calibrationProfile: CaptureCalibrationProfile
    let preRollCount: Int
    let recordingStartedAt: Date?
    let audioStateText: String
    let motionStateText: String
    let captureHealthText: String
    let clickTrackStatusText: String?
    let warningText: String?
    let onStart: () -> Void
    let onStop: () -> Void
    let onRecheck: () -> Void

    private var showsRecordingIndicator: Bool {
        flowState == .recording || flowState == .saving
    }

    private var allowsCalibrationEditing: Bool {
        flowState == .ready
    }

    var body: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(sessionLabel) · Take \(String(format: "%03d", takeNumber))")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)

                Text(readinessSummary)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if showsRecordingIndicator {
                HStack(spacing: 10) {
                    Image(systemName: flowState == .saving ? "waveform.circle.fill" : "record.circle.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(flowState == .saving ? "Finishing Recording" : "Recording")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)

                        Text(clickTrackStatusText ?? "ScratchLab is actively capturing this take.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.82))
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    flowState == .saving ? Color(hex: "EA580C") : Color(hex: "DC2626"),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel(flowState == .saving
                    ? "Finishing recording. ScratchLab is still capturing this take."
                    : (clickTrackStatusText == nil
                        ? "Recording. ScratchLab is actively capturing this take."
                        : "Recording. Click track on. ScratchLab is actively capturing this take."))
            }

            ZStack {
                CalibrationPreviewCard(
                    session: session,
                    videoRotationAngle: videoRotationAngle,
                    calibrationProfile: $calibrationProfile,
                    allowsEditing: allowsCalibrationEditing
                )

                if flowState == .preRoll {
                    ZStack {
                        Circle()
                            .fill(Color.black.opacity(0.62))
                            .frame(width: 140, height: 140)

                        VStack(spacing: 8) {
                            Text("Count-in")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white.opacity(0.72))

                            Text("\(preRollCount)")
                                .font(.system(size: 54, weight: .bold))
                                .foregroundColor(.white)

                            Text("Get ready")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white.opacity(0.76))
                        }
                    }
                }
            }

            if flowState == .recording || flowState == .saving {
                if let warningText {
                    WarningBannerView(text: warningText)
                }

                HStack(spacing: 12) {
                    TimelineView(.periodic(from: .now, by: 0.5)) { context in
                        CaptureMetricView(title: "Elapsed", value: elapsedTimeText(now: context.date))
                    }
                    CaptureMetricView(title: "Audio", value: audioStateText)
                    CaptureMetricView(title: "Motion", value: motionStateText)
                    CaptureMetricView(title: "Health", value: captureHealthText)
                }
            }

            VStack(spacing: 12) {
                if flowState == .recording || flowState == .saving {
                    Button(action: onStop) {
                        Text(flowState == .saving ? "Saving..." : "Stop Take")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 17)
                            .background(Color(hex: "DC2626"), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .disabled(flowState == .saving)
                    .keyboardShortcut(.space, modifiers: [])
                } else if flowState == .preRoll {
                    Button(action: {}) {
                        Text("Starting...")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 17)
                            .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .disabled(true)
                } else {
                    Button(action: onStart) {
                        Text("Record Take")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(canStartTake ? .black : .white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 17)
                            .background((canStartTake ? Color(hex: "22C55E") : Color(hex: "F59E0B")), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .keyboardShortcut(.space, modifiers: [])

                    Text(canStartTake
                         ? "Pause briefly before starting. Perform one scratch type only."
                         : "Preview is live. Tap Record Take to jump to the remaining setup issue.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.68))
                        .fixedSize(horizontal: false, vertical: true)

                    CaptureSecondaryButton(title: "Recheck Setup", action: onRecheck)
                        .keyboardShortcut("k", modifiers: [])
                }
            }
        }
    }

    private func elapsedTimeText(now: Date) -> String {
        guard let recordingStartedAt else { return "00:00" }
        let elapsed = now.timeIntervalSince(recordingStartedAt)
        let minutes = Int(elapsed) / 60
        let seconds = Int(elapsed) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private struct TakeReviewView: View {
    let review: CaptureReview
    let onSelectQuality: (CaptureQualityTag) -> Void
    let onToggleCombo: () -> Void
    let onKeep: () -> Void
    let onKeepAndNext: () -> Void
    let onRetry: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                CaptureCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(review.operatorMessage)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.white)

                        LazyVGrid(columns: reviewStatusColumns, spacing: 10) {
                            ReadinessPill(title: review.syncStatus, color: review.syncStatus == "Ready" ? Color(hex: "22C55E") : Color(hex: "F59E0B"))
                            ReadinessPill(title: review.audioPresent ? "Audio Present" : "Missing Audio", color: review.audioPresent ? Color(hex: "22C55E") : Color(hex: "EF4444"))
                            ReadinessPill(title: review.motionStatusTitle, color: review.motionPresent ? Color(hex: "22C55E") : Color(hex: "F59E0B"))
                        }
                    }
                }

                CaptureThumbnailView(mediaURL: review.summary.mediaURL)

                CaptureCard {
                    VStack(alignment: .leading, spacing: 12) {
                        CaptureReviewDetailBlock(label: "Take ID", value: review.summary.sidecar.takeID)
                        CaptureReviewDetailBlock(label: "Scratch Type", value: review.drillName)
                        CaptureReviewDetailBlock(label: "Duration", value: formatDuration(review.duration))
                        CaptureReviewDetailBlock(label: "Sync", value: review.syncStatus)
                    }
                }

                CaptureCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Quality")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white.opacity(0.72))

                        LazyVGrid(columns: qualityColumns, spacing: 10) {
                            ForEach(CaptureQualityTag.allCases) { quality in
                                Button(action: { onSelectQuality(quality) }) {
                                    Text(quality.title)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(review.quality == quality ? .black : .white)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                        .background((review.quality == quality ? Color(hex: "22C55E") : Color.white.opacity(0.08)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                            }
                        }

                        Button(action: onToggleCombo) {
                            HStack {
                                Image(systemName: review.isComboTagged ? "checkmark.square.fill" : "square")
                                Text("Tag as Combo")
                            }
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                        }
                    }
                }

                HStack(spacing: 12) {
                    Button(action: onKeep) {
                        Text("Keep")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(Color(hex: "22C55E"), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                    Button(action: onRetry) {
                        Text("Retry")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .keyboardShortcut("r", modifiers: [])
                }

                HStack(spacing: 12) {
                    Button(action: onDiscard) {
                        Text("Discard")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(Color(hex: "7F1D1D"), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .keyboardShortcut("d", modifiers: [])

                    Button(action: onKeepAndNext) {
                        Text("Keep and Next")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(Color(hex: "0EA5E9"), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .keyboardShortcut(.return, modifiers: [])
                }
            }
            .padding(.bottom, 24)
        }
    }

    private var reviewStatusColumns: [GridItem] {
        [GridItem(.flexible()), GridItem(.flexible())]
    }

    private var qualityColumns: [GridItem] {
        [GridItem(.flexible()), GridItem(.flexible())]
    }
}

private struct CaptureReviewDetailBlock: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.66))

            Text(value)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SessionCompleteView: View {
    let sessionName: String
    let takeCount: Int
    let uploadAvailable: Bool
    let uploadAvailabilityText: String?
    let uploadJob: SessionUploadJob?
    let onUploadSession: () -> Void
    let onRetryUpload: () -> Void
    let canShare: Bool
    let isExporting: Bool
    let exportStatusText: String?
    let exportBlockingIssues: [String]
    let exportSummaryText: String?
    let exportWarningText: String?
    @Binding var exportMixMode: ExportMixMode
    let timingWarningText: String?
    let onShareSession: () -> Void
    let onNextTake: () -> Void
    let onChangeDrill: () -> Void
    let onRecheckSetup: () -> Void
    let onEndSession: () -> Void

    private var showsUploadSection: Bool {
        uploadAvailable || uploadJob != nil
    }

    var body: some View {
        VStack(spacing: 16) {
            CaptureCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Take saved")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)

                    Text("Keep the loop moving or reset the block before the next take.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if showsUploadSection {
                CaptureCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Upload Session")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)

                        Text(uploadJob?.statusText ?? (uploadAvailable ? "Ready to upload" : uploadAvailabilityText ?? "Upload isn't available right now."))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white.opacity(0.72))
                            .fixedSize(horizontal: false, vertical: true)

                        Text("\(sessionName) · \(takeCount) take\(takeCount == 1 ? "" : "s")")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)

                        if let uploadJob, uploadJob.fileSizeBytes > 0 {
                            Text(uploadJob.formattedFileSize)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.7))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        if let progressFraction = uploadJob?.progressFraction {
                            ProgressView(value: progressFraction)
                                .tint(Color(hex: "22C55E"))
                        } else if uploadJob?.state == .preparing || uploadJob?.state == .requestingUploadURL {
                            ProgressView()
                                .tint(Color(hex: "22C55E"))
                        }

                        Button(action: onUploadSession) {
                            Text(uploadJob?.state == .completed ? "Uploaded" : "Upload Session")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.black)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color(hex: "22C55E"), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .disabled(
                            !canShare
                                || !uploadAvailable
                                || uploadJob?.state == .completed
                                || uploadJob?.state == .uploading
                                || uploadJob?.state == .requestingUploadURL
                                || uploadJob?.state == .preparing
                        )

                        if uploadJob?.canRetry == true {
                            CaptureSecondaryButton(title: "Retry Upload", action: onRetryUpload)
                        }
                    }
                }
            }

            CaptureCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Share Session")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)

                    Text(exportStatusText ?? "Export this session as a ZIP archive.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Export mix")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.72))

                        Picker("Export mix", selection: $exportMixMode) {
                            ForEach(ExportMixMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(.white)
                    }

                    if !exportBlockingIssues.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(exportBlockingIssues, id: \.self) { issue in
                                Text("• \(issue)")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(Color(hex: "FCA5A5"))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    if let exportSummaryText {
                        Text(exportSummaryText)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.7))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if let exportWarningText {
                        Text(exportWarningText)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color(hex: "F59E0B"))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let timingWarningText {
                        Text(timingWarningText)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color(hex: "F59E0B"))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button(action: onShareSession) {
                        Text(isExporting ? "Preparing..." : "Share Session")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color(hex: "0EA5E9"), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .disabled(isExporting || !canShare)
                }
            }

            Button(action: onNextTake) {
                Text("Next Take")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color(hex: "22C55E"), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .keyboardShortcut(.return, modifiers: [])

            CaptureSecondaryButton(title: "Change Scratch Type", action: onChangeDrill)
                .keyboardShortcut("c", modifiers: [])

            CaptureSecondaryButton(title: "Recheck Setup", action: onRecheckSetup)
                .keyboardShortcut("k", modifiers: [])

            CaptureSecondaryButton(title: "End Session", action: onEndSession)
        }
    }
}

private struct CaptureCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
    }
}

private struct CaptureTextField: View {
    let title: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.72))

            TextField(title, text: $text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white)
                .padding(14)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

private struct CapturePickerField: View {
    let title: String
    let selectionTitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.72))

                HStack {
                    Text(selectionTitle)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white.opacity(0.7))
                }
                .padding(14)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

private struct CaptureSelectionSheet<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                content
                    .listRowBackground(Color.black)
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct CaptureSelectionRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(Color(hex: "22C55E"))
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct CaptureStatusCard: View {
    let result: CaptureCheckResult

    var body: some View {
        CaptureCard {
            HStack(spacing: 14) {
                Circle()
                    .fill(result.status.color)
                    .frame(width: 12, height: 12)

                VStack(alignment: .leading, spacing: 4) {
                    Text(result.kind.title)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.white)

                    Text(result.detail)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.72))
                }

                Spacer()

                Text(result.status.label)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(result.status.color)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(result.status.color.opacity(0.14), in: Capsule())
            }
        }
    }
}

private struct CaptureSecondaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

private struct CalibrationPreviewCard: View {
    let session: AVCaptureSession
    let videoRotationAngle: CGFloat
    @Binding var calibrationProfile: CaptureCalibrationProfile
    let allowsEditing: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                CompanionCameraPreview(
                    session: session,
                    videoRotationAngle: videoRotationAngle
                )
                .allowsHitTesting(false)

                ForEach(CaptureCalibrationRole.allCases) { role in
                    InteractiveCalibrationZone(
                        zone: Binding(
                            get: { calibrationProfile[role] },
                            set: { calibrationProfile[role] = $0 }
                        ),
                        role: role,
                        containerSize: proxy.size,
                        allowsEditing: allowsEditing
                    )
                }
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }
}

private struct InteractiveCalibrationZone: View {
    @Binding var zone: CaptureCalibrationZone
    let role: CaptureCalibrationRole
    let containerSize: CGSize
    let allowsEditing: Bool

    @State private var moveStart: CaptureCalibrationZone?
    @State private var resizeStart: CaptureCalibrationZone?

    var body: some View {
        let rect = zone.rect(in: containerSize)

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12)
                .stroke(role.color.opacity(0.92), lineWidth: allowsEditing ? 3 : 2)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(role.color.opacity(0.12))
                )

            Text(role.title)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.72), in: Capsule())
                .padding(8)

            if allowsEditing {
                Circle()
                    .fill(role.color)
                    .frame(width: 28, height: 28)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.92), lineWidth: 2)
                    )
                    .contentShape(Circle())
                    .position(x: rect.width - 18, y: rect.height - 18)
                    .gesture(resizeGesture)
            }
        }
        .frame(width: rect.width, height: rect.height)
        .contentShape(Rectangle())
        .position(x: rect.midX, y: rect.midY)
        .gesture(moveGesture)
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard allowsEditing else { return }
                let start = moveStart ?? zone
                moveStart = start
                zone = CaptureCalibrationZone(
                    x: start.x + value.translation.width / max(containerSize.width, 1),
                    y: start.y + value.translation.height / max(containerSize.height, 1),
                    width: start.width,
                    height: start.height
                ).clamped()
            }
            .onEnded { _ in
                moveStart = nil
                zone = zone.clamped()
            }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard allowsEditing else { return }
                let start = resizeStart ?? zone
                resizeStart = start
                zone = CaptureCalibrationZone(
                    x: start.x,
                    y: start.y,
                    width: start.width + value.translation.width / max(containerSize.width, 1),
                    height: start.height + value.translation.height / max(containerSize.height, 1)
                ).clamped()
            }
            .onEnded { _ in
                resizeStart = nil
                zone = zone.clamped()
            }
    }
}

private struct CaptureMetricView: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.6))

            Text(value)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct WarningBannerView: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(Color(hex: "FDE68A"))

            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(hex: "7C2D12").opacity(0.88), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct CaptureBannerView: View {
    let banner: CaptureBanner

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(banner.tone.color)
                .frame(width: 10, height: 10)

            Text(banner.message)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct ReadinessPill: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(color.opacity(0.14), in: Capsule())
    }
}

private struct CaptureDetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.66))

            Spacer()

            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct CaptureThumbnailView: View {
    let mediaURL: URL

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.white.opacity(0.06)
                    Image(systemName: "video")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundColor(.white.opacity(0.72))
                }
                .task {
                    await loadThumbnail()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    @MainActor
    private func loadThumbnail() async {
        guard image == nil else { return }
        if let loadedImage = await Self.makeThumbnail(from: mediaURL), image == nil {
            image = loadedImage
        }
    }

    private static func makeThumbnail(from mediaURL: URL) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let asset = AVURLAsset(url: mediaURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1280, height: 720)
            generator.generateCGImageAsynchronously(for: .zero) { cgImage, _, _ in
                continuation.resume(returning: cgImage.map(UIImage.init(cgImage:)))
            }
        }
    }
}

private func formatDuration(_ duration: TimeInterval) -> String {
    let minutes = Int(duration) / 60
    let seconds = Int(duration) % 60
    let tenths = Int((duration - floor(duration)) * 10)
    return String(format: "%02d:%02d.%01d", minutes, seconds, tenths)
}

private struct CompanionCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let videoRotationAngle: CGFloat

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.updateSession(session)
        view.updateRotationAngle(videoRotationAngle)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.updateSession(session)
        uiView.updateRotationAngle(videoRotationAngle)
    }

    static func dismantleUIView(_ uiView: PreviewView, coordinator: ()) {
        uiView.updateSession(nil)
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass {
            AVCaptureVideoPreviewLayer.self
        }

        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }

        private var currentVideoRotationAngle: CGFloat = .nan

        func updateSession(_ session: AVCaptureSession?) {
            guard previewLayer.session !== session else { return }
            previewLayer.session = session
        }

        func updateRotationAngle(_ angle: CGFloat) {
            guard currentVideoRotationAngle != angle else { return }
            currentVideoRotationAngle = angle
            guard let connection = previewLayer.connection,
                  connection.isVideoRotationAngleSupported(angle) else {
                return
            }
            connection.videoRotationAngle = angle
        }
    }
}

#if DEBUG
struct CompanionCameraView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            CompanionCameraView()
        }
        .environmentObject(AudioEngine())
        .environmentObject(ProgressManager())
        .environmentObject(WatchMotionCaptureStore())
    }
}
#endif
