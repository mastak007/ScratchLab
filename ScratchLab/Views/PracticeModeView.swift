// PracticeModeView.swift
// ScratchLab - Practice Mode
// Camera feed with gamification overlays for scratch practice

import SwiftUI
import AVFoundation
import UIKit

private enum PracticeBeatUIContract {
    static let sectionAccessibilityID = "practice-beat-controls"
    static let noBeatLabel = "No Beat"
    static let beatOnLabel = "Beat On"
    static let playLabel = "Play Beat"
    static let stopLabel = "Stop Beat"
}

// Practice assist modes. Default is `.open` so the existing coaching loop is
// unchanged for users on first launch. `.demo` is a non-scored reference mode
// that plays the bundled demo audio; `.demoWithMotion` is the same reference
// playback with the learner's live platter motion drawn over the target (still
// non-scored, still camera-free); the rest run the scored practice loop.
fileprivate enum PracticeAssistMode: String, CaseIterable, Identifiable {
    case autoCut
    case demo
    case demoWithMotion
    case guided
    case coached
    case open

    var id: String { rawValue }

    var title: String {
        switch self {
        case .autoCut:        return "Auto-cut"
        case .demo:           return "Demo"
        case .demoWithMotion: return "Demo + My Motion"
        case .guided:         return "Guided"
        case .coached:        return "Coached"
        case .open:           return "Open"
        }
    }

    var explainer: String {
        switch self {
        case .autoCut:        return "Visual target preview. App playback is off for this mode."
        case .demo:           return "ScratchLab plays the demo audio and moves the notation in time — watch and listen; this run isn't scored."
        case .demoWithMotion: return "ScratchLab plays the demo audio and shows the target; your connected platter's motion is drawn over the target as you move. No camera, no mic — this run isn't scored."
        case .guided:         return "ScratchLab shows upcoming cut cues while you move the fader."
        case .coached:        return "Target pattern loops in time. Mic listens for your scratches and gives a practice estimate."
        case .open:           return "Static target reference. Mic listens; freestyle freely. No beat unless you turn one on."
        }
    }
}

struct PracticeModeView: View {
    let scratch: Scratch
    let drillTimeline: ScratchRenderTimeline?
    let drillBPM: Double
    let comboChallenge: ComboScratch?
    let usesBackingTrack: Bool
    /// When true, the pre-session "ready" state shows the approved V3.2
    /// `PracticeReadyOverlay` (Figma `iPhone / Practice Ready`: fixed Open
    /// assist mode, `Start session` / `Watch`) instead of the full legacy
    /// `SessionSetupOverlay` (beat/BPM, assist-mode picker, audio-input
    /// selector, session length). The production Home → Practice route sets
    /// this true; the full setup survives only on the Advanced route.
    let usesSimplifiedReady: Bool

    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var audioEngine: AudioEngine
    @EnvironmentObject var progressManager: ProgressManager
    @EnvironmentObject private var practiceBeatStore: PracticeBeatStore
    /// Live scratch-performance data feed — reads the RANE platter movement
    /// this dispatcher already tracks for MIDI parity, so the Result
    /// screen's MY PERFORMANCE notation panel has real evidence instead of
    /// always resolving `.targetOnly`. See `practiceResultNotation` below.
    @EnvironmentObject private var midiControllerDispatcher: IOSMIDIControllerDispatcher

    @State private var viewportSize: CGSize = .zero

    // Geometry, rather than size class, is authoritative here: iPad can report
    // regular/regular while visibly landscape. Only short landscape canvases
    // receive the compressed HUD treatment.
    private var isCompactVertical: Bool {
        viewportSize.width > viewportSize.height && viewportSize.height < 560
    }

    // Bundled demo-audio player for the non-scored Demo assist mode. Reused
    // from the coach card; owned here so the live session can drive the demo
    // playback and the audio-synced notation playhead.
    @StateObject private var demoPlayer = ScratchCoachDemoAudioPlayer()

    // The call-and-response reel manifest backing the active Demo session,
    // when a valid, audio-backed one is bundled. `nil` outside Demo mode or
    // when the manifest is missing/invalid — the portrait reel then falls
    // back to the horizontal demo chart. Set by configureDemoPlayback().
    @State private var demoReel: PracticeReelTimeline?

    // Session state
    @State private var isSessionActive = false
    @State private var isPaused = false
    @State private var isCameraPreviewVisible = false
    @State private var showingCaptureHelp = false
    @State private var showingQuickStartAgain = false
    @State private var showMicRationale = false
    @State private var showingResults = false
    @AppStorage(QuickStartSettings.hasSeenKey) private var hasSeenQuickStart = false
    @AppStorage(QuickStartSettings.versionKey) private var quickStartVersion = 0
    @AppStorage("scratchlab.practice.assistMode") private var practiceAssistModeRaw = PracticeAssistMode.open.rawValue
    
    // Timing
    @State private var selectedDuration: TimeInterval = 300 // 5 min default
    @State private var timeRemaining: TimeInterval = 300
    @State private var sessionTimer: Timer?
    // Origin for the live notation preview clock. Re-stamped by startSession()
    // so the looping playhead / cue preview is one session-owned source of
    // truth that survives view rebuilds (e.g. rotation) instead of resetting.
    @State private var notationClockStartDate = Date()
    @State private var drillElapsedSeconds: TimeInterval = 0
    @State private var drillLoopCount: Int = 0
    @State private var drillBeatInLoop: Double = 0
    @State private var activeDrillEventIndex: Int?
    @State private var comboStepsHitThisLoop: Set<Int> = []
    @State private var comboBestRunCount: Int = 0
    @State private var comboTrackedLoopCount: Int = 0
    @State private var comboCompleted = false
    @State private var comboCompletionQueued = false
    @State private var sessionProgressPersisted = false
    @State private var comboPhraseStartedAt: Date?
    @State private var lastComboLockAt: Date?
    
    // Scoring
    @State private var currentScore: Int = 0
    @State private var currentAccuracy: Double = 0
    @State private var attemptCount: Int = 0
    @State private var currentStreak: Int = 0
    @State private var bestStreak: Int = 0

    // Practice timing preview — supplementary aggregates derived from the
    // live `ScratchAnalysisResult.timing` stream. Used only by the
    // post-take preview card; never saved, scored, or exported. PROFILE.md
    // keeps classifier labels/confidence off this surface.
    @State private var onBeatHitCount: Int = 0
    @State private var cumulativeAbsoluteBeatOffsetMs: Double = 0
    @State private var sessionStartedAt: Date?
    // Off-beat detections bucketed by the SIGN of the measured beat offset —
    // supplementary REVIEW evidence for the post-take result surface. Never
    // saved, scored, or exported; never a platter-direction/position claim
    // (the mic input path measures timing only).
    @State private var earlyHitCount: Int = 0
    @State private var lateHitCount: Int = 0

    // Feedback
    @State private var lastFeedback: [String] = []
    @State private var showFeedback = false
    @State private var feedbackColor: Color = ScratchLabDesign.Sem.textPrimary
    @State private var sessionTipText = ""
    
    // Animation states
    @State private var pulseRing = false
    @State private var showAccuracyBurst = false
    @State private var lastAccuracyValue: Double = 0
    // Notation feedback overlay state — driven by live scratch detection results.
    @State private var notationFeedbackState: NotationFeedbackState = .neutral
    // Active-attempt performance evidence for the live notation lane. This is
    // presentation state only; Result independently resolves its finalized
    // gesture-relative view from the same raw attempt evidence.
    @State private var livePerformedMovementEvents: [CaptureCore.DetectedNotationRecordMovementEvent] = []

    let durationOptions: [(String, TimeInterval)] = [
        ("5 min", 300),
        ("10 min", 600),
        ("15 min", 900)
    ]
    private let comboSessionDuration: TimeInterval = 45
    private let comboMinimumAccuracy: Double = 40
    private let comboLockCooldown: TimeInterval = 0.24
    private let comboResetInactivity: TimeInterval = 2.4
    private let comboPhraseWindow: TimeInterval = 6.5

    private var activeScratch: Scratch {
        scratch
    }

    // Target notation for the current scratch, materialized from the
    // canonical technique registry (`ScratchNotation.canonicalBeatPattern`)
    // at the session's active BPM. Only techniques with a proven,
    // evidence-backed `BeatPattern` — today, only Baby Scratch — resolve to
    // a pattern; everything else stays nil so the target lane panel is
    // omitted (graceful), never a guessed fallback.
    private var targetNotation: ScratchNotation? {
        ScratchNotation.canonicalBeatPattern(forScratchID: scratch.id)?
            .materialized(bpm: Double(practiceBeatStore.bpmValue))
    }

    private var assistModeBinding: Binding<PracticeAssistMode> {
        Binding(
            get: { PracticeAssistMode(rawValue: practiceAssistModeRaw) ?? .open },
            set: { practiceAssistModeRaw = $0.rawValue }
        )
    }

    private var practiceAssistMode: PracticeAssistMode {
        PracticeAssistMode(rawValue: practiceAssistModeRaw) ?? .open
    }

    // MARK: - Assist-mode semantics
    //
    // Three narrow predicates so the demo-audio / scored split reads the same
    // everywhere instead of scattering `== .demo` / `!= .demo` checks. Adding
    // `.demoWithMotion` only needed these to be taught the new case once.

    /// Reference-only Demo: the bundled demo audio plays and the notation
    /// follows it — nothing else runs. No live performed capture, no camera,
    /// no mic analysis, no scoring, no results, no persisted attempt.
    private var isReferenceOnlyDemo: Bool { practiceAssistMode == .demo }

    /// A mode that plays the bundled demo audio instead of the scored mic
    /// loop: `.demo` (reference only) and `.demoWithMotion` (same playback,
    /// plus the learner's live platter motion drawn over the target). Neither
    /// starts the camera or mic, and neither is scored or persisted.
    private var isDemoAudioMode: Bool {
        practiceAssistMode == .demo || practiceAssistMode == .demoWithMotion
    }

    /// The scored practice loop — camera preview + mic analysis + running
    /// score + post-take results + progression. Every mode that is not a
    /// demo-audio mode.
    private var isScoredPracticeMode: Bool { !isDemoAudioMode }

    private var normalizedDrillEvents: [ScratchRenderEvent] {
        guard let drillTimeline else { return [] }
        return drillTimeline.events.sorted { lhs, rhs in
            if lhs.startBeat == rhs.startBeat {
                return lhs.durationBeats < rhs.durationBeats
            }
            return lhs.startBeat < rhs.startBeat
        }
    }

    private var isGuidedDrillMode: Bool {
        drillTimeline != nil && !normalizedDrillEvents.isEmpty && (drillTimeline?.totalBeats ?? 0) > 0
    }

    private var isComboChallengeMode: Bool {
        comboChallenge != nil && isGuidedDrillMode
    }

    private var comboTargetStepCount: Int {
        normalizedDrillEvents.count
    }

    private var comboLockedStepCount: Int {
        comboStepsHitThisLoop.count
    }

    private var comboBestLockedStepCount: Int {
        max(comboBestRunCount, comboLockedStepCount)
    }

    private var comboProgressPercent: Double {
        guard comboTargetStepCount > 0 else { return 0 }
        return (Double(comboBestLockedStepCount) / Double(comboTargetStepCount)) * 100
    }

    private var displayedAccuracy: Double {
        isComboChallengeMode ? comboProgressPercent : currentAccuracy
    }

    private var activeSessionDuration: TimeInterval {
        isComboChallengeMode ? comboSessionDuration : selectedDuration
    }

    private var currentSessionTitle: String {
        if isComboChallengeMode {
            return comboChallenge?.name ?? "Combo Challenge"
        }
        return activeScratch.name
    }

    private var leadingStat: (icon: String, value: String, label: String, color: Color) {
        if isComboChallengeMode {
            return (
                icon: "point.3.filled.connected.trianglepath.dotted",
                value: "\(comboBestLockedStepCount)/\(max(1, comboTargetStepCount))",
                label: "Best Run",
                color: Color(hex: "00BCD4")
            )
        }
        return (
            icon: "flame.fill",
            value: "\(currentStreak)",
            label: "Streak",
            color: Color(hex: "FF5722")
        )
    }

    private var comboSetupObjective: String? {
        guard isComboChallengeMode else { return nil }
        return "Goal: chain all \(comboTargetStepCount) baby scratches inside one clean phrase window."
    }

    private var comboResultHeadline: String {
        guard isComboChallengeMode else { return "" }
        if comboCompleted {
            return "Phrase Cleared"
        }
        if comboBestLockedStepCount == max(0, comboTargetStepCount - 1) {
            return "One More Hit"
        }
        return "Build The Phrase"
    }

    private var comboResultDetail: String? {
        guard isComboChallengeMode else { return nil }
        let bestRun = "\(comboBestLockedStepCount)/\(max(1, comboTargetStepCount))"
        if comboCompleted {
            return "You chained all \(comboTargetStepCount) steps inside one phrase. Best run: \(bestRun)."
        }
        return "Best run this session: \(bestRun). Keep the hits closer together and clear the full phrase."
    }

    // Truthful hardware naming: a USB audio interface (RANE ONE MKII and
    // similar) is not a microphone, so the ready/off states must not claim
    // "Microphone" while one is the active route.
    private var isUSBHardwareActive: Bool {
        audioEngine.audioHardwareRouteState.transport == .usb
    }

    // DVS readiness requires all three: a selected stereo pair, active PCM,
    // and the decoder confirming valid timecode. No DVS timecode decoder is
    // wired into the iOS multichannel path yet (out of scope for this
    // phase — see project handoff notes), so `decoderReportsValidTimecode`
    // is always false and this state is unreachable until that lands. Do
    // not report "DVS Ready" without wiring a real decoder signal here.
    private var isDVSReady: Bool {
        guard audioEngine.audioHardwareRouteState.selectedStereoPair != nil else { return false }
        guard audioEngine.audioHardwareRouteState.isInputActive else { return false }
        let decoderReportsValidTimecode = false
        return decoderReportsValidTimecode
    }

    // True only once AVAudioSession has actually observed a route (built-in
    // mic, USB interface, whatever) — before that (pre-session, or a
    // malformed/absent route) there is nothing truthful to call a
    // "microphone" at all, so `micStatusTitle` must not default to one.
    private var hasDetectedAudioHardware: Bool {
        audioEngine.audioHardwareRouteState.deviceName != nil
    }

    private var micStatusTitle: String {
        if isDVSReady { return "DVS Ready" }
        switch audioEngine.inputMonitorState {
        case .micOff:
            guard hasDetectedAudioHardware else { return "No Input Connected" }
            return isUSBHardwareActive ? "USB Audio Off" : "Microphone Off"
        case .micLive:
            if isUSBHardwareActive {
                if let name = audioEngine.audioHardwareRouteState.deviceName, !name.isEmpty {
                    return "\(name) Ready"
                }
                return "USB Audio Ready"
            }
            return "Microphone Ready"
        case .listening:
            return "Connected"
        case .noSignal:
            return "No signal"
        }
    }

    private var micStatusIcon: String {
        switch audioEngine.inputMonitorState {
        case .micOff:
            guard hasDetectedAudioHardware else { return "questionmark.circle" }
            return isUSBHardwareActive ? "cable.connector.slash" : "mic.slash.fill"
        case .micLive:
            return isUSBHardwareActive ? "cable.connector" : "mic.fill"
        case .listening:
            return "waveform"
        case .noSignal:
            return "exclamationmark.triangle.fill"
        }
    }

    private var micStatusColor: Color {
        micStatusVariant.color
    }

    /// Shared `StatusBadge` variant for the live mic state — the V3.2 token
    /// for what `micStatusColor` used to express as a raw color.
    private var micStatusVariant: StatusBadgeVariant {
        switch audioEngine.inputMonitorState {
        case .micOff:     return .neutral
        case .micLive:    return .success
        case .listening:  return .accent
        case .noSignal:   return .warning
        }
    }

    private var practiceInputSources: [AudioInputSource] {
        var sources: [AudioInputSource] = [.microphone]
        if audioEngine.hasExternalPracticeInput {
            sources.append(.lineIn)
        }
        return sources
    }

    private var practiceInputHint: String {
        if audioEngine.hasExternalPracticeInput {
            return "Use Microphone for room sound, or switch to Wired Input for a USB/interface or loopback feed into this device."
        }
        return "Use Microphone, or plug in a USB/interface input before starting if you want routed deck audio on this device."
    }

    private var setupModeNote: String {
        if isComboChallengeMode {
            return "Deck video stays live while the phrase cue runs. Add optional beat guidance, or keep live audio only."
        }
        return "Deck video and audio analyze live here. Add optional beat guidance, or keep live input only."
    }

    private var currentTipText: String {
        if isComboChallengeMode {
            return comboCompleted
                ? "Phrase cleared. Hold onto the same clean motion."
                : "Chain four clean baby hits before the phrase window resets."
        }
        if isGuidedDrillMode {
            return "Follow the cue card and hit each move on time."
        }
        return sessionTipText.isEmpty ? (activeScratch.tips.first ?? "Focus on clean execution") : sessionTipText
    }

    private var coachInstruction: ScratchCoachInstruction {
        ScratchCoachInstructionStore.shared.instruction(
            for: normalizeScratchType(input: activeScratch.id),
            scratchDisplayName: activeScratch.name
        )
    }

    private var activeDrillEvent: ScratchRenderEvent? {
        guard let activeDrillEventIndex,
              normalizedDrillEvents.indices.contains(activeDrillEventIndex) else {
            return nil
        }
        return normalizedDrillEvents[activeDrillEventIndex]
    }

    init(
        scratch: Scratch,
        drillTimeline: ScratchRenderTimeline? = nil,
        drillBPM: Double = 90,
        comboChallenge: ComboScratch? = nil,
        usesBackingTrack: Bool = false,
        usesSimplifiedReady: Bool = false
    ) {
        self.scratch = scratch
        self.drillTimeline = drillTimeline
        self.drillBPM = drillBPM
        self.comboChallenge = comboChallenge
        self.usesBackingTrack = usesBackingTrack
        self.usesSimplifiedReady = usesSimplifiedReady
    }

    /// Single derived Practice presentation state over the real iOS Practice
    /// state: `isSessionActive`/`isPaused`/`showingResults` (attempt/pause/
    /// result), `demoPlayer.isPlaying` (reference-audio listen), and
    /// `progressManager.isScratchMastered` (lesson completion). One axis, so
    /// the ready overlay and the live/result surfaces can never contradict.
    ///
    /// Demo mode is reference playback (the Figma "Listen" state), never a live
    /// copy attempt — it is mapped to `.listening`/`.paused` rather than folded
    /// into `.copyActive`, so "Listen" stays reachable from the real
    /// `demoPlayer.isPlaying` owner and the visible state never reads COPY
    /// while the learner is only listening.
    private var practicePresentationState: PracticePresentationState {
        if isDemoAudioMode {
            return isPaused ? .paused : .listening
        }
        return PracticePresentationState.derive(
            isSessionActive: isSessionActive,
            isPaused: isPaused,
            isResult: showingResults,
            isListening: demoPlayer.isPlaying,
            isLessonComplete: progressManager.isScratchMastered(activeScratch.id)
        )
    }
    
