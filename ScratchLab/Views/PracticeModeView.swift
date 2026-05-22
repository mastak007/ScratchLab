// PracticeModeView.swift
// ScratchLab - Practice Mode
// Camera feed with gamification overlays for scratch practice

import SwiftUI
import AVFoundation

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
        case .autoCut: return "Auto-cut animates the target fader pattern as a visual preview — no audio playback yet."
        case .demo:    return "ScratchLab plays the demo audio and moves the notation in time — watch and listen; this run isn't scored."
        case .guided:  return "ScratchLab shows upcoming cut cues while you move the fader."
        case .coached: return "ScratchLab compares your cuts against the target."
        case .open:    return "ScratchLab leaves the fader fully manual."
        }
    }
}

struct PracticeModeView: View {
    let scratch: Scratch
    let drillTimeline: ScratchRenderTimeline?
    let drillBPM: Double
    let comboChallenge: ComboScratch?
    let usesBackingTrack: Bool
    
    @Environment(\.dismiss) var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @EnvironmentObject var audioEngine: AudioEngine
    @EnvironmentObject var progressManager: ProgressManager
    @EnvironmentObject private var practiceBeatStore: PracticeBeatStore

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
    @State private var showingCaptureHelp = false
    @State private var showingQuickStartAgain = false
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
    
    // Feedback
    @State private var lastFeedback: [String] = []
    @State private var showFeedback = false
    @State private var feedbackColor: Color = .white
    @State private var sessionTipText = ""
    
    // Animation states
    @State private var pulseRing = false
    @State private var showAccuracyBurst = false
    @State private var lastAccuracyValue: Double = 0
    
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

