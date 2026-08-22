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
// unchanged for users on first launch. Demo is a non-scored reference mode
// that plays the bundled demo audio; the rest run the scored practice loop.
fileprivate enum PracticeAssistMode: String, CaseIterable, Identifiable {
    case autoCut
    case demo
    case guided
    case coached
    case open

    var id: String { rawValue }

    var title: String {
        switch self {
        case .autoCut: return "Auto-cut"
        case .demo:    return "Demo"
        case .guided:  return "Guided"
        case .coached: return "Coached"
        case .open:    return "Open"
        }
    }

    var explainer: String {
        switch self {
        case .autoCut: return "Visual target preview. App playback is off for this mode."
        case .demo:    return "ScratchLab plays the demo audio and moves the notation in time — watch and listen; this run isn't scored."
        case .guided:  return "ScratchLab shows upcoming cut cues while you move the fader."
        case .coached: return "Target pattern loops in time. Mic listens for your scratches and gives a practice estimate."
        case .open:    return "Static target reference. Mic listens; freestyle freely. No beat unless you turn one on."
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
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @EnvironmentObject var audioEngine: AudioEngine
    @EnvironmentObject var progressManager: ProgressManager
    @EnvironmentObject private var practiceBeatStore: PracticeBeatStore
    /// Live scratch-performance data feed — reads the RANE platter movement
    /// this dispatcher already tracks for MIDI parity, so the Result
    /// screen's MY PERFORMANCE notation panel has real evidence instead of
    /// always resolving `.targetOnly`. See `practiceResultNotation` below.
    @EnvironmentObject private var midiControllerDispatcher: IOSMIDIControllerDispatcher

    // Compact vertical size class is iPhone landscape (and small split-view).
    // Used only for surgical landscape adjustments — every branch keeps the
    // portrait layout byte-identical.
    private var isCompactVertical: Bool { verticalSizeClass == .compact }

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
    @State private var feedbackColor: Color = .white
    @State private var sessionTipText = ""
    
    // Animation states
    @State private var pulseRing = false
    @State private var showAccuracyBurst = false
    @State private var lastAccuracyValue: Double = 0
    // Notation feedback overlay state — driven by live scratch detection results.
    @State private var notationFeedbackState: NotationFeedbackState = .neutral
    // Active-attempt performance evidence for the live notation lane. This is
    // presentation state only; Result continues to resolve its finalized
    // evidence directly from `midiControllerDispatcher.platterMovementEvents`.
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
        switch audioEngine.inputMonitorState {
        case .micOff:
            return Color(hex: "9E9E9E")
        case .micLive:
            return Color(hex: "4CAF50")
        case .listening:
            return Color(hex: "00BCD4")
        case .noSignal:
            return Color(hex: "FF9800")
        }
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
        if practiceAssistMode == .demo {
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
            ZStack {
                // Camera feed background — only when a live session is active
                if isCameraPreviewVisible {
                    CameraPreviewView()
                        .ignoresSafeArea()
                }
                
                // Dark overlay for readability
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                
                // Main UI overlay
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
                
                #if DEBUG
                // Diagnostic-only: floats top-right so it does not disturb
                // the active Practice layout in either orientation. Visible
                // only while a session is live, when the engine is running.
                if isSessionActive {
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
                        .foregroundColor(.white)
                        .padding(12)
                        .background(Color.black.opacity(0.5))
                        .clipShape(Circle())
                }
                
                Spacer()
                
                if isSessionActive {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(timeRemaining < 60 ? Color(hex: "F44336") : Color(hex: "22C55E"))
                            .frame(width: 10, height: 10)

                        Text(formatTime(timeRemaining))
                            .font(.system(size: 24, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.52))
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
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
                            .foregroundColor(.white)
                            .padding(12)
                            .background(Color.black.opacity(0.5))
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
        ScrollView(.horizontal, showsIndicators: false) {
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
                    // Hidden in iPhone landscape — redundant with the session
                    // title in `practiceTopHUD` and saves chip-strip width that
                    // otherwise pushes everything off-screen on narrow heights.
                    StatusBadge(
                        title: "Scratch",
                        value: activeScratch.name,
                        variant: .accent,
                        systemImage: "waveform"
                    )
                }
                StatusBadge(
                    title: "Beat",
                    value: practiceBeatStore.isBeatEnabled
                        ? (practiceBeatStore.isPlaying
                            ? "\(practiceBeatStore.beatEngineMode.title) On"
                            : "\(practiceBeatStore.beatEngineMode.title) Ready")
                        : "Off",
                    variant: practiceBeatStore.isBeatEnabled ? .success : .neutral,
                    systemImage: practiceBeatStore.isBeatEnabled ? "metronome.fill" : "speaker.slash.fill"
                )
            }
        }
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
                .foregroundColor(.white)
                .lineLimit(1)
                .shadow(color: .black.opacity(0.5), radius: 2, y: 1)

            Spacer(minLength: 8)

            // The notation status pill lives in the lane panel's own
            // "TARGET PATTERN" header (notationLanePanel) — not duplicated here.
            if practiceAssistMode != .demo {
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
            if practiceAssistMode != .demo {
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
                .foregroundColor(Color(hex: "38BDF8"))
            Text(activeDrillEvent.map(drillCueTitle(for:)) ?? "Get ready")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
            if let activeDrillEventIndex {
                Text("\(activeDrillEventIndex + 1)/\(normalizedDrillEvents.count)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.5), in: Capsule())
    }

    // Combo-challenge phrase progress, compact.
    private var comboProgressChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.grid.3x3.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(Color(hex: "00BCD4"))
            Text("Phrase \(comboLockedStepCount)/\(max(1, comboTargetStepCount))")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
            Text("· best \(comboBestLockedStepCount)")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.6))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.5), in: Capsule())
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
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.4), in: Capsule())
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
        .background(Color.black.opacity(0.5), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Audio input: \(micStatusTitle)")
    }

    // Compact practice-beat toggle. When the user hasn't enabled a beat in
    // SessionSetupOverlay (`practiceBeatStore.isBeatEnabled == false`), the
    // chip surfaces an honest "Beat Off · slashed speaker" instead of a
    // tappable-looking "Play Beat" — same `.disabled` semantics, just no
    // longer disguising the disabled state.
    private var beatToggleChip: some View {
        Button(action: { practiceBeatStore.togglePlayback() }) {
            HStack(spacing: 6) {
                Image(systemName: beatChipIconName)
                    .font(.system(size: 10, weight: .bold))
                Text(beatChipLabel)
                    .font(.system(size: 12, weight: .bold))
            }
            .foregroundColor(practiceBeatStore.isBeatEnabled ? .black : .white.opacity(0.7))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                practiceBeatStore.isBeatEnabled
                    ? Color(hex: practiceBeatStore.isPlaying ? "F59E0B" : "22C55E")
                    : Color.white.opacity(0.15),
                in: Capsule())
        }
        .disabled(!practiceBeatStore.isBeatEnabled)
        .accessibilityLabel(practiceBeatStore.isBeatEnabled
                            ? (practiceBeatStore.isPlaying
                               ? PracticeBeatUIContract.stopLabel
                               : PracticeBeatUIContract.playLabel)
                            : "Beat Off")
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
                        .background(Color.black.opacity(0.5))
                        .cornerRadius(8)
                }
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    // The notation lane this mode + orientation should render, paired with its
    // clock. Demo follows the demo-audio reel; Auto-cut / Guided loop the
    // target pattern; Coached / Open hold it parked. `nil` when the active
    // scratch ships no notation.
    private var activeLane: (content: LaneContent, clock: LaneClock)? {
        if practiceAssistMode == .demo, let reel = demoReel {
            return (LaneContent(reel: reel),
                    .audioTime { demoPlayer.sampledPlaybackTime() })
        }
        guard let notation = targetNotation else { return nil }
        // Pass the session's selected BPM through so `ScratchMotionLane`'s
        // existing beat-grid renderer (gated on `content.beatsPerMinute`)
        // lights up. The grid is a visual timing reference — shown even
        // when the audible click track is off.
        let content = LaneContent(notation: notation,
                                  beatsPerMinute: Double(practiceBeatStore.bpmValue))
        switch practiceAssistMode {
        case .demo:
            // Reel manifest missing/invalid — follow the demo audio anyway.
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
    // every mode and orientation. `axis` is the only orientation difference
    // (vertical in portrait, horizontal in landscape): Demo audio-sync, the
    // looping preview, and the parked Coached / Open state all flow through the
    // one renderer. A status chip names the runtime state.
    @ViewBuilder
    private func notationLanePanel(axis: LaneAxis) -> some View {
        if let lane = activeLane {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("TARGET")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(ScratchLabDesign.Sem.accent)
                    Spacer()
                    notationStatusChip
                }

                notationInstructionalLine(content: lane.content, clock: lane.clock)

                ScratchMotionLane(content: lane.content, clock: lane.clock, axis: axis,
                                  feedbackState: notationFeedbackState)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if !livePerformedMovementEvents.isEmpty {
                    ScratchNotationPanel(
                        lane: .performance,
                        presentation: .compact,
                        source: .performedPlatter(livePerformedMovementEvents),
                        bpm: Double(practiceBeatStore.bpmValue),
                        domain: livePerformanceDomain,
                        mode: .liveComparison
                    )
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
                    .foregroundColor(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                Text("Practice freely — a notation lane appears once this technique has a verified target pattern.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            ? Color(red: 0.96, green: 0.62, blue: 0.07)
            : Color(red: 0.23, green: 0.51, blue: 0.96)
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
                .foregroundColor(.white.opacity(0.95))
            Text("·")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.35))
            Text(subtitle)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.65))
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
        case .autoCut: return ("Preview playing", true)
        case .demo:    return ("Demo playing", true)
        case .guided:  return ("Guide active", true)
        case .coached, .open: return ("Waiting for input", false)
        }
    }

    private var notationStatusChip: some View {
        let status = notationStatus
        return HStack(spacing: 5) {
            Circle()
                .fill(Color(hex: status.isLive ? "22C55E" : "F59E0B"))
                .frame(width: 6, height: 6)
            Text(status.text)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white.opacity(0.65))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.white.opacity(0.06))
        .clipShape(Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Notation status: \(status.text)")
    }


    // MARK: - Microphone Rationale

    private var microphoneRationaleOverlay: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
            VStack(spacing: 22) {
                Image(systemName: "microphone.fill")
                    .font(.system(size: 44))
                    .foregroundColor(Color(hex: "00D4FF"))
                Text("Microphone access")
                    .font(.title2.weight(.semibold))
                    .foregroundColor(.white)
                Text("ScratchLab uses the microphone to analyse timing from your scratch audio. Audio stays on this device unless you export it yourself.")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button {
                    showMicRationale = false
                    audioEngine.start()
                } label: {
                    Text("Start Practice")
                        .font(.headline)
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color(hex: "00D4FF"))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
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

        // Demo mode is a non-scored reference playback: play the bundled demo
        // audio and skip live scratch analysis. Every other mode runs scored
        // mic analysis. Camera is not needed for demo/coach playback.
        if practiceAssistMode == .demo {
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
    /// Prefers the bundled call-and-response reel manifest: its `audioFile`
    /// field — never a hardcoded filename — selects the audio, and a valid,
    /// audio-backed manifest is stored in `demoReel` so the portrait vertical
    /// reel can render it. Falls back to the legacy coach demo audio with a
    /// nil `demoReel` (the horizontal chart) when no usable manifest is
    /// bundled, or when a manifest loads but its paired audio file is missing.
    private func configureDemoPlayback() {
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
        if practiceAssistMode == .demo {
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

        // Demo mode is a non-scored reference playback — no results screen and
        // no recorded practice attempt.
        guard practiceAssistMode != .demo else { return }

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
            feedbackColor = Color(hex: "4CAF50")
        } else if feedbackScore >= 70 {
            feedbackColor = Color(hex: "FF9800")
        } else {
            feedbackColor = Color(hex: "F44336")
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
        guard practiceAssistMode != .demo else { return nil }
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
        guard practiceAssistMode != .demo else { return nil }
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
    // `startSession`/`resetSession`); `platterMovementEvents` decodes it via
    // the same shared `CaptureCore.derivePlatterMovementEvents` macOS's
    // Practice/Review notation uses. The decision itself lives in
    // `PracticeResultNotation.resolve` (pure, evidence-driven) — this is the
    // "future DVS/MIDI/camera input path" the type's own doc comment
    // anticipated; no change to the result view itself.
    private var practiceResultNotation: PracticeResultNotation {
        let events = midiControllerDispatcher.platterMovementEvents
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
        guard isSessionActive, !isPaused, practiceAssistMode != .demo else { return }
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
        .background(Color.black.opacity(0.5))
        .cornerRadius(8)
    }

    private var activeBarCount: Int {
        let boostedLevel = min(max(level * 60, 0), 1)
        let normalized = sqrtf(boostedLevel)
        return max(0, min(20, Int(ceilf(normalized * 20))))
    }
    
    private func barColor(for index: Int) -> Color {
        if index < 12 {
            return Color(hex: "4CAF50")
        } else if index < 16 {
            return Color(hex: "FFC107")
        } else {
            return Color(hex: "F44336")
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
            return Color(hex: "4CAF50")
        } else if accuracy >= 70 {
            return Color(hex: "FF9800")
        } else {
            return Color(hex: "F44336")
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
    let onStart: () -> Void
    let onWatch: () -> Void
    let onBack: () -> Void
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @EnvironmentObject private var midiManager: IOSMIDIManager
    @EnvironmentObject private var midiLearnCoordinator: IOSMIDILearnCoordinator
    @ObservedObject private var sampleManager = SampleManager.shared

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

    private var layoutMode: ScratchLabAdaptiveLayout.LayoutMode {
        ScratchLabAdaptiveLayout.layoutMode(
            horizontalSizeClass: horizontalSizeClass ?? .compact,
            verticalSizeClass: verticalSizeClass ?? .regular
        )
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.8)
                .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Button(action: onBack) {
                            Image(systemName: "chevron.left")
                                .font(.title2)
                                .foregroundColor(.white)
                                .padding(12)
                                .background(Color.black.opacity(0.5))
                                .clipShape(Circle())
                        }
                        .accessibilityLabel("Back")
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

                    if layoutMode == .regularLandscape {
                        // iPad landscape: dominant notation left, controls right.
                        HStack(alignment: .top, spacing: 16) {
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

                            VStack(alignment: .leading, spacing: 16) {
                                HStack(spacing: 8) {
                                    statusPill(label: micStatusTitle, color: micStatusColor)
                                    statusPill(label: "\(Int(bpm)) BPM", color: ScratchLabDesign.Sem.accent)
                                }

                                midiMappingCard

                                openPracticeCard

                                readyActions
                            }
                            .frame(width: 320, alignment: .top)
                        }
                    } else {
                        // Portrait / compact: single column (unchanged).
                        if let targetNotation {
                            ScratchNotationPanel(
                                lane: .target,
                                presentation: presentation,
                                source: .target(targetNotation),
                                bpm: bpm,
                                mode: .targetReference
                            )
                        }

                        HStack(spacing: 8) {
                            statusPill(label: micStatusTitle, color: micStatusColor)
                            statusPill(label: "\(Int(bpm)) BPM", color: ScratchLabDesign.Sem.accent)
                        }

                        midiMappingCard

                        openPracticeCard

                        readyActions
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, topSafeAreaInset + 12)
                .padding(.bottom, max(bottomSafeAreaInset, 16) + 20)
            }
        }
    }

    private var midiMappingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("MIDI mapping")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(midiDeviceDetail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                Circle()
                    .fill(midiStatusColor)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }

            ForEach(faderActions, id: \.rawValue) { action in
                midiLearnRow(action)
            }

            DisclosureGroup("Hot cues") {
                VStack(spacing: 8) {
                    ForEach(hotCueActions, id: \.rawValue) { action in
                        midiLearnRow(action)
                    }
                }
                .padding(.top, 8)
            }
            .tint(.white)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)

            if !midiLearnCoordinator.feedback.isEmpty {
                Text(midiLearnCoordinator.feedback)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ScratchLabDesign.Sem.accent)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("midi-learn-feedback")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        }
        .accessibilityIdentifier("midi-mapping-card")
    }

    private func midiLearnRow(_ action: MIDISemanticAction) -> some View {
        let learned = midiLearnCoordinator.control(for: action)
        let isLearning = midiLearnCoordinator.activeAction == action
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(learned.map(mappingDetail) ?? "Not mapped")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 8)
                if learned != nil {
                    Button("Clear") { midiLearnCoordinator.clear(action) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
                Button(isLearning ? "Cancel" : (learned == nil ? "Learn" : "Relearn")) {
                    if isLearning {
                        midiLearnCoordinator.cancelLearning()
                    } else {
                        midiLearnCoordinator.startLearning(action)
                    }
                }
                .buttonStyle(.bordered)
                .tint(isLearning ? Color.orange : ScratchLabDesign.Sem.accent)
                .disabled(!canLearnMIDI && !isLearning)
                .accessibilityIdentifier("midi-learn-\(action.rawValue)")
            }

            if let learned, action.hotCueIndex != nil {
                Picker("Scratch sample", selection: Binding(
                    get: { learned.assignedSampleID ?? "" },
                    set: { sampleID in
                        midiLearnCoordinator.assignSample(
                            sampleID.isEmpty ? nil : sampleID,
                            to: action
                        )
                    }
                )) {
                    Text("No sample").tag("")
                    ForEach(sampleManager.availableSamples) { sample in
                        Text(sample.displayName).tag(sample.id)
                    }
                }
                .pickerStyle(.menu)
                .tint(ScratchLabDesign.Sem.accent)
                .accessibilityIdentifier("midi-sample-\(action.rawValue)")
            }
        }
    }

    private var canLearnMIDI: Bool { midiManager.sources.count == 1 }

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
        case .unavailable: return .gray
        case .deviceConnected: return .orange
        case .receivingMessages: return .green
        }
    }

    private func mappingDetail(_ control: MIDILearnedControl) -> String {
        let type = control.messageType == .controlChange ? "CC" : "Note"
        let sample = control.assignedSampleID.flatMap(sampleDisplayName)
            .map { " · \($0)" } ?? ""
        return "\(type) \(control.controlNumber) · Ch \(control.channel + 1)\(sample)"
    }

    private func sampleDisplayName(for sampleID: String) -> String? {
        sampleManager.availableSamples.first(where: { $0.id == sampleID })?.displayName
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
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
            Text("Static target reference. Mic listens; freestyle freely.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        }
    }

    private func statusPill(label: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.06), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}

