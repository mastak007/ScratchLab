import SwiftUI
import AVFoundation
import UIKit
import Combine

struct CompanionCameraView: View {
    @StateObject private var captureStore = GuidedCaptureStore()
    @StateObject private var beatEngine = ScratchLabBeatEngine()
    @StateObject private var sessionExportCoordinator = SessionExportCoordinator()
    @State private var exportMixMode: ExportMixMode = .scratchOnly
    @State private var activeWatchCaptureLink: (sessionID: String, takeID: String)?
    /// The rendered-scratch WAV destination for the take currently recording,
    /// if any — set when scratch capture starts and consumed once the take
    /// finishes (see `beginLinkedRecording`/`handleFinishedRecording`).
    @State private var pendingScratchAudioURL: URL?

    @EnvironmentObject private var audioEngine: AudioEngine
    @EnvironmentObject private var practiceBeatStore: PracticeBeatStore
    @EnvironmentObject private var broadcaster: CompanionCameraBroadcaster
    @EnvironmentObject private var progressManager: ProgressManager
    @EnvironmentObject private var sessionUploadManager: SessionUploadManager
    @EnvironmentObject private var watchMotionCaptureStore: WatchMotionCaptureStore
    @EnvironmentObject private var scratchPlaybackEngine: IOScratchPlaybackEngine
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
                ScratchLabDesign.Surface.applicationBackground
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
        view = AnyView(view.onChange(of: watchMotionCaptureStore.importedSessions.count) { _, _ in
            refreshReadiness()
            refreshReviewMotionAssociation()
        })
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
                                beginLinkedRecording(captureTiming: captureTiming)
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
            beginLinkedRecording(captureTiming: captureTiming)
        }
    }

    private func stopTake() {
        beatEngine.stop()
        captureStore.requestStopRecording()
        if let link = activeWatchCaptureLink {
            watchMotionCaptureStore.requestRemoteCaptureStop(
                sessionID: link.sessionID,
                takeID: link.takeID
            ) { _ in }
            activeWatchCaptureLink = nil
        }
        scratchPlaybackEngine.stopRecordingScratchAudio()
        broadcaster.endRecording()
    }

    /// Starts the existing WatchConnectivity capture command with the exact
    /// identity the local recording sidecar will use. Recording remains
    /// available when the watch is optional, skipped, or unreachable.
    private func beginLinkedRecording(captureTiming: CaptureTimingMetadata) {
        broadcaster.recordingSessionConfig = captureStore.sessionSetup.config

        if !captureStore.motionSkipped, watchMotionCaptureStore.isWatchReachable {
            let sessionID = captureStore.sessionSetup.config.sessionID
            let takeNumber = captureStore.activeTake?.takeNumber ?? broadcaster.nextTakeNumberPreview
            let takeID = CaptureCore.LocalRecordingNaming.takeID(takeNumber: takeNumber)
            activeWatchCaptureLink = (sessionID, takeID)
            watchMotionCaptureStore.requestRemoteCaptureStart(
                sessionID: sessionID,
                takeID: takeID
            ) { _ in }
        } else {
            activeWatchCaptureLink = nil
        }

        beginScratchAudioCapture()
        broadcaster.beginRecording(captureTiming: captureTiming)
    }

    /// Records the exact live-rendered scratch signal (the same samples the
    /// performer hears through the RANE) into a WAV alongside the take, so
    /// the eventual `scratch_only.wav`/`scratch_with_beat.wav` export
    /// carries the real performance instead of a silent camera-audio track.
    /// Best-effort: a failure here still leaves Capture fully usable — the
    /// existing camera-audio-derived fallback simply applies, as it always
    /// has.
    private func beginScratchAudioCapture() {
        guard let directory = broadcaster.stagedCaptureDirectoryURL else {
            pendingScratchAudioURL = nil
            return
        }
        let url = directory.appendingPathComponent("\(UUID().uuidString)_scratch.wav")
        pendingScratchAudioURL = url
        Task {
            do {
                try await scratchPlaybackEngine.startRecordingScratchAudio(to: url)
            } catch {
                #if DEBUG
                print("[AUDIO-CAPTURE-DEBUG] scratch recorder failed to start: \(error.localizedDescription)")
                #endif
            }
        }
    }

    private func handleFinishedRecording() {
        beatEngine.stop()
        guard let summary = broadcaster.lastRecordingSummary else { return }
        let calibrationValid = captureStore.isCalibrationConfirmed
        let scratchAudioURL = pendingScratchAudioURL
        pendingScratchAudioURL = nil

        Task {
            let audioPresent = await Self.mediaContainsAudio(summary.mediaURL)
            guard broadcaster.lastRecordingSummary?.id == summary.id else { return }
            let motionPresent = watchMotionCaptureStore.hasLinkedCapture(
                sessionID: summary.sidecar.sessionID,
                takeID: summary.sidecar.takeID
            )
            captureStore.handleRecordingFinished(
                summary: summary,
                audioPresent: audioPresent,
                motionPresent: motionPresent,
                calibrationValid: calibrationValid,
                scratchAudioURL: scratchAudioURL
            )
        }
    }

    private func refreshReviewMotionAssociation() {
        guard let review = captureStore.review,
              watchMotionCaptureStore.hasLinkedCapture(
                sessionID: review.summary.sidecar.sessionID,
                takeID: review.summary.sidecar.takeID
              ) else { return }
        captureStore.markReviewMotionPresent()
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
            // Prefer the take's own live-rendered scratch capture; if it
            // never started or failed, `audioArtifactURL: nil` falls back to
            // the existing camera-audio-derived source exactly as before.
            let scratchAudioURL: URL? = {
                guard let url = review.scratchAudioURL,
                      FileManager.default.fileExists(atPath: url.path) else { return nil }
                return url
            }()
            return SessionExportTake(
                takeID: review.summary.sidecar.takeID,
                takeNumber: review.summary.sidecar.appLocalTakeNumber,
                bpm: review.summary.sidecar.sessionConfig?.bpm ?? config.bpm ?? 0,
                mediaURL: review.summary.mediaURL,
                audioArtifactURL: scratchAudioURL,
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
        case .ready: return ScratchLabDesign.Sem.success
        case .warning: return ScratchLabDesign.Sem.warning
        case .blocked: return ScratchLabDesign.Sem.danger
        }
    }

    var badgeVariant: StatusBadgeVariant {
        switch self {
        case .ready: return .success
        case .warning: return .warning
        case .blocked: return .danger
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
            case .success: return ScratchLabDesign.Sem.success
            case .warning: return ScratchLabDesign.Sem.warning
            }
        }

        var badgeVariant: StatusBadgeVariant {
            switch self {
            case .success: return .success
            case .warning: return .warning
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
    var syncStatus: String
    let audioPresent: Bool
    var motionStatusTitle: String
    var motionPresent: Bool
    let operatorMessage: String
    var quality: CaptureQualityTag?
    var isComboTagged: Bool = false
    /// The rendered-scratch WAV captured for this take, if the capture tap
    /// started and produced a file. `nil` means no live-rendered scratch
    /// audio was recorded for this take (capture never started, or failed) —
    /// export falls back to its existing camera-audio-derived source.
    var scratchAudioURL: URL?
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
        calibrationValid: Bool,
        scratchAudioURL: URL? = nil
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
            operatorMessage: operatorMessage,
            scratchAudioURL: scratchAudioURL
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

    func markReviewMotionPresent() {
        guard var review, !review.motionPresent else { return }
        let assessment = GuidedCaptureReviewStateResolver.motionAssessment(
            calibrationValid: isCalibrationConfirmed,
            audioPresent: review.audioPresent,
            motionPresent: true,
            motionSkipped: motionSkipped,
            motionOptional: sessionSetup.drillMode.motionOptional
        )
        review.syncStatus = assessment.syncStatus
        review.motionStatusTitle = assessment.motionStatusTitle
        review.motionPresent = assessment.motionPresent
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
        VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.cardSection) {
            VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.xs) {
                Text(title)
                    .font(ScratchLabDesign.Typo.display)
                    .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

                if let subtitle {
                    Text(subtitle)
                        .font(ScratchLabDesign.Typo.pageSubtitle)
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
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
                                    .font(ScratchLabDesign.Typo.cardHeading)
                                    .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

                                Spacer()

                                Button(action: onStartNewSession) {
                                    Text("New Session")
                                }
                                    .scratchLabTertiaryButton()
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
                                .font(ScratchLabDesign.Typo.cardHeading)
                                .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

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
                    .font(ScratchLabDesign.Typo.cardHeading)
                    .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                    .tint(ScratchLabDesign.Sem.textPrimary)
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
                                    .font(ScratchLabDesign.Typo.label)
                                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)

                                Text(BeatEngineMode.silent.title)
                                    .font(ScratchLabDesign.Typo.bodyDefault)
                                    .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(ScratchLabDesign.Card.compactPadding)
                                    .background(ScratchLabDesign.Surface.raised, in: RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous))
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
                                .font(ScratchLabDesign.Typo.label)
                                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)

                            TextField("Add a short note", text: $notes, axis: .vertical)
                                .font(ScratchLabDesign.Typo.bodyDefault)
                                .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                                .padding(ScratchLabDesign.Card.compactPadding)
                                .background(ScratchLabDesign.Surface.raised, in: RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous))
                                .lineLimit(3...5)
                        }
                    }
                }

                if let validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.circle.fill")
                        .font(ScratchLabDesign.Typo.sectionLabel)
                        .foregroundStyle(ScratchLabDesign.Sem.warning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button("Continue", action: onContinue)
                    .scratchLabSuccessButton(fillsWidth: true)
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
                        .font(ScratchLabDesign.Typo.bodyDefault.weight(.semibold))
                        .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

                    Text(subtitle)
                        .font(ScratchLabDesign.Typo.label)
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                }

                Spacer(minLength: 12)

                if let actionLabel {
                    Text(actionLabel)
                        .font(ScratchLabDesign.Typo.statusPill)
                        .foregroundStyle(ScratchLabDesign.Sem.success)
                }
            }

            Text(detail)
                .font(ScratchLabDesign.Typo.technical)
                .foregroundStyle(ScratchLabDesign.Sem.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ScratchLabDesign.Card.compactPadding)
        .background(ScratchLabDesign.Surface.raised, in: RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.compactPanel, style: .continuous))
    }
}