    // Target notation for the current scratch. Only Baby Scratch ships a
    // bundled notation today; other scratches return nil so the target
    // chart panel is omitted (graceful).
    private var targetNotation: ScratchNotation? {
        scratch.id == "baby_scratch" ? ScratchNotation.babyScratch : nil
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

    private var micStatusTitle: String {
        switch audioEngine.inputMonitorState {
        case .micOff:
            return "Microphone Off"
        case .micLive:
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
            return "mic.slash.fill"
        case .micLive:
            return "mic.fill"
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
        usesBackingTrack: Bool = false
    ) {
        self.scratch = scratch
        self.drillTimeline = drillTimeline
        self.drillBPM = drillBPM
        self.comboChallenge = comboChallenge
        self.usesBackingTrack = usesBackingTrack
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Camera feed background
                CameraPreviewView()
                    .ignoresSafeArea()
                
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
                        primaryMetricLabel: isComboChallengeMode ? "Phrase Lock" : "Accuracy",
                        attempts: attemptCount,
                        bestStreak: bestStreak,
                        detailNote: comboResultDetail,
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
                        topSafeAreaInset: geometry.safeAreaInsets.top,
                        bottomSafeAreaInset: geometry.safeAreaInsets.bottom,
                        onSelectInputSource: { source in audioEngine.selectInputSource(source) },
                        onStart: { startSession() },
                        onBack: { dismiss() }
                    )
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
                PracticeStatusChip(
                    title: "Session",
                    value: isComboChallengeMode ? "Challenge" : "Live",
                    color: Color(hex: "F44336")
                )
                PracticeStatusChip(
                    title: "Audio",
                    value: micStatusTitle,
                    color: micStatusColor
                )
                if isGuidedDrillMode {
                    PracticeStatusChip(
                        title: "BPM",
                        value: "\(practiceBeatStore.bpmValue)",
                        color: Color(hex: "38BDF8")
                    )
                    if let activeDrillEventIndex {
                        PracticeStatusChip(
                            title: "Step",
                            value: "\(activeDrillEventIndex + 1)/\(normalizedDrillEvents.count)",
                            color: Color(hex: "F59E0B")
                        )
                    }
                } else {
                    PracticeStatusChip(
                        title: "Scratch",
                        value: activeScratch.name,
                        color: Color(hex: "38BDF8")
                    )
                }
                PracticeStatusChip(
                    title: "Beat",
                    value: practiceBeatStore.isBeatEnabled
                        ? (practiceBeatStore.isPlaying
                            ? "\(practiceBeatStore.beatEngineMode.title) On"
                            : "\(practiceBeatStore.beatEngineMode.title) Ready")
                        : "Off",
                    color: Color(hex: practiceBeatStore.isBeatEnabled ? "A855F7" : "22C55E")
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
    // chip rows above and below it. Portrait runs the lane vertically,
    // landscape horizontally — one hierarchy, one layout, both orientations.
    private var centerFeedbackArea: some View {
        let axis: LaneAxis = verticalSizeClass == .compact ? .horizontal : .vertical
        return VStack(spacing: 8) {
            practiceTopHUD

            notationLanePanel(axis: axis)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) {
                    feedbackBanner.padding(.bottom, 10)
                }

            // Guided mode keeps its crossfader cue beneath the lane.
            if practiceAssistMode == .guided, let notation = targetNotation {
                GuidedCutCueLayer(notation: notation,
                                  clockStartDate: notationClockStartDate)
            }

            practiceBottomHUD
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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

            notationStatusChip

            if practiceAssistMode != .demo {
                practiceMetricsChip
            }
        }
    }

    // Compact scored-practice metrics — understated so the lane stays dominant.
    private var practiceMetricsChip: some View {
        HStack(spacing: 12) {
            StatDisplay(icon: leadingStat.icon, value: leadingStat.value,
                        label: leadingStat.label, color: leadingStat.color)
            StatDisplay(icon: "star.fill", value: "\(currentScore)",
                        label: "Score", color: Color(hex: "FFD700"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.5), in: Capsule())
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
                    .foregroundColor(Color(hex: "FFD700"))
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

    // Compact microphone status: a state dot plus the live input level.
    private var micChip: some View {
        HStack(spacing: 6) {
            Image(systemName: micStatusIcon)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(micStatusColor)
            AudioLevelIndicator(level: audioEngine.inputLevel)
                .frame(width: 46)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.5), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Microphone: \(micStatusTitle)")
    }

    // Compact practice-beat toggle.
    private var beatToggleChip: some View {
        Button(action: { practiceBeatStore.togglePlayback() }) {
            HStack(spacing: 6) {
                Image(systemName: practiceBeatStore.isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 10, weight: .bold))
                Text(practiceBeatStore.isPlaying
                     ? PracticeBeatUIContract.stopLabel
                     : PracticeBeatUIContract.playLabel)
                    .font(.system(size: 12, weight: .bold))
            }
            .foregroundColor(.black)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                practiceBeatStore.isBeatEnabled
                    ? Color(hex: practiceBeatStore.isPlaying ? "F59E0B" : "22C55E")
                    : Color.white.opacity(0.25),
                in: Capsule())
        }
        .disabled(!practiceBeatStore.isBeatEnabled)
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
        let content = LaneContent(notation: notation)
        switch practiceAssistMode {
        case .demo:
            // Reel manifest missing/invalid — follow the demo audio anyway.
            return (content, .audioTime { demoPlayer.sampledPlaybackTime() })
        case .autoCut, .guided:
            return (content, .looping(start: notationClockStartDate,
                                      duration: content.duration))
        case .coached, .open:
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
                    Text("TARGET PATTERN")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.55))
                    Spacer()
                    notationStatusChip
                }

                ScratchMotionLane(content: lane.content, clock: lane.clock, axis: axis)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            Spacer(minLength: 0)
        }
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


    // MARK: - Session Management
    
    private func setupAudioEngine() {
        practiceBeatStore.configurePracticeContext(
            scratchID: activeScratch.id,
            preferredBPM: isGuidedDrillMode ? Int(drillBPM.rounded()) : nil
        )
        audioEngine.start()
        audioEngine.onScratchDetected = { [self] result in
            handleScratchDetected(result)
        }
    }
    
    private func startSession() {
        let sessionDuration = activeSessionDuration
        timeRemaining = sessionDuration
        currentScore = 0
        currentAccuracy = 0
        attemptCount = 0
        currentStreak = 0
        bestStreak = 0
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
        // mic analysis.
        if practiceAssistMode == .demo {
            configureDemoPlayback()
            demoPlayer.play()
        } else {
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
        comboPhraseStartedAt = nil
        lastComboLockAt = nil
        sessionTipText = ""
    }
    
    private func handleScratchDetected(_ result: ScratchAnalysisResult) {
        attemptCount += 1
        
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
        
        // Show feedback
        lastFeedback = result.feedback
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

struct CameraPreviewView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        
        let captureSession = AVCaptureSession()
        captureSession.sessionPreset = .high
        
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera) else {
            return view
        }
        
        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
        }
        