    var body: some View {
        GeometryReader { geometry in
            let usesLandscapeCameraSurface = isSessionActive
                && isCameraPreviewVisible
                && geometry.size.width > geometry.size.height

            ZStack {
                if usesLandscapeCameraSurface {
                    Color.black
                        .ignoresSafeArea()
                }

                // Camera feed background — only when a live session is active
                if isCameraPreviewVisible {
                    CameraPreviewView()
                        .ignoresSafeArea()
                }
                
                // Dark overlay for readability
                Color.black.opacity(usesLandscapeCameraSurface ? 0.08 : 0.3)
                    .ignoresSafeArea()
                
                // Main UI overlay
                if usesLandscapeCameraSurface {
                    landscapeCameraPracticeSurface(
                        size: geometry.size,
                        safeAreaInsets: geometry.safeAreaInsets
                    )
                } else {
                    VStack(spacing: 0) {
                        // Top bar
                        topBar(topSafeAreaInset: geometry.safeAreaInsets.top)

                        // Notation-first practice surface — the timing lane fills
                        // all the space below the top bar; status sits in thin HUD
                        // chip rows inside it. Empty until a session starts.
                        if isSessionActive {
                            centerFeedbackArea
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            Spacer()
                        }
                    }
                }
                
                #if DEBUG
                // Diagnostic-only: floats top-right so it does not disturb
                // the active Practice layout in either orientation. Visible
                // only while a session is live, when the engine is running.
                if isSessionActive && !usesLandscapeCameraSurface {
                    debugInputRecordOverlay
                        .padding(.top, geometry.safeAreaInsets.top + 12)
                        .padding(.trailing, 16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: .topTrailing)
                        .allowsHitTesting(true)
                }
                #endif

                // Accuracy burst animation
                if showAccuracyBurst {
                    AccuracyBurstView(accuracy: lastAccuracyValue)
                        .transition(.scale.combined(with: .opacity))
                }
                
                // Results screen
                if showingResults {
                    ResultsOverlayView(
                        scratch: activeScratch,
                        sessionTitle: isComboChallengeMode ? comboChallenge?.name : nil,
                        headline: isComboChallengeMode ? comboResultHeadline : nil,
                        score: currentScore,
                        accuracy: displayedAccuracy,
                        primaryMetricLabel: isComboChallengeMode ? "Phrase Lock" : "Match estimate",
                        attempts: attemptCount,
                        bestStreak: bestStreak,
                        detailNote: comboResultDetail,
                        takeEvidence: practiceTimingPreviewSummary,
                        targetNotation: targetNotation,
                        bpm: Double(practiceBeatStore.bpmValue),
                        evidence: practiceResultNotation,
                        reviewSummary: practiceReviewSummary,
                        continueButtonTitle: isComboChallengeMode ? "Run It Again" : "Practice Again",
                        onContinue: { showingResults = false; resetSession() },
                        onExit: { dismiss() }
                    )
                }
                
                // Pause overlay
                if isPaused {
                    PauseOverlayView(
                        onResume: { resumeSession() },
                        onRestart: { resetSession(); startSession() },
                        onExit: { dismiss() }
                    )
                }
                
                // Pre-session setup
                if !isSessionActive && !showingResults {
                    if usesSimplifiedReady {
                        PracticeReadyOverlay(
                            scratch: activeScratch,
                            micStatusTitle: micStatusTitle,
                            micStatusColor: micStatusColor,
                            targetNotation: targetNotation,
                            bpm: Double(practiceBeatStore.bpmValue),
                            topSafeAreaInset: geometry.safeAreaInsets.top,
                            bottomSafeAreaInset: geometry.safeAreaInsets.bottom,
                            onSetBPM: { practiceBeatStore.setBPM($0) },
                            onStart: { startOpenPractice() },
                            onWatch: { startWatchPractice() },
                            onBack: { dismiss() }
                        )
                    } else {
                        SessionSetupOverlay(
                            scratch: activeScratch,
                            practiceBeatStore: practiceBeatStore,
                            selectedDuration: $selectedDuration,
                            selectedAssistMode: assistModeBinding,
                            durationOptions: durationOptions,
                            sessionTitle: isComboChallengeMode ? "Combo Challenge" : "Practice",
                            sessionDescription: isComboChallengeMode ? comboChallenge?.description : nil,
                            objectiveText: comboSetupObjective,
                            modeNote: setupModeNote,
                            fixedDurationLabel: isComboChallengeMode ? "45 sec | looping phrase" : nil,
                            startButtonTitle: isComboChallengeMode ? "Start Challenge" : "Start Session",
                            selectedInputSource: audioEngine.currentInputSource,
                            inputSourceOptions: practiceInputSources,
                            activeInputName: audioEngine.activeInputName,
                            inputRouteHint: practiceInputHint,
                            detectedUSBDeviceName: isUSBHardwareActive ? audioEngine.audioHardwareRouteState.deviceName : nil,
                            topSafeAreaInset: geometry.safeAreaInsets.top,
                            bottomSafeAreaInset: geometry.safeAreaInsets.bottom,
                            onSelectInputSource: { source in audioEngine.selectInputSource(source) },
                            onStart: { startSession() },
                            onBack: { dismiss() }
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { viewportSize = geometry.size }
            .onChange(of: geometry.size) { _, newSize in
                viewportSize = newSize
            }
        }
        .onAppear {
            setupAudioEngine()
        }
        .onDisappear {
            cleanupSession()
            practiceBeatStore.handleLeavingPractice()
        }
        .onReceive(midiControllerDispatcher.$livePlatterMovementEvents) { _ in
            updateLivePerformedNotation()
        }
        .overlay {
            if showMicRationale {
                microphoneRationaleOverlay
            }
        }
        .sheet(isPresented: $showingCaptureHelp) {
            CaptureHelpView {
                showingCaptureHelp = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    showingQuickStartAgain = true
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showingQuickStartAgain) {
            QuickStartView(onFinish: completeQuickStartReview)
                .interactiveDismissDisabled()
        }
    }

    /// Notation-first active Practice composition for every landscape device.
    /// The camera remains a clean background source, while the target and live
    /// performance lanes fill the safe workspace beneath overlaid transport
    /// controls. Portrait keeps the existing stacked composition.
    private func landscapeCameraPracticeSurface(
        size: CGSize,
        safeAreaInsets: EdgeInsets
    ) -> some View {
        ZStack {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button(action: pauseSession) {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay {
                                Circle()
                                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Pause practice")
                    .accessibilityHint("Pause to resume, restart, or exit")

                    Spacer(minLength: 12)

                    HStack(spacing: 8) {
                        Circle()
                            .fill(timeRemaining < 60
                                  ? ScratchLabDesign.Sem.danger
                                  : ScratchLabDesign.Sem.success)
                            .frame(width: 8, height: 8)

                        Text(formatTime(timeRemaining))
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 13)
                    .frame(height: 40)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Practice time remaining \(formatTime(timeRemaining))")
                }
                .padding(.leading, max(safeAreaInsets.leading, 12))
                .padding(.trailing, max(safeAreaInsets.trailing, 12))
                .padding(.top, max(safeAreaInsets.top, 8))

                Spacer(minLength: 0)
            }

            landscapeLiveNotationOverlay
                .padding(.horizontal, max(max(safeAreaInsets.leading, safeAreaInsets.trailing), 16))
                .padding(.top, max(safeAreaInsets.top, 8) + 56)
                .padding(.bottom, max(safeAreaInsets.bottom, 8) + 116)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            SamplePositionWaveformView()
                .frame(height: 108)
                .padding(.horizontal, max(max(safeAreaInsets.leading, safeAreaInsets.trailing), 16))
                .padding(.bottom, max(safeAreaInsets.bottom, 8))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

            feedbackBanner
                .padding(.horizontal, 16)
                .padding(.bottom, max(safeAreaInsets.bottom, 10) + 112)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .ignoresSafeArea()
    }

    /// Read-only landscape notation presentation. It consumes the same live
    /// movement events and target lane already used by the portrait panel,
    /// but removes all card/background chrome so the camera remains visible.
    private var landscapeLiveNotationOverlay: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text("LIVE NOTATION")
                    .font(ScratchLabDesign.Typo.metricLabel)
                    .foregroundStyle(ScratchLabDesign.Sem.accent)

                Spacer(minLength: 8)

                Text("CAMERA CLEAN · NOTATION SEPARATE")
                    .font(ScratchLabDesign.Typo.statusPill)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
            }

            Text("TARGET")
                .font(ScratchLabDesign.Typo.statusPill)
                .foregroundStyle(ScratchLabDesign.Notation.targetTrace)

            if let lane = activeLane {
                PracticeLandscapeTargetTrace(content: lane.content, clock: lane.clock)
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

            if !livePerformedMovementEvents.isEmpty {
                PracticeLandscapePerformedTrace(events: livePerformedMovementEvents)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
            } else {
                Text("Waiting for movement input")
                    .font(ScratchLabDesign.Typo.caption)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .layoutPriority(1)
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
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(livePerformedMovementEvents.isEmpty
                            ? "Target reference notation, waiting for movement input"
                            : "Target reference and live performed notation")
    }
    
    // MARK: - Top Bar
    
    private func topBar(topSafeAreaInset: CGFloat) -> some View {
        VStack(spacing: 12) {
            HStack {
                Button(action: {
                    if isSessionActive {
                        pauseSession()
                    } else {
                        dismiss()
                    }
                }) {
                    Image(systemName: isSessionActive ? "pause.fill" : "chevron.left")
                        .font(.title2)
                        .foregroundColor(ScratchLabDesign.Sem.textPrimary)
                        .padding(12)
                        .background(ScratchLabDesign.Surface.scrim)
                        .clipShape(Circle())
                }

                Spacer()

                if isSessionActive {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(timeRemaining < 60 ? ScratchLabDesign.Sem.danger : ScratchLabDesign.Sem.success)
                            .frame(width: 10, height: 10)

                        Text(formatTime(timeRemaining))
                            .font(ScratchLabDesign.Typo.keyMetric)
                            .foregroundColor(ScratchLabDesign.Sem.textPrimary)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(ScratchLabDesign.Surface.scrim)
                    .overlay(
                        Capsule()
                            .stroke(ScratchLabDesign.Border.default, lineWidth: 1)
                    )
                }

                Spacer()

                if isSessionActive {
                    Color.clear
                        .frame(width: 48, height: 48)
                        .accessibilityHidden(true)
                } else {
                    Button(action: { showingCaptureHelp = true }) {
                        Image(systemName: "questionmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(ScratchLabDesign.Sem.textPrimary)
                            .padding(12)
                            .background(ScratchLabDesign.Surface.scrim)
                            .clipShape(Circle())
                    }
                    .accessibilityLabel("Open capture help")
                }
            }

            if isSessionActive {
                practiceStatusStrip
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, topSafeAreaInset + 12)
    }

    private var practiceStatusStrip: some View {
        ViewThatFits(in: .horizontal) {
            expandedPracticeStatusBadges
            compactPracticeStatusBadges
            collapsedPracticeStatusSummary
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Full status fidelity when the viewport has room. `fixedSize` makes
    /// `ViewThatFits` measure the real chip widths instead of squeezing or
    /// wrapping them into a deceptively narrow row.
    private var expandedPracticeStatusBadges: some View {
        HStack(spacing: 8) {
            StatusBadge(
                title: "Practice",
                value: practicePresentationState.label,
                variant: practicePresentationState.variant,
                systemImage: "waveform"
            )
            StatusBadge(
                title: "Audio",
                value: micStatusTitle,
                variant: micStatusVariant,
                systemImage: micStatusIcon
            )
            if let audioError = audioEngine.lastAudioError {
                StatusBadge(
                    title: "Issue",
                    value: audioError,
                    variant: .danger,
                    systemImage: "exclamationmark.triangle.fill"
                )
            }
            if isGuidedDrillMode {
                StatusBadge(
                    title: "BPM",
                    value: "\(practiceBeatStore.bpmValue)",
                    variant: .accent,
                    systemImage: "metronome"
                )
                if let activeDrillEventIndex {
                    StatusBadge(
                        title: "Step",
                        value: "\(activeDrillEventIndex + 1)/\(normalizedDrillEvents.count)",
                        variant: .warning,
                        systemImage: "number"
                    )
                }
            } else if !isCompactVertical {
                StatusBadge(
                    title: "Scratch",
                    value: activeScratch.name,
                    variant: .accent,
                    systemImage: "waveform"
                )
            }
            StatusBadge(
                title: "Beat",
                value: practiceBeatStatusValue,
                variant: practiceBeatStore.isBeatEnabled ? .success : .neutral,
                systemImage: practiceBeatStore.isBeatEnabled ? "metronome.fill" : "speaker.slash.fill"
            )
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Compact single-line chips retain every live status while dropping the
    /// repeated title row. Long, variable error copy becomes an honest
    /// "Audio issue" chip with the full message preserved for VoiceOver.
    private var compactPracticeStatusBadges: some View {
        HStack(spacing: 6) {
            StatusBadge(
                title: "",
                value: practicePresentationState.label,
                variant: practicePresentationState.variant,
                systemImage: "waveform"
            )
            StatusBadge(
                title: "",
                value: micStatusTitle,
                variant: micStatusVariant,
                systemImage: micStatusIcon
            )
            if let audioError = audioEngine.lastAudioError {
                StatusBadge(
                    title: "",
                    value: "Audio issue",
                    variant: .danger,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .accessibilityLabel("Audio issue: \(audioError)")
            }
            if isGuidedDrillMode {
                StatusBadge(
                    title: "",
                    value: "\(practiceBeatStore.bpmValue) BPM",
                    variant: .accent,
                    systemImage: "metronome"
                )
                if let activeDrillEventIndex {
                    StatusBadge(
                        title: "",
                        value: "\(activeDrillEventIndex + 1)/\(normalizedDrillEvents.count)",
                        variant: .warning,
                        systemImage: "number"
                    )
                }
            }
            StatusBadge(
                title: "",
                value: practiceBeatStatusValue,
                variant: practiceBeatStore.isBeatEnabled ? .success : .neutral,
                systemImage: practiceBeatStore.isBeatEnabled ? "metronome.fill" : "speaker.slash.fill"
            )
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Narrowest fallback is one bounded summary chip, never another scroll
    /// region. It remains readable at accessibility sizes and exposes the
    /// complete underlying status/error text to VoiceOver.
    private var collapsedPracticeStatusSummary: some View {
        HStack(spacing: 8) {
            Image(systemName: audioEngine.lastAudioError == nil
                  ? "waveform"
                  : "exclamationmark.triangle.fill")
                .font(ScratchLabDesign.Typo.statusPill)
                .foregroundStyle(audioEngine.lastAudioError == nil
                                 ? practicePresentationState.variant.color
                                 : ScratchLabDesign.Sem.danger)
                .accessibilityHidden(true)

            Text(collapsedPracticeStatusText)
                .font(ScratchLabDesign.Typo.statusPill)
                .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .padding(.horizontal, ScratchLabDesign.Badge.horizontalPadding)
        .padding(.vertical, ScratchLabDesign.Badge.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ScratchLabDesign.Badge.background,
            in: RoundedRectangle(cornerRadius: ScratchLabDesign.Badge.cornerRadius, style: .continuous)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(practiceStatusAccessibilitySummary)
    }

    private var practiceBeatStatusValue: String {
        guard practiceBeatStore.isBeatEnabled else { return "Off" }
        return practiceBeatStore.isPlaying
            ? "\(practiceBeatStore.beatEngineMode.title) On"
            : "\(practiceBeatStore.beatEngineMode.title) Ready"
    }

    private var collapsedPracticeStatusText: String {
        var values = [
            practicePresentationState.label,
            StatusBadge.dedupedStatusValue(title: "Audio", value: micStatusTitle)
        ]
        if audioEngine.lastAudioError != nil {
            values.append("Audio issue")
        }
        if isGuidedDrillMode {
            values.append("\(practiceBeatStore.bpmValue) BPM")
            if let activeDrillEventIndex {
                values.append("Step \(activeDrillEventIndex + 1)/\(normalizedDrillEvents.count)")
            }
        }
        values.append("Beat \(practiceBeatStatusValue)")
        return values.joined(separator: " · ")
    }

    private var practiceStatusAccessibilitySummary: String {
        var values = [
            "Practice \(practicePresentationState.label)",
            "Audio \(micStatusTitle)"
        ]
        if let audioError = audioEngine.lastAudioError {
            values.append("Audio issue: \(audioError)")
        }
        if isGuidedDrillMode {
            values.append("Tempo \(practiceBeatStore.bpmValue) BPM")
            if let activeDrillEventIndex {
                values.append("Step \(activeDrillEventIndex + 1) of \(normalizedDrillEvents.count)")
            }
        }
        values.append("Beat \(practiceBeatStatusValue)")
        return values.joined(separator: ", ")
    }

    private func completeQuickStartReview() {
        hasSeenQuickStart = true
        quickStartVersion = QuickStartSettings.currentVersion
        showingQuickStartAgain = false
    }
    
    // MARK: - Center Feedback Area
    
    // The unified notation-first practice surface. The timing lane dominates
    // (~75% of the area); status, metrics and the beat control sit in two thin
    // chip rows above and below it. Both orientations read TIME LEFT → RIGHT
    // — portrait used to map time vertically, which fanned strokes left and
    // right around a vertical centre column and read as bilateral symmetry
    // (a "mirrored" lane) rather than a temporal flow. Horizontal time means
    // the eye reads scroll direction as time first; the motion axis (up = push,
    // down = pull) becomes a secondary articulation signal.
    private var centerFeedbackArea: some View {
        // `LaneAxis.horizontal` regardless of size class. The lane itself is
        // still axis-parametric (it can render vertical) — this is just the
        // Practice surface's choice.
        let axis: LaneAxis = .horizontal
        // In iPhone landscape, the lane was collapsing to zero height when the
        // top HUD + GuidedCutCueLayer + bottom HUD claimed all available
        // vertical space. A min-height + tighter spacing keeps the lane
        // visible without removing any of the surrounding elements.
        let laneMinHeight: CGFloat = isCompactVertical ? 110 : 0
        return VStack(spacing: isCompactVertical ? 4 : 8) {
            practiceTopHUD

            notationLanePanel(axis: axis)
                .frame(maxWidth: .infinity, minHeight: laneMinHeight, maxHeight: .infinity)
                .overlay(alignment: .bottom) {
                    feedbackBanner.padding(.bottom, 10)
                }

            // Guided mode keeps its crossfader cue beneath the lane. Shares
            // `activeLane`'s clock with the motion lane above it — one
            // playhead timeline drives both the platter curve and this cue,
            // instead of the cue re-deriving its own loop position.
            if practiceAssistMode == .guided, let notation = targetNotation,
               let clock = activeLane?.clock {
                GuidedCutCueLayer(notation: notation, clock: clock)
            }

            practiceBottomHUD
        }
        .padding(.horizontal, 16)
        .padding(.vertical, isCompactVertical ? 6 : 10)
    }

    // Thin top chip row: what the session is, and — when scored — how it goes.
    private var practiceTopHUD: some View {
        HStack(spacing: 8) {
            Text(currentSessionTitle)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(ScratchLabDesign.Sem.textPrimary)
                .lineLimit(1)
                .shadow(color: .black.opacity(0.5), radius: 2, y: 1)

            Spacer(minLength: 8)

            // The notation status pill lives in the lane panel's own
            // "TARGET PATTERN" header (notationLanePanel) — not duplicated here.
            // Demo-audio modes carry no running score, so no metrics chip.
            if isScoredPracticeMode {
                practiceMetricsChip
            }
        }
    }

    // Compact scored-practice metrics — shared StatusBadge instead of the
    // legacy StatDisplay so the live HUD reads as the same V3.2 system.
    private var leadingStatVariant: StatusBadgeVariant {
        isComboChallengeMode ? .info : .warning
    }

    @ViewBuilder
    private var practiceMetricsChip: some View {
        HStack(spacing: 8) {
            StatusBadge(
                title: leadingStat.label,
                value: leadingStat.value,
                variant: leadingStatVariant,
                systemImage: leadingStat.icon
            )
            StatusBadge(
                title: "Practice estimate",
                value: "\(currentScore)",
                variant: .accent,
                systemImage: "star.fill"
            )
        }
        .accessibilityElement(children: .contain)
    }

    // Thin bottom chip row: contextual guidance plus the practice-beat control.
    private var practiceBottomHUD: some View {
        HStack(spacing: 8) {
            bottomHUDContext
            Spacer(minLength: 8)
            // Demo-audio modes never open the mic, so no mic status chip.
            if isScoredPracticeMode {
                micChip
            }
            beatToggleChip
        }
    }

    // The leading bottom-row chip adapts to the session: a guided cue, the
    // combo phrase progress, or a practice tip.
    @ViewBuilder
    private var bottomHUDContext: some View {
        if isGuidedDrillMode {
            guidedCueChip
        } else if isComboChallengeMode {
            comboProgressChip
        } else {
            tipChip
        }
    }

    // Guided-drill cue, compact: the cue name and the step counter.
    private var guidedCueChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(ScratchLabDesign.Sem.accent)
            Text(activeDrillEvent.map(drillCueTitle(for:)) ?? "Get ready")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(ScratchLabDesign.Sem.textPrimary)
                .lineLimit(1)
            if let activeDrillEventIndex {
                Text("\(activeDrillEventIndex + 1)/\(normalizedDrillEvents.count)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(ScratchLabDesign.Sem.textSecondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(ScratchLabDesign.Surface.scrim, in: Capsule())
    }

    // Combo-challenge phrase progress, compact.
    private var comboProgressChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.grid.3x3.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(ScratchLabDesign.Sem.accent)
            Text("Phrase \(comboLockedStepCount)/\(max(1, comboTargetStepCount))")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(ScratchLabDesign.Sem.textPrimary)
            Text("· best \(comboBestLockedStepCount)")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(ScratchLabDesign.Sem.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(ScratchLabDesign.Surface.scrim, in: Capsule())
    }

    // A practice tip, compact.
    @ViewBuilder
    private var tipChip: some View {
        if !currentTipText.isEmpty {
            HStack(spacing: 6) {
                Text("TIP")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(ScratchLabDesign.Sem.accent)
                Text(currentTipText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(ScratchLabDesign.Sem.textPrimary.opacity(0.8))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(ScratchLabDesign.Surface.scrim, in: Capsule())
        }
    }

    #if DEBUG
    // Diagnostic-only Practice control. Tapping starts a 20-second raw
    // input capture in `AudioEngine` (DEBUG-only path); the saved WAV
    // path is logged to console and surfaced under the button so it can
    // be lifted off-device for matcher debugging. Never wired into
    // Release builds; never feeds analysis, scoring, or export.
    private var debugInputRecordOverlay: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button {
                audioEngine.startDebugRecording()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: audioEngine.isDebugRecording
                          ? "record.circle.fill"
                          : "waveform.badge.mic")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(audioEngine.isDebugRecording
                                         ? Color(hex: "F44336")
                                         : .white)
                    Text(audioEngine.isDebugRecording
                         ? "Recording input…"
                         : "Record 20s Input")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.6), in: Capsule())
                .overlay(
                    Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(audioEngine.isDebugRecording || !audioEngine.isRunning)
            .accessibilityHint(
                audioEngine.isDebugRecording
                    ? "A debug input recording is already in progress"
                    : audioEngine.isRunning
                        ? "Records twenty seconds of raw input for diagnostics"
                        : "Start the audio engine before recording diagnostic input"
            )

            if let url = audioEngine.lastDebugRecordingURL {
                Text("Saved: \(url.lastPathComponent)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.5), in: Capsule())
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(audioEngine.isDebugRecording
                            ? "Recording input"
                            : "Record twenty seconds of input")
    }
    #endif

    // Compact microphone status: a state dot plus the live input level.
    // In iPhone landscape the level indicator is suppressed — its underlying
    // HStack-of-20-bars overflows the 46pt frame and collides with the
    // Play Beat button. The `Audio · …` chip in the status strip carries
    // the same state without the overflow.
    private var micChip: some View {
        HStack(spacing: 6) {
            Image(systemName: micStatusIcon)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(micStatusColor)
            if !isCompactVertical {
                AudioLevelIndicator(level: audioEngine.inputLevel)
                    .frame(width: 46)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(ScratchLabDesign.Surface.scrim, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Audio input: \(micStatusTitle)")
    }

    // Compact practice-beat toggle. When the user hasn't enabled a beat in
    // SessionSetupOverlay (`practiceBeatStore.isBeatEnabled == false`), the
    // chip surfaces an honest "Beat Off · slashed speaker" instead of a
    // tappable-looking "Play Beat" — same `.disabled` semantics, just no
    // longer disguising the disabled state.
    private var beatToggleChip: some View {
        Button(action: handleBeatButton) {
            HStack(spacing: 6) {
                Image(systemName: beatChipIconName)
                    .font(.system(size: 10, weight: .bold))
                Text(beatChipLabel)
                    .font(.system(size: 12, weight: .bold))
            }
            .foregroundColor(practiceBeatStore.isBeatEnabled ? ScratchLabDesign.Sem.textOnAccent : ScratchLabDesign.Sem.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                practiceBeatStore.isBeatEnabled
                    ? (practiceBeatStore.isPlaying ? ScratchLabDesign.Sem.warning : ScratchLabDesign.Sem.success)
                    : ScratchLabDesign.Surface.disabledFill,
                in: Capsule())
        }
        .accessibilityLabel(practiceBeatStore.isBeatEnabled
                            ? (practiceBeatStore.isPlaying
                               ? PracticeBeatUIContract.stopLabel
                               : PracticeBeatUIContract.playLabel)
                            : "Beat Off")
        .accessibilityHint(practiceBeatStore.isBeatEnabled
            ? "Stops or resumes the selected practice beat"
            : "Enables and starts the selected practice beat")
    }

    private var beatChipIconName: String {
        guard practiceBeatStore.isBeatEnabled else { return "speaker.slash.fill" }
        return practiceBeatStore.isPlaying ? "stop.fill" : "play.fill"
    }

    private var beatChipLabel: String {
        guard practiceBeatStore.isBeatEnabled else { return "Beat Off" }
        return practiceBeatStore.isPlaying
            ? PracticeBeatUIContract.stopLabel
            : PracticeBeatUIContract.playLabel
    }

    private func handleBeatButton() {
        if practiceBeatStore.isBeatEnabled {
            practiceBeatStore.togglePlayback()
        } else {
            practiceBeatStore.setBeatEnabled(true)
            practiceBeatStore.startPlayback()
        }
    }

    @ViewBuilder
    private var feedbackBanner: some View {
        if showFeedback && !lastFeedback.isEmpty {
            VStack(spacing: 6) {
                ForEach(lastFeedback, id: \.self) { feedback in
                    Text(feedback)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(feedbackColor)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(ScratchLabDesign.Surface.scrim)
                        .cornerRadius(ScratchLabDesign.Radius.control)
                }
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    /// The target rendered during the active session. Baby Scratch demo-audio
    /// modes use the exact 32-stroke BBB timeline paired with
    /// `baby_noBeat.wav`; scored modes keep the BPM-materialized canonical
    /// teaching pattern. This distinction is session-only, so the Ready card
    /// continues to show the concise canonical target.
    private var activeLaneTargetNotation: ScratchNotation? {
        guard isDemoAudioMode,
              activeScratch.id == CaptureSessionScratchType.babyScratch.rawValue else {
            return targetNotation
        }
        return ScratchNotation.babyScratchDemo ?? targetNotation
    }

    /// Beat-grid tempo for the active lane. The bundled BBB recording is a
    /// fixed 79 BPM reference and must not inherit an unrelated user-selected
    /// practice tempo.
    private var activeLaneBPM: Double {
        if isDemoAudioMode,
           activeScratch.id == CaptureSessionScratchType.babyScratch.rawValue {
            return Double(ScratchLabDemoSessionBuilder.demoBPM)
        }
        return Double(practiceBeatStore.bpmValue)
    }

    // The notation lane this mode + orientation should render, paired with its
    // clock. Demo follows the exact bundled demo audio; Auto-cut / Guided loop
    // the target pattern; Coached / Open hold it parked. `nil` when the active
    // scratch ships no notation.
    private var activeLane: (content: LaneContent, clock: LaneClock)? {
        if practiceAssistMode == .demo, let reel = demoReel {
            return (LaneContent(reel: reel),
                    .audioTime { demoPlayer.sampledPlaybackTime() })
        }
        guard let notation = activeLaneTargetNotation else { return nil }
        // Pass the session's selected BPM through so `ScratchMotionLane`'s
        // existing beat-grid renderer (gated on `content.beatsPerMinute`)
        // lights up. The grid is a visual timing reference — shown even
        // when the audible click track is off.
        let content = LaneContent(notation: notation,
                                  beatsPerMinute: activeLaneBPM)
        switch practiceAssistMode {
        case .demo, .demoWithMotion:
            // Follow the demo audio position. `.demo` with a valid reel took
            // the branch above; `.demoWithMotion` always lands here (canonical
            // target notation + a live performance lane, never the reel).
            return (content, .audioTime { demoPlayer.sampledPlaybackTime() })
        case .autoCut, .guided, .coached:
            // Coached promotes from `.fixed(0)` to a wall-clock loop so the
            // lane visibly moves under the action line while the mic listens.
            // The explainer used to overpromise an in-session "vs target"
            // comparison; the looping reference at least delivers the
            // temporal flow that promise implies. Per-attempt user overlays
            // are still Phase 2 work.
            return (content, .looping(start: notationClockStartDate,
                                      duration: content.duration))
        case .open:
            // Open stays parked: it's the freestyle / static-reference mode.
            return (content, .fixed(0))
        }
    }

    // The unified notation-first timing lane — the primary learning surface in
    // every mode and orientation. Auto-cut / Guided / Coached / Open /
    // Demo + My Motion render through the canonical `ScratchNotationPanel`
    // (`ScratchPhraseChartView`) — the same renderer as the pre-session
    // "TARGET — COPY THIS" card and macOS Review — so target geometry, colour
    // tokens, turnaround markers, and direction cues read identically
    // everywhere. Reference-only Demo keeps `ScratchMotionLane`: its
    // call-and-response reel carries demo/copy segments and derived ghost
    // strokes that `ScratchNotation` has no vocabulary for, and it never
    // shows a live-performance overlay (see `updateLivePerformedNotation`'s
    // `isReferenceOnlyDemo` guard). Demo + My Motion is *not* reference-only:
    // it reuses the canonical target/performance surface below, adding a live
    // performed lane driven by the demo-audio clock. A status chip names the
    // runtime state.
    @ViewBuilder
    private func notationLanePanel(axis: LaneAxis) -> some View {
        if let lane = activeLane {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("TARGET")
                        .font(ScratchLabDesign.Typo.technical)
                        .foregroundStyle(ScratchLabDesign.Sem.accent)
                    Spacer()
                    notationStatusChip
                }

                notationInstructionalLine(content: lane.content, clock: lane.clock)

                if practiceAssistMode == .demo {
                    ScratchMotionLane(content: lane.content, clock: lane.clock, axis: axis,
                                      feedbackState: notationFeedbackState)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let activeLaneTargetNotation {
                    // Fixed-height cards (see `canonicalLiveNotationPanel`) need
                    // `.top` here, not the default `.center` — on the taller
                    // iPad frame, centering left a large dead gap between the
                    // instructional line above and the chart.
                    //
                    // Demo + My Motion: the performed lane's visible window and
                    // the target playhead are both driven by the demo-audio
                    // clock (`lane.clock` is `.audioTime` here), and the lane
                    // shows a truthful "connect a controller" state instead of
                    // an empty trace when there is no live platter signal.
                    canonicalLiveNotationPanel(
                        targetNotation: activeLaneTargetNotation,
                        duration: lane.content.duration,
                        clock: lane.clock,
                        performedWindowFollowsClock: practiceAssistMode == .demoWithMotion,
                        showNoMotionPlaceholder: practiceAssistMode == .demoWithMotion
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        } else {
            // Graceful no-target state: this technique has no canonical
            // `BeatPattern` in `ScratchNotation.canonicalBeatPatterns`, so no
            // target lane is rendered — never an invented or guessed pattern.
            // The slot keeps its layout size (like the Spacer it replaces).
            VStack(spacing: 6) {
                Text("Target notation isn't available for \(activeScratch.name) yet.")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(ScratchLabDesign.Sem.textSecondary)
                    .multilineTextAlignment(.center)
                Text("Practice freely — a notation lane appears once this technique has a verified target pattern.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(ScratchLabDesign.Sem.textTertiary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // Canonical target/performance surface for Auto-cut, Guided, Coached, and
    // Open — the same `ScratchNotationPanel` → `ScratchPhraseChartView` pair
    // the pre-session "TARGET — COPY THIS" card and the existing live
    // performance overlay already use (previously only the performance half
    // of this pair rendered during a live session; the target half rendered
    // through the separate `ScratchMotionLane`). `ScratchPhraseChartView`
    // renders one static full phrase (no scrolling/tiling), so the moving
    // element is the playhead, not the content — `clock.now(at:)` is always
    // within `[0, duration]` here (`.looping` wraps via modulo, `.fixed`
    // returns a constant in range; `.audioTime` is Demo-only and never
    // reaches this branch), so it maps directly onto the static chart with
    // no extra remapping. The performance lane keeps its own pre-existing
    // rolling `livePerformanceDomain` window unchanged — it was already
    // correct; only its neighbour (the target lane) was rendering through
    // the wrong component.
    //
    // Canvas heights target macOS's own dominant Practice teaching surface
    // proportions (`MacAnalyzerView.swift` / `LivePerformedNotationTracker
    // .swift`): 220pt for target+performance shown together, 320pt for
    // target alone — `ScratchPhraseChartView`'s fader-lane fraction and
    // label sizes are tuned against those values. A visual pass across
    // iPhone/iPad portrait/landscape found two failure modes from picking
    // just one strategy: deriving the height purely from available space
    // stretches the canvas far past those tuned proportions on iPad
    // (mostly-empty fader lane); using the fixed macOS values unconditionally
    // overflows the short iPhone-landscape frame and collides with the
    // bottom coaching HUD. Capping the macOS value against what's actually
    // available avoids both: iPad settles at the designed 220/320 (there's
    // always room to spare), iPhone landscape shrinks below it to fit.
    // Per-panel label line + card padding, matching `ScratchNotationPanel`'s
    // own standard-presentation chrome (label row + `Card.padding` top/bottom).
    private static let notationChromeAllowance: CGFloat = 34

    // Pure height math, pulled out of the view builder below — nesting this
    // logic inline inside `GeometryReader`/`TimelineView`'s closures made the
    // combined expression too complex for the compiler to type-check
    // ("generic parameter 'Content' could not be inferred").
    private static func liveNotationCanvasHeights(
        availableHeight: CGFloat, hasPerformance: Bool, spacing: CGFloat
    ) -> (target: CGFloat, performance: CGFloat) {
        guard hasPerformance else {
            let target = max(60, min(320, availableHeight - notationChromeAllowance))
            return (target, 0)
        }
        let halfBudget = (availableHeight - spacing) / 2
        let target = max(60, min(220, halfBudget - notationChromeAllowance))
        let performance = max(48, min(220, halfBudget - notationChromeAllowance))
        return (target, performance)
    }

    /// One demo-audio-clock trailing window, in seconds. Matches the width of
    /// `livePerformanceDomain` so Demo + My Motion and the scored preview modes
    /// show the same amount of recent motion.
    private static let liveNotationClockWindowSeconds: TimeInterval = 3.2

    /// A rolling `[end - seconds, end]` range, clamped so the lower bound is
    /// never negative and the bounds are always ordered. Demo + My Motion uses
    /// this to place the performed lane on the same clock as the target
    /// playhead (the demo-audio position) instead of the performed events'
    /// own timestamps.
    private static func rollingClockWindow(
        endingAt end: TimeInterval, seconds: TimeInterval
    ) -> ClosedRange<TimeInterval> {
        max(0, end - seconds)...max(seconds, end)
    }

    // Canonical target/performance surface for Auto-cut, Guided, Coached,
    // Open, and Demo + My Motion — the same `ScratchNotationPanel` →
    // `ScratchPhraseChartView` pair the pre-session "TARGET — COPY THIS" card
    // and the existing live performance overlay already use (previously only
    // the performance half of this pair rendered during a live session; the
    // target half rendered through the separate `ScratchMotionLane`).
    // `ScratchPhraseChartView` renders one static full phrase (no
    // scrolling/tiling), so the moving element is the playhead, not the
    // content. The playhead time is folded onto `[0, duration)` below:
    // `.looping` already wraps via modulo and `.fixed` returns a constant in
    // range (no-ops under the fold); only the `.audioTime` clock (Demo /
    // Demo + My Motion) can run past one target cycle and needs it. The
    // performance lane keeps its own rolling `livePerformanceDomain` window
    // for the scored modes; Demo + My Motion instead follows the demo-audio
    // clock via `performedWindowFollowsClock`.
    //
    // Canvas heights target macOS's own dominant Practice teaching surface
    // proportions (`MacAnalyzerView.swift` / `LivePerformedNotationTracker
    // .swift`): 220pt for target+performance shown together, 320pt for
    // target alone — `ScratchPhraseChartView`'s fader-lane fraction and
    // label sizes are tuned against those values. A visual pass across
    // iPhone/iPad portrait/landscape found two failure modes from picking
    // just one strategy: deriving the height purely from available space
    // stretches the canvas far past those tuned proportions on iPad
    // (mostly-empty fader lane); using the fixed macOS values unconditionally
    // overflows the short iPhone-landscape frame and collides with the
    // bottom coaching HUD. Capping the macOS value against what's actually
    // available (`liveNotationCanvasHeights` above) avoids both: iPad
    // settles at the designed 220/320 (there's always room to spare), iPhone
    // landscape shrinks below it to fit.
    @ViewBuilder
    private func canonicalLiveNotationPanel(targetNotation: ScratchNotation,
                                            duration: TimeInterval,
                                            clock: LaneClock,
                                            performedWindowFollowsClock: Bool = false,
                                            showNoMotionPlaceholder: Bool = false) -> some View {
        let hasPerformance = !livePerformedMovementEvents.isEmpty
        // The placeholder occupies the same slot as a real performance lane,
        // so the height split must treat it like one. For every existing
        // caller `showNoMotionPlaceholder` is false and this is unchanged.
        let showsPerformanceSlot = hasPerformance || showNoMotionPlaceholder
        let spacing = ScratchLabDesign.Spacing.itemTight

        GeometryReader { proxy in
            let heights = Self.liveNotationCanvasHeights(
                availableHeight: proxy.size.height, hasPerformance: showsPerformanceSlot, spacing: spacing
            )
            TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
                let rawNow = clock.now(at: timeline.date)
                // Fold onto `[0, duration)` for the playhead. `.looping`
                // already returns a value in that range and `.fixed` a
                // constant in it (both no-ops); only `.audioTime`
                // (Demo / Demo + My Motion) can exceed one target cycle.
                let now = duration > 0
                    ? rawNow.truncatingRemainder(dividingBy: duration)
                    : rawNow
                let actionLineFraction = duration > 0
                    ? min(max(CGFloat(now / duration), 0), 1)
                    : 0
                // Demo + My Motion drives the performed window off the same
                // demo-audio clock as the target playhead; every other mode
                // keeps the pre-existing event-timestamp window.
                let performedDomain: ClosedRange<TimeInterval>? = performedWindowFollowsClock
                    ? Self.rollingClockWindow(endingAt: rawNow,
                                              seconds: Self.liveNotationClockWindowSeconds)
                    : livePerformanceDomain

                VStack(alignment: .leading, spacing: spacing) {
                    ZStack {
                        ScratchNotationPanel(
                            lane: .target,
                            presentation: .standard,
                            source: .target(targetNotation),
                            bpm: Double(practiceBeatStore.bpmValue),
                            playheadTime: now,
                            mode: .liveComparison,
                            canvasHeightOverride: heights.target
                        )
                        NotationFeedbackOverlay(
                            state: notationFeedbackState,
                            axis: .horizontal,
                            actionLineFraction: actionLineFraction
                        )
                        .allowsHitTesting(false)
                    }

                    if hasPerformance {
                        ScratchNotationPanel(
                            lane: .performance,
                            presentation: .standard,
                            source: .performedPlatter(livePerformedMovementEvents),
                            bpm: Double(practiceBeatStore.bpmValue),
                            domain: performedDomain,
                            mode: .liveComparison,
                            canvasHeightOverride: heights.performance
                        )
                    } else if showNoMotionPlaceholder {
                        // Truthful "no live platter signal" state — reuses the
                        // canonical panel's own `.empty` presentation rather
                        // than drawing a fake zero-motion trace. The target /
                        // demo playback above continues normally.
                        ScratchNotationPanel(
                            lane: .performance,
                            presentation: .standard,
                            source: .empty("Connect a controller to see your motion"),
                            bpm: Double(practiceBeatStore.bpmValue),
                            mode: .liveComparison,
                            canvasHeightOverride: heights.performance
                        )
                    }
                }
            }
        }
    }

    // What's happening *now* on the action line — used to live as an overlay
    // chip inside the lane, dead-centre over the strokes. Lifted out into a
    // small HUD line in the lane header so the notation graph contains only
    // the graph and the instructional language reads as part of the header
    // structure. Ticks at 4 Hz off the same clock the lane uses, which is
    // far more often than segment boundaries change.
    @ViewBuilder
    private func notationInstructionalLine(content: LaneContent, clock: LaneClock) -> some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
            instructionalLineContent(
                content: content,
                segment: content.segment(at: clock.now(at: timeline.date)))
        }
    }

    @ViewBuilder
    private func instructionalLineContent(content _: LaneContent,
                                          segment: LaneSegment?) -> some View {
        let isCopy = segment?.kind == .copy
        let accent: Color = isCopy
            ? ScratchLabDesign.Sem.warning
            : ScratchLabDesign.Notation.targetTrace
        let title: String = {
            if let segment {
                return isCopy
                    ? "YOUR TURN"
                    : instructionalSegmentLabel(segment).uppercased()
            }
            return "TARGET"
        }()
        let subtitle: String = {
            if segment != nil {
                return isCopy ? "Copy what you heard" : "Watch & listen"
            }
            return "Play it on the line"
        }()

        HStack(spacing: 7) {
            Circle()
                .fill(accent)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.4)
                .foregroundColor(ScratchLabDesign.Sem.textPrimary)
            Text("·")
                .font(.system(size: 11))
                .foregroundColor(ScratchLabDesign.Sem.textTertiary)
            Text(subtitle)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(ScratchLabDesign.Sem.textSecondary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(subtitle)")
    }

    private func instructionalSegmentLabel(_ segment: LaneSegment) -> String {
        if let label = segment.label,
           !label.trimmingCharacters(in: .whitespaces).isEmpty {
            return label
        }
        return segment.kind == .copy ? "Your turn" : "Demo"
    }

    // Runtime status for the notation surface. Once a session is live the
    // assist mode otherwise gives no on-screen signal, so this names what the
    // active mode is doing: Auto-cut runs a silent visual preview, Guided
    // shows the cue guide, and the remaining modes are listening for the
    // learner's own scratches. Honest copy — no mode plays audio.
    private var notationStatus: (text: String, isLive: Bool) {
        switch practiceAssistMode {
        case .autoCut:        return ("Preview playing", true)
        case .demo:           return ("Demo playing", true)
        case .demoWithMotion: return ("Demo + your motion", true)
        case .guided:         return ("Guide active", true)
        case .coached, .open: return ("Waiting for input", false)
        }
    }

    private var notationStatusChip: some View {
        let status = notationStatus
        return HStack(spacing: 5) {
            Circle()
                .fill(status.isLive ? ScratchLabDesign.Sem.success : ScratchLabDesign.Sem.warning)
                .frame(width: 6, height: 6)
            Text(status.text)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(ScratchLabDesign.Sem.textSecondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(ScratchLabDesign.Surface.subtleFill)
        .clipShape(Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Notation status: \(status.text)")
    }


    // MARK: - Microphone Rationale

    private var microphoneRationaleOverlay: some View {
        ZStack {
            ScratchLabDesign.Surface.overlay.ignoresSafeArea()
            VStack(spacing: 22) {
                Image(systemName: "microphone.fill")
                    .font(.system(size: 44))
                    .foregroundColor(ScratchLabDesign.Sem.accent)
                Text("Microphone access")
                    .font(.title2.weight(.semibold))
                    .foregroundColor(ScratchLabDesign.Sem.textPrimary)
                Text("ScratchLab uses the microphone to analyse timing from your scratch audio. Audio stays on this device unless you export it yourself.")
                    .font(.subheadline)
                    .foregroundColor(ScratchLabDesign.Sem.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button {
                    showMicRationale = false
                    audioEngine.start()
                } label: {
                    Text("Start Practice")
                }
                .scratchLabPrimaryButton(fillsWidth: true)
                .padding(.horizontal, 32)
            }
        }
    }

    // MARK: - Session Management
    
    private func setupAudioEngine() {
        practiceBeatStore.configurePracticeContext(
            scratchID: activeScratch.id,
            preferredBPM: isGuidedDrillMode ? Int(drillBPM.rounded()) : nil
        )
        audioEngine.onScratchDetected = { [self] result in
            handleScratchDetected(result)
        }

        let isMicUndetermined: Bool
        if #available(iOS 17.0, *) {
            isMicUndetermined = AVAudioApplication.shared.recordPermission == .undetermined
        } else {
            isMicUndetermined = AVAudioSession.sharedInstance().recordPermission == .undetermined
        }

        if isMicUndetermined {
            showMicRationale = true
        } else {
            audioEngine.start()
        }
    }
    
    /// Production V3.2 "Start session" — runs the Open assist mode (static
    /// target reference, mic listens) and starts the live scored session.
    private func startOpenPractice() {
        practiceAssistModeRaw = PracticeAssistMode.open.rawValue
        startSession()
    }

    /// Production V3.2 "Watch" — runs the Demo assist mode (bundled demo audio
    /// + notation play along; non-scored) so the learner watches and listens.
    private func startWatchPractice() {
        practiceAssistModeRaw = PracticeAssistMode.demo.rawValue
        startSession()
    }

    private func startSession() {
        let sessionDuration = activeSessionDuration
        timeRemaining = sessionDuration
        currentScore = 0
        currentAccuracy = 0
        attemptCount = 0
        currentStreak = 0
        bestStreak = 0
        onBeatHitCount = 0
        cumulativeAbsoluteBeatOffsetMs = 0
        earlyHitCount = 0
        lateHitCount = 0
        sessionStartedAt = Date()
        drillElapsedSeconds = 0
        drillLoopCount = 0
        drillBeatInLoop = 0
        activeDrillEventIndex = nil
        comboStepsHitThisLoop.removeAll()
        comboBestRunCount = 0
        comboTrackedLoopCount = 0
        comboCompleted = false
        comboCompletionQueued = false
        sessionProgressPersisted = false
        livePerformedMovementEvents = []
        midiControllerDispatcher.resetCapturedPlatterEvents()
        comboPhraseStartedAt = nil
        lastComboLockAt = nil
        sessionTipText = isComboChallengeMode
            ? "Chain all \(comboTargetStepCount) baby scratches before the phrase window resets."
            : (activeScratch.tips.randomElement() ?? "Focus on clean execution")
        
        isSessionActive = true
        isPaused = false
        // Stamp the notation preview clock so the looping playhead starts from
        // t = 0 together with this session.
        notationClockStartDate = Date()

        // Demo-audio modes are non-scored reference playback: play the bundled
        // demo audio and skip live scratch analysis. `.demoWithMotion` also
        // stays camera-free and mic-free — it only adds the live platter
        // overlay, which rides the always-on MIDI feed. Every other mode runs
        // scored mic analysis with the camera preview.
        if isDemoAudioMode {
            configureDemoPlayback()
            demoPlayer.play()
        } else {
            isCameraPreviewVisible = true
            audioEngine.startAnalyzing(for: activeScratch)
        }

        if isGuidedDrillMode {
            updateGuidedDrillState()
        }

        startSessionTimer()
    }

    /// Configures the Demo-mode audio and the matching notation surface.
    ///
    /// Baby Scratch now uses the exact BBB reference pair:
    /// `CoachDemoAudio/baby_noBeat.wav` plus
    /// `CoachDemoMotion/baby_scratch_strokes.json`. The older 42-second
    /// call-and-response reel remains only as a fallback for a future scratch
    /// that has no extracted full-demo notation; it must never override the
    /// current Baby Scratch asset merely because both resources are bundled.
    private func configureDemoPlayback() {
        if activeScratch.id == CaptureSessionScratchType.babyScratch.rawValue,
           ScratchNotation.babyScratchDemo != nil {
            demoReel = nil
            demoPlayer.configure(with: coachInstruction)
            return
        }

        if let reel = loadDemoReelTimeline(), reel.isValid {
            demoPlayer.configure(withAudioFileNamed: reel.audioFile)
            // The manifest only drives the reel if its paired audio resolved.
            demoReel = demoPlayer.isAudioAvailable ? reel : nil
        } else {
            demoReel = nil
        }
        if demoReel == nil {
            demoPlayer.configure(with: coachInstruction)
        }
    }

    /// Loads the call-and-response demo manifest for the active scratch, if one
    /// is bundled. Only Baby Scratch ships a reel manifest today.
    private func loadDemoReelTimeline() -> PracticeReelTimeline? {
        guard activeScratch.id == "baby_scratch" else { return nil }
        return PracticeReelTimeline.loadBundled(named: PracticeReelTimeline.babyReelManifestName)
    }
    
    private func pauseSession() {
        isPaused = true
        sessionTimer?.invalidate()
        audioEngine.stopAnalyzing()
        practiceBeatStore.stopPlayback()
        demoPlayer.pause()
    }
    
    private func resumeSession() {
        isPaused = false
        if isDemoAudioMode {
            demoPlayer.play()
        } else {
            audioEngine.startAnalyzing(for: activeScratch)
        }

        startSessionTimer()
    }
    
    private func endSession() {
        finalizeComboLoopProgress()
        demoReel = nil
        sessionTimer?.invalidate()
        audioEngine.stopAnalyzing()
        practiceBeatStore.stopPlayback()
        demoPlayer.stop()

        isCameraPreviewVisible = false
        isSessionActive = false

        // Demo-audio modes (`.demo`, `.demoWithMotion`) are non-scored
        // reference playback — no results screen, no recorded practice
        // attempt, no progression update.
        guard isScoredPracticeMode else { return }

        showingResults = true
        persistSessionProgressIfNeeded()
    }
    
    private func resetSession() {
        timeRemaining = selectedDuration
        currentScore = 0
        currentAccuracy = 0
        attemptCount = 0
        currentStreak = 0
        bestStreak = 0
        onBeatHitCount = 0
        cumulativeAbsoluteBeatOffsetMs = 0
        earlyHitCount = 0
        lateHitCount = 0
        sessionStartedAt = nil
        drillElapsedSeconds = 0
        drillLoopCount = 0
        drillBeatInLoop = 0
        activeDrillEventIndex = nil
        comboStepsHitThisLoop.removeAll()
        comboBestRunCount = 0
        comboTrackedLoopCount = 0
        comboCompleted = false
        comboCompletionQueued = false
        sessionProgressPersisted = false
        livePerformedMovementEvents = []
        midiControllerDispatcher.resetCapturedPlatterEvents()
        comboPhraseStartedAt = nil
        lastComboLockAt = nil
        sessionTipText = ""
        showingResults = false
        isSessionActive = false
        demoReel = nil
    }
    
    private func cleanupSession() {
        sessionTimer?.invalidate()
        audioEngine.stopAnalyzing()
        practiceBeatStore.stopPlayback()
        demoPlayer.stop()
        isCameraPreviewVisible = false
        demoReel = nil
        drillElapsedSeconds = 0
        drillLoopCount = 0
        drillBeatInLoop = 0
        activeDrillEventIndex = nil
        comboStepsHitThisLoop.removeAll()
        comboBestRunCount = 0
        comboTrackedLoopCount = 0
        comboCompleted = false
        comboCompletionQueued = false
        sessionProgressPersisted = false
        livePerformedMovementEvents = []
        comboPhraseStartedAt = nil
        lastComboLockAt = nil
        sessionTipText = ""
    }
    
    private func handleScratchDetected(_ result: ScratchAnalysisResult) {
        attemptCount += 1

        // Practice timing preview — running aggregates only. Does not feed
        // scoring, capture, export, or any retained notation; surfaces only
        // through the post-take preview card.
        if result.timing.isOnBeat {
            onBeatHitCount += 1
        } else if result.timing.beatOffset < 0 {
            earlyHitCount += 1
        } else {
            lateHitCount += 1
        }
        cumulativeAbsoluteBeatOffsetMs += abs(result.timing.beatOffset)

        // Update accuracy (running average)
        if currentAccuracy == 0 {
            currentAccuracy = result.accuracy
        } else {
            currentAccuracy = (currentAccuracy * Double(attemptCount - 1) + result.accuracy) / Double(attemptCount)
        }
        
        // Update score
        let basePoints = 100
        let accuracyMultiplier = result.accuracy / 100.0
        let streakMultiplier = 1.0 + (Double(currentStreak) * 0.1)
        currentScore += Int(Double(basePoints) * accuracyMultiplier * streakMultiplier)

        let comboStepLocked = registerComboHitIfNeeded(result)

        if isGuidedDrillMode, let event = activeDrillEvent, !isComboChallengeMode {
            let onTargetScratch = (result.matchedScratchID == event.scratchID)
            if onTargetScratch && result.timing.isOnBeat {
                currentScore += 75
            } else if onTargetScratch {
                currentScore += 35
            }
        }
        
        // Update streak
        if result.accuracy >= 70 {
            currentStreak += 1
            if currentStreak > bestStreak {
                bestStreak = currentStreak
            }
        } else {
            currentStreak = 0
        }
        
        // Show feedback — prepend the coaching message before combo/drill
        // overrides so the general coaching hint sits below mode-specific lines.
        lastFeedback = result.feedback
        if let coachingText = NotationFeedbackState.coachingMessage(
            accuracy: result.accuracy,
            isOnBeat: result.timing.isOnBeat,
            beatOffset: result.timing.beatOffset
        ), !lastFeedback.contains(coachingText) {
            lastFeedback.insert(coachingText, at: 0)
        }
        if isComboChallengeMode {
            if comboCompleted {
                lastFeedback.insert("Phrase cleared: \(comboTargetStepCount)/\(comboTargetStepCount) locked", at: 0)
            } else if comboStepLocked {
                lastFeedback.insert("Locked step \(comboLockedStepCount)/\(max(1, comboTargetStepCount))", at: 0)
            } else {
                lastFeedback.insert("Keep the phrase moving and lock the next baby hit.", at: 0)
            }
        } else if isGuidedDrillMode {
            if let event = activeDrillEvent, result.matchedScratchID == event.scratchID {
                lastFeedback.insert("On cue: \(drillCueTitle(for: event))", at: 0)
            } else if let event = activeDrillEvent {
                lastFeedback.insert("Target now: \(drillCueTitle(for: event))", at: 0)
            }
        }
        lastAccuracyValue = isComboChallengeMode ? displayedAccuracy : result.accuracy
        
        // Determine feedback color
        let feedbackScore = isComboChallengeMode ? displayedAccuracy : result.accuracy
        if feedbackScore >= 90 {
            feedbackColor = ScratchLabDesign.Sem.success
        } else if feedbackScore >= 70 {
            feedbackColor = ScratchLabDesign.Sem.warning
        } else {
            feedbackColor = ScratchLabDesign.Sem.danger
        }
        
        // Notation feedback overlay — maps the detection result to a visual state
        // and auto-resets to neutral after the effect decays.
        let feedbackResult = NotationFeedbackState.from(
            accuracy: result.accuracy,
            isOnBeat: result.timing.isOnBeat,
            beatOffset: result.timing.beatOffset
        )
        notationFeedbackState = feedbackResult
        let resetDelay = feedbackResult.decayDuration + 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.30, resetDelay)) {
            notationFeedbackState = .neutral
        }

        // Animate
        withAnimation(.easeOut(duration: 0.3)) {
            showFeedback = true
            showAccuracyBurst = true
        }

        withAnimation(.easeOut(duration: 0.5)) {
            pulseRing = true
        }

        // Hide feedback after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                showFeedback = false
                showAccuracyBurst = false
                pulseRing = false
            }
        }

        if comboCompleted {
            queueComboCompletion()
        }
    }
    
    private func formatTime(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func startSessionTimer() {
        sessionTimer?.invalidate()

        let tick: TimeInterval = isGuidedDrillMode ? 0.1 : 1.0
        sessionTimer = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { _ in
            if timeRemaining > tick {
                timeRemaining -= tick
            } else {
                timeRemaining = 0
                endSession()
                return
            }

            if isGuidedDrillMode {
                drillElapsedSeconds += tick
                updateGuidedDrillState()
            }

            if isComboChallengeMode {
                refreshComboPhraseWindow()
            }
        }
    }

    private func updateGuidedDrillState() {
        guard isGuidedDrillMode,
              let timeline = drillTimeline else {
            activeDrillEventIndex = nil
            drillLoopCount = 0
            drillBeatInLoop = 0
            return
        }

        let secondsPerBeat = 60.0 / max(1, Double(practiceBeatStore.bpmValue))
        let elapsedBeats = drillElapsedSeconds / secondsPerBeat
        let totalBeats = max(0.0001, timeline.totalBeats)
        let loopCount = Int(floor(elapsedBeats / totalBeats))
        let beatInLoop = elapsedBeats.truncatingRemainder(dividingBy: totalBeats)

        comboTrackedLoopCount = loopCount
        drillLoopCount = max(0, loopCount)
        drillBeatInLoop = beatInLoop

        activeDrillEventIndex = normalizedDrillEvents.firstIndex(where: { event in
            let endBeat = event.startBeat + max(0.0001, event.durationBeats)
            return beatInLoop >= event.startBeat && beatInLoop < endBeat
        })

        if activeDrillEventIndex == nil {
            activeDrillEventIndex = normalizedDrillEvents.firstIndex(where: { beatInLoop < $0.startBeat })
                ?? normalizedDrillEvents.indices.last
        }
    }

    private func drillCueTitle(for event: ScratchRenderEvent) -> String {
        let directionLabel = event.direction == .forward ? "Forward" : "Reverse"
        let scratchName = ScratchLibrary.shared.scratch(byID: event.scratchID)?.name ?? event.scratchID
        return "\(directionLabel) \(scratchName)"
    }

    private func finalizeComboLoopProgress() {
        guard isComboChallengeMode else { return }
        comboBestRunCount = max(comboBestRunCount, comboStepsHitThisLoop.count)
    }

    private func persistSessionProgressIfNeeded() {
        guard !sessionProgressPersisted else { return }

        let elapsedDuration = max(0, activeSessionDuration - timeRemaining)
        progressManager.recordScratchAttempt(
            scratchID: activeScratch.id,
            accuracy: currentAccuracy,
            duration: elapsedDuration
        )

        if isComboChallengeMode {
            progressManager.recordComboAttempt(levelID: 1, accuracy: comboProgressPercent)
        }

        sessionProgressPersisted = true
    }

    // Builds the post-take preview-card payload from the live aggregates.
    // Returns `nil` for Demo (which never reaches the results overlay) and
    // for any session that produced zero mic attempts, so the card stays
    // absent rather than rendering "0 / 0". PROFILE.md keeps classifier
    // labels/confidence out of this surface — only timing aggregates flow
    // through.
    private var practiceTimingPreviewSummary: TakeEvidenceSummary? {
        guard isScoredPracticeMode else { return nil }
        guard attemptCount > 0 else { return nil }
        let elapsed = sessionStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let avgOffset = cumulativeAbsoluteBeatOffsetMs / Double(attemptCount)
        return TakeEvidenceSummary(
            takeLengthSeconds: max(0, elapsed),
            attempts: attemptCount,
            onBeatCount: onBeatHitCount,
            averageAbsoluteBeatOffsetMs: avgOffset
        )
    }

    // Honest REVIEW evidence for the post-take result surface. Projected
    // from the live timing aggregates — no platter direction/position claim,
    // never saved, scored, or exported.
    private var practiceReviewSummary: PracticeReviewSummary? {
        guard isScoredPracticeMode else { return nil }
        return PracticeReviewSummary(
            attempts: attemptCount,
            averageAccuracy: currentAccuracy,
            onBeatCount: onBeatHitCount,
            earlyCount: earlyHitCount,
            lateCount: lateHitCount
        )
    }

    // The Result surface's notation evidence is capability-driven: the live
    // mic Practice path captures sound and timing only, so it has no
    // movement evidence and `resolve` returns `.targetOnly`. When a RANE
    // platter was used this attempt, `midiControllerDispatcher` already
    // accumulated its CC6 telemetry (see `resetCapturedPlatterEvents` in
    // `startSession`/`resetSession`);
    // `gestureRelativePlatterNotationEvents` decodes the same shared run and
    // reversal boundaries macOS presentation uses, then locally rebases each
    // accepted gesture. The decision itself lives in
    // `PracticeResultNotation.resolve` (pure, evidence-driven) — this is the
    // "future DVS/MIDI/camera input path" the type's own doc comment
    // anticipated; no change to the result view itself.
    private var practiceResultNotation: PracticeResultNotation {
        let events = midiControllerDispatcher.gestureRelativePlatterNotationEvents
        #if DEBUG
        if !events.isEmpty {
            print("[SCRATCH-DEBUG] practice received update · movementEvents=\(events.count)")
        }
        #endif
        let resolved = PracticeResultNotation.resolve(performedMovementEvents: events)
        #if DEBUG
        if case .comparison = resolved {
            print("[SCRATCH-DEBUG] notation renderer received performance data")
        }
        #endif
        return resolved
    }

    /// Bridges the dispatcher's published CC6 accumulation into the active
    /// Practice attempt. SwiftUI then invalidates the existing performance
    /// `ScratchNotationPanel`; no renderer geometry or notation grammar is
    /// reimplemented here.
    private func updateLivePerformedNotation() {
        // Reference-only Demo collects nothing; every other mode — including
        // Demo + My Motion — feeds the live performed lane from the always-on
        // MIDI platter stream. Camera/mic are irrelevant to this path.
        guard isSessionActive, !isPaused, !isReferenceOnlyDemo else { return }
        let events = midiControllerDispatcher.livePlatterMovementEvents
        guard events != livePerformedMovementEvents else { return }
        livePerformedMovementEvents = events
        #if DEBUG
        print("[SCRATCH-DEBUG] practice live state updated · movementEvents=\(events.count)")
        if !events.isEmpty {
            print("[NOTATION-DEBUG] renderer received live performance data · movementEvents=\(events.count)")
        }
        #endif
    }

    /// Rolling live window, matching the macOS tracker card's visible domain.
    private var livePerformanceDomain: ClosedRange<TimeInterval>? {
        guard let first = livePerformedMovementEvents.first,
              let last = livePerformedMovementEvents.last else { return nil }
        let end = max(first.startTime + 3.2, last.endTime)
        return max(0, end - 3.2)...end
    }

    private func registerComboHitIfNeeded(_ result: ScratchAnalysisResult) -> Bool {
        guard isComboChallengeMode else {
            return false
        }

        let now = Date()
        refreshComboPhraseWindow(now: now)

        let expectedStepIndex = comboLockedStepCount
        guard normalizedDrillEvents.indices.contains(expectedStepIndex),
              result.matchedScratchID == normalizedDrillEvents[expectedStepIndex].scratchID else {
            return false
        }
        guard result.accuracy >= comboMinimumAccuracy else { return false }
        if let lastComboLockAt,
           now.timeIntervalSince(lastComboLockAt) < comboLockCooldown {
            return false
        }

        let inserted = comboStepsHitThisLoop.insert(expectedStepIndex).inserted
        guard inserted else { return false }

        if comboPhraseStartedAt == nil {
            comboPhraseStartedAt = now
        }
        lastComboLockAt = now
        comboBestRunCount = max(comboBestRunCount, comboStepsHitThisLoop.count)
        currentScore += 125
        if comboStepsHitThisLoop.count >= comboTargetStepCount {
            comboCompleted = true
            currentScore += comboChallenge?.bonusPoints ?? 300
        }

        return true
    }

    private func refreshComboPhraseWindow(now: Date = Date()) {
        guard isComboChallengeMode, !comboCompleted, !comboStepsHitThisLoop.isEmpty else { return }

        if let comboPhraseStartedAt,
           now.timeIntervalSince(comboPhraseStartedAt) > comboPhraseWindow {
            resetComboPhraseProgress(reason: "window timeout")
            return
        }

        if let lastComboLockAt,
           now.timeIntervalSince(lastComboLockAt) > comboResetInactivity {
            resetComboPhraseProgress(reason: "inactivity")
        }
    }

    private func resetComboPhraseProgress(reason _: String) {
        guard !comboStepsHitThisLoop.isEmpty else {
            comboPhraseStartedAt = nil
            lastComboLockAt = nil
            return
        }

        finalizeComboLoopProgress()
        comboStepsHitThisLoop.removeAll()
        comboPhraseStartedAt = nil
        lastComboLockAt = nil
    }

    private func queueComboCompletion() {
        guard isComboChallengeMode, comboCompleted, !comboCompletionQueued else { return }

        comboCompletionQueued = true
        finalizeComboLoopProgress()
        sessionTimer?.invalidate()
        audioEngine.stopAnalyzing()
        practiceBeatStore.stopPlayback()
        demoPlayer.stop()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            endSession()
        }
    }

}

/// Transparent target trace for the active Practice camera surface. The clock,
/// lane content, geometry, and renderer are the existing Practice sources; this
/// wrapper changes presentation only by omitting the chart card and substrate.
private struct PracticeLandscapeTargetTrace: View {
    let content: LaneContent
    let clock: LaneClock
    private let motionPath: MotionPath

    init(content: LaneContent, clock: LaneClock) {
        self.content = content
        self.clock = clock
        self.motionPath = ScratchStrokeGeometry.motionPath(for: content)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let viewport = LaneViewport(
                    size: size,
                    now: clock.now(at: timeline.date),
                    axis: .horizontal,
                    actionLineFraction: 0.18,
                    secondsAhead: 3.0
                )
                ScratchMotionRenderer.draw(
                    motionPath,
                    in: context,
                    viewport: viewport,
                    style: .target
                )

                let actionX = size.width * 0.18
                var actionLine = Path()
                actionLine.move(to: CGPoint(x: actionX, y: 0))
                actionLine.addLine(to: CGPoint(x: actionX, y: size.height))
                context.stroke(
                    actionLine,
                    with: .color(ScratchLabDesign.Sem.accent.opacity(0.72)),
                    lineWidth: 1
                )
            }
        }
        .allowsHitTesting(false)
    }
}

/// Transparent measured-performance trace for landscape camera Practice. It
/// adapts the already-published movement events with the canonical adapter and
/// renderer and never writes back to capture, MIDI, or notation state.
private struct PracticeLandscapePerformedTrace: View {
    let events: [CaptureCore.DetectedNotationRecordMovementEvent]
    private let motionPath: MotionPath
    private let visibleWindow: ClosedRange<TimeInterval>?

    init(events: [CaptureCore.DetectedNotationRecordMovementEvent]) {
        self.events = events
        let strokes = events.compactMap(PerformedStrokeAdapter.laneStroke)
        let end = max(events.map(\.endTime).max() ?? 0.1, 0.1)
        let content = LaneContent(
            strokes: strokes,
            segments: [],
            beatsPerMinute: nil,
            duration: end,
            loops: false
        )
        if let frame = PerformedStrokeAdapter.gestureRelativeNormalizationFrame(for: events) {
            self.motionPath = ScratchStrokeGeometry.motionPath(
                for: content,
                normalizingTo: frame
            )
        } else {
            self.motionPath = ScratchStrokeGeometry.motionPath(for: content)
        }

        if let first = events.first, let last = events.last {
            self.visibleWindow = first.startTime...max(first.startTime + 0.1, last.endTime)
        } else {
            self.visibleWindow = nil
        }
    }

    var body: some View {
        Canvas { context, size in
            guard let visibleWindow else { return }
            let duration = max(visibleWindow.upperBound - visibleWindow.lowerBound, 0.1)
            let viewport = LaneViewport(
                size: size,
                now: visibleWindow.lowerBound,
                axis: .horizontal,
                actionLineFraction: 0,
                secondsAhead: duration
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

// MARK: - Camera Preview

struct CameraPreviewView: View {
    @State private var authorizationStatus: AVAuthorizationStatus = .notDetermined

    var body: some View {
        ZStack {
            switch authorizationStatus {
            case .authorized:
                CameraPreviewLayer()
            case .denied, .restricted:
                deniedOverlay
            case .notDetermined:
                cameraRationaleCard
            @unknown default:
                Color.black
            }
        }
        .onAppear {
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            authorizationStatus = status
        }
    }

    private var cameraRationaleCard: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.white.opacity(0.7))
                Text("Camera practice")
                    .font(.headline)
                    .foregroundColor(.white)
                Text("Camera practice uses your device camera to preview movement while you practise. Camera access is only used when you enable this mode.")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button {
                    requestAccess()
                } label: {
                    Text("Enable Camera")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.black)
                        .frame(maxWidth: 220)
                        .frame(height: 44)
                        .background(Color.white.opacity(0.9))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            .padding(24)
        }
    }

    private var deniedOverlay: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "video.slash")
                    .font(.system(size: 40))
                    .foregroundColor(.white.opacity(0.5))
                Text("Camera access is turned off")
                    .font(.headline)
                    .foregroundColor(.white)
                Text("Grant camera permission in Settings so ScratchLab can show the camera feed during practice.")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    Button {
                        UIApplication.shared.open(url)
                    } label: {
                        Text("Open Settings")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func requestAccess() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                authorizationStatus = granted ? .authorized : .denied
            }
        }
    }
}

private extension SessionSetupOverlay {
    private var usesAccessibilitySetupSizing: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    /// Advanced Practice setup in landscape is a fixed three-pane workspace:
    /// beat, session, and input. Each pane uses `ViewThatFits` so normal text
    /// sizes require no scrolling; a local pane scroll is used only when
    /// accessibility text, an error, or optional descriptive copy needs it.
    private func landscapeSetupLayout(
        size: CGSize,
        safeAreaInsets: EdgeInsets
    ) -> some View {
        let leadingInset = max(safeAreaInsets.leading, 10)
        let trailingInset = max(safeAreaInsets.trailing, 10)
        let topInset = max(safeAreaInsets.top, 6)
        let bottomInset = max(safeAreaInsets.bottom, 6)
        let availableWidth = max(0, size.width - leadingInset - trailingInset)
        let toolbarHeight: CGFloat = 40
        let workspaceHeight = max(190, size.height - topInset - bottomInset - toolbarHeight - 6)
        let paneSpacing: CGFloat = 8
        let paneWidth = max(0, availableWidth - (paneSpacing * 2))
        let beatWidth = paneWidth * 0.36
        let sessionWidth = paneWidth * 0.31
        let inputWidth = max(0, paneWidth - beatWidth - sessionWidth)

        return VStack(spacing: 6) {
            HStack(spacing: 12) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                        .frame(width: 40, height: 40)
                        .background(ScratchLabDesign.Surface.scrim, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to Practice")

                VStack(alignment: .leading, spacing: 1) {
                    Text("\(sessionTitle) · \(scratch.name)")
                        .font(ScratchLabDesign.Typo.cardHeading)
                        .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                        .lineLimit(1)
                    Text(sessionDescription ?? scratch.description)
                        .font(ScratchLabDesign.Typo.caption)
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(selectedAssistMode.title.uppercased())
                    .font(ScratchLabDesign.Typo.statusPill)
                    .foregroundStyle(ScratchLabDesign.Sem.accent)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(ScratchLabDesign.Surface.subtleFill, in: Capsule())
            }
            .frame(height: toolbarHeight)

            HStack(alignment: .top, spacing: paneSpacing) {
                ViewThatFits(in: .vertical) {
                    landscapeBeatPane
                        .fixedSize(horizontal: false, vertical: true)
                    ScrollView(showsIndicators: true) {
                        landscapeBeatPane
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(width: beatWidth, height: workspaceHeight, alignment: .top)

                ViewThatFits(in: .vertical) {
                    landscapeSessionPane
                        .fixedSize(horizontal: false, vertical: true)
                    ScrollView(showsIndicators: true) {
                        landscapeSessionPane
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(width: sessionWidth, height: workspaceHeight, alignment: .top)

                ViewThatFits(in: .vertical) {
                    landscapeInputPane
                        .fixedSize(horizontal: false, vertical: true)
                    ScrollView(showsIndicators: true) {
                        landscapeInputPane
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(width: inputWidth, height: workspaceHeight, alignment: .top)
            }
        }
        .padding(.leading, leadingInset)
        .padding(.trailing, trailingInset)
        .padding(.top, topInset)
        .padding(.bottom, bottomInset)
    }

    private var landscapeBeatPane: some View {
        landscapeSetupCard {
            VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("PRACTICE BEAT")
                    .font(ScratchLabDesign.Typo.technical)
                    .foregroundStyle(ScratchLabDesign.Sem.textTertiary)
                Spacer(minLength: 8)
                Text(practiceBeatStore.isBeatEnabled
                     ? PracticeBeatUIContract.beatOnLabel
                     : PracticeBeatUIContract.noBeatLabel)
                    .font(ScratchLabDesign.Typo.statusPill)
                    .foregroundStyle(practiceBeatStore.isBeatEnabled
                                     ? ScratchLabDesign.Sem.success
                                     : ScratchLabDesign.Sem.textSecondary)
            }

            HStack(spacing: 6) {
                compactSelectionButton(
                    title: PracticeBeatUIContract.noBeatLabel,
                    isSelected: !practiceBeatStore.isBeatEnabled,
                    selectedColor: ScratchLabDesign.Sem.accent,
                    accessibilityID: "practice-beat-no-beat-button",
                    action: { practiceBeatStore.setBeatEnabled(false) }
                )
                compactSelectionButton(
                    title: PracticeBeatUIContract.beatOnLabel,
                    isSelected: practiceBeatStore.isBeatEnabled,
                    selectedColor: ScratchLabDesign.Sem.success,
                    accessibilityID: "practice-beat-on-button",
                    action: { practiceBeatStore.setBeatEnabled(true) }
                )
            }

            if practiceBeatStore.isBeatEnabled {
                Menu {
                    ForEach(practiceBeatStore.availableBeatModes) { mode in
                        Button {
                            practiceBeatStore.selectBeatMode(mode)
                        } label: {
                            if practiceBeatStore.selectedBeatMode == mode {
                                Label(mode.title, systemImage: "checkmark")
                            } else {
                                Text(mode.title)
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text("Beat style")
                            .font(ScratchLabDesign.Typo.caption)
                            .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                        Spacer(minLength: 8)
                        Text(practiceBeatStore.selectedBeatMode.title)
                            .font(ScratchLabDesign.Typo.sectionLabel)
                            .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                            .lineLimit(usesAccessibilitySetupSizing ? nil : 1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(ScratchLabDesign.Sem.textTertiary)
                    }
                    .padding(.horizontal, 10)
                    .frame(minHeight: 44)
                    .background(
                        ScratchLabDesign.Surface.controlFill,
                        in: RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.compactPanel, style: .continuous)
                    )
                }
            }

            HStack(spacing: 6) {
                compactBPMButton(systemImage: "minus") {
                    practiceBeatStore.stepBPM(by: -1)
                }

                PracticeBPMInput(
                    value: practiceBeatStore.bpmValue,
                    onCommit: { practiceBeatStore.setBPM($0) }
                )

                compactBPMButton(systemImage: "plus") {
                    practiceBeatStore.stepBPM(by: 1)
                }
            }

            HStack(spacing: 5) {
                ForEach(practiceBeatStore.allowedBPMList, id: \.self) { bpm in
                    Button(action: { practiceBeatStore.setBPM(bpm) }) {
                        Text("\(bpm)")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(practiceBeatStore.bpmValue == bpm
                                             ? ScratchLabDesign.Sem.textOnAccent
                                             : ScratchLabDesign.Sem.textPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(
                                practiceBeatStore.bpmValue == bpm
                                    ? ScratchLabDesign.Sem.accent
                                    : ScratchLabDesign.Surface.controlFill,
                                in: RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.compactPanel, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            Button(action: { practiceBeatStore.togglePlayback() }) {
                Text(practiceBeatStore.isPlaying
                     ? PracticeBeatUIContract.stopLabel
                     : PracticeBeatUIContract.playLabel)
                    .font(ScratchLabDesign.Typo.sectionLabel)
                    .foregroundStyle(ScratchLabDesign.Sem.textOnAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(
                        practiceBeatStore.isBeatEnabled
                            ? (practiceBeatStore.isPlaying
                               ? ScratchLabDesign.Sem.warning
                               : ScratchLabDesign.Sem.success)
                            : ScratchLabDesign.Surface.disabledFill,
                        in: RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!practiceBeatStore.isBeatEnabled)
            .accessibilityIdentifier("practice-beat-playback-button")

            if let playbackErrorMessage = practiceBeatStore.playbackErrorMessage {
                Text(playbackErrorMessage)
                    .font(ScratchLabDesign.Typo.caption)
                    .foregroundStyle(ScratchLabDesign.Sem.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            }
        }
        .accessibilityIdentifier(PracticeBeatUIContract.sectionAccessibilityID)
    }

    private var landscapeSessionPane: some View {
        landscapeSetupCard {
            VStack(alignment: .leading, spacing: 6) {
            Text("SESSION")
                .font(ScratchLabDesign.Typo.technical)
                .foregroundStyle(ScratchLabDesign.Sem.textTertiary)

            if let fixedDurationLabel {
                HStack {
                    Text("Length")
                        .font(ScratchLabDesign.Typo.caption)
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                    Spacer(minLength: 8)
                    Text(fixedDurationLabel)
                        .font(ScratchLabDesign.Typo.sectionLabel)
                        .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(
                    ScratchLabDesign.Surface.controlFill,
                    in: RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.compactPanel, style: .continuous)
                )
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Length")
                        .font(ScratchLabDesign.Typo.caption)
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                    HStack(spacing: 5) {
                        ForEach(durationOptions, id: \.1) { option in
                            compactSelectionButton(
                                title: option.0,
                                isSelected: selectedDuration == option.1,
                                selectedColor: ScratchLabDesign.Sem.accent,
                                accessibilityID: nil,
                                action: { selectedDuration = option.1 }
                            )
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Assist mode")
                    .font(ScratchLabDesign.Typo.caption)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)

                Menu {
                    ForEach(PracticeAssistMode.allCases) { mode in
                        Button {
                            selectedAssistMode = mode
                        } label: {
                            if selectedAssistMode == mode {
                                Label(mode.title, systemImage: "checkmark")
                            } else {
                                Text(mode.title)
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text(selectedAssistMode.title)
                            .font(ScratchLabDesign.Typo.sectionLabel)
                            .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(ScratchLabDesign.Sem.textTertiary)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 44)
                    .background(
                        ScratchLabDesign.Surface.controlFill,
                        in: RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.compactPanel, style: .continuous)
                    )
                }

                Text(selectedAssistMode.explainer)
                    .font(ScratchLabDesign.Typo.caption)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                    .lineLimit(usesAccessibilitySetupSizing ? nil : 1)
                    .minimumScaleFactor(0.72)
            }

            if let landscapeSetupSummaryText {
                Text(landscapeSetupSummaryText)
                    .font(ScratchLabDesign.Typo.caption)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                    .lineLimit(usesAccessibilitySetupSizing ? nil : 1)
                    .minimumScaleFactor(0.76)
                    .padding(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        ScratchLabDesign.Surface.subtleFill,
                        in: RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.compactPanel, style: .continuous)
                    )
            }
            }
        }
    }

    private var landscapeInputPane: some View {
        landscapeSetupCard {
            VStack(alignment: .leading, spacing: 6) {
            Text("AUDIO INPUT")
                .font(ScratchLabDesign.Typo.technical)
                .foregroundStyle(ScratchLabDesign.Sem.textTertiary)

            ForEach(inputSourceOptions, id: \.self) { source in
                Button(action: { onSelectInputSource(source) }) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.practiceLabel)
                                .font(ScratchLabDesign.Typo.sectionLabel)
                            Text(inputTileSubtitle(for: source))
                                .font(ScratchLabDesign.Typo.caption)
                                .lineLimit(usesAccessibilitySetupSizing ? nil : 1)
                        }
                        Spacer(minLength: 6)
                        if selectedInputSource == source {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 13, weight: .bold))
                        }
                    }
                    .foregroundStyle(selectedInputSource == source
                                     ? ScratchLabDesign.Sem.textOnAccent
                                     : ScratchLabDesign.Sem.textPrimary)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .background(
                        selectedInputSource == source
                            ? ScratchLabDesign.Sem.accent
                            : ScratchLabDesign.Surface.controlFill,
                        in: RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Current route: \(activeInputName)")
                    .font(ScratchLabDesign.Typo.sectionLabel)
                    .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                    .lineLimit(usesAccessibilitySetupSizing ? nil : 1)
                Text(inputRouteHint)
                    .font(ScratchLabDesign.Typo.caption)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                    .lineLimit(usesAccessibilitySetupSizing ? nil : 1)
                    .minimumScaleFactor(0.72)
            }

            Spacer(minLength: 0)

            Button(action: onStart) {
                Text(startButtonTitle)
            }
            .scratchLabPrimaryButton(fillsWidth: true)
            }
        }
    }

    private func compactSelectionButton(
        title: String,
        isSelected: Bool,
        selectedColor: Color,
        accessibilityID: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(isSelected
                                 ? ScratchLabDesign.Sem.textOnAccent
                                 : ScratchLabDesign.Sem.textPrimary)
                .lineLimit(usesAccessibilitySetupSizing ? 2 : 1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .background(
                    isSelected ? selectedColor : ScratchLabDesign.Surface.controlFill,
                    in: RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.compactPanel, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityID ?? "session-option-\(title)")
    }

    private func compactBPMButton(
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                .frame(width: 34, height: 44)
                .background(
                    ScratchLabDesign.Surface.controlFill,
                    in: RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.compactPanel, style: .continuous)
                )
        }
        .buttonStyle(.plain)
    }

    private var landscapeSetupSummaryText: String? {
        let details = [
            objectiveText.map { "Objective: \($0)" },
            modeNote.map { "Mode: \($0)" }
        ].compactMap { $0 }
        return details.isEmpty ? nil : details.joined(separator: " · ")
    }

    /// Landscape setup uses the design system's compact card metrics rather
    /// than the 20-point standard card padding used by portrait.
    private func landscapeSetupCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(ScratchLabDesign.Card.compactPadding)
            .background(
                ScratchLabDesign.Surface.card,
                in: RoundedRectangle(
                    cornerRadius: ScratchLabDesign.Card.compactCornerRadius,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: ScratchLabDesign.Card.compactCornerRadius,
                    style: .continuous
                )
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            }
        }
}

// MARK: - Camera Preview Layer (UIViewRepresentable)

private struct CameraPreviewLayer: UIViewRepresentable {
    final class Coordinator: NSObject {
        var captureSession: AVCaptureSession?
        var previewLayer: AVCaptureVideoPreviewLayer?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black

        let captureSession = AVCaptureSession()
        captureSession.sessionPreset = .high

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera),
              captureSession.canAddInput(input) else {
            return view
        }

        captureSession.addInput(input)
        context.coordinator.captureSession = captureSession

        let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = view.bounds
        view.layer.addSublayer(previewLayer)
        context.coordinator.previewLayer = previewLayer

        DispatchQueue.global(qos: .userInitiated).async {
            captureSession.startRunning()
        }

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.previewLayer?.frame = uiView.bounds
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.captureSession?.stopRunning()
        coordinator.captureSession = nil
        coordinator.previewLayer = nil
    }
}

// MARK: - Audio Level Indicator

struct AudioLevelIndicator: View {
    let level: Float

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<20, id: \.self) { i in
                Rectangle()
                    .fill(barColor(for: i))
                    .frame(width: 8, height: 30)
                    .opacity(i < activeBarCount ? 1.0 : 0.2)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(ScratchLabDesign.Surface.scrim)
        .cornerRadius(ScratchLabDesign.Radius.control)
    }

    private var activeBarCount: Int {
        let boostedLevel = min(max(level * 60, 0), 1)
        let normalized = sqrtf(boostedLevel)
        return max(0, min(20, Int(ceilf(normalized * 20))))
    }

    private func barColor(for index: Int) -> Color {
        if index < 12 {
            return ScratchLabDesign.Sem.success
        } else if index < 16 {
            return ScratchLabDesign.Sem.warning
        } else {
            return ScratchLabDesign.Sem.danger
        }
    }
}

// MARK: - Stat Display

// MARK: - Accuracy Burst Animation

struct AccuracyBurstView: View {
    let accuracy: Double

    var body: some View {
        ZStack {
            // Expanding rings
            ForEach(0..<3) { i in
                Circle()
                    .stroke(burstColor.opacity(0.5 - Double(i) * 0.15), lineWidth: 3)
                    .frame(width: 100 + CGFloat(i * 40), height: 100 + CGFloat(i * 40))
            }

            // Center text
            Text(accuracy >= 90 ? "🔥" : accuracy >= 70 ? "👍" : "💪")
                .font(.system(size: 60))
        }
    }

    private var burstColor: Color {
        if accuracy >= 90 {
            return ScratchLabDesign.Sem.success
        } else if accuracy >= 70 {
            return ScratchLabDesign.Sem.warning
        } else {
            return ScratchLabDesign.Sem.danger
        }
    }
}

// MARK: - Practice Ready (V3.2, Figma "iPhone / Practice Ready")

// The production V3.2 pre-session screen (Figma node 33:18): fixed technique,
// canonical TARGET notation, real mic/BPM status, and the two approved entry
// actions — "Start session" (Open assist mode, scored mic practice) and
// "Watch" (Demo assist mode, watch + listen). This replaces the legacy
// `SessionSetupOverlay` (session length / assist-mode picker / audio-input
// selector / beat controls) on the production route; those controls now live
// only on the Advanced route.
private struct PracticeReadyOverlay: View {
    let scratch: Scratch
    let micStatusTitle: String
    let micStatusColor: Color
    let targetNotation: ScratchNotation?
    let bpm: Double
    let topSafeAreaInset: CGFloat
    let bottomSafeAreaInset: CGFloat
    let onSetBPM: (Int) -> Void
    let onStart: () -> Void
    let onWatch: () -> Void
    let onBack: () -> Void
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var midiManager: IOSMIDIManager
    @EnvironmentObject private var midiLearnCoordinator: IOSMIDILearnCoordinator
    @EnvironmentObject private var midiControllerDispatcher: IOSMIDIControllerDispatcher
    @EnvironmentObject private var scratchPlaybackEngine: IOScratchPlaybackEngine
    @State private var isControllerSetupExpanded = false
    @State private var isDetailedMappingExpanded = false

    private let faderActions: [MIDISemanticAction] = [
        .crossfader, .leftUpfader, .rightUpfader
    ]
    private let hotCueActions: [MIDISemanticAction] = [
        .hotCue1, .hotCue2, .hotCue3, .hotCue4,
        .hotCue5, .hotCue6, .hotCue7, .hotCue8
    ]

    private var presentation: ScratchNotationPanelPresentation {
        ScratchLabAdaptiveLayout.notationPresentation(isRegularWidth: horizontalSizeClass == .regular)
    }

    /// The notation canvas is only the inner chart. Reserve the panel's two
    /// card insets, lane-label row, and label-to-canvas spacing so the outer
    /// card stays inside the landscape workspace instead of clipping its edge.
    private var landscapeNotationChromeAllowance: CGFloat {
        let cardPadding = presentation == .compact
            ? ScratchLabDesign.Card.compactPadding
            : ScratchLabDesign.Card.padding
        let laneLabelHeight: CGFloat = 16
        return (cardPadding * 2) + ScratchLabDesign.Spacing.itemTight + laneLabelHeight
    }

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height

            ZStack {
                ScratchLabDesign.Surface.overlay
                    .ignoresSafeArea()

                if isLandscape {
                    landscapeReadyLayout(
                        size: geometry.size,
                        safeAreaInsets: geometry.safeAreaInsets
                    )
                } else {
                    ScrollView(showsIndicators: false) {
                        portraitReadyContent
                            .padding(.horizontal, 24)
                            .padding(.top, topSafeAreaInset + 12)
                            .padding(.bottom, max(bottomSafeAreaInset, 16) + 20)
                    }
                }
            }
        }
    }

    private var portraitReadyContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                portraitBackButton
                Spacer()
            }

            AdaptiveWorkspaceHeader(
                title: "Practice",
                status: .ready,
                detail: "\(scratch.name) · Copy the target"
            )

            LessonProgressIndicator(
                stages: [.watch, .listen, .copy, .result, .review],
                current: .watch
            )

            targetNotationPanel
            readyControlSurface
        }
    }

    /// One-screen landscape Ready workspace. The columns are proportional to
    /// the available viewport (not a fixed side rail), with notation owning
    /// the majority of the width. The controls pane scrolls only after the
    /// genuinely variable controller-mapping disclosure is expanded.
    private func landscapeReadyLayout(
        size: CGSize,
        safeAreaInsets: EdgeInsets
    ) -> some View {
        let horizontalInset = max(max(safeAreaInsets.leading, safeAreaInsets.trailing), 14)
        let topInset = max(safeAreaInsets.top, 8)
        let bottomInset = max(safeAreaInsets.bottom, 8)
        let availableWidth = max(0, size.width - (horizontalInset * 2))
        let availableHeight = max(0, size.height - topInset - bottomInset)
        let toolbarHeight: CGFloat = 46
        let workspaceHeight = max(180, availableHeight - toolbarHeight - 10)
        let controlsFraction: CGFloat = size.width >= 1_000 ? 0.34 : 0.39
        let controlsWidth = min(
            max(230, (availableWidth - 14) * controlsFraction),
            max(230, availableWidth - 14 - 260)
        )
        let notationWidth = max(0, availableWidth - controlsWidth - 14)

        return VStack(spacing: 10) {
            HStack(spacing: 12) {
                backButton

                VStack(alignment: .leading, spacing: 1) {
                    Text("Practice · \(scratch.name)")
                        .font(ScratchLabDesign.Typo.cardHeading)
                        .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                        .lineLimit(1)
                    Text("Copy the target")
                        .font(ScratchLabDesign.Typo.caption)
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                }

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    Circle()
                        .fill(ScratchLabDesign.Sem.accent)
                        .frame(width: 6, height: 6)
                    Text("WATCH · 1 OF 5")
                        .font(ScratchLabDesign.Typo.statusPill)
                        .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(ScratchLabDesign.Surface.subtleFill, in: Capsule())
                .accessibilityLabel("Practice stage Watch, one of five")
            }
            .frame(height: toolbarHeight)

            HStack(alignment: .top, spacing: 14) {
                landscapeTargetNotationPanel(
                    canvasHeight: max(112, workspaceHeight - landscapeNotationChromeAllowance)
                )
                .frame(width: notationWidth, height: workspaceHeight, alignment: .top)

                landscapeReadyControlPane
                    .frame(width: controlsWidth, height: workspaceHeight, alignment: .top)
            }
        }
        .padding(.horizontal, horizontalInset)
        .padding(.top, topInset)
        .padding(.bottom, bottomInset)
    }

    private var backButton: some View {
        Button(action: onBack) {
            Image(systemName: "chevron.left")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(ScratchLabDesign.Sem.textPrimary)
                .frame(width: 40, height: 40)
                .background(ScratchLabDesign.Surface.scrim)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back")
    }

    /// Keeps the established portrait navigation affordance byte-for-byte in
    /// appearance while landscape uses the denser 40-point toolbar control.
    private var portraitBackButton: some View {
        Button(action: onBack) {
            Image(systemName: "chevron.left")
                .font(.title2)
                .foregroundColor(ScratchLabDesign.Sem.textPrimary)
                .padding(12)
                .background(ScratchLabDesign.Surface.scrim)
                .clipShape(Circle())
        }
        .accessibilityLabel("Back")
    }

    @ViewBuilder
    private func landscapeTargetNotationPanel(canvasHeight: CGFloat) -> some View {
        if let targetNotation {
            ScratchNotationPanel(
                lane: .target,
                presentation: presentation,
                source: .target(targetNotation),
                bpm: bpm,
                mode: .targetReference,
                canvasHeightOverride: canvasHeight
            )
            .frame(maxWidth: .infinity, alignment: .top)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "waveform.path")
                    .font(.title2)
                    .foregroundStyle(ScratchLabDesign.Sem.textTertiary)
                Text("Target notation isn't available for \(scratch.name) yet.")
                    .font(ScratchLabDesign.Typo.bodySecondary)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scratchLabCard(.standard)
        }
    }

    @ViewBuilder
    private var landscapeReadyControlPane: some View {
        if isControllerSetupExpanded {
            ScrollView(showsIndicators: true) {
                landscapeReadyControls
            }
        } else {
            landscapeReadyControls
        }
    }

    private var landscapeReadyControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                statusPill(label: micStatusTitle, color: micStatusColor)
                    .frame(maxWidth: .infinity, alignment: .leading)

                PracticeBPMInput(value: Int(bpm.rounded()), onCommit: onSetBPM)
                    .frame(width: 126)
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ScratchLabDesign.Sem.accent)
                    .padding(.top, 2)
                Text("Open practice · Static target reference. Mic listens; freestyle freely.")
                    .font(ScratchLabDesign.Typo.caption)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                ScratchLabDesign.Surface.subtleFill,
                in: RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous)
            )

            HStack(spacing: 8) {
                Button(action: onStart) {
                    Text("Start session")
                }
                .scratchLabPrimaryButton(fillsWidth: true)

                Button(action: onWatch) {
                    Text("Watch")
                }
                .scratchLabSecondaryButton(fillsWidth: true)
            }

            midiMappingCard
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var targetNotationPanel: some View {
        if let targetNotation {
            ScratchNotationPanel(
                lane: .target,
                presentation: presentation,
                source: .target(targetNotation),
                bpm: bpm,
                mode: .targetReference
            )
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var readyControlSurface: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusPill(label: micStatusTitle, color: micStatusColor)

            VStack(alignment: .leading, spacing: 6) {
                Text("TEMPO")
                    .font(ScratchLabDesign.Typo.technical)
                    .foregroundStyle(ScratchLabDesign.Sem.textTertiary)
                PracticeBPMInput(value: Int(bpm.rounded()), onCommit: onSetBPM)
                Text("\(CaptureClickTrackDefaults.supportedBPMRange.lowerBound)–\(CaptureClickTrackDefaults.supportedBPMRange.upperBound) BPM")
                    .font(ScratchLabDesign.Typo.caption)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
            }

            openPracticeCard
            readyActions
            midiMappingCard
        }
    }

    private var midiMappingCard: some View {
        DisclosureGroup(isExpanded: $isControllerSetupExpanded) {
            VStack(alignment: .leading, spacing: 7) {
                Button("Apply Verified RANE Mapping") {
                    midiLearnCoordinator.applyVerifiedRaneOneMKIIMapping()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(ScratchLabDesign.Sem.accent)
                .disabled(!canLearnMIDI || midiLearnCoordinator.activeAction != nil)
                .accessibilityIdentifier("apply-rane-one-mkii-mapping")

                Button("Load AHHH") {
                    scratchPlaybackEngine.loadPlatterAHHH()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(ScratchLabDesign.Sem.accent)
                .disabled(!canLearnMIDI)
                .accessibilityIdentifier("load-platter-ahhh")

                Text(RaneOneMKIIVerifiedLearnedMapping.isComplete(midiLearnCoordinator.currentMapping)
                    ? "Mapped: crossfader, both upfaders, and Hot Cues 1–8. Hot Cue 1 loads AHHH."
                    : "Mapping incomplete. Apply the verified RANE mapping.")
                    .font(ScratchLabDesign.Typo.caption)
                    .foregroundStyle(RaneOneMKIIVerifiedLearnedMapping.isComplete(midiLearnCoordinator.currentMapping)
                        ? ScratchLabDesign.Sem.success
                        : ScratchLabDesign.Sem.warning)
                    .fixedSize(horizontal: false, vertical: true)

                Text(scratchPlaybackEngine.platterSampleStatus)
                    .font(ScratchLabDesign.Typo.caption)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("platter-sample-status")

                Text(midiActivitySummary)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if let message = midiManager.latestMessage {
                    Text("Last MIDI · raw ch \(message.channel) · \(String(describing: message.messageType)) · CC \(message.controlNumber) · Note \(message.noteNumber) · value \(message.value)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                        .lineLimit(2)
                }

                DisclosureGroup("Fine-tune mappings", isExpanded: $isDetailedMappingExpanded) {
                    ScrollView(showsIndicators: true) {
                        VStack(spacing: 7) {
                            ForEach(faderActions, id: \.rawValue) { action in
                                midiLearnRow(action)
                            }

                        ForEach(hotCueActions, id: \.rawValue) { action in
                            midiLearnRow(action)
                        }
                    }
                        .padding(.top, 6)
                    }
                    .frame(maxHeight: 150)
                }
                .tint(ScratchLabDesign.Sem.textPrimary)
                .font(ScratchLabDesign.Typo.caption)
                .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

                if !midiLearnCoordinator.feedback.isEmpty {
                    Text(midiLearnCoordinator.feedback)
                        .font(ScratchLabDesign.Typo.caption)
                        .foregroundStyle(ScratchLabDesign.Sem.accent)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("midi-learn-feedback")
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Controller setup")
                        .font(ScratchLabDesign.Typo.sectionLabel)
                        .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                    Text(midiDeviceDetail)
                        .font(ScratchLabDesign.Typo.caption)
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                }
                Spacer()
                Circle()
                    .fill(midiStatusColor)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }
        }
        .tint(ScratchLabDesign.Sem.textPrimary)
        .padding(10)
        .background(
            ScratchLabDesign.Surface.subtleFill,
            in: RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous)
                .stroke(ScratchLabDesign.Border.default, lineWidth: 1)
        }
        .accessibilityIdentifier("midi-mapping-card")
    }

    private var midiActivitySummary: String {
        let crossfader = midiControllerDispatcher.crossfaderMIDIValue.map(String.init) ?? "--"
        let left = midiControllerDispatcher.leftUpfaderMIDIValue.map(String.init) ?? "--"
        let right = midiControllerDispatcher.rightUpfaderMIDIValue.map(String.init) ?? "--"
        let hotCue = midiControllerDispatcher.lastHotCueIndex.map { "HC\($0)" }
            ?? midiControllerDispatcher.lastHotCueSampleID.map { "HC \($0)" }
            ?? "HC--"
        return "LIVE · XF \(crossfader) · L \(left) · R \(right) · \(hotCue)"
    }

    private func midiLearnRow(_ action: MIDISemanticAction) -> some View {
        let learned = midiLearnCoordinator.control(for: action)
        let isLearning = midiLearnCoordinator.activeAction == action
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.displayName)
                        .font(ScratchLabDesign.Typo.sectionLabel)
                        .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                    Text(learned.map(mappingDetail) ?? "Not mapped")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                }
                Spacer(minLength: 8)
                if learned != nil {
                    Button("Clear") { midiLearnCoordinator.clear(action) }
                        .buttonStyle(.borderless)
                        .font(ScratchLabDesign.Typo.caption)
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                }
                Button(isLearning ? "Cancel" : (learned == nil ? "Learn" : "Relearn")) {
                    if isLearning {
                        midiLearnCoordinator.cancelLearning()
                    } else {
                        midiLearnCoordinator.startLearning(action)
                    }
                }
                .buttonStyle(.bordered)
                .tint(isLearning ? ScratchLabDesign.Sem.warning : ScratchLabDesign.Sem.accent)
                .disabled(!canLearnMIDI && !isLearning)
                .accessibilityIdentifier("midi-learn-\(action.rawValue)")
            }

        }
    }

    private var canLearnMIDI: Bool { midiLearnCoordinator.selectedDeviceName != nil }

    private var midiDeviceDetail: String {
        switch midiManager.sources.count {
        case 0: return "Connect a controller to enable Learn"
        case 1:
            let name = midiManager.sources[0].name
            return midiManager.readinessState == .receivingMessages
                ? "\(name) · receiving messages"
                : "\(name) · connected"
        default: return "Multiple MIDI sources found; connect one to learn"
        }
    }

    private var midiStatusColor: Color {
        switch midiManager.readinessState {
        case .unavailable: return ScratchLabDesign.Sem.muted
        case .deviceConnected: return ScratchLabDesign.Sem.warning
        case .receivingMessages: return ScratchLabDesign.Sem.success
        }
    }

    private func mappingDetail(_ control: MIDILearnedControl) -> String {
        let type = control.messageType == .controlChange ? "CC" : "Note"
        return "\(type) \(control.controlNumber) · Ch \(control.channel + 1)"
    }

    private var readyActions: some View {
        VStack(spacing: 12) {
            Button(action: onStart) {
                Text("Start session")
            }
            .scratchLabPrimaryButton(fillsWidth: true)

            Button(action: onWatch) {
                Text("Watch")
            }
            .scratchLabSecondaryButton(fillsWidth: true)
        }
    }

    private var openPracticeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Open practice")
                .font(ScratchLabDesign.Typo.cardHeading)
                .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
            Text("Static target reference. Mic listens; freestyle freely.")
                .font(ScratchLabDesign.Typo.bodySecondary)
                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .scratchLabCard(.standard)
    }

    private func statusPill(label: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(ScratchLabDesign.Typo.caption)
                .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(ScratchLabDesign.Surface.subtleFill, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}

/// Numeric tempo entry shared by the production Ready screen and Advanced
/// beat setup. Draft digits stay local while the user types (so entering 120
/// is not prematurely clamped after the first digit); valid values flow
/// through the existing `PracticeBeatStore.setBPM` action.
private struct PracticeBPMInput: View {
    let value: Int
    let onCommit: (Int) -> Void

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField("90", text: $draft)
                .keyboardType(.numberPad)
                .submitLabel(.done)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                .focused($isFocused)
                .onSubmit(commitDraft)

            Text("BPM")
                .font(ScratchLabDesign.Typo.sectionLabel)
                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 44)
        .background(ScratchLabDesign.Surface.controlFill, in: RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous)
                .stroke(isFocused ? ScratchLabDesign.Sem.accent : ScratchLabDesign.Border.default, lineWidth: 1)
        }
        .onAppear { draft = String(value) }
        .onChange(of: value) { _, newValue in
            guard !isFocused else { return }
            draft = String(newValue)
        }
        .onChange(of: draft) { _, newValue in
            let digits = String(newValue.filter(\.isNumber).prefix(3))
            if digits != newValue {
                draft = digits
                return
            }
            guard let bpm = Int(digits),
                  CaptureClickTrackDefaults.supportedBPMRange.contains(bpm) else { return }
            onCommit(bpm)
        }
        .onChange(of: isFocused) { wasFocused, nowFocused in
            guard wasFocused, !nowFocused else { return }
            commitDraft()
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    isFocused = false
                }
            }
        }
        .accessibilityLabel("Tempo in beats per minute")
        .accessibilityValue("\(value)")
    }

    private func commitDraft() {
        guard let bpm = Int(draft), !draft.isEmpty else {
            draft = String(value)
            return
        }
        let clamped = CaptureClickTrackDefaults.clampedBPM(bpm)
        onCommit(clamped)
        draft = String(clamped)
    }
}

// MARK: - Session Setup Overlay

struct SessionSetupOverlay: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let scratch: Scratch
    @ObservedObject var practiceBeatStore: PracticeBeatStore
    @Binding var selectedDuration: TimeInterval
    @Binding fileprivate var selectedAssistMode: PracticeAssistMode
    let durationOptions: [(String, TimeInterval)]
    let sessionTitle: String
    let sessionDescription: String?
    let objectiveText: String?
    let modeNote: String?
    let fixedDurationLabel: String?
    let startButtonTitle: String
    let selectedInputSource: AudioInputSource
    let inputSourceOptions: [AudioInputSource]
    let activeInputName: String
    let inputRouteHint: String
    /// The detected USB device's name (e.g. "Rane ONE MKII"), when the
    /// active route is USB — lets the Wired Input tile name the actual
    /// hardware instead of a generic "USB / interface" label. `nil` when no
    /// USB device is currently detected.
    let detectedUSBDeviceName: String?
    let topSafeAreaInset: CGFloat
    let bottomSafeAreaInset: CGFloat
    let onSelectInputSource: (AudioInputSource) -> Void
    let onStart: () -> Void
    let onBack: () -> Void

    private func inputTileSubtitle(for source: AudioInputSource) -> String {
        if source == .lineIn, let detectedUSBDeviceName, !detectedUSBDeviceName.isEmpty {
            return detectedUSBDeviceName
        }
        return source == .lineIn ? "USB / interface" : "Room / turntable mic"
    }

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height

            ZStack {
                ScratchLabDesign.Surface.overlay
                    .ignoresSafeArea()

                if isLandscape {
                    landscapeSetupLayout(
                        size: geometry.size,
                        safeAreaInsets: geometry.safeAreaInsets
                    )
                } else {
                    ScrollView(showsIndicators: true) {
                        VStack(spacing: 22) {
                    // Header
                    VStack(spacing: 6) {
                        Text(sessionTitle)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(ScratchLabDesign.Sem.accent)

                        Text(scratch.name)
                            .font(ScratchLabDesign.Typo.title1)
                            .foregroundColor(ScratchLabDesign.Sem.textPrimary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.82)
                            .multilineTextAlignment(.center)

                        Text(sessionDescription ?? scratch.description)
                            .font(ScratchLabDesign.Typo.bodySmall)
                            .foregroundColor(ScratchLabDesign.Sem.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)
                    }

                    PracticeBeatControlsCard(practiceBeatStore: practiceBeatStore)

                    if let fixedDurationLabel {
                        VStack(spacing: 12) {
                            Text("CHALLENGE LENGTH")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(ScratchLabDesign.Sem.textTertiary)

                            Text(fixedDurationLabel)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(ScratchLabDesign.Sem.textPrimary)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 12)
                                .background(ScratchLabDesign.Surface.controlFill)
                                .cornerRadius(ScratchLabDesign.Radius.panel)
                        }
                    } else {
                        // Duration selector
                        VStack(spacing: 12) {
                            Text("SESSION LENGTH")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(ScratchLabDesign.Sem.textTertiary)

                            HStack(spacing: 12) {
                                ForEach(durationOptions, id: \.1) { option in
                                    Button(action: { selectedDuration = option.1 }) {
                                        Text(option.0)
                                            .font(.system(size: 16, weight: .bold))
                                            .foregroundColor(selectedDuration == option.1 ? ScratchLabDesign.Sem.textOnAccent : ScratchLabDesign.Sem.textPrimary)
                                            .padding(.horizontal, 20)
                                            .padding(.vertical, 12)
                                            .background(selectedDuration == option.1 ? ScratchLabDesign.Sem.accent : ScratchLabDesign.Surface.controlFill)
                                            .cornerRadius(ScratchLabDesign.Radius.panel)
                                    }
                                }
                            }
                        }
                    }

                    // Assist mode picker. Drives which notation surface the
                    // live session shows and, for Demo, its reference playback.
                    VStack(spacing: 12) {
                        Text("ASSIST MODE")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(ScratchLabDesign.Sem.textTertiary)

                        HStack(spacing: 8) {
                            ForEach(PracticeAssistMode.allCases) { mode in
                                Button(action: { selectedAssistMode = mode }) {
                                    Text(mode.title)
                                        .font(ScratchLabDesign.Typo.sectionLabel)
                                        .foregroundColor(selectedAssistMode == mode ? ScratchLabDesign.Sem.textOnAccent : ScratchLabDesign.Sem.textPrimary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(selectedAssistMode == mode ? ScratchLabDesign.Sem.accent : ScratchLabDesign.Surface.controlFill)
                                        .cornerRadius(ScratchLabDesign.Radius.panel)
                                }
                            }
                        }
                        .padding(.horizontal, 24)

                        Text(selectedAssistMode.explainer)
                            .font(ScratchLabDesign.Typo.bodySecondary)
                            .foregroundColor(ScratchLabDesign.Sem.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)
                    }

                    if let objectiveText {
                        Text(objectiveText)
                            .font(ScratchLabDesign.Typo.bodySmall)
                            .foregroundColor(ScratchLabDesign.Sem.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }

                    if let modeNote {
                        Text(modeNote)
                            .font(ScratchLabDesign.Typo.bodySmall)
                            .foregroundColor(ScratchLabDesign.Sem.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }

                    VStack(spacing: 12) {
                        Text("AUDIO INPUT")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(ScratchLabDesign.Sem.textTertiary)

                        HStack(spacing: 12) {
                            ForEach(inputSourceOptions, id: \.self) { source in
                                Button(action: { onSelectInputSource(source) }) {
                                    VStack(spacing: 6) {
                                        Text(source.practiceLabel)
                                            .font(ScratchLabDesign.Typo.body)
                                            .foregroundColor(selectedInputSource == source ? ScratchLabDesign.Sem.textOnAccent : ScratchLabDesign.Sem.textPrimary)

                                        Text(inputTileSubtitle(for: source))
                                            .font(ScratchLabDesign.Typo.caption)
                                            .foregroundColor(selectedInputSource == source ? ScratchLabDesign.Sem.textOnAccent.opacity(0.72) : ScratchLabDesign.Sem.textSecondary)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 12)
                                    .background(selectedInputSource == source ? ScratchLabDesign.Sem.accent : ScratchLabDesign.Surface.controlFill)
                                    .cornerRadius(ScratchLabDesign.Radius.panel)
                                }
                            }
                        }

                        VStack(spacing: 6) {
                            Text("Current route: \(activeInputName)")
                                .font(ScratchLabDesign.Typo.sectionLabel)
                                .foregroundColor(ScratchLabDesign.Sem.textPrimary)

                            Text(inputRouteHint)
                                .font(ScratchLabDesign.Typo.bodySecondary)
                                .foregroundColor(ScratchLabDesign.Sem.textSecondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, 28)
                    }

                    // Buttons
                    VStack(spacing: 12) {
                        Button(action: onStart) {
                            Text(startButtonTitle)
                        }
                        .scratchLabPrimaryButton(fillsWidth: true)
                    }
                    .padding(.horizontal, 24)

                    Button(action: onBack) {
                        Text("Back to Practice")
                            .font(ScratchLabDesign.Typo.bodySmall)
                            .foregroundColor(ScratchLabDesign.Sem.textTertiary)
                    }
                }
                        .padding(.top, topSafeAreaInset + 12)
                        .padding(.bottom, max(bottomSafeAreaInset, 16) + 20)
                    }
                }
            }
        }
    }
}

// Guided assist-mode crossfader cue layer. UI-only: resolves fader state via
// `ScratchNotation.faderAuthoritySpans` (non-empty canonical `faderEvents`
// wins; otherwise falls back to per-stroke `faderState`, unchanged from
// before this channel existed) and renders a forward-looking visual guide.
// It drives nothing — no playback, scoring, capture, export, or audio.
// `clock` is the same `LaneClock` driving the motion lane above it (built
// from the session-owned `notationClockStartDate`); the TimelineView here is
// only a render-side ticker, not an independent timing source.
private struct GuidedCutCueLayer: View {
    let notation: ScratchNotation
    // The lane's own playhead clock (see `LaneClock` in TimingLane.swift) —
    // shared with `ScratchMotionLane` so the cue and the platter motion
    // never drift against each other or run their own timers.
    let clock: LaneClock

    // Compact-vertical (iPhone landscape) trims the caption sentence and
    // tightens padding so the lane above can claim more height. The
    // look-ahead bar and the status pill — the actionable parts — stay.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isCompactVertical: Bool { verticalSizeClass == .compact }

    // Forward look-ahead window drawn in the cue bar.
    private let windowSeconds: TimeInterval = 3.0
    // Lead time before an upcoming closed window that triggers "CUT SOON".
    private let cutLeadSeconds: TimeInterval = 0.2

    // Palette matches the macOS crossfader lane (Slice 1) for consistency.
    private let openColor   = Color(red: 0.20, green: 0.88, blue: 0.55)
    private let closedColor = Color(red: 1.00, green: 0.25, blue: 0.25)
    private let soonColor   = Color(hex: "F59E0B")

    private enum CueState { case open, cutSoon, closed }

    private var closedFaderSpans: [LaneFaderSpan] {
        notation.faderAuthoritySpans(documentEnd: max(notation.timelineDuration, 0.1))
            .filter { $0.state == .closed }
    }

    private var hasCuts: Bool { !closedFaderSpans.isEmpty }

    private var caption: String {
        hasCuts
            ? "Upcoming fader cuts — close on the red, open on the green."
            : "Keep the fader open — no cuts in this pattern."
    }

    var body: some View {
        // TimelineView is a render-side ticker; the timing authority is the
        // shared `clock`. ~10 Hz is smooth for a cue.
        TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
            let loopDuration = max(notation.timelineDuration, 0.1)
            let now = clock.now(at: timeline.date)
            let state = faderState(at: now, loopDuration: loopDuration)

            VStack(alignment: .leading, spacing: isCompactVertical ? 4 : 8) {
                HStack {
                    Text("GUIDED CUE")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.55))
                    Spacer()
                    statusPill(state)
                }

                lookaheadBar(now: now, loopDuration: loopDuration)
                    .frame(height: 16)

                if !isCompactVertical {
                    Text(caption)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.66))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, isCompactVertical ? 8 : 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.5))
            .cornerRadius(16)
            .padding(.horizontal, 20)
        }
    }

    private func faderState(at t: TimeInterval, loopDuration: TimeInterval) -> CueState {
        // A closed span covering `t` (checked in this loop and the next so
        // the result is correct across the loop boundary).
        let active = closedFaderSpans.contains { span in
            (t >= span.startTime && t < span.endTime) ||
            (t + loopDuration >= span.startTime && t + loopDuration < span.endTime)
        }
        if active { return .closed }

        let soon = closedFaderSpans.contains { span in
            let lead = span.startTime - t
            let wrappedLead = span.startTime + loopDuration - t
            return (lead > 0 && lead <= cutLeadSeconds) ||
                   (wrappedLead > 0 && wrappedLead <= cutLeadSeconds)
        }
        return soon ? .cutSoon : .open
    }

    private func pillStyle(_ state: CueState) -> (label: String, color: Color) {
        switch state {
        case .open:    return ("FADER OPEN", openColor)
        case .cutSoon: return ("CUT SOON", soonColor)
        case .closed:  return ("CLOSE FADER", closedColor)
        }
    }

    private func statusPill(_ state: CueState) -> some View {
        let style = pillStyle(state)
        return Text(style.label)
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(.black)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(style.color)
            .cornerRadius(8)
    }

    private func lookaheadBar(now: TimeInterval, loopDuration: TimeInterval) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                // Base: fader open across the whole look-ahead window.
                RoundedRectangle(cornerRadius: 4)
                    .fill(openColor.opacity(0.45))

                // Closed (cut) windows intersecting [now, now + window].
                ForEach(Array(closedFaderSpans.enumerated()), id: \.offset) { _, span in
                    ForEach(segmentRects(for: span, now: now,
                                         loopDuration: loopDuration, width: width),
                            id: \.minX) { rect in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(closedColor)
                            .frame(width: rect.width)
                            .offset(x: rect.minX)
                    }
                }

                // "Now" marker at the leading edge of the window.
                Rectangle()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 2)
            }
        }
    }

    // Visible rectangles for a closed fader span — checked in this loop and
    // the next so cuts near the loop boundary still scroll in correctly.
    private func segmentRects(for span: LaneFaderSpan,
                              now: TimeInterval,
                              loopDuration: TimeInterval,
                              width: CGFloat) -> [(minX: CGFloat, width: CGFloat)] {
        let duration = span.endTime - span.startTime
        return [span.startTime, span.startTime + loopDuration].compactMap { start in
            let end = start + duration
            let visibleStart = max(start, now)
            let visibleEnd   = min(end, now + windowSeconds)
            guard visibleEnd > visibleStart else { return nil }
            let scale = width / CGFloat(windowSeconds)
            return (CGFloat(visibleStart - now) * scale,
                    CGFloat(visibleEnd - visibleStart) * scale)
        }
    }
}

private struct ScratchCoachCard: View {
    let instruction: ScratchCoachInstruction
    @ObservedObject var practiceBeatStore: PracticeBeatStore
    @StateObject private var demoPlayer = ScratchCoachDemoAudioPlayer()

    private let theme = ScratchCoachCardTheme(
        accentColor: ScratchLabDesign.Sem.accent,
        primaryTextColor: .white,
        secondaryTextColor: .white.opacity(0.72),
        bubbleFill: Color.white.opacity(0.08),
        bubbleOutline: Color.white.opacity(0.12),
        illustrationFill: Color.white.opacity(0.06),
        detailFill: Color.white.opacity(0.06),
        controllerFill: Color.black.opacity(0.18),
        controllerTrackColor: Color.white.opacity(0.16),
        inactiveKnobColor: Color.white.opacity(0.38)
    )

    private var demoInstructionKey: String {
        "\(instruction.scratchType)|\(instruction.demoAudioFile ?? "")|\(instruction.demoAudioRole)"
    }

    private var isDemoPlaybackBlocked: Bool {
        practiceBeatStore.isPlaying
    }

    private var demoStatusMessage: String {
        if instruction.scratchType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Choose a scratch to load a coach demo."
        }
        if isDemoPlaybackBlocked {
            return "Stop the practice beat to hear the coach demo."
        }
        if !demoPlayer.isAudioAvailable {
            return "Demo audio unavailable for this scratch."
        }
        return instruction.demoAudioRole == "withBeat"
            ? "Coach demo includes beat and scratch together."
            : "Coach demo is isolated for scratch focus."
    }

    var body: some View {
        ScratchCoachCardContent(
            instruction: instruction,
            demoStatusMessage: demoStatusMessage,
            playbackTimeProvider: { demoPlayer.currentPlaybackTime },
            isPlayingProvider: { demoPlayer.isActivelyPlayingAudio },
            theme: theme
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    coachDemoButton(
                        title: "Listen",
                        icon: "play.fill",
                        enabled: demoPlayer.isAudioAvailable && !isDemoPlaybackBlocked,
                        action: demoPlayer.play
                    )

                    coachDemoButton(
                        title: "Pause",
                        icon: "pause.fill",
                        enabled: demoPlayer.isPlaying && !isDemoPlaybackBlocked,
                        action: demoPlayer.pause
                    )

                    coachDemoButton(
                        title: "Replay",
                        icon: "gobackward",
                        enabled: demoPlayer.isAudioAvailable && !isDemoPlaybackBlocked,
                        action: demoPlayer.replay
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .scratchLabCard(.standard)
        .padding(.horizontal, 16)
        .accessibilityIdentifier("scratchlab-coach-card")
        .onAppear {
            demoPlayer.configure(with: instruction)
        }
        .onChange(of: demoInstructionKey) { _, _ in
            demoPlayer.configure(with: instruction)
        }
        .onChange(of: practiceBeatStore.isPlaying) { _, isPlaying in
            guard isPlaying else { return }
            demoPlayer.stop()
        }
        .onDisappear {
            demoPlayer.stop()
        }
    }

    private func coachDemoButton(
        title: String,
        icon: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(enabled ? .black : .white.opacity(0.5))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(enabled ? ScratchLabDesign.Sem.accent : Color.white.opacity(0.08))
            .cornerRadius(10)
        }
        .disabled(!enabled)
    }
}

private struct PracticeBeatControlsCard: View {
    private static let beatModeColumns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    @ObservedObject var practiceBeatStore: PracticeBeatStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("PRACTICE BEAT")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(ScratchLabDesign.Sem.textTertiary)

                Spacer()

                Text(practiceBeatStore.isBeatEnabled ? PracticeBeatUIContract.beatOnLabel : PracticeBeatUIContract.noBeatLabel)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(practiceBeatStore.isBeatEnabled ? ScratchLabDesign.Sem.success : ScratchLabDesign.Sem.textSecondary)
            }

            HStack(spacing: 10) {
                Button(action: { practiceBeatStore.setBeatEnabled(false) }) {
                    Text(PracticeBeatUIContract.noBeatLabel)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(!practiceBeatStore.isBeatEnabled ? ScratchLabDesign.Sem.textOnAccent : ScratchLabDesign.Sem.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(!practiceBeatStore.isBeatEnabled ? ScratchLabDesign.Sem.accent : ScratchLabDesign.Surface.controlFill)
                        .cornerRadius(ScratchLabDesign.Radius.compactPanel)
                }
                .accessibilityIdentifier("practice-beat-no-beat-button")

                Button(action: { practiceBeatStore.setBeatEnabled(true) }) {
                    Text(PracticeBeatUIContract.beatOnLabel)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(practiceBeatStore.isBeatEnabled ? ScratchLabDesign.Sem.textOnAccent : ScratchLabDesign.Sem.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(practiceBeatStore.isBeatEnabled ? ScratchLabDesign.Sem.success : ScratchLabDesign.Surface.controlFill)
                        .cornerRadius(ScratchLabDesign.Radius.compactPanel)
                }
                .accessibilityIdentifier("practice-beat-on-button")
            }

            if practiceBeatStore.isBeatEnabled {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Beat style")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(ScratchLabDesign.Sem.textSecondary)

                    LazyVGrid(columns: Self.beatModeColumns, spacing: 10) {
                        ForEach(practiceBeatStore.availableBeatModes) { mode in
                            Button(action: { practiceBeatStore.selectBeatMode(mode) }) {
                                HStack(spacing: 8) {
                                    Text(mode.title)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(practiceBeatStore.selectedBeatMode == mode ? ScratchLabDesign.Sem.textOnAccent : ScratchLabDesign.Sem.textPrimary)
                                        .multilineTextAlignment(.leading)

                                    Spacer(minLength: 0)

                                    if practiceBeatStore.selectedBeatMode == mode {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 14, weight: .bold))
                                            .foregroundColor(ScratchLabDesign.Sem.textOnAccent.opacity(0.78))
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 12)
                                .background(
                                    practiceBeatStore.selectedBeatMode == mode
                                        ? ScratchLabDesign.Sem.accent
                                        : ScratchLabDesign.Surface.controlFill
                                )
                                .cornerRadius(ScratchLabDesign.Radius.compactPanel)
                            }
                            .accessibilityIdentifier("practice-beat-mode-\(mode.rawValue)")
                        }
                    }
                }
            } else {
                Text("No beat. Keep the timing guide off and practise from live scratch audio only.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(ScratchLabDesign.Sem.textSecondary)
            }

            VStack(spacing: 10) {
                HStack {
                    Button(action: { practiceBeatStore.stepBPM(by: -1) }) {
                        Image(systemName: "minus")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(ScratchLabDesign.Sem.textPrimary)
                            .frame(width: 40, height: 40)
                            .background(ScratchLabDesign.Surface.controlFill)
                            .clipShape(RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.compactPanel, style: .continuous))
                    }

                    Spacer()

                    PracticeBPMInput(
                        value: practiceBeatStore.bpmValue,
                        onCommit: { practiceBeatStore.setBPM($0) }
                    )
                    .frame(maxWidth: 150)

                    Spacer()

                    Button(action: { practiceBeatStore.stepBPM(by: 1) }) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(ScratchLabDesign.Sem.textPrimary)
                            .frame(width: 40, height: 40)
                            .background(ScratchLabDesign.Surface.controlFill)
                            .clipShape(RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.compactPanel, style: .continuous))
                    }
                }

                Text("Enter \(CaptureClickTrackDefaults.supportedBPMRange.lowerBound)–\(CaptureClickTrackDefaults.supportedBPMRange.upperBound) BPM, or use a preset.")
                    .font(ScratchLabDesign.Typo.caption)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)

                HStack(spacing: 10) {
                    ForEach(practiceBeatStore.allowedBPMList, id: \.self) { bpm in
                        Button(action: { practiceBeatStore.setBPM(bpm) }) {
                            Text("\(bpm)")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(practiceBeatStore.bpmValue == bpm ? ScratchLabDesign.Sem.textOnAccent : ScratchLabDesign.Sem.textPrimary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(
                                    practiceBeatStore.bpmValue == bpm ? ScratchLabDesign.Sem.accent : ScratchLabDesign.Surface.controlFill
                                )
                                .cornerRadius(ScratchLabDesign.Radius.compactPanel)
                        }
                    }
                }
            }

            Button(action: { practiceBeatStore.togglePlayback() }) {
                Text(practiceBeatStore.isPlaying ? PracticeBeatUIContract.stopLabel : PracticeBeatUIContract.playLabel)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(ScratchLabDesign.Sem.textOnAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        practiceBeatStore.isBeatEnabled
                            ? (practiceBeatStore.isPlaying ? ScratchLabDesign.Sem.warning : ScratchLabDesign.Sem.success)
                            : ScratchLabDesign.Surface.disabledFill
                    )
                    .cornerRadius(ScratchLabDesign.Radius.panel)
            }
            .disabled(!practiceBeatStore.isBeatEnabled)
            .accessibilityIdentifier("practice-beat-playback-button")

            if let playbackErrorMessage = practiceBeatStore.playbackErrorMessage {
                Text(playbackErrorMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(ScratchLabDesign.Sem.warning)
            }
        }
        .scratchLabCard(.standard)
        .padding(.horizontal, 20)
        .accessibilityIdentifier(PracticeBeatUIContract.sectionAccessibilityID)
    }
}

// MARK: - Pause Overlay

struct PauseOverlayView: View {
    let onResume: () -> Void
    let onRestart: () -> Void
    let onExit: () -> Void

    var body: some View {
        ZStack {
            ScratchLabDesign.Surface.overlay
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Text("Session paused")
                    .font(ScratchLabDesign.Typo.title1)
                    .foregroundColor(ScratchLabDesign.Sem.textPrimary)

                VStack(spacing: 12) {
                    Button(action: onResume) {
                        Label("Resume", systemImage: "play.fill")
                    }
                    .scratchLabPrimaryButton(fillsWidth: true)

                    Button(action: onRestart) {
                        Label("Restart", systemImage: "arrow.counterclockwise")
                    }
                    .scratchLabSecondaryButton(fillsWidth: true)

                    Button(action: onExit) {
                        Label("Exit", systemImage: "xmark")
                    }
                    .scratchLabDestructiveButton()
                }
                .padding(.horizontal, 40)
            }
        }
    }
}

// MARK: - Results Overlay

// Supplementary post-take timing preview payload. Carries only aggregates
// derived from the live `ScratchAnalysisResult.timing` stream — no
// classifier labels, no confidence, no retained notation. PROFILE.md
// keeps classifier labels/confidence off this surface and treats audio-
// onset timing as preview-only (not saved/exported/scored).
fileprivate struct TakeEvidenceSummary: Equatable {
    let takeLengthSeconds: TimeInterval
    let attempts: Int
    let onBeatCount: Int
    let averageAbsoluteBeatOffsetMs: Double
}

struct ResultsOverlayView: View {
    let scratch: Scratch
    let sessionTitle: String?
    let headline: String?
    let score: Int
    let accuracy: Double
    let primaryMetricLabel: String
    let attempts: Int
    let bestStreak: Int
    let detailNote: String?
    fileprivate let takeEvidence: TakeEvidenceSummary?
    let targetNotation: ScratchNotation?
    let bpm: Double
    let evidence: PracticeResultNotation
    let reviewSummary: PracticeReviewSummary?
    let continueButtonTitle: String
    let onContinue: () -> Void
    let onExit: () -> Void

    @State private var viewportSize: CGSize = .zero

    private var isLandscapeViewport: Bool {
        viewportSize.width > viewportSize.height
    }

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height

            ZStack {
                ScratchLabDesign.Surface.overlay
                    .ignoresSafeArea()

                if isLandscape {
                    landscapeResultLayout(
                        size: geometry.size,
                        safeAreaInsets: geometry.safeAreaInsets
                    )
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            resultHeader
                            resultNotation
                            resultSummaryBody
                        }
                        .padding(.vertical, 24)
                    }
                }
            }
            .onAppear { viewportSize = geometry.size }
            .onChange(of: geometry.size) { _, newSize in
                viewportSize = newSize
            }
        }
    }

    /// Landscape Result is a stable one-viewport workspace: notation never
    /// scrolls away, while only the genuinely variable review/detail summary
    /// can scroll within its proportional pane.
    private func landscapeResultLayout(
        size: CGSize,
        safeAreaInsets: EdgeInsets
    ) -> some View {
        let horizontalInset = max(max(safeAreaInsets.leading, safeAreaInsets.trailing), 16)
        let verticalInset = max(max(safeAreaInsets.top, safeAreaInsets.bottom), 12)
        let availableWidth = max(0, size.width - (horizontalInset * 2))
        let availableHeight = max(0, size.height - (verticalInset * 2))
        let summaryFraction: CGFloat = size.width >= 1_000 ? 0.35 : 0.40
        let summaryWidth = min(
            max(250, (availableWidth - 16) * summaryFraction),
            max(250, availableWidth - 16 - 260)
        )
        let notationWidth = max(0, availableWidth - summaryWidth - 16)

        return HStack(alignment: .top, spacing: 16) {
            resultNotation
                .frame(width: notationWidth, height: availableHeight, alignment: .top)

            ScrollView(showsIndicators: true) {
                landscapeResultSummary
            }
            .frame(width: summaryWidth, height: availableHeight, alignment: .top)
        }
        .padding(.horizontal, horizontalInset)
        .padding(.vertical, verticalInset)
    }

    private var landscapeResultSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("RESULT · LOCAL")
                        .font(ScratchLabDesign.Typo.technical)
                        .foregroundStyle(ScratchLabDesign.Sem.success)
                    Text(resultHeadline)
                        .font(ScratchLabDesign.Typo.cardHeading)
                        .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                        .lineLimit(2)
                    Text(sessionTitle ?? scratch.name)
                        .font(ScratchLabDesign.Typo.caption)
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text("\(Int(accuracy))%")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(ScratchLabDesign.Sem.accent)
                    .minimumScaleFactor(0.75)
                    .lineLimit(1)
            }

            HStack(alignment: .top, spacing: 8) {
                resultCard(title: "Timing", body: timingBody, selected: true)
                resultCard(title: "Best streak", body: "\(bestStreak)", selected: false)
            }

            Text("Timing is an on-device audio-onset estimate — it isn't saved, exported, or scored.")
                .font(ScratchLabDesign.Typo.caption)
                .foregroundStyle(ScratchLabDesign.Sem.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if let reviewSummary {
                PracticeReviewCard(summary: reviewSummary)
            }

            if let detailNote {
                Text(detailNote)
                    .font(ScratchLabDesign.Typo.bodySmall)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button(action: onContinue) {
                    Text(continueButtonTitle)
                }
                .scratchLabPrimaryButton(fillsWidth: true)

                Button(action: onExit) {
                    Text("Done")
                }
                .scratchLabSecondaryButton(fillsWidth: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // Result eyebrow — "LOCAL" names the real progression outcome: the attempt
    // was recorded on device, not uploaded. Headline + accuracy stay centred in
    // the single-column layout and lead the side column on iPad landscape.
    private var resultHeader: some View {
        VStack(spacing: 16) {
            Text("RESULT · LOCAL")
                .font(ScratchLabDesign.Typo.technical)
                .foregroundStyle(ScratchLabDesign.Sem.success)

            VStack(spacing: 4) {
                Text(resultHeadline)
                    .font(ScratchLabDesign.Typo.title1)
                    .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

                Text("\(Int(accuracy))%")
                    .font(ScratchLabDesign.Typo.largeScore)
                    .foregroundStyle(ScratchLabDesign.Sem.accent)
            }

            Text(sessionTitle ?? scratch.name)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
        }
    }

    /// Canonical TARGET notation + the capability-driven performance region
    /// (real MY PERFORMANCE only when movement evidence exists; otherwise the
    /// truthful unavailable card).
    @ViewBuilder
    private var resultNotation: some View {
        if !isCombo {
            PracticeResultNotationSection(target: targetNotation, bpm: bpm, evidence: evidence)
                .padding(.horizontal, isLandscapeViewport ? 0 : 32)
        }
    }

    private var resultMetrics: some View {
        VStack(spacing: 12) {
            resultCard(title: "Timing", body: timingBody, selected: true)
            resultCard(title: "Best streak", body: "\(bestStreak)", selected: false)
        }
        .padding(.horizontal, isLandscapeViewport ? 0 : 32)
    }

    private var resultDisclaimers: some View {
        VStack(spacing: 16) {
            Text("Timing is an on-device audio-onset estimate — it isn't saved, exported, or scored.")
                .font(ScratchLabDesign.Typo.caption)
                .foregroundStyle(ScratchLabDesign.Sem.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, isLandscapeViewport ? 0 : 32)

            Text("Practice estimate \(score) · \(attempts) attempts")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ScratchLabDesign.Sem.textTertiary)
        }
    }

    @ViewBuilder
    private var resultReview: some View {
        if let reviewSummary {
            PracticeReviewCard(summary: reviewSummary)
                .padding(.horizontal, isLandscapeViewport ? 0 : 32)
        }
        if let detailNote {
            Text(detailNote)
                .font(ScratchLabDesign.Typo.bodySmall)
                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, isLandscapeViewport ? 0 : 32)
        }
    }

    private var resultActions: some View {
        VStack(spacing: 12) {
            Button(action: onContinue) {
                Text(continueButtonTitle)
            }
            .scratchLabPrimaryButton(fillsWidth: true)

            Button(action: onExit) {
                Text("Done")
            }
            .scratchLabSecondaryButton(fillsWidth: true)
        }
        .padding(.horizontal, isLandscapeViewport ? 0 : 32)
    }

    /// The scored-summary column that trails the notation in the iPad landscape
    /// composition.
    private var resultSummaryBody: some View {
        VStack(spacing: 16) {
            resultMetrics
            resultDisclaimers
            resultReview
            resultActions
        }
    }

    private var isCombo: Bool { primaryMetricLabel == "Phrase Lock" }

    private var resultHeadline: String {
        headline ?? reviewSummary?.headline ?? "Practice complete"
    }

    private var timingBody: String {
        guard let takeEvidence else { return "No timing evidence yet." }
        let avg = Int(takeEvidence.averageAbsoluteBeatOffsetMs.rounded())
        return "Average offset \(avg) ms · \(takeEvidence.onBeatCount) on-beat hits"
    }

    @ViewBuilder
    private func resultCard(title: String, body: String, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(ScratchLabDesign.Typo.cardHeading)
                .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
            Text(body)
                .font(ScratchLabDesign.Typo.bodySecondary)
                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .scratchLabCard(selected ? .selected : .standard)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(body)")
    }
}

// The Result surface's notation region: the canonical TARGET reference plus,
// capability-driven, either a real MY PERFORMANCE panel (when performed
// movement evidence exists) or a truthful "trace unavailable" state. The
// decision lives in `PracticeResultNotation`; this view only renders it.
private struct PracticeResultNotationSection: View {
    let target: ScratchNotation?
    let bpm: Double
    let evidence: PracticeResultNotation
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var presentation: ScratchNotationPanelPresentation {
        ScratchLabAdaptiveLayout.notationPresentation(isRegularWidth: horizontalSizeClass == .regular)
    }

    var body: some View {
        if let target {
            let domain = ScratchPhraseChartComparisonDomain.commonDomain(targetDuration: target.timelineDuration)
            VStack(alignment: .leading, spacing: 12) {
                ScratchNotationPanel(
                    lane: .target,
                    presentation: presentation,
                    source: .target(target),
                    bpm: bpm,
                    domain: domain
                )

                switch evidence {
                case .comparison(let performed):
                    ScratchNotationPanel(
                        lane: .performance,
                        presentation: presentation,
                        source: .performedPlatter(performed),
                        bpm: bpm,
                        domain: domain
                    )
                case .targetOnly:
                    PerformanceTraceUnavailableCard()
                }
            }
        }
    }
}

// Truthful capability state for the region where Figma's Result frame shows a
// stacked PERFORMANCE notation panel. The live mic Practice path records sound
// and timing only — it never captures platter movement — so there is no motion
// trace to compare against the target. This card says exactly that, without
// implying failure: the distinction is evidence availability, not correctness.
private struct PerformanceTraceUnavailableCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(ScratchLabDesign.Sem.warning)
                Text("PERFORMANCE")
                    .font(ScratchLabDesign.Typo.technical)
                    .foregroundColor(ScratchLabDesign.Sem.warning)
            }
            Text("Performance trace unavailable for this input mode")
                .font(ScratchLabDesign.Typo.sectionLabel)
                .foregroundColor(ScratchLabDesign.Sem.textPrimary)
            Text("Mic practice records sound and timing only — it doesn't capture platter movement, so there's no motion trace to compare against the target yet.")
                .font(ScratchLabDesign.Typo.bodySecondary)
                .foregroundColor(ScratchLabDesign.Sem.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .scratchLabCard(.warning)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Performance trace unavailable for this input mode")
    }
}