private struct CaptureTempoEditor: View {
    @Binding var bpmText: String

    let presetBPMs: [Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Timed capture")
                .font(ScratchLabDesign.Typo.label)
                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)

            HStack(spacing: ScratchLabDesign.Spacing.sm) {
                ForEach(presetBPMs, id: \.self) { bpm in
                    Chip("\(bpm)", isSelected: Int(bpmText) == bpm, isNumeric: true) {
                        bpmText = String(bpm)
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            TextField("Custom BPM (60–140)", text: $bpmText)
                .keyboardType(.numberPad)
                .font(ScratchLabDesign.Typo.bodyDefault)
                .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                .padding(ScratchLabDesign.Card.compactPadding)
                .background(ScratchLabDesign.Surface.raised, in: RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous))
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
                            .font(ScratchLabDesign.Typo.sectionLabel)
                            .foregroundStyle(ScratchLabDesign.Sem.warning)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button(hasRunCheck ? "Recheck" : "Start Setup Check", action: hasRunCheck ? onRecheck : onStartCheck)
                        .scratchLabSuccessButton(fillsWidth: true)

                    if hasBlockingIssue {
                        CaptureSecondaryButton(title: "Fix Issues", action: onFixIssues)
                    } else if needsSessionSetup {
                        CaptureSecondaryButton(title: "Complete Session Setup", action: onCompleteSessionSetup)
                    }

                    Button(action: onBeginCapture) {
                        Text("Open Record Controls")
                    }
                        .scratchLabPrimaryButton(fillsWidth: true)

                    if canSkipMotion {
                        CaptureSecondaryButton(title: "Skip Motion", action: onSkipMotion)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A camera/deck preview paired with a control row, sized by the widescreen
/// vs. tall shape of the space it's given (raw width/height comparison,
/// rather than horizontal/vertical size class, because iPad reports the same
/// regular/regular size classes in both orientations). Wide: preview fills
/// the available height with controls beside it in a fixed-width column.
/// Tall: preview dominates, controls sit in a footer below it.
private struct CameraCalibrationAdaptiveLayout<Controls: View>: View {
    let preview: CalibrationPreviewCard
    @ViewBuilder let controls: (_ isWide: Bool) -> Controls

    var body: some View {
        GeometryReader { proxy in
            let isWide = proxy.size.width > proxy.size.height
            if isWide {
                HStack(alignment: .top, spacing: 16) {
                    preview
                    controls(true)
                        .frame(width: 220)
                }
            } else {
                VStack(spacing: 16) {
                    preview
                    controls(false)
                }
            }
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
        CameraCalibrationAdaptiveLayout(
            preview: CalibrationPreviewCard(
                session: session,
                videoRotationAngle: videoRotationAngle,
                calibrationProfile: $calibrationProfile,
                allowsEditing: true
            )
        ) { isWide in
            let stack = isWide ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
            stack {
                CaptureSecondaryButton(title: "Adjust Guides", action: onAdjustGuides)

                Button("Confirm Camera", action: onConfirmCamera)
                    .scratchLabSuccessButton(fillsWidth: true)
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
                        .font(ScratchLabDesign.Typo.label)
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)

                    Text(selectedInputName)
                        .font(ScratchLabDesign.Typo.title2)
                        .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Live meter")
                            .font(ScratchLabDesign.Typo.label)
                            .foregroundStyle(ScratchLabDesign.Sem.textSecondary)

                        ProgressView(value: normalizedLevel)
                            .tint(isClipping ? ScratchLabDesign.Sem.danger : ScratchLabDesign.Sem.success)

                        HStack {
                            Text(canUseInput ? "Signal present" : "No signal yet")
                                .font(ScratchLabDesign.Typo.bodySmall)
                                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)

                            Spacer()

                            Text(isClipping ? "Clipping" : "Healthy")
                                .font(ScratchLabDesign.Typo.statusPill)
                                .foregroundStyle(isClipping ? ScratchLabDesign.Sem.textError : ScratchLabDesign.Sem.textSuccess)
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
            }
            .scratchLabSecondaryButton(fillsWidth: true)

            HStack(spacing: 12) {
                Button("Use This Input", action: onUseThisInput)
                    .scratchLabSuccessButton(fillsWidth: true)
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
                            .font(ScratchLabDesign.Typo.sectionTitle)
                            .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

                        Spacer()

                        StatusBadge(
                            title: "",
                            value: isConnected ? "Ready" : "Warning",
                            variant: isConnected ? .success : .warning
                        )
                    }

                    Text(connectionSummary)
                        .font(ScratchLabDesign.Typo.pageSubtitle)
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Last sample")
                            .font(ScratchLabDesign.Typo.label)
                            .foregroundStyle(ScratchLabDesign.Sem.textSecondary)

                        Text(lastSampleText)
                            .font(ScratchLabDesign.Typo.bodyDefault)
                            .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Movement activity")
                            .font(ScratchLabDesign.Typo.label)
                            .foregroundStyle(ScratchLabDesign.Sem.textSecondary)

                        ProgressView(value: activityLevel)
                            .tint(ScratchLabDesign.Sem.motion)
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
        CameraCalibrationAdaptiveLayout(
            preview: CalibrationPreviewCard(
                session: session,
                videoRotationAngle: videoRotationAngle,
                calibrationProfile: $calibrationProfile,
                allowsEditing: true
            )
        ) { isWide in
            let stack = isWide ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
            VStack(spacing: 12) {
                stack {
                    Button("Save Calibration", action: onSave)
                        .scratchLabSuccessButton(fillsWidth: true)

                    CaptureSecondaryButton(title: "Reset", action: onReset)
                }

                if hasStoredCalibration {
                    CaptureSecondaryButton(title: "Use Previous Calibration", action: onUsePrevious)
                }
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
        GeometryReader { proxy in
            if proxy.size.width > proxy.size.height {
                landscapeBody
            } else {
                portraitBody
            }
        }
    }

    /// Preview dominates; status and controls stack in a footer below it.
    private var portraitBody: some View {
        VStack(spacing: 16) {
            headerBlock
            if showsRecordingIndicator { recordingIndicator }
            previewStack
            if flowState == .recording || flowState == .saving {
                if let warningText { WarningBannerView(text: warningText) }
                metricsRow
            }
            controlsBlock
        }
    }

    /// Header and status/helper text run full width above and below a
    /// preview/controls HStack, so the control rail stays controls-only —
    /// matching the rail CameraSetupView and CalibrationSetupView use in
    /// landscape — instead of carrying text that only that rail's narrow
    /// width would force to wrap or clip. This keeps the same fixed →
    /// flexible → fixed sandwich shape portraitBody already relies on, with
    /// the flexible preview never the first or only child of its stack.
    private var landscapeBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerBlock
            if showsRecordingIndicator { recordingIndicator }

            HStack(alignment: .top, spacing: 16) {
                previewStack
                controlsOnlyBlock
                    .frame(width: 220)
            }

            if flowState == .recording || flowState == .saving {
                if let warningText { WarningBannerView(text: warningText) }
                metricsRow
            } else {
                helperText
            }
        }
    }

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(sessionLabel) · Take \(String(format: "%03d", takeNumber))")
                .font(ScratchLabDesign.Typo.sectionTitle)
                .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

            Text(readinessSummary)
                .font(ScratchLabDesign.Typo.bodySmall)
                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var recordingIndicator: some View {
        HStack(spacing: 10) {
            Image(systemName: flowState == .saving ? "waveform.circle.fill" : "record.circle.fill")
                .font(ScratchLabDesign.Typo.sectionTitle)
                .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

            VStack(alignment: .leading, spacing: 2) {
                Text(flowState == .saving ? "Finishing Recording" : "Recording")
                    .font(ScratchLabDesign.Typo.controlValue)
                    .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

                Text(clickTrackStatusText ?? "ScratchLab is actively capturing this take.")
                    .font(ScratchLabDesign.Typo.label)
                    .foregroundStyle(ScratchLabDesign.Sem.textPrimary.opacity(0.82))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            flowState == .saving ? ScratchLabDesign.Sem.warning : ScratchLabDesign.Sem.danger,
            in: RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.panel, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(flowState == .saving
            ? "Finishing recording. ScratchLab is still capturing this take."
            : (clickTrackStatusText == nil
                ? "Recording. ScratchLab is actively capturing this take."
                : "Recording. Click track on. ScratchLab is actively capturing this take."))
    }

    private var previewStack: some View {
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
                        .fill(ScratchLabDesign.Surface.scrim)
                        .frame(width: 140, height: 140)

                    VStack(spacing: 8) {
                        Text("Count-in")
                            .font(ScratchLabDesign.Typo.statusPill)
                            .foregroundStyle(ScratchLabDesign.Sem.textSecondary)

                        Text("\(preRollCount)")
                            .font(ScratchLabDesign.Typo.largeScore)
                            .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

                        Text("Get ready")
                            .font(ScratchLabDesign.Typo.controlValue)
                            .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                    }
                }
            }
        }
    }

    private var metricsRow: some View {
        HStack(spacing: 12) {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                CaptureMetricView(title: "Elapsed", value: elapsedTimeText(now: context.date))
            }
            CaptureMetricView(title: "Audio", value: audioStateText)
            CaptureMetricView(title: "Motion", value: motionStateText)
            CaptureMetricView(title: "Health", value: captureHealthText)
        }
    }

    /// Full control stack: primary action button, plus (when idle) the
    /// helper sentence and the Recheck Setup button.
    private var controlsBlock: some View {
        VStack(spacing: 12) {
            primaryActionButton
            if flowState != .recording, flowState != .saving, flowState != .preRoll {
                helperText
                CaptureSecondaryButton(title: "Recheck Setup", action: onRecheck)
                    .keyboardShortcut("k", modifiers: [])
            }
        }
    }

    /// Same as `controlsBlock` but without the helper sentence, for layouts
    /// (landscape) that show that sentence elsewhere at full width instead
    /// of wrapped inside a narrow control rail.
    private var controlsOnlyBlock: some View {
        VStack(spacing: 12) {
            primaryActionButton
            if flowState != .recording, flowState != .saving, flowState != .preRoll {
                CaptureSecondaryButton(title: "Recheck Setup", action: onRecheck)
                    .keyboardShortcut("k", modifiers: [])
            }
        }
    }

    private var primaryActionButton: some View {
        Group {
            if flowState == .recording || flowState == .saving {
                Button(flowState == .saving ? "Saving..." : "Stop Take", action: onStop)
                    .scratchLabDestructiveButton(fillsWidth: true)
                    .disabled(flowState == .saving)
                    .keyboardShortcut(.space, modifiers: [])
            } else if flowState == .preRoll {
                Button("Starting...", action: {})
                    .scratchLabSuccessButton(fillsWidth: true)
                    .disabled(true)
            } else {
                if canStartTake {
                    Button("Record Take", action: onStart)
                        .scratchLabSuccessButton(fillsWidth: true)
                        .keyboardShortcut(.space, modifiers: [])
                } else {
                    Button("Record Take", action: onStart)
                        .scratchLabWarningButton(fillsWidth: true)
                        .keyboardShortcut(.space, modifiers: [])
                }
            }
        }
    }

    private var helperText: some View {
        Text(canStartTake
             ? "Pause briefly before starting. Perform one scratch type only."
             : "Preview is live. Tap Record Take to jump to the remaining setup issue.")
            .font(ScratchLabDesign.Typo.bodySmall)
            .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
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
                            .font(ScratchLabDesign.Typo.keyMetric)
                            .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

                        LazyVGrid(columns: reviewColumns, spacing: 10) {
                            ReadinessPill(title: review.syncStatus, variant: review.syncStatus == "Ready" ? .success : .warning)
                            ReadinessPill(title: review.audioPresent ? "Audio Present" : "Missing Audio", variant: review.audioPresent ? .success : .danger)
                            ReadinessPill(title: review.motionStatusTitle, variant: review.motionPresent ? .success : .warning)
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
                            .font(ScratchLabDesign.Typo.sectionLabel)
                            .foregroundStyle(ScratchLabDesign.Sem.textSecondary)

                        LazyVGrid(columns: qualityColumns, spacing: 10) {
                            ForEach(CaptureQualityTag.allCases) { quality in
                                Chip(quality.title, isSelected: review.quality == quality) {
                                    onSelectQuality(quality)
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }

                        Button(action: onToggleCombo) {
                            HStack {
                                Image(systemName: review.isComboTagged ? "checkmark.square.fill" : "square")
                                Text("Tag as Combo")
                            }
                            .font(ScratchLabDesign.Typo.controlValue)
                            .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                        }
                    }
                }

                HStack(spacing: 12) {
                    Button("Keep", action: onKeep)
                        .scratchLabSuccessButton(fillsWidth: true)

                    Button("Retry", action: onRetry)
                        .scratchLabSecondaryButton(fillsWidth: true)
                        .keyboardShortcut("r", modifiers: [])
                }

                HStack(spacing: 12) {
                    Button("Discard", action: onDiscard)
                        .scratchLabDestructiveButton(fillsWidth: true)
                        .keyboardShortcut("d", modifiers: [])

                    Button("Keep and Next", action: onKeepAndNext)
                        .scratchLabPrimaryButton(fillsWidth: true)
                        .keyboardShortcut(.return, modifiers: [])
                }
            }
            .padding(.bottom, 24)
        }
    }

    private var reviewColumns: [GridItem] {
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
                .font(ScratchLabDesign.Typo.label)
                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)

            Text(value)
                .font(ScratchLabDesign.Typo.title3)
                .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
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
                        .font(ScratchLabDesign.Typo.keyMetric)
                        .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

                    Text("Keep the loop moving or reset the block before the next take.")
                        .font(ScratchLabDesign.Typo.pageSubtitle)
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            #if DEBUG
            if showsUploadSection {
                CaptureCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Upload Session")
                            .font(ScratchLabDesign.Typo.sectionTitle)
                            .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

                        Text(uploadJob?.statusText ?? (uploadAvailable ? "Ready to upload" : uploadAvailabilityText ?? "Upload isn't available right now."))
                            .font(ScratchLabDesign.Typo.pageSubtitle)
                            .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("\(sessionName) · \(takeCount) take\(takeCount == 1 ? "" : "s")")
                            .font(ScratchLabDesign.Typo.label)
                            .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if let uploadJob, uploadJob.fileSizeBytes > 0 {
                            Text(uploadJob.formattedFileSize)
                                .font(ScratchLabDesign.Typo.technical)
                                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        if let progressFraction = uploadJob?.progressFraction {
                            ProgressView(value: progressFraction)
                                .tint(ScratchLabDesign.Sem.success)
                        } else if uploadJob?.state == .preparing || uploadJob?.state == .requestingUploadURL {
                            ProgressView()
                                .tint(ScratchLabDesign.Sem.success)
                        }

                        Button(uploadJob?.state == .completed ? "Uploaded" : "Upload Session", action: onUploadSession)
                            .scratchLabSuccessButton(fillsWidth: true)
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
            #endif

            CaptureCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Share Session")
                        .font(ScratchLabDesign.Typo.sectionTitle)
                        .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

                    Text(exportStatusText ?? "Export this session as a ZIP archive.")
                        .font(ScratchLabDesign.Typo.pageSubtitle)
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Export mix")
                            .font(ScratchLabDesign.Typo.label)
                            .foregroundStyle(ScratchLabDesign.Sem.textSecondary)

                        #if DEBUG
                        Picker("Export mix", selection: $exportMixMode) {
                            ForEach(ExportMixMode.appReviewVisibleModes) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(.white)
                        #else
                        Text(ExportMixMode.scratchOnly.title)
                            .font(ScratchLabDesign.Typo.controlValue)
                            .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                            .onAppear {
                                exportMixMode = .scratchOnly
                            }
                        #endif
                    }

                    if !exportBlockingIssues.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(exportBlockingIssues, id: \.self) { issue in
                                Text("• \(issue)")
                                    .font(ScratchLabDesign.Typo.label)
                                    .foregroundStyle(ScratchLabDesign.Sem.textError)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    if let exportSummaryText {
                        Text(exportSummaryText)
                            .font(ScratchLabDesign.Typo.technical)
                            .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if let exportWarningText {
                        Text(exportWarningText)
                            .font(ScratchLabDesign.Typo.label)
                            .foregroundStyle(ScratchLabDesign.Sem.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let timingWarningText {
                        Text(timingWarningText)
                            .font(ScratchLabDesign.Typo.label)
                            .foregroundStyle(ScratchLabDesign.Sem.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button(isExporting ? "Preparing..." : "Share Session", action: onShareSession)
                        .scratchLabPrimaryButton(fillsWidth: true)
                        .disabled(isExporting || !canShare)
                }
            }

            Button("Next Take", action: onNextTake)
                .scratchLabSuccessButton(fillsWidth: true)
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
            .scratchLabCard(.standard)
    }
}

private struct CaptureTextField: View {
    let title: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default

    var body: some View {
        VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.sm) {
            Text(title)
                .font(ScratchLabDesign.Typo.label)
                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)

            TextField(title, text: $text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .font(ScratchLabDesign.Typo.bodyDefault)
                .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                .padding(ScratchLabDesign.Card.compactPadding)
                .background(
                    ScratchLabDesign.Surface.raised,
                    in: RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous)
                        .stroke(ScratchLabDesign.Border.default, lineWidth: 1)
                }
        }
    }
}

private struct CapturePickerField: View {
    let title: String
    let selectionTitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.sm) {
                Text(title)
                    .font(ScratchLabDesign.Typo.label)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)

                HStack {
                    Text(selectionTitle)
                        .font(ScratchLabDesign.Typo.bodyDefault)
                        .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(ScratchLabDesign.Typo.label)
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                }
                .padding(ScratchLabDesign.Card.compactPadding)
                .background(
                    ScratchLabDesign.Surface.raised,
                    in: RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous)
                        .stroke(ScratchLabDesign.Border.default, lineWidth: 1)
                }
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
                    .listRowBackground(ScratchLabDesign.Surface.canvas)
            }
            .scrollContentBackground(.hidden)
            .background(ScratchLabDesign.Surface.canvas)
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
            HStack(spacing: ScratchLabDesign.Spacing.md) {
                Text(title)
                    .font(ScratchLabDesign.Typo.title3)
                    .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(ScratchLabDesign.Typo.sectionTitle)
                        .foregroundStyle(ScratchLabDesign.Sem.accent)
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
            HStack(spacing: ScratchLabDesign.Spacing.itemRow) {
                Circle()
                    .fill(result.status.color)
                    .frame(width: 12, height: 12)

                VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.xxs) {
                    Text(result.kind.title)
                        .font(ScratchLabDesign.Typo.title3)
                        .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

                    Text(result.detail)
                        .font(ScratchLabDesign.Typo.pageSubtitle)
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                }

                Spacer()

                StatusBadge(
                    title: "",
                    value: result.status.label,
                    variant: result.status.badgeVariant
                )
            }
        }
    }
}