        let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = UIScreen.main.bounds
        view.layer.addSublayer(previewLayer)
        
        DispatchQueue.global(qos: .userInitiated).async {
            captureSession.startRunning()
        }
        
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {}
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

struct PracticeStatusChip: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)

            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.58))

            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.46), in: Capsule())
    }
}

struct StatDisplay: View {
    let icon: String
    let value: String
    let label: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundColor(color)
                Text(value)
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
            }
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.6))
        }
    }
}

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
    let topSafeAreaInset: CGFloat
    let bottomSafeAreaInset: CGFloat
    let onSelectInputSource: (AudioInputSource) -> Void
    let onStart: () -> Void
    let onBack: () -> Void
    
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
                            .foregroundColor(Color(hex: "FFD700"))

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
                                            .background(selectedDuration == option.1 ? Color(hex: "FFD700") : Color.white.opacity(0.1))
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
                                        .background(selectedAssistMode == mode ? Color(hex: "FFD700") : Color.white.opacity(0.1))
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

                                        Text(source == .lineIn ? "USB / interface" : "Room / turntable mic")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundColor(selectedInputSource == source ? .black.opacity(0.72) : .white.opacity(0.62))
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 12)
                                    .background(selectedInputSource == source ? Color(hex: "FFD700") : Color.white.opacity(0.1))
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
                                .background(Color(hex: "FFD700"))
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

// Guided assist-mode crossfader cue layer. UI-only: reads `faderState` from
// the existing target notation and renders a forward-looking visual guide.
// It drives nothing — no playback, scoring, capture, export, or audio.
// `clockStartDate` is the shared session-owned clock origin; the TimelineView
// is only a render-side ticker.
private struct GuidedCutCueLayer: View {
    let notation: ScratchNotation
    let clockStartDate: Date

    // Forward look-ahead window drawn in the cue bar.
    private let windowSeconds: TimeInterval = 3.0
    // Lead time before an upcoming closed window that triggers "CUT SOON".
    private let cutLeadSeconds: TimeInterval = 0.2

    // Palette matches the macOS crossfader lane (Slice 1) for consistency.
    private let openColor   = Color(red: 0.20, green: 0.88, blue: 0.55)
    private let closedColor = Color(red: 1.00, green: 0.25, blue: 0.25)
    private let soonColor   = Color(hex: "F59E0B")

    private enum CueState { case open, cutSoon, closed }

    private var closedStrokes: [ScratchNotation.Stroke] {
        notation.strokes.filter { $0.faderState == .closed }
    }

    private var hasCuts: Bool { !closedStrokes.isEmpty }

    private var caption: String {
        hasCuts
            ? "Upcoming fader cuts — close on the red, open on the green."
            : "Keep the fader open — no cuts in this pattern."
    }

    var body: some View {
        // TimelineView is a render-side ticker; the clock origin is the
        // shared session-owned clockStartDate. ~10 Hz is smooth for a cue.
        TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
            let loopDuration = max(notation.timelineDuration, 0.1)
            let elapsed = timeline.date.timeIntervalSince(clockStartDate)
            let now = elapsed.truncatingRemainder(dividingBy: loopDuration)
            let state = faderState(at: now, loopDuration: loopDuration)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("GUIDED CUE")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.55))
                    Spacer()
                    statusPill(state)
                }

                lookaheadBar(now: now, loopDuration: loopDuration)
                    .frame(height: 16)

                Text(caption)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.66))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.5))
            .cornerRadius(16)
            .padding(.horizontal, 20)
        }
    }

    private func faderState(at t: TimeInterval, loopDuration: TimeInterval) -> CueState {
        // A closed stroke covering `t` (checked in this loop and the next so
        // the result is correct across the loop boundary).
        let active = closedStrokes.contains { stroke in
            (t >= stroke.startTime && t < stroke.endTime) ||
            (t + loopDuration >= stroke.startTime && t + loopDuration < stroke.endTime)
        }
        if active { return .closed }

        let soon = closedStrokes.contains { stroke in
            let lead = stroke.startTime - t
            let wrappedLead = stroke.startTime + loopDuration - t
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
                ForEach(Array(closedStrokes.enumerated()), id: \.offset) { _, stroke in
                    ForEach(segmentRects(for: stroke, now: now,
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

    // Visible rectangles for a closed stroke — checked in this loop and the
    // next so cuts near the loop boundary still scroll in correctly.
    private func segmentRects(for stroke: ScratchNotation.Stroke,
                              now: TimeInterval,
                              loopDuration: TimeInterval,
                              width: CGFloat) -> [(minX: CGFloat, width: CGFloat)] {
        [stroke.startTime, stroke.startTime + loopDuration].compactMap { start in
            let end = start + stroke.duration
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
        accentColor: Color(hex: "FFD700"),
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
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.08))
        .cornerRadius(16)
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
            .background(enabled ? Color(hex: "FFD700") : Color.white.opacity(0.08))
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
                        .background(!practiceBeatStore.isBeatEnabled ? Color(hex: "FFD700") : Color.white.opacity(0.1))
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
                                        ? Color(hex: "FFD700")
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
                                    practiceBeatStore.bpmValue == bpm ? Color(hex: "FFD700") : Color.white.opacity(0.1)
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
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(Color.white.opacity(0.08))
        .cornerRadius(16)
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
                Text("PAUSED")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.white)
                
                VStack(spacing: 12) {
                    PauseButton(title: "Resume", icon: "play.fill", color: Color(hex: "4CAF50"), action: onResume)
                    PauseButton(title: "Restart", icon: "arrow.counterclockwise", color: Color(hex: "FF9800"), action: onRestart)
                    PauseButton(title: "Exit", icon: "xmark", color: Color(hex: "F44336"), action: onExit)
                }
                .padding(.horizontal, 40)
            }
        }
    }
}