// Semantic Review continuation of the Result screen: honest coaching derived
// from the session's timing aggregates (dominant early/late direction, on-beat
// consistency, and the established coaching voice). No platter direction or
// position is asserted — the mic input path can't support those claims.
private struct PracticeReviewCard: View {
    let summary: PracticeReviewSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("REVIEW")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundColor(ScratchLabDesign.Sem.textTertiary)

            HStack(spacing: 6) {
                Image(systemName: directionIcon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(directionColor)
                Text(summary.headline)
                    .font(ScratchLabDesign.Typo.sectionLabel)
                    .foregroundColor(ScratchLabDesign.Sem.textPrimary)
            }

            if let line = summary.coachingLine {
                Text(line)
                    .font(ScratchLabDesign.Typo.bodySecondary)
                    .foregroundColor(ScratchLabDesign.Sem.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if summary.hasEvidence, let rate = summary.onBeatRate {
                HStack(spacing: 8) {
                    Text("On-beat estimate")
                        .font(ScratchLabDesign.Typo.bodySecondary)
                        .foregroundColor(ScratchLabDesign.Sem.textSecondary)
                    Spacer(minLength: 8)
                    Text("\(summary.onBeatCount) / \(summary.attempts) · \(Int((rate * 100).rounded()))%")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(ScratchLabDesign.Sem.textPrimary)
                        .lineLimit(1)
                }
            }
        }
        .scratchLabCard(.standard)
    }

    private var directionIcon: String {
        switch summary.timingDirection {
        case .noSignal: return "waveform.slash"
        case .onBeat:   return "checkmark.circle.fill"
        case .early:    return "gobackward"
        case .late:     return "goforward"
        }
    }

    private var directionColor: Color {
        switch summary.timingDirection {
        case .noSignal:     return ScratchLabDesign.Sem.textTertiary
        case .onBeat:       return ScratchLabDesign.Sem.success
        case .early, .late: return ScratchLabDesign.Sem.warning
        }
    }
}

struct CaptureHelpView: View {
    @Environment(\.dismiss) private var dismiss