private struct CaptureSecondaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .scratchLabSecondaryButton(fillsWidth: true)
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
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous)
                .stroke(ScratchLabDesign.Border.default, lineWidth: 1)
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
            RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.panel)
                .stroke(role.color.opacity(0.92), lineWidth: allowsEditing ? 3 : 2)
                .background(
                    RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.panel)
                        .fill(role.color.opacity(0.12))
                )

            Text(role.title)
                .font(ScratchLabDesign.Typo.statusPill)
                .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                .padding(.horizontal, ScratchLabDesign.Spacing.controlGap)
                .padding(.vertical, ScratchLabDesign.Spacing.xs)
                .background(ScratchLabDesign.Surface.scrim, in: Capsule())
                .padding(8)

            if allowsEditing {
                Circle()
                    .fill(role.color)
                    .frame(width: 28, height: 28)
                    .overlay(
                        Circle()
                            .stroke(ScratchLabDesign.Sem.textPrimary.opacity(0.92), lineWidth: 2)
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
        VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.componentCompact) {
            Text(title)
                .font(ScratchLabDesign.Typo.caption)
                .foregroundStyle(ScratchLabDesign.Sem.textTertiary)

            Text(value)
                .font(ScratchLabDesign.Typo.controlValue)
                .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, ScratchLabDesign.Spacing.md)
        .padding(.vertical, ScratchLabDesign.Spacing.controlGap)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ScratchLabDesign.Surface.raised,
            in: RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous)
                .stroke(ScratchLabDesign.Border.default, lineWidth: 1)
        }
    }
}