struct PauseButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 16, weight: .bold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(color.opacity(0.3))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(color, lineWidth: 2)
            )
            .cornerRadius(12)
        }
    }
}

// MARK: - Results Overlay

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
    let continueButtonTitle: String
    let onContinue: () -> Void
    let onExit: () -> Void
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.9)
                .ignoresSafeArea()
            
            VStack(spacing: 32) {
                // Performance emoji
                Text(accuracy >= 90 ? "🔥" : accuracy >= 70 ? "👏" : "💪")
                    .font(.system(size: 80))
                
                // Result text
                VStack(spacing: 8) {
                    Text(headline ?? (accuracy >= 90 ? "MASTERY!" : accuracy >= 70 ? "GOOD JOB!" : "KEEP PRACTICING!"))
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(accuracy >= 90 ? Color(hex: "FFD700") : .white)
                    
                    Text(sessionTitle ?? scratch.name)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                }
                
                // Stats grid
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 20) {
                    ResultStat(value: "\(Int(accuracy))%", label: primaryMetricLabel, icon: primaryMetricLabel == "Phrase Lock" ? "point.3.filled.connected.trianglepath.dotted" : "target")
                    ResultStat(value: "\(score)", label: "Score", icon: "star.fill")
                    ResultStat(value: "\(attempts)", label: "Attempts", icon: "number")
                    ResultStat(value: "\(bestStreak)", label: "Best Streak", icon: "flame.fill")
                }
                .padding(.horizontal, 40)

                if let detailNote {
                    Text(detailNote)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.72))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                
                // Progress to mastery
                let progressGoal = primaryMetricLabel == "Phrase Lock" ? 100.0 : 90.0
                if accuracy < progressGoal {
                    VStack(spacing: 8) {
                        Text(primaryMetricLabel == "Phrase Lock" ? "Progress to Phrase Clear" : "Progress to Mastery")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))
                        
                        ProgressView(value: accuracy, total: progressGoal)
                            .progressViewStyle(LinearProgressViewStyle(tint: Color(hex: "FFD700")))
                            .padding(.horizontal, 40)
                        
                        Text(primaryMetricLabel == "Phrase Lock"
                            ? "\(Int(progressGoal - accuracy))% more to clear the phrase"
                            : "\(Int(progressGoal - accuracy))% more to master")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
                
                // Buttons
                VStack(spacing: 12) {
                    Button(action: onContinue) {
                        Text(continueButtonTitle)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color(hex: "FFD700"))
                            .cornerRadius(12)
                    }
                    
                    Button(action: onExit) {
                        Text("Back to Level")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
                .padding(.horizontal, 40)
            }
        }
    }
}

struct ResultStat: View {
    let value: String
    let label: String
    let icon: String
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(Color(hex: "FFD700"))
            
            Text(value)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.white)
            
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
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