    let onShowQuickStartAgain: () -> Void

    private let quickStartSteps = [
        "Use one drill per take.",
        "Check camera, audio, and motion before recording.",
        "Pause briefly before starting.",
        "Review each take before continuing."
    ]

    private let checklistItems = [
        "Decks and mixer visible",
        "Audio routed",
        "Motion active",
        "Calibration confirmed"
    ]

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                backgroundGradient

                if geometry.size.width > geometry.size.height {
                    landscapeHelpLayout(
                        size: geometry.size,
                        safeAreaInsets: geometry.safeAreaInsets
                    )
                } else {
                    portraitHelpLayout
                }
            }
        }
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                Color(hex: "05070B"),
                Color(hex: "0B1018"),
                Color(hex: "101826")
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    /// Keeps the established portrait stack unchanged while landscape uses
    /// the wider viewport for two parallel, immediately scannable sections.
    private var portraitHelpLayout: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                helpTitle
                Spacer()
                doneButton
            }

            helpSection(title: "Quick Start", items: quickStartSteps)
            helpSection(title: "Capture Checklist", items: checklistItems)
            quickStartButton(fillsWidth: true)
            Spacer(minLength: 0)
        }
        .padding(24)
    }

    /// Fixed capture guidance fits one landscape viewport at normal text
    /// sizes. A scroll fallback is selected only when accessibility sizing
    /// makes the fixed composition taller than the safe-area workspace.
    private func landscapeHelpLayout(
        size: CGSize,
        safeAreaInsets: EdgeInsets
    ) -> some View {
        let horizontalInset = max(max(safeAreaInsets.leading, safeAreaInsets.trailing), 18)
        let verticalInset = max(max(safeAreaInsets.top, safeAreaInsets.bottom), 10)
        let availableHeight = max(0, size.height - (verticalInset * 2))

        return ViewThatFits(in: .vertical) {
            landscapeHelpContent

            ScrollView(showsIndicators: true) {
                landscapeHelpContent
            }
        }
        .frame(maxWidth: .infinity, minHeight: availableHeight, maxHeight: availableHeight, alignment: .top)
        .padding(.horizontal, horizontalInset)
        .padding(.vertical, verticalInset)
    }

    private var landscapeHelpContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                helpTitle
                Spacer(minLength: 12)
                quickStartButton(fillsWidth: false)
                doneButton
            }

            HStack(alignment: .top, spacing: 14) {
                helpSection(title: "Quick Start", items: quickStartSteps)
                    .frame(maxWidth: .infinity, alignment: .top)

                helpSection(title: "Capture Checklist", items: checklistItems)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    private var helpTitle: some View {
        Text("Capture Help")
            .font(.system(size: 24, weight: .bold))
            .foregroundColor(.white)
            .lineLimit(1)
    }

    private var doneButton: some View {
        Button("Done") {
            dismiss()
        }
        .font(.headline)
        .foregroundColor(Color(hex: "00D4FF"))
    }

    private func quickStartButton(fillsWidth: Bool) -> some View {
        Button(action: showQuickStartAgain) {
            Text("Show Quick Start Again")
                .font(.headline)
                .foregroundColor(.black)
                .frame(maxWidth: fillsWidth ? .infinity : nil)
                .padding(.horizontal, fillsWidth ? 0 : 16)
                .frame(height: fillsWidth ? 52 : 40)
                .background(Color(hex: "00D4FF"))
                .cornerRadius(8)
        }
        .accessibilityLabel("Show Quick Start Again")
    }

    private func helpSection(title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.62))
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(Color(hex: "00D4FF"))
                            .padding(.top, 1)
                            .accessibilityHidden(true)

                        Text(item)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white.opacity(0.84))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(Color.white.opacity(0.06))
            .cornerRadius(8)
        }
    }

    private func showQuickStartAgain() {
        dismiss()
        onShowQuickStartAgain()
    }
}

// MARK: - Preview

#if DEBUG
struct PracticeModeView_Previews: PreviewProvider {
    static var previews: some View {
        PracticeModeView(scratch: ScratchLibrary.shared.allScratches[0])
            .environmentObject(GameState())
            .environmentObject(AudioEngine())
            .environmentObject(ProgressManager())
            .environmentObject(PracticeBeatStore())
    }
}
#endif
