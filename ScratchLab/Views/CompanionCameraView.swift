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
    @State private var captureLiveNotationEvents: [CaptureCore.DetectedNotationRecordMovementEvent] = []
    @State private var captureLiveFaderEvents: [CaptureCore.DetectedNotationFaderEvent] = []
    @State private var captureNotationBaselineTime: TimeInterval?
    /// The single finalization timer. `CaptureFinalizationMachine` is the only
    /// thing that arms it, and scheduling replaces any previous deadline, so a
    /// second watchdog cannot appear alongside it.
    @State private var finalizationScheduler = CaptureFinalizationDeadlineScheduler()
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
    @EnvironmentObject private var midiControllerDispatcher: IOSMIDIControllerDispatcher
    @Environment(\.dismiss) private var dismiss
    @State private var isShowingHardwareSetup = false

    private let scratches = ScratchLibrary.shared.allScratches.sorted { $0.name < $1.name }

    /// Presentation-only target for the live camera HUD. This reuses the
    /// canonical registry and materializer already used by Practice; it does
    /// not create a second notation path or write into capture evidence.
    private var captureTargetNotation: ScratchNotation? {
        guard let pattern = ScratchNotation.canonicalBeatPattern(
            forScratchID: captureStore.sessionSetup.scratchTypeID
        ) else { return nil }
        return pattern.materialized(
            bpm: Double(
                captureStore.sessionSetup.bpmValue
                    ?? CaptureClickTrackDefaults.defaultTimedBPM
            )
        )
    }

    var body: some View {
        makeBody()
    }

    private var contentView: some View {
        GeometryReader { proxy in
            let isLandscape = proxy.size.width > proxy.size.height
            let topPadding: CGFloat = isLandscape ? 8 : 12
            let bottomPadding: CGFloat = isLandscape ? 8 : 16
            let horizontalPadding = isLandscape ? 12.0 : 20.0
            let usesImmersiveCameraLayout = isImmersiveCaptureFlow && isLandscape

            ZStack(alignment: .top) {
                ScratchLabDesign.Surface.applicationBackground
                .ignoresSafeArea()

                if usesImmersiveCameraLayout {
                    currentScreen
                        .ignoresSafeArea()
                } else {
                    currentScreen
                        .padding(.horizontal, horizontalPadding)
                        .padding(.bottom, bottomPadding)
                        .padding(.top, topPadding)
                }

                if let banner = captureStore.banner {
                    CaptureBannerView(banner: banner)
                        .padding(.top, topPadding)
                        .padding(.horizontal, horizontalPadding)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .toolbar(usesImmersiveCameraLayout ? .hidden : .visible, for: .navigationBar)
            .toolbarBackground(usesImmersiveCameraLayout ? .hidden : .visible, for: .navigationBar)
        }
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
        .sheet(isPresented: $isShowingHardwareSetup) {
            CaptureHardwareSetupView(
                availableAudioInputs: broadcaster.availableAudioInputs,
                selectedAudioInputID: broadcaster.selectedAudioInputID,
                activeAudioInputName: broadcaster.activeAudioInputName,
                onSelectAudioInput: { option in
                    selectAudioInput(option)
                },
                onRetestAudio: {
                    retestSelectedAudioInput()
                }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
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

    private var isImmersiveCaptureFlow: Bool {
        switch captureStore.flowState {
        case .cameraSetup, .calibrationSetup, .ready, .preRoll, .recording, .saving:
            return true
        default:
            return false
        }
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
        view = AnyView(view.onReceive(broadcaster.$lastRecordingSummary.compactMap { $0 }) { summary in
            // One of three delivery paths for the same summary. All three end
            // in `handleFinishedRecording`, which is idempotent because the
            // finalization machine accepts exactly one summary per take.
            guard captureStore.matchesActiveSavingTake(summary) else { return }
            handleFinishedRecording(summary)
        })
        view = AnyView(view.onChange(of: captureStore.flowState) { _, newState in
            if newState != .saving {
                finalizationScheduler.cancel()
            }
            if newState == .recording {
                // `beginLinkedRecording` resets the dispatcher's take clock,
                // so the recording owns a fresh 0-based notation timeline.
                captureNotationBaselineTime = nil
                captureLiveNotationEvents.removeAll()
                captureLiveFaderEvents.removeAll()
            } else {
                captureNotationBaselineTime = nil
                captureLiveNotationEvents.removeAll()
                captureLiveFaderEvents.removeAll()
            }
        })
        view = AnyView(view.onReceive(midiControllerDispatcher.$livePlatterMovementEvents) { events in
            guard captureStore.flowState == .recording else { return }
            if let baseline = captureNotationBaselineTime {
                captureLiveNotationEvents = events.filter { $0.endTime > baseline }
            } else {
                captureLiveNotationEvents = events
            }
        })
        view = AnyView(view.onReceive(midiControllerDispatcher.$crossfaderMIDIValue) { _ in
            guard captureStore.flowState == .recording else { return }
            captureLiveFaderEvents = midiControllerDispatcher.capturedCrossfaderEvents
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
                title: "",
                subtitle: nil,
                onBack: { dismiss() },
                trailingAction: hardwareSetupAction
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
                trailingAction: hardwareSetupAction
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
                    onFixIssue: { kind in
                        captureStore.openSetup(for: kind)
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
                title: "",
                subtitle: nil,
                onBack: { captureStore.flowState = .systemCheck },
                trailingAction: hardwareSetupAction
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
                // Figma's iOS audio surface has no trailing toolbar action.
                // Keep the DEBUG staging inspector available from the other
                // capture screens instead of presenting a confusing extra
                // control during input selection.
                trailingAction: nil
            ) {
                AudioSetupView(
                    selectedInputName: broadcaster.selectedAudioInputName,
                    availableInputs: broadcaster.availableAudioInputs,
                    selectedAudioInputID: broadcaster.selectedAudioInputID,
                    inputMonitorState: audioEngine.inputMonitorState,
                    inputLevel: audioEngine.inputLevel,
                    isClipping: audioEngine.inputLevel > 0.18,
                    inputErrorMessage: audioEngine.lastAudioError,
                    onSelectInput: { option in
                        selectAudioInput(option)
                    },
                    onUseThisInput: {
                        confirmSelectedAudioInput()
                    },
                    onTestAgain: {
                        retestSelectedAudioInput()
                    }
                )
            }

        case .motionSetup:
            CaptureScreen(
                title: "Check Motion",
                subtitle: "Make one quick test movement.",
                onBack: { captureStore.flowState = .systemCheck },
                trailingAction: hardwareSetupAction
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
                title: "",
                subtitle: nil,
                onBack: { captureStore.flowState = .systemCheck },
                trailingAction: hardwareSetupAction
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
            CaptureScreen(title: "", subtitle: nil, onBack: { dismiss() }, trailingAction: hardwareSetupAction) {
                CaptureHubView(
                    flowState: captureStore.flowState,
                    sessionLabel: captureStore.sessionSetup.takeHeader,
                    techniqueName: captureStore.sessionSetup.scratchTypeName,
                    bpmLabel: captureStore.sessionSetup.bpmValue.map { "\($0) BPM" } ?? "No beat",
                    modeLabel: captureStore.sessionSetup.drillMode.title,
                    hardwareLabel: broadcaster.selectedAudioInputName,
                    readinessSummary: captureStore.readinessSummaryText,
                    canStartTake: captureStore.canBeginCapture,
                    takeNumber: captureStore.currentTakeNumber(fallback: broadcaster.nextTakeNumberPreview),
                    session: broadcaster.captureSession,
                    videoRotationAngle: broadcaster.videoRotationAngle,
                    calibrationProfile: captureTakeCalibrationBinding,
                    preRollCount: captureStore.preRollCountdown,
                    recordingStartedAt: captureStore.activeTake?.startedAt,
                    recordingStoppedAt: captureStore.activeTake?.stoppedAt,
                    audioStateText: audioStateText,
                    motionStateText: motionStateText,
                    captureHealthText: captureHealthText,
                    targetNotation: captureTargetNotation,
                    liveNotationEvents: captureLiveNotationEvents,
                    liveFaderEvents: captureLiveFaderEvents,
                    notationBPM: Double(captureStore.sessionSetup.bpmValue ?? CaptureClickTrackDefaults.defaultTimedBPM),
                    showsNotationBeatGrid: captureStore.sessionSetup.clickEnabled,
                    warningText: recordingWarningText,
                    onStart: {
                        startTake()
                    },
                    onStop: {
                        stopTake(source: .phone)
                    },
                    onRecheck: {
                        captureStore.flowState = .systemCheck
                        runSystemCheck()
                    },
                    onBack: {
                        dismiss()
                    },
                    onHardwareSetup: {
                        isShowingHardwareSetup = true
                    }
                )
            }

        case .review:
            if let review = captureStore.review {
                CaptureScreen(title: "", subtitle: nil, onBack: { dismiss() }, trailingAction: hardwareSetupAction) {
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
                title: "",
                subtitle: nil,
                onBack: { dismiss() },
                trailingAction: hardwareSetupAction
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

    private var hardwareSetupAction: CaptureScreenAction? {
        CaptureScreenAction(
            title: "Hardware Setup",
            systemImage: "slider.horizontal.3",
            action: { isShowingHardwareSetup = true }
        )
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
        watchMotionCaptureStore.onPhoneCaptureCommand = { payload, completion in
            self.handlePhoneCaptureCommand(payload, completion: completion)
        }
        refreshReadiness()
    }

    private func cleanupFlow() {
        watchMotionCaptureStore.onPhoneCaptureCommand = nil
        finalizationScheduler.cancel()
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

    /// Keeps the capture recorder and the live audio monitor on the same
    /// system input. The broadcaster owns the exact port UID used by the
    /// recording session; `AudioEngine` reuses its existing source-selection
    /// flow so the visible meter follows that route as well.
    private func selectAudioInput(
        _ option: CompanionCameraBroadcaster.AudioInputOption,
        completion: (() -> Void)? = nil
    ) {
        broadcaster.selectedAudioInputID = option.id
        audioEngine.stop()
        audioEngine.selectInputSource(
            audioInputSource(for: option),
            preferredPortUID: option.id
        ) { didSelect in
            guard didSelect else {
                refreshReadiness()
                return
            }

            audioEngine.start()
            syncAnalyzerTarget()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                refreshReadiness()
                completion?()
            }
        }
    }

    private func confirmSelectedAudioInput() {
        guard let option = broadcaster.availableAudioInputs.first(where: {
            $0.id == broadcaster.selectedAudioInputID
        }) else { return }

        selectAudioInput(option) {
            captureStore.flowState = .systemCheck
            runSystemCheck()
        }
    }

    private func retestSelectedAudioInput() {
        if let option = broadcaster.availableAudioInputs.first(where: {
            $0.id == broadcaster.selectedAudioInputID
        }) {
            selectAudioInput(option) {
                runSystemCheck()
            }
        } else {
            audioEngine.start()
            syncAnalyzerTarget()
            runSystemCheck()
        }
    }

    private func audioInputSource(
        for option: CompanionCameraBroadcaster.AudioInputOption
    ) -> AudioInputSource {
        switch option.portType {
        case .usbAudio, .lineIn:
            return .lineIn
        default:
            return .microphone
        }
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

    /// The one Stop transition path.
    ///
    /// The phone Stop button and the Watch Stop command both enter here, so
    /// there is a single place that can move a take into finalization and a
    /// single place that decides what a Stop costs. `CaptureFinalizationMachine`
    /// decides; this function only performs the effects it returns.
    private func stopTake(source: CaptureStopSource) {
        beatEngine.stop()
        // `isRecording` is only true once `AVCaptureFileOutput` has reported
        // didStart. A Stop before that must still reach the recorder, or
        // capture keeps running with no visible UI state.
        let effects = captureStore.requestStopRecording(
            source: source,
            recorderPhase: broadcaster.isRecording ? .recording : .starting
        )
        // Empty means this Stop joined an in-flight finalization: the timer
        // stays frozen at the first accepted Stop and no second deadline,
        // recorder stop, or Watch stop is issued.
        guard !effects.isEmpty else { return }

        if let link = activeWatchCaptureLink {
            watchMotionCaptureStore.requestRemoteCaptureStop(
                sessionID: link.sessionID,
                takeID: link.takeID
            ) { _ in }
            activeWatchCaptureLink = nil
        }
        scratchPlaybackEngine.stopRecordingScratchAudio()
        runFinalizationEffects(effects)
    }

    /// Performs one machine-emitted effect list in the order it was returned.
    /// The ordering is load-bearing: staged media is always preserved before a
    /// recoverable failure is presented.
    private func runFinalizationEffects(_ effects: [CaptureFinalizationEffect]) {
        for effect in effects {
            switch effect {
            case let .freezeElapsedTimer(date):
                captureStore.freezeElapsedTime(at: date)

            case .closeTakeEvidenceWindow:
                // Close the MIDI take window before finalization begins, so
                // controller moves made while the movie is still finalizing
                // cannot land in this take's evidence.
                midiControllerDispatcher.markCaptureStopped()

            case .cancelPendingRecorderStart:
                // Stop arrived while the recorder was still starting. Nothing
                // that a start would have left running may survive it.
                beatEngine.stop()
                scratchPlaybackEngine.stopRecordingScratchAudio()

            case let .scheduleDeadline(date):
                finalizationScheduler.schedule(at: date) {
                    handleFinalizationDeadline()
                }

            case .cancelDeadline:
                finalizationScheduler.cancel()

            case .requestRecorderStop:
                broadcaster.endRecording { summary in
                    guard let summary else {
                        runFinalizationEffects(
                            captureStore.handleFinalizationTimeout(status: broadcaster.recordingStatus)
                        )
                        return
                    }
                    handleFinishedRecording(summary)
                }

            case .completeToReview:
                // The Review transition needs the summary itself, so the
                // delivery site performs it; see `handleFinishedRecording`.
                break

            case .preserveStagedMedia:
                preserveStagedMediaForRecovery()

            case let .presentRecoverableFailure(message):
                captureStore.presentRecoverableFinalizationFailure(message: message)
            }
        }
    }

    /// The one deadline handler. A summary that was already published while
    /// the deadline was pending is consumed here rather than being lost.
    private func handleFinalizationDeadline() {
        if let summary = broadcaster.lastRecordingSummary,
           captureStore.matchesActiveSavingTake(summary) {
            handleFinishedRecording(summary)
            return
        }

        runFinalizationEffects(
            captureStore.applyFinalization(
                .deadlineElapsed(
                    recorderStillRecording: broadcaster.isRecording,
                    status: broadcaster.recordingStatus
                )
            )
        )
    }

    /// Failure must never cost the operator the recording.
    ///
    /// The movie and its sidecar are already staged on disk by the broadcaster
    /// and are not removed on any failure path. This additionally stops the
    /// scratch recorder and detaches the staged stem from the pending slot, so
    /// the file survives on disk for recovery and the next take cannot adopt
    /// another take's stem.
    private func preserveStagedMediaForRecovery() {
        scratchPlaybackEngine.stopRecordingScratchAudio()
        pendingScratchAudioURL = nil
    }

    /// Routes the Watch's Start/Stop button through the same capture actions
    /// used by the iPhone UI. The iPhone remains authoritative for readiness,
    /// pre-roll, take identity, file recording, and finalization.
    private func handlePhoneCaptureCommand(
        _ payload: PhoneCaptureCommandPayload,
        completion: @escaping (WatchCaptureControlReply) -> Void
    ) {
        let sessionID = captureStore.sessionSetup.config.sessionID
        let takeNumber = captureStore.activeTake?.takeNumber ?? broadcaster.nextTakeNumberPreview
        let takeID = CaptureCore.LocalRecordingNaming.takeID(takeNumber: takeNumber)

        func reply(_ state: CaptureWatchSyncState, _ detail: String) {
            completion(
                WatchCaptureControlReply(
                    commandID: payload.commandID,
                    sessionID: sessionID,
                    takeID: takeID,
                    syncState: state,
                    detail: detail,
                    acknowledgedAt: Date()
                )
            )
        }

        switch payload.command {
        case .start:
            if watchMotionCaptureStore.isWatchReachable, captureStore.motionSkipped {
                captureStore.motionSkipped = false
                refreshReadiness()
            }
            guard captureStore.flowState == .ready, captureStore.canBeginCapture else {
                reply(.unavailable, "Finish System Check on iPhone before starting the take from Watch.")
                return
            }
            startTake()
            reply(.requested, "iPhone accepted Start Take. Waiting for the linked recording to begin.")

        case .stop:
            switch captureStore.flowState {
            case .preRoll:
                // Startup, not recording: there is no take to finalize, but
                // every service a start would have armed is stopped so nothing
                // can keep running invisibly behind the cancelled take.
                beatEngine.stop()
                midiControllerDispatcher.markCaptureStopped()
                scratchPlaybackEngine.stopRecordingScratchAudio()
                pendingScratchAudioURL = nil
                runFinalizationEffects(captureStore.armFinalizationForActiveTake())
                captureStore.cancelPendingCapture(message: "Take start cancelled from Watch.")
                reply(.notRequested, "The pending iPhone take was cancelled.")
            case .recording:
                // Identical transition path to the phone Stop button; only the
                // recorded provenance and this reply differ.
                stopTake(source: .watch)
                reply(.requested, "iPhone accepted Stop Take and is saving the recording.")
            case .saving:
                reply(.requested, "The iPhone take is already saving.")
            default:
                reply(.unavailable, "There is no active iPhone take to stop.")
            }
        }
    }

    /// Starts the existing WatchConnectivity capture command with the exact
    /// identity the local recording sidecar will use. Recording remains
    /// available when the watch is optional, skipped, or unreachable.
    private func beginLinkedRecording(captureTiming: CaptureTimingMetadata) {
        broadcaster.recordingSessionConfig = captureStore.sessionSetup.config
        // Retire the previous take's terminal finalization result so this take
        // owns a fresh, take-ID-scoped cycle.
        runFinalizationEffects(captureStore.armFinalizationForActiveTake())
        midiControllerDispatcher.resetCapturedPlatterEvents()
        captureNotationBaselineTime = nil
        captureLiveNotationEvents.removeAll()
        captureLiveFaderEvents.removeAll()

        if !captureStore.motionSkipped, watchMotionCaptureStore.isWatchReachable {
            let sessionID = captureStore.sessionSetup.config.sessionID
            let takeNumber = captureStore.activeTake?.takeNumber ?? broadcaster.nextTakeNumberPreview
            let takeID = CaptureCore.LocalRecordingNaming.takeID(takeNumber: takeNumber)
            let request = WatchCaptureCommandPayload(
                command: .start,
                sessionID: sessionID,
                takeID: takeID
            )
            activeWatchCaptureLink = (sessionID, takeID)
            broadcaster.recordingWatchRequest = request
            watchMotionCaptureStore.requestRemoteCaptureStart(
                sessionID: sessionID,
                takeID: takeID,
                commandID: request.commandID
            ) { reply in
                broadcaster.recordWatchControlReply(reply)
            }
        } else {
            activeWatchCaptureLink = nil
            broadcaster.recordingWatchRequest = nil
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

    private func handleFinishedRecording(_ summary: CompanionCameraBroadcaster.RecordingSummary) {
        // The single idempotent gate. Duplicate recorder callbacks, a
        // re-published summary, and deadline-driven delivery all arrive here;
        // the finalization machine accepts exactly one summary per take, and a
        // summary for any other take is refused before any side effect runs.
        let effects = captureStore.applyFinalization(
            .summaryDelivered(
                take: captureStore.takeKey(for: summary),
                recordingID: summary.id
            )
        )
        guard !effects.isEmpty else { return }
        runFinalizationEffects(effects)

        beatEngine.stop()
        let calibrationValid = captureStore.isCalibrationConfirmed
        let scratchAudioURL = finalizedScratchAudioURL(for: summary)
        pendingScratchAudioURL = nil
        let notationSnapshot = midiControllerDispatcher.detectedNotationSnapshot()
        let persistedSummary: CompanionCameraBroadcaster.RecordingSummary
        do {
            persistedSummary = try broadcaster.persistingDetectedNotation(
                notationSnapshot,
                in: summary
            )
        } catch {
            persistedSummary = summary
            captureStore.reportTakeArtifactIssue(
                "The take was saved, but its controller notation could not be attached: \(error.localizedDescription)"
            )
        }
        if scratchAudioURL == nil {
            captureStore.reportTakeArtifactIssue(
                "The take video was saved, but the rendered AHHH audio file is missing. Retake before export."
            )
        }

        // A completed movie-file callback is sufficient to leave Saving.
        // Track inspection is useful validation, but it must never hold the
        // entire capture state machine hostage on a slow AVAsset load.
        let expectedAudioPresent = persistedSummary.sidecar.recordingStatus == "completed"
            && persistedSummary.sidecar.errorDescription == nil
            && !(persistedSummary.sidecar.audioInputName?.isEmpty ?? true)
        // Resolve motion from the notation this take actually persisted, not
        // from the Watch alone. `persistedSummary.sidecar.detectedNotation` is
        // the same field the recovery/export path reads, so a take reviewed
        // live and the same take rebuilt from disk resolve identically.
        let motionEvidence = CaptureMotionEvidenceResolver.resolve(
            detectedNotation: persistedSummary.sidecar.detectedNotation,
            watchCaptureLinked: watchMotionCaptureStore.hasLinkedCapture(
                sessionID: persistedSummary.sidecar.sessionID,
                takeID: persistedSummary.sidecar.takeID
            )
        )
        captureStore.handleRecordingFinished(
            summary: persistedSummary,
            audioPresent: expectedAudioPresent,
            motionEvidence: motionEvidence,
            calibrationValid: calibrationValid,
            scratchAudioURL: scratchAudioURL
        )

        // Optional and already past Review. It is additionally bounded so a
        // stalled AVAsset load cannot leave an inspection running forever.
        // A timed-out inspection reports nothing: the sidecar-derived value
        // stands, because "the asset was slow to open" is not evidence that
        // the take is silent.
        Task {
            guard let audioPresent = await Self.mediaContainsAudio(
                persistedSummary.mediaURL,
                timeout: captureStore.finalizationBudget.audioInspection
            ) else { return }
            captureStore.updateAudioPresence(audioPresent, forRecordingID: persistedSummary.id)
        }
    }

    /// Gives the scratch stem the same basename as the take's MOV/JSON pair.
    /// Recovery already recognizes same-basename WAVs as owned media, whereas
    /// the old anonymous UUID file was correctly quarantined as an orphan.
    private func finalizedScratchAudioURL(
        for summary: CompanionCameraBroadcaster.RecordingSummary
    ) -> URL? {
        guard let sourceURL = pendingScratchAudioURL,
              FileManager.default.fileExists(atPath: sourceURL.path),
              (try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 0 else {
            return nil
        }
        let destinationURL = summary.sidecarURL
            .deletingPathExtension()
            .appendingPathExtension("wav")
        guard sourceURL != destinationURL else { return sourceURL }
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else { return nil }
        do {
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
            return destinationURL
        } catch {
            return nil
        }
    }

    private func refreshReviewMotionAssociation() {
        guard let review = captureStore.review,
              watchMotionCaptureStore.hasLinkedCapture(
                sessionID: review.summary.sidecar.sessionID,
                takeID: review.summary.sidecar.takeID
              ) else { return }
        captureStore.markReviewWatchMotionLinked()
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

    /// Bounded optional audio inspection. Returns `nil` when the bound was
    /// reached first, which the caller treats as "no new information" rather
    /// than as a silent take.
    private static func mediaContainsAudio(_ url: URL, timeout: TimeInterval) async -> Bool? {
        let inspection = Task.detached(priority: .userInitiated) { () -> Bool? in
            let asset = AVURLAsset(url: url)
            do {
                let tracks = try await asset.loadTracks(withMediaType: .audio)
                return !tracks.isEmpty
            } catch {
                return false
            }
        }

        let deadline = Task.detached(priority: .utility) { () -> Bool? in
            try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            return nil
        }

        let result = await withTaskGroup(of: Bool?.self, returning: Bool?.self) { group in
            group.addTask { await inspection.value }
            group.addTask { await deadline.value }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        inspection.cancel()
        deadline.cancel()
        return result
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
            // Resolve from the take's persisted sidecar notation — the same
            // input `SessionExportCoordinator`'s recovery path uses — so a
            // live-exported take and a recovered one resolve identically.
            // Controller platter evidence counts here even with no Watch.
            let exportMotionEvidence = CaptureMotionEvidenceResolver.resolve(
                detectedNotation: review.summary.sidecar.detectedNotation,
                watchCaptureLinked: linkedWatchCapture != nil
            )
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
                motionPresent: exportMotionEvidence.motionPresent,
                syncStatus: review.syncStatus,
                recordingStatus: review.summary.sidecar.recordingStatus,
                verbalSlateUsed: nil,
                syncClapUsed: nil,
                note: review.operatorMessage,
                captureTiming: review.summary.sidecar.captureTiming,
                motionSources: exportMotionEvidence.motionSources,
                faderMappingSource: exportMotionEvidence.faderMappingSource
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
    var stoppedAt: Date? = nil
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
    var audioPresent: Bool
    /// Typed provenance behind motion presence — which sources actually
    /// supplied evidence. Resolved from this take's persisted sidecar
    /// notation, so it survives into export and recovery unchanged.
    var motionEvidence: CaptureMotionEvidence
    /// The single resolved verdict every review label projects from. Stored as
    /// one value rather than four independently-settable strings so the review
    /// surface cannot render a take as ready and blocked at the same time.
    var reviewState: GuidedCaptureReviewState

    var operatorMessage: String { reviewState.operatorMessage }
    var syncStatus: String { reviewState.syncStatus }
    var motionStatusTitle: String { reviewState.motionStatusTitle }
    var motionPresent: Bool { reviewState.motionPresent }
    var evidenceRows: [CaptureEvidenceRow] {
        CaptureMotionEvidencePresenter.rows(for: motionEvidence)
    }

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
    private var needsNewSessionIdentity = false
    private var cancellables: Set<AnyCancellable> = []

    /// The one authoritative finalization state. Nothing else stores "are we
    /// saving", "did the watchdog already run", or "was this summary already
    /// handled"; `flowState` is a projection of this plus the setup flow.
    @Published private(set) var finalizationState: CaptureFinalizationState = .idle
    private var finalization: CaptureFinalizationMachine
    private let finalizationClock: CaptureFinalizationClock

    var finalizationBudget: CaptureFinalizationBudget { finalization.budget }

    var sessionStartedAt: Date {
        sessionSetup.config.createdAt
    }

    init(
        finalizationBudget: CaptureFinalizationBudget = .default,
        finalizationClock: CaptureFinalizationClock = .system
    ) {
        self.finalization = CaptureFinalizationMachine(budget: finalizationBudget)
        self.finalizationClock = finalizationClock
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

    /// The take key the finalization machine scopes the active cycle to.
    var activeTakeKey: CaptureFinalizationTakeKey? {
        guard let activeTake else { return nil }
        return CaptureFinalizationTakeKey(
            sessionID: sessionSetup.config.sessionID,
            takeNumber: activeTake.takeNumber
        )
    }

    /// The take key a delivered summary belongs to. A summary carries its own
    /// identity, so a summary for another take is recognisable without
    /// consulting the take that happens to be active.
    func takeKey(for summary: CompanionCameraBroadcaster.RecordingSummary) -> CaptureFinalizationTakeKey {
        CaptureFinalizationTakeKey(
            sessionID: summary.sidecar.sessionID,
            takeNumber: summary.sidecar.appLocalTakeNumber
        )
    }

    /// Drives the one finalization machine and republishes its state. The
    /// caller performs the returned effects, in order.
    @discardableResult
    func applyFinalization(_ event: CaptureFinalizationEvent) -> [CaptureFinalizationEffect] {
        let effects = finalization.apply(event, at: finalizationClock.now())
        finalizationState = finalization.state
        return effects
    }

    /// Retires the previous take's terminal result so a new take owns a fresh,
    /// take-ID-scoped cycle.
    func armFinalizationForActiveTake() -> [CaptureFinalizationEffect] {
        guard let key = activeTakeKey else { return [] }
        return applyFinalization(.takeArmedForRecording(take: key))
    }

    func requestStopRecording(
        source: CaptureStopSource,
        recorderPhase: CaptureRecorderPhase
    ) -> [CaptureFinalizationEffect] {
        guard flowState == .recording, let key = activeTakeKey else { return [] }
        return applyFinalization(
            .stopRequested(take: key, source: source, recorderPhase: recorderPhase)
        )
    }

    /// Freezes the visible elapsed readout at the first accepted Stop and
    /// moves the flow into Saving. A later Stop emits no effect, so this can
    /// never run twice for one take.
    func freezeElapsedTime(at date: Date) {
        if var activeTake {
            activeTake.stoppedAt = date
            self.activeTake = activeTake
        }
        flowState = .saving
    }

    func matchesActiveSavingTake(_ summary: CompanionCameraBroadcaster.RecordingSummary) -> Bool {
        finalization.acceptsSummary(for: takeKey(for: summary))
    }

    /// The recorder stated no summary will arrive for this take.
    func handleFinalizationTimeout(status: String) -> [CaptureFinalizationEffect] {
        applyFinalization(.recorderReportedNoSummary(status: status))
    }

    /// The single recoverable-failure presentation. The staged media has
    /// already been preserved by the time this runs.
    func presentRecoverableFinalizationFailure(message: String) {
        showBanner(message: message, tone: .warning)
        activeTake = nil
        flowState = .systemCheck
    }

    func reportTakeArtifactIssue(_ message: String) {
        showBanner(message: message, tone: .warning)
    }

    func handleRecordingFinished(
        summary: CompanionCameraBroadcaster.RecordingSummary,
        audioPresent: Bool,
        motionEvidence: CaptureMotionEvidence,
        calibrationValid: Bool,
        scratchAudioURL: URL? = nil
    ) {
        let duration = max(0, (summary.sidecar.endedAt ?? Date()).timeIntervalSince(summary.sidecar.startedAt))
        let drillName = ScratchLibrary.shared.scratch(byID: sessionSetup.scratchTypeID)?.name ?? sessionSetup.scratchTypeName

        review = CaptureReview(
            summary: summary,
            drillName: drillName,
            duration: duration,
            audioPresent: audioPresent,
            motionEvidence: motionEvidence,
            reviewState: resolvedReviewState(
                recordingFailed: summary.sidecar.recordingStatus == "failed",
                duration: duration,
                calibrationValid: calibrationValid,
                audioPresent: audioPresent,
                motionPresent: motionEvidence.motionPresent
            ),
            scratchAudioURL: scratchAudioURL
        )
        flowState = .review
    }

    /// Single entry point to the shared readiness resolver, so the finish
    /// handler and every later refresh cannot drift apart.
    private func resolvedReviewState(
        recordingFailed: Bool,
        duration: TimeInterval,
        calibrationValid: Bool,
        audioPresent: Bool,
        motionPresent: Bool
    ) -> GuidedCaptureReviewState {
        GuidedCaptureReviewStateResolver.reviewState(
            recordingFailed: recordingFailed,
            duration: duration,
            calibrationValid: calibrationValid,
            audioPresent: audioPresent,
            motionPresent: motionPresent,
            motionSkipped: motionSkipped,
            motionOptional: sessionSetup.drillMode.motionOptional
        )
    }

    func updateAudioPresence(_ audioPresent: Bool, forRecordingID recordingID: String) {
        if var currentReview = review,
           currentReview.summary.id == recordingID,
           finalization.acceptsAudioInspection(forRecordingID: recordingID) {
            applyAudioPresence(audioPresent, to: &currentReview)
            review = currentReview
        }

        if let index = keptReviews.firstIndex(where: { $0.summary.id == recordingID }) {
            var keptReview = keptReviews[index]
            applyAudioPresence(audioPresent, to: &keptReview)
            keptReviews[index] = keptReview
        }
    }

    private func applyAudioPresence(_ audioPresent: Bool, to review: inout CaptureReview) {
        review.audioPresent = audioPresent
        review.reviewState = resolvedReviewState(
            recordingFailed: review.summary.sidecar.recordingStatus == "failed",
            duration: review.duration,
            calibrationValid: isCalibrationConfirmed,
            audioPresent: audioPresent,
            motionPresent: review.motionEvidence.motionPresent
        )
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

    /// A Watch artifact linked after the take finished. Records the Watch as a
    /// source on the existing evidence rather than flipping a bare boolean, so
    /// a take that already had platter evidence keeps it and a Watch-only take
    /// gains the source that actually arrived.
    func markReviewWatchMotionLinked() {
        guard var review, review.motionEvidence.watch != .linked else { return }
        let updatedEvidence = CaptureMotionEvidence(
            platter: review.motionEvidence.platter,
            faderEventCount: review.motionEvidence.faderEventCount,
            watch: .linked,
            dvs: review.motionEvidence.dvs
        )
        review.motionEvidence = updatedEvidence
        review.reviewState = resolvedReviewState(
            recordingFailed: review.summary.sidecar.recordingStatus == "failed",
            duration: review.duration,
            calibrationValid: isCalibrationConfirmed,
            audioPresent: review.audioPresent,
            motionPresent: updatedEvidence.motionPresent
        )
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
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: verticalSizeClass == .compact ? ScratchLabDesign.Spacing.sm : ScratchLabDesign.Spacing.cardSection) {
            if !title.isEmpty {
                if verticalSizeClass == .compact {
                    HStack(alignment: .firstTextBaseline, spacing: ScratchLabDesign.Spacing.md) {
                        Text(title)
                            .font(ScratchLabDesign.Typo.title2)
                            .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

                        if let subtitle {
                            Text(subtitle)
                                .font(ScratchLabDesign.Typo.label)
                                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                                .lineLimit(1)
                        }
                    }
                } else {
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
    @State private var isShowingSessionBrowser = false

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

    private var visibleSetupMessage: String? {
        if let validationMessage { return validationMessage }
        if performerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a performer name to continue."
        }
        if drillID.isEmpty {
            return "Choose a scratch type to continue."
        }
        if captureMode == .timedClick, (Int(bpmText) ?? 0) <= 0 {
            return "Enter a tempo from 60 to 140 BPM to continue."
        }
        return nil
    }

    private var continueAccessibilityHint: String {
        if isContinueEnabled {
            return "Saves this session and opens input readiness"
        }
        return visibleSetupMessage ?? "Complete the required session details before continuing"
    }

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width > proxy.size.height {
                landscapeContent(availableWidth: proxy.size.width)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.xs) {
                    Text("Session Setup")
                        .font(ScratchLabDesign.Typo.display)
                        .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

                    Text("Complete the take details, then check the inputs.")
                        .font(ScratchLabDesign.Typo.pageSubtitle)
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

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
                                if session.id == sessionListPresentation.activeSession?.id {
                                    CaptureSessionSummaryRow(
                                        title: sessionTitle(for: session.session),
                                        subtitle: sessionSubtitle(for: session.session),
                                        detail: sessionDetail(for: session.session),
                                        actionLabel: "Current"
                                    )
                                    .accessibilityHint("This session is already open")
                                } else {
                                    Button(action: { onOpenSession(session.id) }) {
                                        CaptureSessionSummaryRow(
                                            title: sessionTitle(for: session.session),
                                            subtitle: sessionSubtitle(for: session.session),
                                            detail: sessionDetail(for: session.session),
                                            actionLabel: "Open"
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
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

                if let visibleSetupMessage {
                    Label(visibleSetupMessage, systemImage: "exclamationmark.circle.fill")
                        .font(ScratchLabDesign.Typo.sectionLabel)
                        .foregroundStyle(ScratchLabDesign.Sem.warning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button("Continue Setup", action: onContinue)
                    .scratchLabPrimaryButton(fillsWidth: true)
                    .disabled(!isContinueEnabled)
                    .accessibilityHint(continueAccessibilityHint)
            }
                        .padding(.bottom, 32)
                    }
                }
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
        .sheet(isPresented: $isShowingSessionBrowser) {
            CaptureSelectionSheet(title: "All Sessions") {
                ForEach(sessionListPresentation.allSessions) { session in
                    CaptureSelectionRow(
                        title: "\(sessionTitle(for: session.session)) · \(sessionSubtitle(for: session.session))",
                        isSelected: session.id == sessionListPresentation.activeSession?.id,
                        action: {
                            guard session.id != sessionListPresentation.activeSession?.id else { return }
                            onOpenSession(session.id)
                            isShowingSessionBrowser = false
                        }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func landscapeContent(availableWidth: CGFloat) -> some View {
        VStack(spacing: ScratchLabDesign.Spacing.sm) {
            compactLandscapeSessionStrip
            landscapeSetupForm(minimumColumnWidth: availableWidth < 760 ? 132 : 148)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var landscapeSessionRail: some View {
        CaptureCard {
            VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.md) {
                HStack(spacing: ScratchLabDesign.Spacing.sm) {
                    Text("Current Session")
                        .font(ScratchLabDesign.Typo.cardHeading)
                        .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

                    Spacer(minLength: ScratchLabDesign.Spacing.xs)

                    Button("New", action: onStartNewSession)
                        .scratchLabTertiaryButton()
                }

                landscapeSessionIdentity

                Button("All Sessions") {
                    isShowingSessionBrowser = true
                }
                .scratchLabSecondaryButton(fillsWidth: true)
            }
        }
    }

    private var compactLandscapeSessionStrip: some View {
        HStack(spacing: ScratchLabDesign.Spacing.sm) {
            Label("CURRENT", systemImage: "circle.fill")
                .font(ScratchLabDesign.Typo.metricLabel)
                .foregroundStyle(ScratchLabDesign.Sem.accent)
                .labelStyle(.titleAndIcon)

            if let activeSession = sessionListPresentation.activeSession {
                Text(sessionTitle(for: activeSession.session))
                    .font(ScratchLabDesign.Typo.controlValue)
                    .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                    .lineLimit(1)

                Text("· \(sessionSubtitle(for: activeSession.session))")
                    .font(ScratchLabDesign.Typo.label)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                    .lineLimit(1)
            } else {
                Text("New session")
                    .font(ScratchLabDesign.Typo.controlValue)
                    .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
            }

            Spacer(minLength: 0)

            Button("Sessions") {
                isShowingSessionBrowser = true
            }
            .scratchLabTertiaryButton()

            Button("New", action: onStartNewSession)
                .scratchLabTertiaryButton()
        }
        .padding(.horizontal, ScratchLabDesign.Spacing.md)
        .padding(.vertical, ScratchLabDesign.Spacing.xs)
        .background(
            ScratchLabDesign.Surface.raised,
            in: RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous)
                .stroke(ScratchLabDesign.Border.default, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var landscapeSessionIdentity: some View {
        if let activeSession = sessionListPresentation.activeSession {
            VStack(alignment: .leading, spacing: 2) {
                Text(sessionTitle(for: activeSession.session))
                    .font(ScratchLabDesign.Typo.controlValue)
                    .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                    .lineLimit(1)

                Text(sessionSubtitle(for: activeSession.session))
                    .font(ScratchLabDesign.Typo.label)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                    .lineLimit(1)
            }
        } else {
            Text("Set the performer and scratch type for this take.")
                .font(ScratchLabDesign.Typo.bodySmall)
                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                .lineLimit(1)
        }
    }

    private func landscapeSetupForm(minimumColumnWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.sm) {
            HStack(spacing: ScratchLabDesign.Spacing.sm) {
                Text("TAKE DETAILS")
                    .font(ScratchLabDesign.Typo.metricLabel)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)

                Spacer(minLength: ScratchLabDesign.Spacing.sm)

                if let visibleSetupMessage {
                    Label(visibleSetupMessage, systemImage: "exclamationmark.circle.fill")
                        .font(ScratchLabDesign.Typo.label)
                        .foregroundStyle(ScratchLabDesign.Sem.warning)
                        .lineLimit(1)
                }
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: minimumColumnWidth), spacing: ScratchLabDesign.Spacing.xs)],
                alignment: .leading,
                spacing: ScratchLabDesign.Spacing.xs
            ) {
                CaptureTextField(title: "Performer", text: $performerName, isCompact: true)

                CapturePickerField(
                    title: "Scratch Type",
                    selectionTitle: scratches.first(where: { $0.id == drillID })?.name ?? "Choose",
                    action: { activePicker = .scratchType },
                    isCompact: true
                )

                if captureMode == .timedClick {
                    CaptureCompactTempoEditor(bpmText: $bpmText)
                } else {
                    CaptureCompactValueField(title: "Tempo", value: "No beat")
                }

                CapturePickerField(
                    title: "Handedness",
                    selectionTitle: handedness.title,
                    action: { activePicker = .handedness },
                    isCompact: true
                )

                CapturePickerField(
                    title: "Click track",
                    selectionTitle: captureMode.title,
                    action: { activePicker = .captureMode },
                    isCompact: true
                )

                if captureMode == .timedClick {
                    CapturePickerField(
                        title: "Practice beat",
                        selectionTitle: beatEngineMode.title,
                        action: { activePicker = .beatEngineMode },
                        isCompact: true
                    )
                } else {
                    CaptureCompactValueField(title: "Practice beat", value: BeatEngineMode.silent.title)
                }

                CapturePickerField(
                    title: "Deck / mixer",
                    selectionTitle: deckProfile.title,
                    action: { activePicker = .deckProfile },
                    isCompact: true
                )

                CapturePickerField(
                    title: "Camera",
                    selectionTitle: cameraProfile.title,
                    action: { activePicker = .cameraProfile },
                    isCompact: true
                )

                CapturePickerField(
                    title: "Capture Mode",
                    selectionTitle: practiceMode.title,
                    action: { activePicker = .practiceMode },
                    isCompact: true
                )

                CapturePickerField(
                    title: "Watch wrist",
                    selectionTitle: watchWrist.title,
                    action: { activePicker = .watchWrist },
                    isCompact: true
                )

                CaptureTextField(title: "Notes", text: $notes, isCompact: true)
            }

            HStack(spacing: ScratchLabDesign.Spacing.sm) {
                Spacer(minLength: ScratchLabDesign.Spacing.xs)

                Button("Continue Setup", action: onContinue)
                    .scratchLabPrimaryButton(fillsWidth: false)
                    .disabled(!isContinueEnabled)
                    .accessibilityHint(continueAccessibilityHint)
            }
        }
        .padding(ScratchLabDesign.Spacing.sm)
        .background(
            ScratchLabDesign.Surface.surface,
            in: RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous)
                .stroke(ScratchLabDesign.Border.default, lineWidth: 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

    @State private var draftBPM = ""
    @FocusState private var isBPMFocused: Bool

    private let supportedRange = CaptureClickTrackDefaults.supportedBPMRange

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Timed capture")
                .font(ScratchLabDesign.Typo.label)
                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)

            HStack(spacing: ScratchLabDesign.Spacing.sm) {
                ForEach(presetBPMs, id: \.self) { bpm in
                    Chip("\(bpm)", isSelected: Int(draftBPM) == bpm, isNumeric: true) {
                        let value = String(bpm)
                        draftBPM = value
                        bpmText = value
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            TextField(
                "Custom BPM (\(supportedRange.lowerBound)–\(supportedRange.upperBound))",
                text: Binding(
                    get: { draftBPM },
                    set: updateDraftBPM
                )
            )
                .keyboardType(.numberPad)
                .focused($isBPMFocused)
                .font(ScratchLabDesign.Typo.bodyDefault)
                .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                .padding(ScratchLabDesign.Card.compactPadding)
                .background(ScratchLabDesign.Surface.raised, in: RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous))

            if !draftBPM.isEmpty, !isDraftValid {
                Text("Enter a tempo from \(supportedRange.lowerBound) to \(supportedRange.upperBound) BPM.")
                    .font(ScratchLabDesign.Typo.label)
                    .foregroundStyle(ScratchLabDesign.Sem.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            draftBPM = bpmText
        }
        .onChange(of: bpmText) { _, newValue in
            guard !isBPMFocused else { return }
            draftBPM = newValue
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    isBPMFocused = false
                }
            }
        }
    }

    private var isDraftValid: Bool {
        guard let value = Int(draftBPM) else { return false }
        return supportedRange.contains(value)
    }

    private func updateDraftBPM(_ proposedValue: String) {
        let digits = proposedValue.filter(\.isNumber)
        let limitedDigits = String(digits.prefix(3))
        draftBPM = limitedDigits

        guard let value = Int(limitedDigits), supportedRange.contains(value) else {
            // Clear only the persisted binding while the user is between valid
            // multi-digit values. This avoids the model's per-keystroke clamp
            // turning the first digit of "100" into "60".
            bpmText = ""
            return
        }

        bpmText = String(value)
    }
}

private struct CaptureCompactValueField: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.xxs) {
            Text(title)
                .font(ScratchLabDesign.Typo.label)
                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)

            Text(value)
                .font(ScratchLabDesign.Typo.bodyDefault)
                .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                .padding(.horizontal, 10)
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

private struct CaptureCompactTempoEditor: View {
    @Binding var bpmText: String

    @State private var draftBPM = ""
    @FocusState private var isFocused: Bool

    private let supportedRange = CaptureClickTrackDefaults.supportedBPMRange

    var body: some View {
        VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.xxs) {
            Text("Tempo")
                .font(ScratchLabDesign.Typo.label)
                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)

            HStack(spacing: ScratchLabDesign.Spacing.xs) {
                TextField("BPM", text: Binding(get: { draftBPM }, set: updateDraftBPM))
                    .keyboardType(.numberPad)
                    .focused($isFocused)
                    .font(ScratchLabDesign.Typo.bodyDefault)
                    .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                    .accessibilityLabel("Tempo in beats per minute")

                Text("BPM")
                    .font(ScratchLabDesign.Typo.label)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .padding(.horizontal, 10)
            .background(
                ScratchLabDesign.Surface.raised,
                in: RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous)
                    .stroke(isDraftValid ? ScratchLabDesign.Border.default : ScratchLabDesign.Sem.warning, lineWidth: 1)
            }
        }
        .onAppear {
            draftBPM = bpmText
        }
        .onChange(of: bpmText) { _, newValue in
            guard !isFocused else { return }
            draftBPM = newValue
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    isFocused = false
                }
            }
        }
    }

    private var isDraftValid: Bool {
        guard let value = Int(draftBPM) else { return false }
        return supportedRange.contains(value)
    }

    private func updateDraftBPM(_ proposedValue: String) {
        let digits = proposedValue.filter(\.isNumber)
        let limitedDigits = String(digits.prefix(3))
        draftBPM = limitedDigits

        guard let value = Int(limitedDigits), supportedRange.contains(value) else {
            bpmText = ""
            return
        }

        bpmText = String(value)
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
    let onFixIssue: (CaptureCheckKind) -> Void
    let onCompleteSessionSetup: () -> Void
    let onBeginCapture: () -> Void
    let onSkipMotion: () -> Void

    private var hasBlockingIssue: Bool {
        results.contains { $0.status == .blocked }
    }

    private var needsSessionSetup: Bool {
        !hasBlockingIssue && !canBeginCapture && configurationMessage != nil
    }

    private var firstActionableBlockingIssue: CaptureCheckResult? {
        results.first { result in
            result.status == .blocked && result.kind != .storage
        }
    }

    private var hasStorageBlocker: Bool {
        results.contains { $0.status == .blocked && $0.kind == .storage }
    }

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width > proxy.size.height {
                VStack(spacing: ScratchLabDesign.Spacing.sm) {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.flexible(), spacing: ScratchLabDesign.Spacing.sm),
                            count: 3
                        ),
                        spacing: ScratchLabDesign.Spacing.sm
                    ) {
                        ForEach(results) { result in
                            CaptureStatusCard(result: result, isCompact: true)
                        }
                    }

                    landscapeActions
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
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
                                .scratchLabPrimaryButton(fillsWidth: true)

                            if let firstActionableBlockingIssue {
                                CaptureSecondaryButton(title: "Fix \(firstActionableBlockingIssue.kind.title)") {
                                    onFixIssue(firstActionableBlockingIssue.kind)
                                }
                            } else if hasStorageBlocker {
                                Label("Storage unavailable — free space, then recheck", systemImage: "internaldrive.fill")
                                    .font(ScratchLabDesign.Typo.bodySmall)
                                    .foregroundStyle(ScratchLabDesign.Sem.warning)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else if needsSessionSetup {
                                CaptureSecondaryButton(title: "Complete Session Setup", action: onCompleteSessionSetup)
                            }

                            Button(canBeginCapture ? "Open Record Controls" : "Recording unavailable", action: onBeginCapture)
                                .scratchLabPrimaryButton(fillsWidth: true)
                                .disabled(!canBeginCapture)
                                .accessibilityHint(canBeginCapture
                                    ? "Opens the capture-ready screen"
                                    : "Resolve the setup issue shown above before recording")

                            if canSkipMotion {
                                CaptureSecondaryButton(title: "Skip Motion", action: onSkipMotion)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var landscapeActions: some View {
        HStack(spacing: ScratchLabDesign.Spacing.sm) {
            if let configurationMessage, needsSessionSetup {
                Label(configurationMessage, systemImage: "exclamationmark.circle.fill")
                    .font(ScratchLabDesign.Typo.label)
                    .foregroundStyle(ScratchLabDesign.Sem.warning)
                    .lineLimit(2)
            }

            Button(hasRunCheck ? "Recheck" : "Start Check", action: hasRunCheck ? onRecheck : onStartCheck)
                .scratchLabSecondaryButton(fillsWidth: true)

            if let firstActionableBlockingIssue {
                Button("Fix \(firstActionableBlockingIssue.kind.title)") {
                    onFixIssue(firstActionableBlockingIssue.kind)
                }
                .scratchLabSecondaryButton(fillsWidth: true)
            } else if hasStorageBlocker {
                Label("Free storage, then recheck", systemImage: "internaldrive.fill")
                    .font(ScratchLabDesign.Typo.label)
                    .foregroundStyle(ScratchLabDesign.Sem.warning)
            } else if needsSessionSetup {
                Button("Session Setup", action: onCompleteSessionSetup)
                    .scratchLabSecondaryButton(fillsWidth: true)
            }

            Button(canBeginCapture ? "Record Controls" : "Recording unavailable", action: onBeginCapture)
                .scratchLabPrimaryButton(fillsWidth: true)
                .disabled(!canBeginCapture)
                .accessibilityHint(canBeginCapture
                    ? "Opens the capture-ready screen"
                    : "Resolve the setup issue shown above before recording")

            if canSkipMotion {
                Button("Skip Motion", action: onSkipMotion)
                    .scratchLabTertiaryButton()
            }
        }
    }
}

/// A camera/deck preview paired with a control row, sized by the widescreen
/// vs. tall shape of the space it's given (raw width/height comparison,
/// rather than horizontal/vertical size class, because iPad reports the same
/// regular/regular size classes in both orientations). Wide: the complete
/// camera canvas fills the available space and compact controls float over
/// it. Tall: preview dominates, controls sit in a footer below it.
private struct CameraCalibrationAdaptiveLayout<Controls: View>: View {
    let preview: (_ fillsAvailableSpace: Bool) -> CalibrationPreviewCard
    @ViewBuilder let controls: (_ isWide: Bool) -> Controls

    var body: some View {
        GeometryReader { proxy in
            let isWide = proxy.size.width > proxy.size.height
            if isWide {
                ZStack(alignment: .top) {
                    preview(true)
                        .frame(width: proxy.size.width, height: proxy.size.height)

                    controls(true)
                        .frame(width: min(660, max(440, proxy.size.width - 200)))
                        .padding(.horizontal, ScratchLabDesign.Spacing.sm)
                        .padding(.vertical, ScratchLabDesign.Spacing.xs)
                        .background(
                            .ultraThinMaterial,
                            in: RoundedRectangle(
                                cornerRadius: ScratchLabDesign.Radius.control,
                                style: .continuous
                            )
                        )
                        .padding(.top, ScratchLabDesign.Spacing.xs)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            } else {
                VStack(spacing: 16) {
                    preview(false)
                        .frame(maxWidth: .infinity, alignment: .top)
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
            preview: { fillsAvailableSpace in
                CalibrationPreviewCard(
                session: session,
                videoRotationAngle: videoRotationAngle,
                calibrationProfile: $calibrationProfile,
                allowsEditing: true,
                fillsAvailableSpace: fillsAvailableSpace
                )
            }
        ) { isWide in
            if isWide {
                HStack(spacing: ScratchLabDesign.Spacing.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Align Camera")
                            .font(ScratchLabDesign.Typo.cardHeading)
                            .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

                        Text("Fit the decks and mixer inside the guides.")
                            .font(ScratchLabDesign.Typo.label)
                            .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: ScratchLabDesign.Spacing.xs)

                    Button("Adjust Guides", action: onAdjustGuides)
                        .scratchLabSecondaryButton()

                    Button(isCameraReady ? "Confirm Camera" : "Waiting for Camera", action: onConfirmCamera)
                        .scratchLabSuccessButton()
                        .disabled(!isCameraReady)
                        .accessibilityHint(isCameraReady
                            ? "Saves the current camera alignment"
                            : "Unavailable until the camera preview is ready")
                }
            } else {
                VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.md) {
                VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.xs) {
                    Text("Align Camera")
                        .font(ScratchLabDesign.Typo.cardHeading)
                        .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

                    Text("Fit the decks and mixer inside the guides.")
                        .font(ScratchLabDesign.Typo.bodySmall)
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                    HStack(spacing: 12) {
                    CaptureSecondaryButton(title: "Adjust Guides", action: onAdjustGuides)

                    Button(isCameraReady ? "Confirm Camera" : "Waiting for Camera", action: onConfirmCamera)
                        .scratchLabSuccessButton(fillsWidth: true)
                        .disabled(!isCameraReady)
                        .accessibilityHint(isCameraReady
                            ? "Saves the current camera alignment"
                            : "Unavailable until the camera preview is ready")
                    }
                }
            }
        }
    }
}

private struct AudioSetupView: View {
    let selectedInputName: String
    let availableInputs: [CompanionCameraBroadcaster.AudioInputOption]
    let selectedAudioInputID: String
    let inputMonitorState: AudioMonitorState
    let inputLevel: Float
    let isClipping: Bool
    let inputErrorMessage: String?
    let onSelectInput: (CompanionCameraBroadcaster.AudioInputOption) -> Void
    let onUseThisInput: () -> Void
    let onTestAgain: () -> Void

    private var normalizedLevel: Double {
        min(1.0, max(0.0, Double(inputLevel) * 12.0))
    }

    private var canUseInput: Bool {
        !selectedAudioInputID.isEmpty
            && availableInputs.contains(where: { $0.id == selectedAudioInputID })
    }

    private var monitorStatusText: String {
        switch inputMonitorState {
        case .micOff:
            return "Audio monitor off — test again"
        case .micLive:
            return "Listening — scratch the record"
        case .listening:
            return "Signal present"
        case .noSignal:
            return "No signal — test again"
        }
    }

    private var monitorHealthText: String {
        if isClipping { return "Clipping" }
        switch inputMonitorState {
        case .listening:
            return "Healthy"
        case .micLive:
            return "Listening"
        case .micOff, .noSignal:
            return "Waiting"
        }
    }

    private var monitorHealthColor: Color {
        if isClipping { return ScratchLabDesign.Sem.textError }
        return inputMonitorState == .listening
            ? ScratchLabDesign.Sem.textSuccess
            : ScratchLabDesign.Sem.textSecondary
    }

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width > proxy.size.height {
                HStack(spacing: ScratchLabDesign.Spacing.md) {
                    inputSummary
                    VStack(spacing: ScratchLabDesign.Spacing.md) {
                        inputMenu
                        actionButtons
                    }
                    .frame(width: min(320, proxy.size.width * 0.38))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                VStack(spacing: 16) {
                    inputSummary
                    inputMenu
                    actionButtons
                }
            }
        }
    }

    private var inputSummary: some View {
        CaptureCard {
            VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.md) {
                Text("Selected input")
                    .font(ScratchLabDesign.Typo.label)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)

                Text(selectedInputName)
                    .font(ScratchLabDesign.Typo.title2)
                    .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                    .lineLimit(1)

                VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.sm) {
                    Text("Live meter")
                        .font(ScratchLabDesign.Typo.label)
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)

                    ProgressView(value: normalizedLevel)
                        .tint(isClipping ? ScratchLabDesign.Sem.danger : ScratchLabDesign.Sem.success)

                    HStack {
                        Text(monitorStatusText)
                            .font(ScratchLabDesign.Typo.bodySmall)
                            .foregroundStyle(ScratchLabDesign.Sem.textSecondary)

                        Spacer()

                        Text(monitorHealthText)
                            .font(ScratchLabDesign.Typo.statusPill)
                            .foregroundStyle(monitorHealthColor)
                    }
                }

                if let inputErrorMessage {
                    Label(inputErrorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(ScratchLabDesign.Typo.bodySmall)
                        .foregroundStyle(ScratchLabDesign.Sem.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var inputMenu: some View {
        Menu {
            if availableInputs.isEmpty {
                Text("No alternate inputs").disabled(true)
            } else {
                ForEach(availableInputs) { option in
                    Button {
                        onSelectInput(option)
                    } label: {
                        if option.id == selectedAudioInputID {
                            Label(option.displayName, systemImage: "checkmark")
                        } else {
                            Text(option.displayName)
                        }
                    }
                }
            }
        } label: {
            Text(availableInputs.isEmpty ? "No alternate inputs" : "Choose Input")
        }
        .scratchLabSecondaryButton(fillsWidth: true)
        .disabled(availableInputs.isEmpty)
        .accessibilityHint(availableInputs.isEmpty
            ? "No additional audio inputs are currently available"
            : "Selects an available audio input")
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button("Use This Input", action: onUseThisInput)
                .scratchLabSuccessButton(fillsWidth: true)
                .disabled(!canUseInput)
                .accessibilityHint(canUseInput
                    ? "Keeps the selected input and returns to System Check"
                    : "Choose an available audio input first")

            Button("Test Again", systemImage: "arrow.clockwise", action: onTestAgain)
                .scratchLabSecondaryButton(fillsWidth: true)
                .accessibilityHint("Restarts listening on the selected input")
        }
    }
}

private struct CaptureHardwareSetupView: View {
    let availableAudioInputs: [CompanionCameraBroadcaster.AudioInputOption]
    let selectedAudioInputID: String
    let activeAudioInputName: String
    let onSelectAudioInput: (CompanionCameraBroadcaster.AudioInputOption) -> Void
    let onRetestAudio: () -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var audioEngine: AudioEngine
    @EnvironmentObject private var midiManager: IOSMIDIManager
    @EnvironmentObject private var midiLearnCoordinator: IOSMIDILearnCoordinator
    @EnvironmentObject private var midiControllerDispatcher: IOSMIDIControllerDispatcher
    @EnvironmentObject private var scratchPlaybackEngine: IOScratchPlaybackEngine
    @AppStorage(MIDISelectionSettings.selectedSourceIDKey) private var selectedMIDISourceID = ""

    private let verifiedActions: [MIDISemanticAction] = [
        .crossfader,
        .leftUpfader,
        .rightUpfader,
        .hotCue1,
        .hotCue2,
        .hotCue3,
        .hotCue4,
        .hotCue5,
        .hotCue6,
        .hotCue7,
        .hotCue8
    ]

    private var selectedMIDISource: IOSMIDIManager.Source? {
        midiManager.sources.first(where: { $0.id == selectedMIDISourceID })
    }

    private var selectedSourceIsRane: Bool {
        selectedMIDISource?.name.localizedCaseInsensitiveContains("rane") == true
    }

    private var hasVerifiedMapping: Bool {
        verifiedActions.allSatisfy { midiLearnCoordinator.control(for: $0) != nil }
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.cardSection) {
                    VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.xs) {
                        Text("Hardware Setup")
                            .font(ScratchLabDesign.Typo.display)
                            .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

                        Text("Choose the recording input and the MIDI source ScratchLab should map.")
                            .font(ScratchLabDesign.Typo.pageSubtitle)
                            .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                    }

                    audioCard
                    midiCard
                }
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(.horizontal, ScratchLabDesign.Spacing.lg)
                .padding(.bottom, ScratchLabDesign.Spacing.xxl)
            }
            .background(ScratchLabDesign.Surface.applicationBackground.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            midiManager.refreshSources()
        }
    }

    private var audioCard: some View {
        CaptureCard {
            VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.md) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Audio Input")
                        .font(ScratchLabDesign.Typo.cardHeading)
                        .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

                    Spacer()

                    Text(activeAudioInputName)
                        .font(ScratchLabDesign.Typo.statusPill)
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                        .lineLimit(1)
                }

                if availableAudioInputs.isEmpty {
                    Label("No selectable inputs are available. Check microphone permission or reconnect USB-C.", systemImage: "exclamationmark.triangle.fill")
                        .font(ScratchLabDesign.Typo.bodySmall)
                        .foregroundStyle(ScratchLabDesign.Sem.warning)
                } else {
                    VStack(spacing: ScratchLabDesign.Spacing.sm) {
                        ForEach(availableAudioInputs) { option in
                            hardwareSelectionRow(
                                title: option.displayName,
                                detail: audioInputDetail(option),
                                isSelected: option.id == selectedAudioInputID
                            ) {
                                onSelectAudioInput(option)
                            }
                        }
                    }
                }

                let route = audioEngine.audioHardwareRouteState
                VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.xs) {
                    HardwareSetupDetailRow(
                        title: "Current route",
                        value: route.deviceName ?? activeAudioInputName
                    )
                    HardwareSetupDetailRow(
                        title: "Transport",
                        value: route.transport.rawValue.uppercased()
                    )
                    HardwareSetupDetailRow(
                        title: "Input monitor",
                        value: route.isInputActive ? "Active" : "Waiting for PCM"
                    )
                }

                if route.availableStereoPairs.count > 1 {
                    VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.sm) {
                        Text("Stereo Pair")
                            .font(ScratchLabDesign.Typo.label)
                            .foregroundStyle(ScratchLabDesign.Sem.textSecondary)

                        HStack(spacing: ScratchLabDesign.Spacing.sm) {
                            ForEach(route.availableStereoPairs) { pair in
                                Button(pair.displayName) {
                                    audioEngine.selectStereoPair(pair)
                                }
                                .buttonStyle(.bordered)
                                .tint(route.selectedStereoPair == pair
                                    ? ScratchLabDesign.Sem.accent
                                    : ScratchLabDesign.Sem.textSecondary)
                            }
                        }
                    }
                }

                if let error = audioEngine.lastAudioError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(ScratchLabDesign.Typo.bodySmall)
                        .foregroundStyle(ScratchLabDesign.Sem.warning)
                }

                Button("Test Selected Input", action: onRetestAudio)
                    .scratchLabPrimaryButton(fillsWidth: true)
                    .disabled(selectedAudioInputID.isEmpty)

                if selectedAudioInputID.isEmpty {
                    Text("Select an audio input before testing.")
                        .font(ScratchLabDesign.Typo.bodySmall)
                        .foregroundStyle(ScratchLabDesign.Sem.warning)
                }
            }
        }
    }

    private var midiCard: some View {
        CaptureCard {
            VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.md) {
                HStack(alignment: .firstTextBaseline) {
                    Text("MIDI Controller")
                        .font(ScratchLabDesign.Typo.cardHeading)
                        .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

                    Spacer()

                    Text(midiReadinessText)
                        .font(ScratchLabDesign.Typo.statusPill)
                        .foregroundStyle(midiReadinessColor)
                }

                if midiManager.sources.isEmpty {
                    Label("No MIDI source detected. Connect and power the RANE ONE MKII, then refresh.", systemImage: "cable.connector")
                        .font(ScratchLabDesign.Typo.bodySmall)
                        .foregroundStyle(ScratchLabDesign.Sem.warning)
                } else {
                    VStack(spacing: ScratchLabDesign.Spacing.sm) {
                        ForEach(midiManager.sources) { source in
                            hardwareSelectionRow(
                                title: source.name,
                                detail: source.id,
                                isSelected: source.id == selectedMIDISourceID
                            ) {
                                selectMIDISource(source)
                            }
                        }
                    }
                }

                Button("Refresh MIDI Devices") {
                    midiManager.refreshSources()
                }
                .scratchLabSecondaryButton(fillsWidth: true)

                Button(hasVerifiedMapping ? "Reapply Verified RANE Mapping" : "Apply Verified RANE Mapping") {
                    applyVerifiedRaneMapping()
                }
                .scratchLabPrimaryButton(fillsWidth: true)
                .disabled(!selectedSourceIsRane)

                Button("Load AHHH") {
                    scratchPlaybackEngine.loadPlatterAHHH()
                }
                .scratchLabSecondaryButton(fillsWidth: true)
                .disabled(!selectedSourceIsRane)
                .accessibilityIdentifier("load-platter-ahhh")

                Text(scratchPlaybackEngine.platterSampleStatus)
                    .font(ScratchLabDesign.Typo.bodySmall)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(raneMappingAvailabilityText)
                    .font(ScratchLabDesign.Typo.bodySmall)
                    .foregroundStyle(selectedSourceIsRane
                        ? ScratchLabDesign.Sem.textSecondary
                        : ScratchLabDesign.Sem.warning)

                VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.xs) {
                    HardwareSetupDetailRow(title: "Crossfader", value: crossfaderMappingDescription)
                    HardwareSetupDetailRow(title: "Left upfader", value: mappingDescription(for: .leftUpfader, fallback: "Raw ch 0 · CC 28"))
                    HardwareSetupDetailRow(title: "Right upfader", value: mappingDescription(for: .rightUpfader, fallback: "Raw ch 1 · CC 28"))
                    HardwareSetupDetailRow(title: "Right pads", value: "Raw ch 5 · Notes 20–27 · ScratchLab samples")
                    HardwareSetupDetailRow(title: "Hot Cue 1", value: hotCueOneDescription)
                }

                if let message = midiManager.latestMessage {
                    Text("Last MIDI: \(String(describing: message.messageType)) · raw ch \(message.channel) · value \(message.value)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Move a RANE control after selecting its MIDI source. The latest message will appear here.")
                        .font(ScratchLabDesign.Typo.bodySmall)
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                }

                if !midiLearnCoordinator.feedback.isEmpty {
                    Text(midiLearnCoordinator.feedback)
                        .font(ScratchLabDesign.Typo.bodySmall)
                        .foregroundStyle(ScratchLabDesign.Sem.accent)
                }
            }
        }
    }

    private func hardwareSelectionRow(
        title: String,
        detail: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: ScratchLabDesign.Spacing.md) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected
                        ? ScratchLabDesign.Sem.accent
                        : ScratchLabDesign.Sem.textSecondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(ScratchLabDesign.Typo.bodyDefault)
                        .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                    Text(detail)
                        .font(ScratchLabDesign.Typo.caption)
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(ScratchLabDesign.Card.compactPadding)
            .background(
                isSelected ? ScratchLabDesign.Sem.accent.opacity(0.12) : ScratchLabDesign.Surface.raised,
                in: RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous)
                    .stroke(isSelected ? ScratchLabDesign.Sem.accent : ScratchLabDesign.Border.default, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func selectMIDISource(_ source: IOSMIDIManager.Source) {
        selectedMIDISourceID = source.id
        midiLearnCoordinator.selectDevice(id: source.id, name: source.name)
        midiControllerDispatcher.updateMapping(deviceIdentifier: source.id, deviceName: source.name)
    }

    private func applyVerifiedRaneMapping() {
        guard let source = selectedMIDISource, selectedSourceIsRane else { return }
        selectMIDISource(source)
        midiLearnCoordinator.applyVerifiedRaneOneMKIIMapping()
    }

    private func audioInputDetail(_ option: CompanionCameraBroadcaster.AudioInputOption) -> String {
        switch option.portType {
        case .usbAudio: return "USB-C audio interface"
        case .lineIn: return "Line input"
        case .builtInMic: return "Built-in microphone"
        default: return option.portType.rawValue
        }
    }

    private var midiReadinessText: String {
        switch midiManager.readinessState {
        case .unavailable: return "Not connected"
        case .deviceConnected: return "Connected"
        case .receivingMessages: return "Receiving"
        }
    }

    private var midiReadinessColor: Color {
        switch midiManager.readinessState {
        case .unavailable: return ScratchLabDesign.Sem.textSecondary
        case .deviceConnected: return ScratchLabDesign.Sem.warning
        case .receivingMessages: return ScratchLabDesign.Sem.success
        }
    }

    private var raneMappingAvailabilityText: String {
        guard selectedMIDISource != nil else {
            return "Select the RANE MIDI source before applying mappings."
        }
        guard selectedSourceIsRane else {
            return "The verified mapping is only available for a detected RANE source."
        }
        return "Applies the verified controller mapping for notation, capture, and local ScratchLab sample playback."
    }

    /// Distinguishes the three real crossfader states. The previous single
    /// `"Not active · expected …"` fallback could not say that ScratchLab is
    /// recording fader evidence from a certified hardware default, which would
    /// read as "not active" while events were genuinely being captured.
    private var crossfaderMappingDescription: String {
        if let control = midiLearnCoordinator.control(for: .crossfader) {
            return "Learned · raw ch \(control.channel) · CC \(control.controlNumber)"
        }
        switch midiControllerDispatcher.crossfaderMappingSource {
        case .certifiedRegistry:
            return "Certified default · raw ch 15 · CC 8 · evidence only, no audio"
        case .learned, .none:
            return "Not active · expected raw ch 15 · CC 8"
        }
    }

    private func mappingDescription(for action: MIDISemanticAction, fallback: String) -> String {
        guard let control = midiLearnCoordinator.control(for: action) else {
            return "Not active · expected \(fallback)"
        }
        let kind = control.messageType == .controlChange ? "CC" : "Note"
        return "Raw ch \(control.channel) · \(kind) \(control.controlNumber)"
    }

    private var hotCueOneDescription: String {
        guard let control = midiLearnCoordinator.control(for: .hotCue1) else {
            return "Not active · expected raw ch 5 · Note 20"
        }
        let sampleName = control.assignedSampleID == "dvs_ahhh" ? "AHHH" : (control.assignedSampleID ?? "No sample")
        return "Raw ch \(control.channel) · Note \(control.controlNumber) · \(sampleName)"
    }
}

private struct HardwareSetupDetailRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ScratchLabDesign.Spacing.md) {
            Text(title)
                .font(ScratchLabDesign.Typo.label)
                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
            Spacer()
            Text(value)
                .font(ScratchLabDesign.Typo.bodySmall)
                .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                .multilineTextAlignment(.trailing)
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
        GeometryReader { proxy in
            if proxy.size.width > proxy.size.height {
                HStack(spacing: ScratchLabDesign.Spacing.md) {
                    motionSummary
                    actionButtons
                        .frame(width: min(320, proxy.size.width * 0.38))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                VStack(spacing: 16) {
                    motionSummary
                    actionButtons
                }
            }
        }
    }

    private var motionSummary: some View {
        CaptureCard {
            VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.md) {
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
                    .lineLimit(2)

                HStack(spacing: ScratchLabDesign.Spacing.xl) {
                    VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.xs) {
                        Text("Last sample")
                            .font(ScratchLabDesign.Typo.label)
                            .foregroundStyle(ScratchLabDesign.Sem.textSecondary)

                        Text(lastSampleText)
                            .font(ScratchLabDesign.Typo.bodyDefault)
                            .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                    }

                    VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.xs) {
                        Text("Movement activity")
                            .font(ScratchLabDesign.Typo.label)
                            .foregroundStyle(ScratchLabDesign.Sem.textSecondary)

                        ProgressView(value: activityLevel)
                            .tint(ScratchLabDesign.Sem.motion)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var actionButtons: some View {
        VStack(spacing: ScratchLabDesign.Spacing.md) {
            HStack(spacing: 12) {
                CaptureSecondaryButton(title: "Reconnect", action: onReconnect)
                CaptureSecondaryButton(title: "Recheck Motion", action: onTestMotion)
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
            preview: { fillsAvailableSpace in
                CalibrationPreviewCard(
                session: session,
                videoRotationAngle: videoRotationAngle,
                calibrationProfile: $calibrationProfile,
                allowsEditing: true,
                fillsAvailableSpace: fillsAvailableSpace
                )
            }
        ) { isWide in
            if isWide {
                HStack(spacing: ScratchLabDesign.Spacing.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Calibrate Deck Layout")
                            .font(ScratchLabDesign.Typo.cardHeading)
                            .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

                        Text("Match the guides to the real deck and mixer positions.")
                            .font(ScratchLabDesign.Typo.label)
                            .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: ScratchLabDesign.Spacing.xs)

                    Button("Save", action: onSave)
                        .scratchLabSuccessButton()

                    Button("Reset", action: onReset)
                        .scratchLabSecondaryButton()

                    if hasStoredCalibration {
                        Button("Use Previous", action: onUsePrevious)
                            .scratchLabSecondaryButton()
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.xs) {
                    Text("Calibrate Deck Layout")
                        .font(ScratchLabDesign.Typo.cardHeading)
                        .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

                    Text("Match the guides to the real deck and mixer positions.")
                        .font(ScratchLabDesign.Typo.bodySmall)
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                    HStack(spacing: 12) {
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
}

private struct CaptureHubView: View {
    let flowState: CaptureFlowState
    let sessionLabel: String
    let techniqueName: String
    let bpmLabel: String
    let modeLabel: String
    let hardwareLabel: String
    let readinessSummary: String
    let canStartTake: Bool
    let takeNumber: Int
    let session: AVCaptureSession
    let videoRotationAngle: CGFloat
    @Binding var calibrationProfile: CaptureCalibrationProfile
    let preRollCount: Int
    let recordingStartedAt: Date?
    let recordingStoppedAt: Date?
    let audioStateText: String
    let motionStateText: String
    let captureHealthText: String
    let targetNotation: ScratchNotation?
    let liveNotationEvents: [CaptureCore.DetectedNotationRecordMovementEvent]
    let liveFaderEvents: [CaptureCore.DetectedNotationFaderEvent]
    let notationBPM: Double
    let showsNotationBeatGrid: Bool
    let warningText: String?
    let onStart: () -> Void
    let onStop: () -> Void
    let onRecheck: () -> Void
    let onBack: () -> Void
    let onHardwareSetup: () -> Void

    @State private var isShowingCameraMonitor = false

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width > proxy.size.height {
                landscapeWorkspace(proxy: proxy)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.cardSection) {
                        workspaceHeader
                        sessionStateCard

                        if flowState == .preRoll {
                            countInCard
                        }

                        if flowState == .recording || flowState == .saving {
                            if let warningText {
                                WarningBannerView(text: warningText)
                            }
                            metricsRow
                        } else if flowState == .ready {
                            CaptureCameraLauncherRow {
                                isShowingCameraMonitor = true
                            }

                            CaptureSecondaryButton(title: "Recheck Setup", action: onRecheck)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 24)
                }
            }
        }
        .fullScreenCover(isPresented: $isShowingCameraMonitor) {
            CaptureCameraMonitorView(
                flowState: flowState,
                session: session,
                videoRotationAngle: videoRotationAngle,
                calibrationProfile: $calibrationProfile,
                canStartTake: canStartTake,
                preRollCount: preRollCount,
                targetNotation: targetNotation,
                liveNotationEvents: liveNotationEvents,
                liveFaderEvents: liveFaderEvents,
                notationBPM: notationBPM,
                showsNotationBeatGrid: showsNotationBeatGrid,
                onStart: onStart,
                onStop: onStop,
                onRecheck: onRecheck
            )
        }
    }

    private func landscapeWorkspace(proxy: GeometryProxy) -> some View {
        ZStack {
            Color.black

            CompanionCameraPreview(
                session: session,
                videoRotationAngle: videoRotationAngle,
                videoGravity: .resizeAspectFill
            )
            .frame(width: proxy.size.width, height: proxy.size.height)
            .allowsHitTesting(false)

            CaptureLiveNotationOverlay(
                targetNotation: targetNotation,
                events: liveNotationEvents,
                faderEvents: liveFaderEvents,
                bpm: notationBPM,
                showsBeatGrid: showsNotationBeatGrid
            )
            .padding(.horizontal, max(ScratchLabDesign.Spacing.lg, proxy.safeAreaInsets.leading + 8))
            .padding(.top, max(ScratchLabDesign.Spacing.sm, proxy.safeAreaInsets.top + 8) + 96)
            .padding(.bottom, max(ScratchLabDesign.Spacing.sm, proxy.safeAreaInsets.bottom + 8) + 108)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)

            SamplePositionWaveformView()
                .frame(height: 108)
                .padding(.horizontal, max(ScratchLabDesign.Spacing.lg, proxy.safeAreaInsets.leading + 8))
                .padding(.bottom, max(ScratchLabDesign.Spacing.sm, proxy.safeAreaInsets.bottom + 8))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

            if flowState == .preRoll {
                countInOverlay
            }

            VStack(spacing: ScratchLabDesign.Spacing.sm) {
                HStack(alignment: .center, spacing: ScratchLabDesign.Spacing.sm) {
                    landscapeNavigationButton(
                        title: "Back",
                        systemImage: "chevron.left",
                        action: onBack
                    )

                    landscapeSessionSummary
                        .frame(maxWidth: 360, alignment: .leading)

                    Spacer(minLength: ScratchLabDesign.Spacing.sm)

                    if flowState == .ready {
                        Button("Recheck", action: onRecheck)
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .tint(ScratchLabDesign.Sem.textPrimary)
                    }

                    primaryActionButton
                        .frame(width: 164)

                    landscapeNavigationButton(
                        title: "Hardware Setup",
                        systemImage: "slider.horizontal.3",
                        action: onHardwareSetup
                    )
                }

                if flowState == .recording || flowState == .saving {
                    HStack(spacing: ScratchLabDesign.Spacing.sm) {
                        if let warningText {
                            Label(warningText, systemImage: "exclamationmark.triangle.fill")
                                .font(ScratchLabDesign.Typo.label)
                                .foregroundStyle(ScratchLabDesign.Sem.warning)
                                .lineLimit(1)
                        }

                        Spacer(minLength: ScratchLabDesign.Spacing.sm)
                        landscapeMetrics
                    }
                }
            }
            .padding(.horizontal, max(ScratchLabDesign.Spacing.lg, proxy.safeAreaInsets.leading + 8))
            .padding(.top, max(ScratchLabDesign.Spacing.sm, proxy.safeAreaInsets.top + 8))
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: proxy.size.width, height: proxy.size.height)
        .ignoresSafeArea()
    }

    private func landscapeNavigationButton(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .tint(ScratchLabDesign.Sem.textPrimary)
        .accessibilityLabel(title)
    }

    private var landscapeSessionSummary: some View {
        VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.xxs) {
            HStack(spacing: ScratchLabDesign.Spacing.sm) {
                Circle()
                    .fill(captureStatusColor)
                    .frame(width: 9, height: 9)

                Text(workspaceTitle)
                    .font(ScratchLabDesign.Typo.controlValue)
                    .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

                Text("·")
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)

                Text(sessionLabel)
                    .font(ScratchLabDesign.Typo.label)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                    .lineLimit(1)
            }

            Text("\(techniqueName) · \(bpmLabel) · \(modeLabel)")
                .font(ScratchLabDesign.Typo.caption)
                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, ScratchLabDesign.Spacing.md)
        .frame(minHeight: 44)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var landscapeMetrics: some View {
        HStack(spacing: ScratchLabDesign.Spacing.xs) {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                landscapeMetric(label: "TIME", value: elapsedTimeText(now: context.date))
            }
            landscapeMetric(label: "AUDIO", value: audioStateText)
            landscapeMetric(label: "MOTION", value: motionStateText)
            landscapeMetric(label: "HEALTH", value: captureHealthText)
        }
    }

    private func landscapeMetric(label: String, value: String) -> some View {
        Text("\(label) \(value)")
            .font(ScratchLabDesign.Typo.statusPill)
            .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, ScratchLabDesign.Spacing.sm)
            .frame(minHeight: 32)
            .background(.ultraThinMaterial, in: Capsule())
    }

    private var countInOverlay: some View {
        VStack(spacing: ScratchLabDesign.Spacing.sm) {
            Text("COUNT-IN")
                .font(ScratchLabDesign.Typo.metricLabel)
                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
            Text("\(preRollCount)")
                .font(ScratchLabDesign.Typo.largeScore)
                .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                .contentTransition(.numericText())
        }
        .padding(ScratchLabDesign.Spacing.xl)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.panel, style: .continuous))
    }

    private var workspaceStatus: WorkspaceStatus {
        switch flowState {
        case .recording:
            return .recording
        case .saving:
            return .standard
        case .ready, .preRoll:
            return .ready
        default:
            return .standard
        }
    }

    private var workspaceTitle: String {
        switch flowState {
        case .recording:
            return "Recording"
        case .saving:
            return "Saving Take"
        case .preRoll:
            return "Get Ready"
        default:
            return canStartTake ? "Capture Ready" : "Needs Attention"
        }
    }

    @ViewBuilder
    private var workspaceHeader: some View {
        if flowState == .recording || flowState == .saving {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                CaptureWorkspaceHeader(
                    title: workspaceTitle,
                    status: workspaceStatus,
                    detail: "Take \(String(format: "%02d", takeNumber)) · \(elapsedTimeText(now: context.date))"
                )
            }
        } else {
            CaptureWorkspaceHeader(
                title: workspaceTitle,
                status: canStartTake ? workspaceStatus : .needsAttention,
                detail: flowState == .preRoll
                    ? "Count-in before recording starts"
                    : (canStartTake ? "All required inputs are ready" : readinessSummary)
            )
        }
    }

    private var sessionSummaryState: SessionSummaryState {
        switch flowState {
        case .recording, .saving:
            return .recording
        case .ready, .preRoll:
            return canStartTake ? .ready : .incomplete
        default:
            return .configured
        }
    }

    private var captureStatusText: String {
        switch flowState {
        case .recording:
            return "Recording"
        case .saving:
            return "Saving recording"
        case .preRoll:
            return "Count-in"
        default:
            return canStartTake ? "Capture ready" : "Setup requires attention"
        }
    }

    private var captureStatusColor: Color {
        switch flowState {
        case .recording:
            return ScratchLabDesign.Sem.danger
        case .saving:
            return ScratchLabDesign.Sem.warning
        case .ready, .preRoll:
            return canStartTake ? ScratchLabDesign.Sem.success : ScratchLabDesign.Sem.warning
        default:
            return ScratchLabDesign.Sem.warning
        }
    }

    private var sessionStateCard: some View {
        VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.cardSection) {
            HStack(spacing: ScratchLabDesign.Spacing.sm) {
                Text(sessionLabel)
                    .font(ScratchLabDesign.Typo.cardHeading)
                    .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: ScratchLabDesign.Spacing.sm)

                StatusBadge(
                    title: "",
                    value: sessionSummaryState.label,
                    variant: sessionSummaryState.variant
                )
            }

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                alignment: .leading,
                spacing: ScratchLabDesign.Spacing.md
            ) {
                CaptureSummaryField(label: "TECHNIQUE", value: techniqueName)
                CaptureSummaryField(label: "BPM", value: bpmLabel)
                CaptureSummaryField(label: "MODE", value: modeLabel)
                CaptureSummaryField(label: "AUDIO", value: hardwareLabel)
            }

            CaptureSummaryField(
                label: "CAPTURE STATUS",
                value: captureStatusText,
                valueColor: captureStatusColor
            )

            primaryActionButton
        }
        .scratchLabCard(.standard)
    }

    private var countInCard: some View {
        HStack(spacing: ScratchLabDesign.Spacing.md) {
            VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.xxs) {
                Text("COUNT-IN")
                    .font(ScratchLabDesign.Typo.metricLabel)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)

                Text("Recording starts automatically")
                    .font(ScratchLabDesign.Typo.bodySmall)
                    .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
            }

            Spacer(minLength: ScratchLabDesign.Spacing.sm)

            Text("\(preRollCount)")
                .font(ScratchLabDesign.Typo.largeScore)
                .foregroundStyle(ScratchLabDesign.Sem.accent)
                .contentTransition(.numericText())
        }
        .scratchLabCard(.standard)
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

    private var primaryActionButton: some View {
        Group {
            if flowState == .recording || flowState == .saving {
                Button(flowState == .saving ? "Saving…" : "Stop", action: onStop)
                    .scratchLabDestructiveButton(fillsWidth: true)
                    .disabled(flowState == .saving)
                    .keyboardShortcut(.space, modifiers: [])
            } else if flowState == .preRoll {
                Button("Starting…", action: {})
                    .scratchLabPrimaryButton(fillsWidth: true)
                    .disabled(true)
            } else {
                if canStartTake {
                    Button("Start Recording", action: onStart)
                        .scratchLabPrimaryButton(fillsWidth: true)
                        .keyboardShortcut(.space, modifiers: [])
                } else {
                    Button("Resolve Setup", action: onRecheck)
                        .scratchLabWarningButton(fillsWidth: true)
                }
            }
        }
    }

    private func elapsedTimeText(now: Date) -> String {
        guard let recordingStartedAt else { return "00:00" }
        let elapsed = max(0, (recordingStoppedAt ?? now).timeIntervalSince(recordingStartedAt))
        let minutes = Int(elapsed) / 60
        let seconds = Int(elapsed) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private struct CaptureWorkspaceHeader: View {
    let title: String
    let status: WorkspaceStatus
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.xs) {
            Text("CAPTURE")
                .font(ScratchLabDesign.Typo.metricLabel)
                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)

            AdaptiveWorkspaceHeader(
                title: title,
                status: status,
                detail: detail
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CaptureSummaryField: View {
    let label: String
    let value: String
    var valueColor: Color = ScratchLabDesign.Sem.textPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.xxs) {
            Text(label)
                .font(ScratchLabDesign.Typo.metricLabel)
                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)

            Text(value)
                .font(ScratchLabDesign.Typo.technical)
                .foregroundStyle(valueColor)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CaptureCameraLauncherRow: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: ScratchLabDesign.Spacing.md) {
                Image(systemName: "chevron.right")
                    .font(ScratchLabDesign.Typo.controlValue)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)

                VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.xxs) {
                    Text("Camera / visual guide")
                        .font(ScratchLabDesign.Typo.controlValue)
                        .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

                    Text("Optional · Opens full-screen monitor")
                        .font(ScratchLabDesign.Typo.caption)
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                }

                Spacer(minLength: ScratchLabDesign.Spacing.sm)

                Text("OPEN")
                    .font(ScratchLabDesign.Typo.statusPill)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
            }
            .padding(.horizontal, ScratchLabDesign.Spacing.lg)
            .frame(minHeight: 60)
            .contentShape(Rectangle())
            .background(
                ScratchLabDesign.Surface.surface,
                in: RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous)
                    .stroke(ScratchLabDesign.Border.default, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open camera and visual guide")
        .accessibilityHint("Shows the complete camera frame without cropping")
    }
}

private struct CaptureCameraMonitorView: View {
    let flowState: CaptureFlowState
    let session: AVCaptureSession
    let videoRotationAngle: CGFloat
    @Binding var calibrationProfile: CaptureCalibrationProfile
    let canStartTake: Bool
    let preRollCount: Int
    let targetNotation: ScratchNotation?
    let liveNotationEvents: [CaptureCore.DetectedNotationRecordMovementEvent]
    let liveFaderEvents: [CaptureCore.DetectedNotationFaderEvent]
    let notationBPM: Double
    let showsNotationBeatGrid: Bool
    let onStart: () -> Void
    let onStop: () -> Void
    let onRecheck: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GeometryReader { proxy in
            let isWide = proxy.size.width > proxy.size.height

            if isWide {
                landscapeCameraSurface(proxy: proxy)
                    .statusBarHidden(true)
            } else {
                NavigationStack {
                    VStack(spacing: ScratchLabDesign.Spacing.cardSection) {
                        preview
                        controls
                    }
                    .padding(ScratchLabDesign.Spacing.lg)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                    .background(ScratchLabDesign.Surface.applicationBackground)
                    .navigationTitle("Camera / visual guide")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") {
                                dismiss()
                            }
                        }
                    }
                }
            }
        }
        .background(Color.black)
    }

    private func landscapeCameraSurface(proxy: GeometryProxy) -> some View {
        ZStack {
            Color.black

            CompanionCameraPreview(
                session: session,
                videoRotationAngle: videoRotationAngle,
                videoGravity: .resizeAspectFill
            )
            .frame(width: proxy.size.width, height: proxy.size.height)
            .allowsHitTesting(false)

            CaptureLiveNotationOverlay(
                targetNotation: targetNotation,
                events: liveNotationEvents,
                faderEvents: liveFaderEvents,
                bpm: notationBPM,
                showsBeatGrid: showsNotationBeatGrid
            )
            .padding(.horizontal, max(ScratchLabDesign.Spacing.lg, proxy.safeAreaInsets.leading + 8))
            .padding(.top, max(ScratchLabDesign.Spacing.sm, proxy.safeAreaInsets.top + 8) + 52)
            .padding(.bottom, max(ScratchLabDesign.Spacing.sm, proxy.safeAreaInsets.bottom + 8) + 108)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)

            SamplePositionWaveformView()
                .frame(height: 108)
                .padding(.horizontal, max(ScratchLabDesign.Spacing.lg, proxy.safeAreaInsets.leading + 8))
                .padding(.bottom, max(ScratchLabDesign.Spacing.sm, proxy.safeAreaInsets.bottom + 8))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

            if flowState == .preRoll {
                countInOverlay
            }

            HStack(spacing: ScratchLabDesign.Spacing.sm) {
                Button {
                    dismiss()
                } label: {
                    Label("Close camera", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                .background(.ultraThinMaterial, in: Circle())

                Spacer(minLength: ScratchLabDesign.Spacing.md)

                landscapeCaptureControl
            }
            .padding(.horizontal, max(ScratchLabDesign.Spacing.lg, proxy.safeAreaInsets.leading + 8))
            .padding(.top, max(ScratchLabDesign.Spacing.sm, proxy.safeAreaInsets.top + 8))
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: proxy.size.width, height: proxy.size.height)
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var landscapeCaptureControl: some View {
        if flowState == .recording || flowState == .saving {
            Button(flowState == .saving ? "Saving…" : "Stop", action: onStop)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(ScratchLabDesign.Sem.danger)
                .disabled(flowState == .saving)
        } else if flowState == .preRoll {
            Label("Starting…", systemImage: "timer")
                .font(ScratchLabDesign.Typo.controlValue)
                .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                .padding(.horizontal, ScratchLabDesign.Spacing.md)
                .frame(minHeight: 44)
                .background(.ultraThinMaterial, in: Capsule())
        } else if canStartTake {
            Button("Start Recording", action: onStart)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(ScratchLabDesign.Sem.accent)
        } else {
            Button("Resolve Setup", action: onRecheck)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(ScratchLabDesign.Sem.warning)
        }
    }

    private var countInOverlay: some View {
        VStack(spacing: ScratchLabDesign.Spacing.sm) {
            Text("COUNT-IN")
                .font(ScratchLabDesign.Typo.metricLabel)
                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
            Text("\(preRollCount)")
                .font(ScratchLabDesign.Typo.largeScore)
                .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                .contentTransition(.numericText())
        }
        .padding(ScratchLabDesign.Spacing.xl)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.panel, style: .continuous))
    }

    private var preview: some View {
        ZStack {
            CalibrationPreviewCard(
                session: session,
                videoRotationAngle: videoRotationAngle,
                calibrationProfile: $calibrationProfile,
                allowsEditing: flowState == .ready
            )

            if flowState == .preRoll {
                VStack(spacing: ScratchLabDesign.Spacing.sm) {
                    Text("COUNT-IN")
                        .font(ScratchLabDesign.Typo.metricLabel)
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                    Text("\(preRollCount)")
                        .font(ScratchLabDesign.Typo.largeScore)
                        .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                        .contentTransition(.numericText())
                }
                .padding(ScratchLabDesign.Spacing.xl)
                .background(ScratchLabDesign.Surface.scrim, in: RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.panel, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.md) {
            Text("Full camera frame")
                .font(ScratchLabDesign.Typo.cardHeading)
                .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

            Text("Use the corner handles to adjust the deck guides before recording.")
                .font(ScratchLabDesign.Typo.bodySmall)
                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if flowState == .recording || flowState == .saving {
                Button(flowState == .saving ? "Saving…" : "Stop", action: onStop)
                    .scratchLabDestructiveButton(fillsWidth: true)
                    .disabled(flowState == .saving)
            } else if flowState == .preRoll {
                Button("Starting…", action: {})
                    .scratchLabPrimaryButton(fillsWidth: true)
                    .disabled(true)
            } else if canStartTake {
                Button("Start Recording", action: onStart)
                    .scratchLabPrimaryButton(fillsWidth: true)
            } else {
                Button("Resolve Setup", action: onRecheck)
                    .scratchLabWarningButton(fillsWidth: true)
            }
        }
        .scratchLabCard(.standard)
    }
}

/// Display-only live notation over the landscape camera. The event stream is
/// the existing coalesced MIDI/DVS presentation feed; this view does not
/// decode, score, persist, or modify capture evidence.
private struct CaptureLiveNotationOverlay: View {
    let targetNotation: ScratchNotation?
    let events: [CaptureCore.DetectedNotationRecordMovementEvent]
    let faderEvents: [CaptureCore.DetectedNotationFaderEvent]
    let bpm: Double
    let showsBeatGrid: Bool

    private var visibleWindow: ClosedRange<TimeInterval>? {
        guard let first = events.first, let last = events.last else { return nil }
        return first.startTime...max(first.startTime + 0.1, last.endTime)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.xs) {
            HStack {
                Text("LIVE NOTATION")
                    .font(ScratchLabDesign.Typo.metricLabel)
                    .foregroundStyle(ScratchLabDesign.Sem.accent)

                Spacer()

                Text("CAMERA CLEAN · NOTATION SEPARATE")
                    .font(ScratchLabDesign.Typo.statusPill)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
            }

            Text("TARGET")
                .font(ScratchLabDesign.Typo.statusPill)
                .foregroundStyle(ScratchLabDesign.Notation.targetTrace)

            if let targetNotation {
                CaptureTargetNotationTrace(notation: targetNotation, bpm: bpm)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
            } else {
                Text("Target notation is unavailable for this technique.")
                    .font(ScratchLabDesign.Typo.caption)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .layoutPriority(1)
            }

            Text("MY PERFORMANCE · LIVE")
                .font(ScratchLabDesign.Typo.statusPill)
                .foregroundStyle(ScratchLabDesign.Notation.performanceTrace)

            if events.isEmpty {
                Text("Waiting for MIDI / DVS movement")
                    .font(ScratchLabDesign.Typo.caption)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .layoutPriority(1)
            } else {
                CaptureLiveNotationTrace(
                    events: events,
                    bpm: showsBeatGrid ? bpm : nil,
                    visibleWindow: visibleWindow
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            }

            if !faderEvents.isEmpty {
                HStack(spacing: ScratchLabDesign.Spacing.sm) {
                    Text("FADER")
                        .font(ScratchLabDesign.Typo.metricLabel)
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                    CaptureLiveFaderTrace(
                        events: faderEvents,
                        visibleWindow: visibleWindow
                    )
                    .frame(height: 18)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(ScratchLabDesign.Spacing.md)
        .background(Color.clear)
        .overlay {
            RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous)
                .stroke(Color.white.opacity(0.24), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.9), radius: 2, x: 0, y: 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(events.isEmpty
            ? "Live notation waiting for MIDI or DVS movement"
            : "Live notation showing \(events.count) measured movement events")
    }
}

/// Captured crossfader marks share the measured take clock and canonical
/// renderer vocabulary. The baseline remains clear; only real derived cuts,
/// pulses, transforms, or flares draw marks.
private struct CaptureLiveFaderTrace: View {
    let events: [CaptureCore.DetectedNotationFaderEvent]
    let visibleWindow: ClosedRange<TimeInterval>?

    var body: some View {
        Canvas { context, size in
            let start = visibleWindow?.lowerBound ?? events.map(\.startTime).min() ?? 0
            let end = visibleWindow?.upperBound ?? events.map(\.endTime).max() ?? (start + 0.1)
            let duration = max(end - start, 0.1)
            let viewport = LaneViewport(
                size: size,
                now: start,
                axis: .horizontal,
                actionLineFraction: 0,
                secondsAhead: duration
            )
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: size.height / 2))
            baseline.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(baseline, with: .color(Color.white.opacity(0.35)), lineWidth: 1)
            ScratchMotionRenderer.drawCrossfaderTicks(
                events,
                in: context,
                viewport: viewport,
                style: .performance
            )
        }
        .allowsHitTesting(false)
        .accessibilityLabel("Crossfader activity: \(events.count) detected events")
    }
}

/// Full-width canonical target trace for the camera HUD. The target is
/// materialized upstream by the existing registry and only rendered here.
private struct CaptureTargetNotationTrace: View {
    let notation: ScratchNotation
    let bpm: Double

    var body: some View {
        Canvas { context, size in
            let content = LaneContent(notation: notation, beatsPerMinute: bpm)
            let motionPath = ScratchStrokeGeometry.motionPath(for: content)
            let viewport = LaneViewport(
                size: size,
                now: 0,
                axis: .horizontal,
                actionLineFraction: 0,
                secondsAhead: max(notation.timelineDuration, 0.1)
            )
            ScratchMotionRenderer.draw(
                motionPath,
                in: context,
                viewport: viewport,
                style: .target
            )
        }
        .allowsHitTesting(false)
    }
}

/// Transparent measured-stroke renderer used by the camera overlay. It
/// reuses the canonical stroke adapter, geometry, and cyan performance style,
/// while intentionally omitting the chart card, grid, labels, and fader lane.
private struct CaptureLiveNotationTrace: View {
    let events: [CaptureCore.DetectedNotationRecordMovementEvent]
    let bpm: Double?
    let visibleWindow: ClosedRange<TimeInterval>?

    var body: some View {
        Canvas { context, size in
            let strokes = events.compactMap(PerformedStrokeAdapter.laneStroke)
            guard !strokes.isEmpty else { return }

            let windowStart = visibleWindow?.lowerBound ?? 0
            let windowEnd = visibleWindow?.upperBound ?? max(events.map(\.endTime).max() ?? 0.1, 0.1)
            let windowDuration = max(windowEnd - windowStart, 0.1)
            let content = LaneContent(
                strokes: strokes,
                segments: [],
                beatsPerMinute: bpm,
                duration: max(windowEnd, 0.1),
                loops: false
            )
            let motionPath: MotionPath
            if let frame = PerformedStrokeAdapter.gestureRelativeNormalizationFrame(for: events) {
                motionPath = ScratchStrokeGeometry.motionPath(
                    for: content,
                    normalizingTo: frame
                )
            } else {
                motionPath = ScratchStrokeGeometry.motionPath(for: content)
            }
            let viewport = LaneViewport(
                size: size,
                now: windowStart,
                axis: .horizontal,
                actionLineFraction: 0,
                secondsAhead: windowDuration
            )
            ScratchMotionRenderer.draw(
                motionPath,
                in: context,
                viewport: viewport,
                style: .performance
            )
        }
        .allowsHitTesting(false)
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
        GeometryReader { proxy in
            let usesTwoPaneReview = proxy.size.width > proxy.size.height

            if usesTwoPaneReview {
                landscapeReview(proxy: proxy)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: ScratchLabDesign.Spacing.cardSection) {
                        reviewStatusCard
                        CaptureThumbnailView(mediaURL: review.summary.mediaURL)
                        decisionColumn
                    }
                    .frame(maxWidth: 1100)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, ScratchLabDesign.Spacing.xl)
                }
            }
        }
    }

    private func landscapeReview(proxy: GeometryProxy) -> some View {
        VStack(spacing: ScratchLabDesign.Spacing.sm) {
            HStack(spacing: ScratchLabDesign.Spacing.md) {
                Text(review.operatorMessage)
                    .font(ScratchLabDesign.Typo.controlValue)
                    .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: ScratchLabDesign.Spacing.sm)
                reviewStatusPills
            }
            .padding(.horizontal, ScratchLabDesign.Spacing.md)
            .frame(minHeight: 44)
            .background(
                ScratchLabDesign.Surface.surface,
                in: RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous)
                    .stroke(ScratchLabDesign.Border.default, lineWidth: 1)
            }

            HStack(alignment: .top, spacing: ScratchLabDesign.Spacing.sm) {
                CaptureThumbnailView(mediaURL: review.summary.mediaURL)
                    .frame(maxWidth: .infinity, alignment: .top)

                landscapeDetails
                    .frame(width: min(270, proxy.size.width * 0.32))

                landscapeActions
                    .frame(width: min(180, proxy.size.width * 0.22))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var landscapeDetails: some View {
        VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.sm) {
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                alignment: .leading,
                spacing: ScratchLabDesign.Spacing.sm
            ) {
                CaptureReviewDetailBlock(label: "Take", value: String(review.summary.sidecar.takeID.prefix(8)))
                CaptureReviewDetailBlock(label: "Scratch", value: review.drillName)
                CaptureReviewDetailBlock(label: "Duration", value: formatDuration(review.duration))
                CaptureReviewDetailBlock(label: "Sync", value: review.syncStatus)
                ForEach(review.evidenceRows) { row in
                    CaptureReviewDetailBlock(label: row.label, value: row.value)
                }
            }

            Divider().overlay(ScratchLabDesign.Border.default)

            LazyVGrid(columns: qualityColumns, spacing: ScratchLabDesign.Spacing.xs) {
                ForEach(CaptureQualityTag.allCases) { quality in
                    Chip(quality.title, isSelected: review.quality == quality) {
                        onSelectQuality(quality)
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            Button(action: onToggleCombo) {
                Label("Combo", systemImage: review.isComboTagged ? "checkmark.square.fill" : "square")
                    .font(ScratchLabDesign.Typo.controlValue)
                    .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
            }
        }
        .padding(12)
        .background(
            ScratchLabDesign.Surface.surface,
            in: RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous)
                .stroke(ScratchLabDesign.Border.default, lineWidth: 1)
        }
    }

    private var landscapeActions: some View {
        VStack(spacing: ScratchLabDesign.Spacing.sm) {
            Button("Keep and Next", action: onKeepAndNext)
                .scratchLabPrimaryButton(fillsWidth: true)

            Button("Keep", action: onKeep)
                .scratchLabSecondaryButton(fillsWidth: true)

            Button("Retry", action: onRetry)
                .scratchLabSecondaryButton(fillsWidth: true)

            Button("Discard", action: onDiscard)
                .scratchLabDestructiveButton(fillsWidth: true)
        }
    }

    private var reviewStatusCard: some View {
        CaptureCard {
            VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.md) {
                Text(review.operatorMessage)
                    .font(ScratchLabDesign.Typo.keyMetric)
                    .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: ScratchLabDesign.Spacing.sm) {
                        reviewStatusPills
                    }

                    VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.sm) {
                        reviewStatusPills
                    }
                }
            }
        }
    }

    /// Sync and motion are both projections of one resolved readiness, so these
    /// pills restate each other at worst — they can no longer disagree the way
    /// a separately-computed "Motion pending" could sit beside "Motion Missing".
    @ViewBuilder
    private var reviewStatusPills: some View {
        ReadinessPill(
            title: review.syncStatus,
            variant: review.reviewState.readiness == .readyToKeep ? .success : .warning
        )
        ReadinessPill(
            title: review.audioPresent ? "Audio Present" : "Missing Audio",
            variant: review.audioPresent ? .success : .danger
        )
        ReadinessPill(
            title: review.motionStatusTitle,
            variant: review.motionPresent ? .success : .warning
        )
    }

    private var decisionColumn: some View {
        VStack(spacing: ScratchLabDesign.Spacing.md) {
            CaptureCard {
                LazyVGrid(columns: detailColumns, alignment: .leading, spacing: ScratchLabDesign.Spacing.md) {
                    CaptureReviewDetailBlock(label: "Take ID", value: review.summary.sidecar.takeID)
                    CaptureReviewDetailBlock(label: "Scratch Type", value: review.drillName)
                    CaptureReviewDetailBlock(label: "Duration", value: formatDuration(review.duration))
                    CaptureReviewDetailBlock(label: "Sync", value: review.syncStatus)
                    ForEach(review.evidenceRows) { row in
                        CaptureReviewDetailBlock(label: row.label, value: row.value)
                    }
                }
            }

            CaptureCard {
                VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.md) {
                    Text("Quality")
                        .font(ScratchLabDesign.Typo.sectionLabel)
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)

                    LazyVGrid(columns: qualityColumns, spacing: ScratchLabDesign.Spacing.sm) {
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

            Button("Keep and Next", action: onKeepAndNext)
                .scratchLabPrimaryButton(fillsWidth: true)
                .keyboardShortcut(.return, modifiers: [])

            ViewThatFits(in: .horizontal) {
                HStack(spacing: ScratchLabDesign.Spacing.sm) {
                    secondaryReviewActions
                }

                VStack(spacing: ScratchLabDesign.Spacing.sm) {
                    secondaryReviewActions
                }
            }

            Button("Discard", action: onDiscard)
                .scratchLabDestructiveButton(fillsWidth: true)
                .keyboardShortcut("d", modifiers: [])
        }
    }

    @ViewBuilder
    private var secondaryReviewActions: some View {
        Button("Keep", action: onKeep)
            .scratchLabSecondaryButton(fillsWidth: true)

        Button("Retry", action: onRetry)
            .scratchLabSecondaryButton(fillsWidth: true)
            .keyboardShortcut("r", modifiers: [])
    }

    private var detailColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 132), spacing: ScratchLabDesign.Spacing.md)]
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
        GeometryReader { proxy in
            if proxy.size.width > proxy.size.height {
                landscapeContent(proxy: proxy)
            } else {
                ScrollView(showsIndicators: false) {
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

                        Button(isExporting ? "Preparing…" : "Share Session", action: onShareSession)
                            .scratchLabPrimaryButton(fillsWidth: true)
                            .disabled(isExporting || !canShare)
                            .accessibilityHint(canShare
                                ? "Creates and opens the existing session export"
                                : "Keep at least one take before sharing")
                    }
                }

                Button("Next Take", action: onNextTake)
                    .scratchLabPrimaryButton(fillsWidth: true)
                    .keyboardShortcut(.return, modifiers: [])

                CaptureSecondaryButton(title: "Change Scratch Type", action: onChangeDrill)
                    .keyboardShortcut("c", modifiers: [])

                CaptureSecondaryButton(title: "Recheck Setup", action: onRecheckSetup)
                    .keyboardShortcut("k", modifiers: [])

                CaptureSecondaryButton(title: "End Session", action: onEndSession)
            }
                        .padding(.bottom, ScratchLabDesign.Spacing.xl)
                    }
                }
        }
    }
    private func landscapeContent(proxy: GeometryProxy) -> some View {
        let sideWidth = min(210, max(172, proxy.size.width * 0.24))

        return HStack(alignment: .top, spacing: ScratchLabDesign.Spacing.sm) {
            completionColumn
                .frame(width: sideWidth)

            #if DEBUG
            if showsUploadSection {
                uploadPanel
                    .frame(width: sideWidth)
            }
            #endif

            sharePanel
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var completionColumn: some View {
        VStack(spacing: ScratchLabDesign.Spacing.sm) {
            VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.xs) {
                Label("Take saved", systemImage: "checkmark.circle.fill")
                    .font(ScratchLabDesign.Typo.controlValue)
                    .foregroundStyle(ScratchLabDesign.Sem.textSuccess)

                Text("\(sessionName) · \(takeCount) take\(takeCount == 1 ? "" : "s")")
                    .font(ScratchLabDesign.Typo.label)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                    .lineLimit(2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                ScratchLabDesign.Surface.surface,
                in: RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous)
                    .stroke(ScratchLabDesign.Sem.success.opacity(0.65), lineWidth: 1)
            }

            Button("Next Take", action: onNextTake)
                .scratchLabPrimaryButton(fillsWidth: true)
            Button("Change Scratch", action: onChangeDrill)
                .scratchLabSecondaryButton(fillsWidth: true)
            Button("Recheck Setup", action: onRecheckSetup)
                .scratchLabSecondaryButton(fillsWidth: true)
            Button("End Session", action: onEndSession)
                .scratchLabTertiaryButton()
                .frame(maxWidth: .infinity)
        }
    }

    #if DEBUG
    private var uploadPanel: some View {
        VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.sm) {
            Text("Upload Session")
                .font(ScratchLabDesign.Typo.controlValue)
                .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

            Text(uploadJob?.statusText ?? (uploadAvailable ? "Ready to upload" : uploadAvailabilityText ?? "Upload unavailable"))
                .font(ScratchLabDesign.Typo.label)
                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                .lineLimit(2)

            if let uploadJob, uploadJob.fileSizeBytes > 0 {
                Text(uploadJob.formattedFileSize)
                    .font(ScratchLabDesign.Typo.technical)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                    .lineLimit(1)
            }

            if let progressFraction = uploadJob?.progressFraction {
                ProgressView(value: progressFraction)
                    .tint(ScratchLabDesign.Sem.success)
            } else if uploadJob?.state == .preparing || uploadJob?.state == .requestingUploadURL {
                ProgressView()
                    .tint(ScratchLabDesign.Sem.success)
            }

            Button(uploadJob?.state == .completed ? "Uploaded" : "Upload", action: onUploadSession)
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
                Button("Retry Upload", action: onRetryUpload)
                    .scratchLabSecondaryButton(fillsWidth: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ScratchLabDesign.Surface.surface,
            in: RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous)
                .stroke(ScratchLabDesign.Border.default, lineWidth: 1)
        }
    }
    #endif

    private var sharePanel: some View {
        VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: ScratchLabDesign.Spacing.md) {
                VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.xxs) {
                    Text("Share Session")
                        .font(ScratchLabDesign.Typo.sectionTitle)
                        .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

                    Text(exportStatusText ?? "Export this session as a ZIP archive.")
                        .font(ScratchLabDesign.Typo.label)
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                        .lineLimit(2)
                }

                Spacer(minLength: ScratchLabDesign.Spacing.sm)

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
                    .onAppear { exportMixMode = .scratchOnly }
                #endif
            }

            if let exportSummaryText {
                Text(exportSummaryText)
                    .font(ScratchLabDesign.Typo.technical)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if !exportBlockingIssues.isEmpty || exportWarningText != nil || timingWarningText != nil {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.xs) {
                        ForEach(exportBlockingIssues, id: \.self) { issue in
                            Text("• \(issue)")
                                .font(ScratchLabDesign.Typo.label)
                                .foregroundStyle(ScratchLabDesign.Sem.textError)
                        }
                        if let exportWarningText {
                            Text(exportWarningText)
                                .font(ScratchLabDesign.Typo.label)
                                .foregroundStyle(ScratchLabDesign.Sem.warning)
                        }
                        if let timingWarningText {
                            Text(timingWarningText)
                                .font(ScratchLabDesign.Typo.label)
                                .foregroundStyle(ScratchLabDesign.Sem.warning)
                        }
                    }
                }
                .frame(maxHeight: 86)
            }

            Spacer(minLength: 0)

            Button(isExporting ? "Preparing…" : "Share Session", action: onShareSession)
                .scratchLabPrimaryButton(fillsWidth: true)
                .disabled(isExporting || !canShare)
                .accessibilityHint(canShare
                    ? "Creates and opens the existing session export"
                    : "Keep at least one take before sharing")
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            ScratchLabDesign.Surface.surface,
            in: RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous)
                .stroke(ScratchLabDesign.Border.default, lineWidth: 1)
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
    var isCompact = false

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? ScratchLabDesign.Spacing.xxs : ScratchLabDesign.Spacing.sm) {
            Text(title)
                .font(ScratchLabDesign.Typo.label)
                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)

            TextField(title, text: $text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .font(ScratchLabDesign.Typo.bodyDefault)
                .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                .padding(.horizontal, isCompact ? 10 : ScratchLabDesign.Card.compactPadding)
                .padding(.vertical, isCompact ? 0 : ScratchLabDesign.Card.compactPadding)
                .frame(minHeight: isCompact ? 34 : nil)
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
    var isCompact = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: isCompact ? ScratchLabDesign.Spacing.xxs : ScratchLabDesign.Spacing.sm) {
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
                .padding(.horizontal, isCompact ? 10 : ScratchLabDesign.Card.compactPadding)
                .padding(.vertical, isCompact ? 0 : ScratchLabDesign.Card.compactPadding)
                .frame(minHeight: isCompact ? 34 : nil)
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
    var isCompact = false

    var body: some View {
        HStack(alignment: .top, spacing: isCompact ? ScratchLabDesign.Spacing.sm : ScratchLabDesign.Spacing.itemRow) {
                Circle()
                    .fill(result.status.color)
                    .frame(width: isCompact ? 9 : 12, height: isCompact ? 9 : 12)

                VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.xxs) {
                    Text(result.kind.title)
                        .font(isCompact ? ScratchLabDesign.Typo.controlValue : ScratchLabDesign.Typo.title3)
                        .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                        .lineLimit(1)

                    Text(result.detail)
                        .font(isCompact ? ScratchLabDesign.Typo.label : ScratchLabDesign.Typo.pageSubtitle)
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                        .lineLimit(isCompact ? 2 : nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .layoutPriority(1)

                Spacer(minLength: ScratchLabDesign.Spacing.xs)

                StatusBadge(
                    title: "",
                    value: result.status.label,
                    variant: result.status.badgeVariant
                )
            }
            .padding(isCompact ? 10 : ScratchLabDesign.Card.padding)
            .background(
                ScratchLabDesign.Surface.surface,
                in: RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.panel, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.panel, style: .continuous)
                    .stroke(ScratchLabDesign.Border.default, lineWidth: 1)
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
    var fillsAvailableSpace = false

    var body: some View {
        Group {
            if fillsAvailableSpace {
                calibrationCanvas
            } else {
                calibrationCanvas
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous)
                .stroke(ScratchLabDesign.Border.default, lineWidth: 1)
        )
    }

    private var calibrationCanvas: some View {
        GeometryReader { proxy in
            let viewport = fittedCameraViewport(in: proxy.size)

            ZStack {
                Color.black

                ZStack {
                    CompanionCameraPreview(
                        session: session,
                        videoRotationAngle: videoRotationAngle,
                        videoGravity: .resizeAspect
                    )
                    .allowsHitTesting(false)

                    ForEach(CaptureCalibrationRole.allCases) { role in
                        InteractiveCalibrationZone(
                            zone: Binding(
                                get: { calibrationProfile[role] },
                                set: { calibrationProfile[role] = $0 }
                            ),
                            role: role,
                            containerSize: viewport.size,
                            allowsEditing: allowsEditing
                        )
                    }
                }
                .frame(width: viewport.width, height: viewport.height)
                .position(x: viewport.midX, y: viewport.midY)
            }
        }
    }

    private func fittedCameraViewport(in size: CGSize) -> CGRect {
        guard fillsAvailableSpace else {
            return CGRect(origin: .zero, size: size)
        }

        let cameraAspect: CGFloat = 16.0 / 9.0
        let containerAspect = size.width / max(size.height, 1)
        if containerAspect > cameraAspect {
            let width = size.height * cameraAspect
            return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
        }

        let height = size.width / cameraAspect
        return CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
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
                    .fill(ScratchLabDesign.Sem.success)
                    .frame(width: 22, height: 22)
                    .overlay {
                        Circle()
                            .stroke(ScratchLabDesign.Sem.textPrimary.opacity(0.92), lineWidth: 2)
                    }
                    // Keep the visible handle compact while giving it a full
                    // touch target, matching the iPhone calibration control.
                    .frame(width: 52, height: 52)
                    .contentShape(Rectangle())
                    .position(x: rect.width - 22, y: rect.height - 22)
                    .highPriorityGesture(resizeGesture)
                    .accessibilityLabel("Resize \(role.title) guide")
            }
        }
        .frame(width: rect.width, height: rect.height)
        .contentShape(Rectangle())
        .position(x: rect.midX, y: rect.midY)
        // Apply movement to the guide itself without stealing touches from
        // the dedicated resize handle above.
        .gesture(moveGesture, including: .gesture)
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
                    .scaledToFit()
                    .background(Color.black)
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
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.updateVideoGravity(videoGravity)
        view.updateSession(session)
        view.updateRotationAngle(videoRotationAngle)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.updateVideoGravity(videoGravity)
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

        func updateVideoGravity(_ videoGravity: AVLayerVideoGravity) {
            guard previewLayer.videoGravity != videoGravity else { return }
            previewLayer.videoGravity = videoGravity
        }

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