// MARK: - Session Setup Overlay

struct SessionSetupOverlay: View {
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
        ZStack {
            Color.black.opacity(0.8)
                .ignoresSafeArea()
            ScrollView(showsIndicators: true) {
                VStack(spacing: 22) {
                    // Header
                    VStack(spacing: 6) {
                        Text(sessionTitle)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(ScratchLabDesign.Sem.accent)

                        Text(scratch.name)
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(2)
                            .minimumScaleFactor(0.82)
                            .multilineTextAlignment(.center)

                        Text(sessionDescription ?? scratch.description)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)
                    }

                    PracticeBeatControlsCard(practiceBeatStore: practiceBeatStore)

                    if let fixedDurationLabel {
                        VStack(spacing: 12) {
                            Text("CHALLENGE LENGTH")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white.opacity(0.5))

                            Text(fixedDurationLabel)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 12)
                                .background(Color.white.opacity(0.1))
                                .cornerRadius(12)
                        }
                    } else {
                        // Duration selector
                        VStack(spacing: 12) {
                            Text("SESSION LENGTH")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white.opacity(0.5))

                            HStack(spacing: 12) {
                                ForEach(durationOptions, id: \.1) { option in
                                    Button(action: { selectedDuration = option.1 }) {
                                        Text(option.0)
                                            .font(.system(size: 16, weight: .bold))
                                            .foregroundColor(selectedDuration == option.1 ? .black : .white)
                                            .padding(.horizontal, 20)
                                            .padding(.vertical, 12)
                                            .background(selectedDuration == option.1 ? ScratchLabDesign.Sem.accent : Color.white.opacity(0.1))
                                            .cornerRadius(12)
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
                            .foregroundColor(.white.opacity(0.5))

                        HStack(spacing: 8) {
                            ForEach(PracticeAssistMode.allCases) { mode in
                                Button(action: { selectedAssistMode = mode }) {
                                    Text(mode.title)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(selectedAssistMode == mode ? .black : .white)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(selectedAssistMode == mode ? ScratchLabDesign.Sem.accent : Color.white.opacity(0.1))
                                        .cornerRadius(12)
                                }
                            }
                        }
                        .padding(.horizontal, 24)

                        Text(selectedAssistMode.explainer)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.66))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)
                    }