private struct WarningBannerView: View {
    let text: String

    var body: some View {
        HStack(spacing: ScratchLabDesign.Spacing.controlGap) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(ScratchLabDesign.Sem.warning)

            Text(text)
                .font(ScratchLabDesign.Typo.sectionLabel)
                .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

            Spacer(minLength: 0)
        }
        .padding(ScratchLabDesign.Card.compactPadding)
        .background(
            ScratchLabDesign.Surface.surface,
            in: RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous)
                .stroke(ScratchLabDesign.Border.warning, lineWidth: 1)
        }
    }
}

private struct CaptureBannerView: View {
    let banner: CaptureBanner

    var body: some View {
        HStack(spacing: ScratchLabDesign.Spacing.md) {
            Circle()
                .fill(banner.tone.color)
                .frame(width: 10, height: 10)

            Text(banner.message)
                .font(ScratchLabDesign.Typo.controlValue)
                .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, ScratchLabDesign.Spacing.lg)
        .padding(.vertical, ScratchLabDesign.Spacing.md)
        .background(
            ScratchLabDesign.Surface.overlay,
            in: RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous)
                .stroke(ScratchLabDesign.Border.default, lineWidth: 1)
        )
    }
}

private struct ReadinessPill: View {
    let title: String
    let variant: StatusBadgeVariant

    var body: some View {
        StatusBadge(title: "", value: title, variant: variant)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CaptureDetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(ScratchLabDesign.Typo.sectionLabel)
                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)

            Spacer()

            Text(value)
                .font(ScratchLabDesign.Typo.bodySmall)
                .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
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
                    ScratchLabDesign.Surface.subtleFill
                    Image(systemName: "video")
                        .font(ScratchLabDesign.Typo.display)
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                }
                .task {
                    await loadThumbnail()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous)
                .stroke(ScratchLabDesign.Border.default, lineWidth: 1)
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