                    if let objectiveText {
                        Text(objectiveText)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.74))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }

                    if let modeNote {
                        Text(modeNote)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.74))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }

                    VStack(spacing: 12) {
                        Text("AUDIO INPUT")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white.opacity(0.5))

                        HStack(spacing: 12) {
                            ForEach(inputSourceOptions, id: \.self) { source in
                                Button(action: { onSelectInputSource(source) }) {
                                    VStack(spacing: 6) {
                                        Text(source.practiceLabel)
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundColor(selectedInputSource == source ? .black : .white)

                                        Text(inputTileSubtitle(for: source))
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundColor(selectedInputSource == source ? .black.opacity(0.72) : .white.opacity(0.62))
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 12)
                                    .background(selectedInputSource == source ? ScratchLabDesign.Sem.accent : Color.white.opacity(0.1))
                                    .cornerRadius(12)
                                }
                            }
                        }

                        VStack(spacing: 6) {
                            Text("Current route: \(activeInputName)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)

                            Text(inputRouteHint)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.66))
                                .multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, 28)
                    }

                    // Buttons
                    VStack(spacing: 12) {
                        Button(action: onStart) {
                            Text(startButtonTitle)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(.black)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(ScratchLabDesign.Sem.accent)
                                .cornerRadius(16)
                        }

                    }
                    .padding(.horizontal, 24)

                    Button(action: onBack) {
                        Text("Back to Practice")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
                .padding(.top, topSafeAreaInset + 12)
                .padding(.bottom, max(bottomSafeAreaInset, 16) + 20)
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
                    .foregroundColor(.white.opacity(0.5))

                Spacer()

                Text(practiceBeatStore.isBeatEnabled ? PracticeBeatUIContract.beatOnLabel : PracticeBeatUIContract.noBeatLabel)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(practiceBeatStore.isBeatEnabled ? Color(hex: "22C55E") : .white.opacity(0.64))
            }

            HStack(spacing: 10) {
                Button(action: { practiceBeatStore.setBeatEnabled(false) }) {
                    Text(PracticeBeatUIContract.noBeatLabel)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(!practiceBeatStore.isBeatEnabled ? .black : .white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(!practiceBeatStore.isBeatEnabled ? ScratchLabDesign.Sem.accent : Color.white.opacity(0.1))
                        .cornerRadius(10)
                }
                .accessibilityIdentifier("practice-beat-no-beat-button")

                Button(action: { practiceBeatStore.setBeatEnabled(true) }) {
                    Text(PracticeBeatUIContract.beatOnLabel)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(practiceBeatStore.isBeatEnabled ? .black : .white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(practiceBeatStore.isBeatEnabled ? Color(hex: "22C55E") : Color.white.opacity(0.1))
                        .cornerRadius(10)
                }
                .accessibilityIdentifier("practice-beat-on-button")
            }

            if practiceBeatStore.isBeatEnabled {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Beat style")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.72))

                    LazyVGrid(columns: Self.beatModeColumns, spacing: 10) {
                        ForEach(practiceBeatStore.availableBeatModes) { mode in
                            Button(action: { practiceBeatStore.selectBeatMode(mode) }) {
                                HStack(spacing: 8) {
                                    Text(mode.title)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(practiceBeatStore.selectedBeatMode == mode ? .black : .white)
                                        .multilineTextAlignment(.leading)

                                    Spacer(minLength: 0)

                                    if practiceBeatStore.selectedBeatMode == mode {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 14, weight: .bold))
                                            .foregroundColor(.black.opacity(0.78))
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 12)
                                .background(
                                    practiceBeatStore.selectedBeatMode == mode
                                        ? ScratchLabDesign.Sem.accent
                                        : Color.white.opacity(0.1)
                                )
                                .cornerRadius(10)
                            }
                            .accessibilityIdentifier("practice-beat-mode-\(mode.rawValue)")
                        }
                    }
                }
            } else {
                Text("No beat. Keep the timing guide off and practise from live scratch audio only.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.72))
            }

            VStack(spacing: 10) {
                HStack {
                    Button(action: { practiceBeatStore.stepBPM(by: -1) }) {
                        Image(systemName: "minus")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 40, height: 40)
                            .background(Color.white.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    Spacer()

                    VStack(spacing: 2) {
                        Text("\(practiceBeatStore.bpmValue) BPM")
                            .font(.system(size: 22, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)

                        Text("Range \(CaptureClickTrackDefaults.supportedBPMRange.lowerBound)-\(CaptureClickTrackDefaults.supportedBPMRange.upperBound)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                    }

                    Spacer()

                    Button(action: { practiceBeatStore.stepBPM(by: 1) }) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 40, height: 40)
                            .background(Color.white.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }

                HStack(spacing: 10) {
                    ForEach(practiceBeatStore.allowedBPMList, id: \.self) { bpm in
                        Button(action: { practiceBeatStore.setBPM(bpm) }) {
                            Text("\(bpm)")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(practiceBeatStore.bpmValue == bpm ? .black : .white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(
                                    practiceBeatStore.bpmValue == bpm ? ScratchLabDesign.Sem.accent : Color.white.opacity(0.1)
                                )
                                .cornerRadius(10)
                        }
                    }
                }
            }

            Button(action: { practiceBeatStore.togglePlayback() }) {
                Text(practiceBeatStore.isPlaying ? PracticeBeatUIContract.stopLabel : PracticeBeatUIContract.playLabel)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        practiceBeatStore.isBeatEnabled
                            ? Color(hex: practiceBeatStore.isPlaying ? "F59E0B" : "22C55E")
                            : Color.white.opacity(0.22)
                    )
                    .cornerRadius(12)
            }
            .disabled(!practiceBeatStore.isBeatEnabled)
            .accessibilityIdentifier("practice-beat-playback-button")

            if let playbackErrorMessage = practiceBeatStore.playbackErrorMessage {
                Text(playbackErrorMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(hex: "F59E0B"))
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
            Color.black.opacity(0.9)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Text("Session paused")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(.white)

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
    fileprivate var takeEvidence: TakeEvidenceSummary? = nil
    let targetNotation: ScratchNotation?
    let bpm: Double
    let evidence: PracticeResultNotation
    let reviewSummary: PracticeReviewSummary?
    let continueButtonTitle: String
    let onContinue: () -> Void
    let onExit: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var isRegularLandscape: Bool {
        ScratchLabAdaptiveLayout.layoutMode(
            horizontalSizeClass: horizontalSizeClass ?? .compact,
            verticalSizeClass: verticalSizeClass ?? .regular
        ) == .regularLandscape
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.9)
                .ignoresSafeArea()

            ScrollView {
                if isRegularLandscape {
                    // iPad landscape (Figma 281:1280): the canonical TARGET /
                    // MY PERFORMANCE notation dominates the left, and the scored
                    // summary sits in a fixed side column — a true two-column
                    // composition rather than a stretched single column.
                    HStack(alignment: .top, spacing: 24) {
                        resultNotation
                            .frame(maxWidth: .infinity, alignment: .top)

                        VStack(alignment: .leading, spacing: 16) {
                            resultHeader
                            resultSummaryBody
                        }
                        .frame(width: 360, alignment: .top)
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 24)
                } else {
                    VStack(spacing: 16) {
                        resultHeader
                        resultNotation
                        resultSummaryBody
                    }
                    .padding(.vertical, 24)
                }
            }
        }
    }

    // Result eyebrow — "LOCAL" names the real progression outcome: the attempt
    // was recorded on device, not uploaded. Headline + accuracy stay centred in
    // the single-column layout and lead the side column on iPad landscape.
    private var resultHeader: some View {
        VStack(spacing: 16) {
            Text("RESULT · LOCAL")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(ScratchLabDesign.Sem.success)

            VStack(spacing: 4) {
                Text(resultHeadline)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)

                Text("\(Int(accuracy))%")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(ScratchLabDesign.Sem.accent)
            }

            Text(sessionTitle ?? scratch.name)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    /// Canonical TARGET notation + the capability-driven performance region
    /// (real MY PERFORMANCE only when movement evidence exists; otherwise the
    /// truthful unavailable card).
    @ViewBuilder
    private var resultNotation: some View {
        if !isCombo {
            PracticeResultNotationSection(target: targetNotation, bpm: bpm, evidence: evidence)
                .padding(.horizontal, isRegularLandscape ? 0 : 32)
        }
    }

    private var resultMetrics: some View {
        VStack(spacing: 12) {
            resultCard(title: "Timing", body: timingBody, selected: true)
            resultCard(title: "Best streak", body: "\(bestStreak)", selected: false)
        }
        .padding(.horizontal, isRegularLandscape ? 0 : 32)
    }

    private var resultDisclaimers: some View {
        VStack(spacing: 16) {
            Text("Timing is an on-device audio-onset estimate — it isn't saved, exported, or scored.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .padding(.horizontal, isRegularLandscape ? 0 : 32)

            Text("Practice estimate \(score) · \(attempts) attempts")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    @ViewBuilder
    private var resultReview: some View {
        if let reviewSummary {
            PracticeReviewCard(summary: reviewSummary)
                .padding(.horizontal, isRegularLandscape ? 0 : 32)
        }
        if let detailNote {
            Text(detailNote)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .padding(.horizontal, isRegularLandscape ? 0 : 32)
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
        .padding(.horizontal, isRegularLandscape ? 0 : 32)
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
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
            Text(body)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            selected ? ScratchLabDesign.Sem.accent.opacity(0.12) : Color.white.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    selected ? ScratchLabDesign.Sem.accent.opacity(0.6) : Color.white.opacity(0.1),
                    lineWidth: selected ? 1.5 : 1
                )
        }
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
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(ScratchLabDesign.Sem.warning)
            }
            Text("Performance trace unavailable for this input mode")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
            Text("Mic practice records sound and timing only — it doesn't capture platter movement, so there's no motion trace to compare against the target yet.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(ScratchLabDesign.Surface.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(ScratchLabDesign.Sem.warning.opacity(0.35), lineWidth: 1)
        }
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
                .foregroundColor(.white.opacity(0.55))

            HStack(spacing: 6) {
                Image(systemName: directionIcon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(directionColor)
                Text(summary.headline)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
            }

            if let line = summary.coachingLine {
                Text(line)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if summary.hasEvidence, let rate = summary.onBeatRate {
                HStack(spacing: 8) {
                    Text("On-beat estimate")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                    Spacer(minLength: 8)
                    Text("\(summary.onBeatCount) / \(summary.attempts) · \(Int((rate * 100).rounded()))%")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(Color.white.opacity(0.04))
        .cornerRadius(10)
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
        case .noSignal:     return .white.opacity(0.5)
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
        ZStack {
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

            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Capture Help")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)

                    Spacer()

                    Button("Done") {
                        dismiss()
                    }
                    .font(.headline)
                    .foregroundColor(Color(hex: "00D4FF"))
                }

                helpSection(title: "Quick Start", items: quickStartSteps)
                helpSection(title: "Capture Checklist", items: checklistItems)

                Button(action: showQuickStartAgain) {
                    Text("Show Quick Start Again")
                        .font(.headline)
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color(hex: "00D4FF"))
                        .cornerRadius(8)
                }
                .accessibilityLabel("Show Quick Start Again")

                Spacer(minLength: 0)
            }
            .padding(24)
        }
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
