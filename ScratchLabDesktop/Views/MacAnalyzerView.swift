import SwiftUI
import AVFoundation
import AppKit
import ApplicationServices
import Network
import OSLog
import Darwin

enum MacWorkspaceRouting {
    static let workspaceTabStorageKey = "scratchlab.mac.workspaceTab"
    static let practiceWorkspaceID = "practice"
    static let captureWorkspaceID = "capture"
    static let reviewWorkspaceID = "review"
    static let advancedWorkspaceID = "advanced"

    static func showRoutineCapture(defaults: UserDefaults = .standard) {
        defaults.set(captureWorkspaceID, forKey: workspaceTabStorageKey)
    }
}

struct MacAnalyzerView: View {
    private static let practiceBeatModeColumns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    private enum WorkspaceTab: String, CaseIterable, Identifiable {
        case practice
        case capture
        case review
        case advanced

        var id: String { rawValue }

        var title: String {
            switch self {
            case .practice: return "Practice"
            case .capture: return "Capture"
            case .review: return "Review"
            case .advanced: return "Advanced"
            }
        }

        var systemImage: String {
            switch self {
            case .practice: return "figure.disc.sports"
            case .capture: return "record.circle"
            case .review: return "checkmark.seal.fill"
            case .advanced: return "slider.horizontal.3"
            }
        }

        static func resolved(from storedValue: String) -> WorkspaceTab {
            if let tab = WorkspaceTab(rawValue: storedValue) {
                return tab
            }

            switch storedValue {
            case "testLab":
                return .practice
            case "routineLab":
                return .capture
            case "notationLab":
                return .advanced
            default:
                return .practice
            }
        }
    }

    private enum CaptureTarget: String, CaseIterable, Identifiable {
        case autoDetect
        case babyScratch
        case chirp
        case transform
        case flare
        case unknown

        var id: String { rawValue }

        var title: String {
            switch self {
            case .autoDetect: return "Auto Detect"
            case .babyScratch: return "Baby Scratch"
            case .chirp: return "Chirp"
            case .transform: return "Transform"
            case .flare: return "Flare"
            case .unknown: return "Unknown"
            }
        }

        var scratchType: CaptureSessionScratchType {
            switch self {
            case .autoDetect, .unknown:
                return .unknown
            case .babyScratch:
                return .babyScratch
            case .chirp:
                return .chirp
            case .transform:
                return .transform
            case .flare:
                return .flare1Click
            }
        }

        static func target(for scratchType: CaptureSessionScratchType?) -> CaptureTarget {
            switch scratchType {
            case .babyScratch:
                return .babyScratch
            case .chirp:
                return .chirp
            case .transform:
                return .transform
            case .flare1Click, .flare2Click, .flare3Click:
                return .flare
            case .unknown:
                return .unknown
            case .none:
                return .autoDetect
            default:
                return .autoDetect
            }
        }
    }

    private enum CaptureTimingMode: String, CaseIterable, Identifiable {
        case noBeat
        case click
        case beat
        case calibration

        var id: String { rawValue }

        var title: String {
            switch self {
            case .noBeat: return "No Beat"
            case .click: return "Click"
            case .beat: return "Beat"
            case .calibration: return "Calibration"
            }
        }
    }

    private enum ReviewCorrection: String, CaseIterable, Identifiable {
        case babyScratch = "baby_scratch"
        case chirp
        case flare
        case transform
        case stab
        case drag
        case scribble
        case tear
        case orbit
        case crab
        case cut
        case combo
        case unknown
        case manualLabel = "manual_label"

        var id: String { rawValue }
    }

    private enum StageLayout: String, CaseIterable, Identifiable {
        case desktopDeck
        case dualCam

        var id: String { rawValue }

        var title: String {
            switch self {
            case .desktopDeck: return "Deck View"
            case .dualCam: return "Dual Cam"
            }
        }
    }

    private enum AudioRoutingOption: String, CaseIterable, Identifiable {
        case blackHole
        case loopback
        case interfaceLoopback

        var id: String { rawValue }

        var title: String {
            switch self {
            case .blackHole: return "BlackHole"
            case .loopback: return "Loopback"
            case .interfaceLoopback: return "Interface Loopback"
            }
        }

        var icon: String {
            switch self {
            case .blackHole: return "circle.grid.2x2.fill"
            case .loopback: return "arrow.trianglehead.2.clockwise.rotate.90"
            case .interfaceLoopback: return "cable.connector"
            }
        }

        var detail: String {
            switch self {
            case .blackHole:
                return "Mirror Serato into a Multi-Output Device with BlackHole, then select the BlackHole input here."
            case .loopback:
                return "Send Serato DJ Pro into a Loopback virtual device, then choose that Loopback input above."
            case .interfaceLoopback:
                return "If your mixer or interface exposes loopback, REC, or USB return channels, pick that hardware input here."
            }
        }

        func matches(deviceName: String) -> Bool {
            let lowercasedName = deviceName.lowercased()

            switch self {
            case .blackHole:
                return lowercasedName.contains("blackhole")
            case .loopback:
                return lowercasedName.contains("loopback")
                    || lowercasedName.contains("rogue amoeba")
            case .interfaceLoopback:
                return lowercasedName.contains("djm")
                    || lowercasedName.contains("scarlett")
                    || lowercasedName.contains("mixer")
                    || lowercasedName.contains("record")
                    || lowercasedName.contains("usb")
            }
        }
    }

    private enum PracticeDuration: String, CaseIterable, Identifiable {
        case fiveMinutes = "5m"
        case tenMinutes = "10m"
        case fifteenMinutes = "15m"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .fiveMinutes: return "5 min"
            case .tenMinutes: return "10 min"
            case .fifteenMinutes: return "15 min"
            }
        }

        var duration: TimeInterval {
            switch self {
            case .fiveMinutes: return 300
            case .tenMinutes: return 600
            case .fifteenMinutes: return 900
            }
        }
    }

    private enum AdvancedSection: String, CaseIterable, Identifiable {
        case overview
        case audio
        case cameraDeck
        case midiFader
        case monitor
        case captureDetails

        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview:       return "Overview"
            case .audio:          return "Audio"
            case .cameraDeck:     return "Camera / Deck"
            case .midiFader:      return "MIDI / Fader"
            case .monitor:        return "Monitor / Connection"
            case .captureDetails: return "Capture details"
            }
        }

        var systemImage: String {
            switch self {
            case .overview:       return "rectangle.grid.2x2"
            case .audio:          return "waveform"
            case .cameraDeck:     return "video"
            case .midiFader:      return "slider.horizontal.3"
            case .monitor:        return "dot.radiowaves.left.and.right"
            case .captureDetails: return "doc.text.magnifyingglass"
            }
        }
    }

    @AppStorage("scratchlab.mac.advancedSection") private var advancedSectionRaw = AdvancedSection.overview.rawValue
    private var advancedSection: AdvancedSection {
        get { AdvancedSection(rawValue: advancedSectionRaw) ?? .overview }
        nonmutating set { advancedSectionRaw = newValue.rawValue }
    }
    private var advancedSectionBinding: Binding<AdvancedSection> {
        Binding(get: { advancedSection }, set: { advancedSection = $0 })
    }

    @AppStorage(MacWorkspaceRouting.workspaceTabStorageKey) private var workspaceTabRaw = WorkspaceTab.practice.rawValue
    @AppStorage("scratchlab.mac.stageLayout") private var stageLayoutRaw = StageLayout.desktopDeck.rawValue
    @AppStorage("scratchlab.mac.practiceDuration") private var practiceDurationRaw = PracticeDuration.fiveMinutes.rawValue
    @AppStorage("scratchlab.mac.liveInputEnabled") private var liveInputEnabled = false
    @AppStorage("scratchlab.mac.lastPerformerName") private var lastPerformerName = ""
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var captureEngine: MacCaptureEngine
    @EnvironmentObject private var companionReceiver: CompanionCameraReceiver
    @EnvironmentObject private var practiceBeatStore: PracticeBeatStore
    @EnvironmentObject private var relayedWatchCaptureStore: RelayedWatchCaptureStore
    @EnvironmentObject private var performerBroadcaster: PerformerMonitorBroadcaster
    @EnvironmentObject private var routineSessionStore: RoutineSessionStore
    @EnvironmentObject private var sessionUploadManager: SessionUploadManager
    @EnvironmentObject private var progressManager: ProgressManager
    @StateObject private var beatEngine = ScratchLabBeatEngine()
    @StateObject private var seratoWindowMover = SeratoWindowMover()
    @StateObject private var sessionExportCoordinator = SessionExportCoordinator()
    @StateObject private var routineSessionSetup = SessionSetupViewModel(surface: .macRoutine)
    @StateObject private var babyScratchDemo = BabyScratchDemoPlaybackCoordinator()
    @StateObject private var demoModeController = ScratchLabDemoModeController()
    @StateObject private var rawJSONInspector = RawJSONInspectorViewModel()
    @ObservedObject private var runtimeDiagnostics = ScratchLabRuntimeDiagnostics.shared
    @State private var exportMixMode: ExportMixMode = .scratchOnly
    @State private var isBuildingDemoExportPackage = false
    @State private var capturedNotationSnapshot: CaptureCore.DetectedNotationSnapshot?
    @State private var isPracticeSessionActive = false
    @State private var practiceTimeRemaining: TimeInterval = PracticeDuration.fiveMinutes.duration
    @State private var practiceDetectionCount = 0
    @State private var practiceAverageAccuracy = 0.0
    @State private var practiceBestAccuracy = 0.0
    @State private var practiceScore = 0
    @State private var practiceCurrentStreak = 0
    @State private var practiceBestStreak = 0
    @State private var practiceLastHandledDetectionAt: Date?
    @State private var practiceLastSavedAt: Date?
    @State private var practiceLastSavedAccuracy = 0.0
    @State private var practiceLastSavedDuration: TimeInterval = 0
    @State private var practiceTimer: Timer?
    @State private var routineCountInBeat: Int?
    @State private var isShowingAllRoutineSessions = false
    @State private var captureTimingMode: CaptureTimingMode = .noBeat
    @State private var reviewCorrectionSelection: ReviewCorrection = .unknown
    @State private var reviewDecisionByTakeID: [String: ReviewCorrection] = [:]
    @State private var reviewStatusMessage = "Confirm before export."
    @State private var isShowingRawJSONInspector = false
    #if DEBUG
    @State private var isShowingStagingInspector = false
    #endif

    private var stagingInspectorContexts: [StagingInspectorContext] {
        [
            StagingInspectorContext(
                storageKind: .routine,
                title: "Routine Capture",
                actionTitle: "Re-scan",
                captureDirectoryURLProvider: { captureEngine.routineRecordingsFolderURL },
                statusTextProvider: { captureEngine.routineRecordingStatus },
                runAction: { captureEngine.rescanRoutineCaptures() },
                validationReportProvider: nil
            ),
            StagingInspectorContext(
                storageKind: .relayedWatch,
                title: "Relayed Watch Capture",
                actionTitle: "Reconcile",
                captureDirectoryURLProvider: { relayedWatchCaptureStore.captureDirectoryURL },
                statusTextProvider: { relayedWatchCaptureStore.lastImportStatus },
                runAction: { relayedWatchCaptureStore.reconcileStoredSessionsNow() },
                validationReportProvider: nil
            )
        ]
    }

    var body: some View {
        TabView(selection: workspaceTabBinding) {
            practiceWorkspace
                .tabItem {
                    Label(WorkspaceTab.practice.title, systemImage: WorkspaceTab.practice.systemImage)
                }
                .tag(WorkspaceTab.practice)

            captureWorkspace
                .tabItem {
                    Label(WorkspaceTab.capture.title, systemImage: WorkspaceTab.capture.systemImage)
                }
                .tag(WorkspaceTab.capture)

            reviewWorkspace
                .tabItem {
                    Label(WorkspaceTab.review.title, systemImage: WorkspaceTab.review.systemImage)
                }
                .tag(WorkspaceTab.review)

            advancedWorkspace
                .tabItem {
                    Label(WorkspaceTab.advanced.title, systemImage: WorkspaceTab.advanced.systemImage)
                }
                .tag(WorkspaceTab.advanced)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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
        .safeAreaInset(edge: .top, spacing: 0) {
            if let alertState = routineSessionStore.alertState {
                RoutineSessionErrorBanner(
                    title: alertState.title,
                    message: alertState.message,
                    dismiss: routineSessionStore.dismissAlert
                )
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 8)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: createNewSessionAction) {
                    Label("New Session", systemImage: "plus")
                }
                .disabled(captureEngine.isRoutineRecording)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: routineSessionStore.alertState?.id)
        .onAppear {
            captureEngine.autoSelectCaptureAudioDeviceIfNeeded()
            if liveInputEnabled {
                startMacLiveInput()
            } else {
                captureEngine.statusMessage = "Demo is ready. No hardware is needed. Start live input only when hardware is connected."
            }
            performerBroadcaster.refreshAdvertising()
            sessionUploadManager.refresh()
            captureEngine.setPerformerMonitorStreamingEnabled(!performerBroadcaster.connectedPeerNames.isEmpty)
            practiceBeatStore.configurePracticeContext(scratchID: CaptureSessionScratchType.babyScratch.rawValue)
            seratoWindowMover.refreshStatus()
            synchronizeSelectedRoutineSession()
            babyScratchDemo.configureBabyScratchIfNeeded()
            stageLayout = .desktopDeck
            if !isPracticeSessionActive {
                practiceTimeRemaining = practiceDuration.duration
            }
            if liveInputEnabled, stageLayout == .desktopDeck {
                captureEngine.preferMacCameraForDesktopDeck()
            }
        }
        .onChange(of: routineSessionSetup.performerName) { _, newValue in
            let trimmedValue = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedValue.isEmpty else { return }
            lastPerformerName = trimmedValue
        }
        .onChange(of: routineSessionStore.selectedSessionID) { _, _ in
            synchronizeSelectedRoutineSession()
        }
        .onDisappear {
            beatEngine.stop()
            babyScratchDemo.stop()
            demoModeController.stopDemo()
            practiceBeatStore.handleLeavingPractice()
            cancelTestLabPracticeSession()
            captureEngine.setPerformerMonitorStreamingEnabled(false)
        }
        .onChange(of: stageLayoutRaw) { _, newValue in
            guard liveInputEnabled, StageLayout(rawValue: newValue) == .desktopDeck else { return }
            captureEngine.preferMacCameraForDesktopDeck()
        }
        .onChange(of: workspaceTabRaw) { _, newValue in
            if WorkspaceTab.resolved(from: newValue) == .capture {
                captureEngine.refreshDevices()
                captureEngine.autoSelectCaptureAudioDeviceIfNeeded()
            }
            guard WorkspaceTab.resolved(from: newValue) != .practice else { return }
            babyScratchDemo.stop()
            demoModeController.stopDemo()
            practiceBeatStore.handleLeavingPractice()
            cancelTestLabPracticeSession()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active, workspaceTab == .capture {
                captureEngine.refreshDevices()
                captureEngine.autoSelectCaptureAudioDeviceIfNeeded()
                return
            }
            guard newPhase != .active else { return }
            babyScratchDemo.stop()
            demoModeController.stopDemo()
            practiceBeatStore.handleAppDidBecomeInactive()
        }
        .onChange(of: practiceDurationRaw) { _, _ in
            guard !isPracticeSessionActive else { return }
            practiceTimeRemaining = practiceDuration.duration
        }
        .onChange(of: coachDemoInstructionKey) { _, _ in
            babyScratchDemo.configureBabyScratchIfNeeded()
        }
        .onChange(of: coachDemoPlaybackBlocked) { _, isBlocked in
            guard isBlocked else { return }
            babyScratchDemo.stop()
        }
        .onReceive(captureEngine.$availableVideoDevices) { _ in
            guard liveInputEnabled, stageLayout == .desktopDeck else { return }
            captureEngine.preferMacCameraForDesktopDeck()
        }
        .onReceive(performerBroadcaster.$connectedPeerNames) { peers in
            captureEngine.setPerformerMonitorStreamingEnabled(!peers.isEmpty)
        }
        .onReceive(captureEngine.$performerMonitorFrame) { frame in
            guard let frame else { return }
            performerBroadcaster.send(frame: frame)
        }
        .onReceive(captureEngine.$lastScratchDetection) { detection in
            handlePracticeDetection(detection)
        }
        .onReceive(routineSessionSetup.$config.dropFirst()) { config in
            guard routineSessionStore.selectedSessionID == config.sessionID else { return }
            routineSessionStore.updateSelectedSession(config: config)
        }
        .sheet(isPresented: $isShowingRawJSONInspector, onDismiss: {
            rawJSONInspector.close()
        }) {
            RawJSONInspectorView(viewModel: rawJSONInspector)
        }
        #if DEBUG
        .sheet(isPresented: $isShowingStagingInspector) {
            StagingInspectorView(contexts: stagingInspectorContexts)
        }
        #endif
    }

    private var practiceWorkspace: some View {
        HSplitView {
            practiceSidebar
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 400)

            VStack(spacing: 18) {
                practiceStageHeader
                practiceCameraStage
            }
            .padding(18)
            .background(Color.black)
        }
    }

    private var captureWorkspace: some View {
        HSplitView {
            captureSidebar
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 420)

            VStack(spacing: 18) {
                captureStageHeader

                if !hasRoutineSessions {
                    captureEmptyStateStage
                } else if stageLayout == .desktopDeck {
                    localCameraStage
                } else {
                    HStack(spacing: 18) {
                        localCameraStage
                            .frame(maxWidth: .infinity)
                        companionStage
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(18)
            .background(Color.black)
        }
    }

    private var reviewWorkspace: some View {
        HSplitView {
            reviewSidebar
                .frame(minWidth: 340, idealWidth: 380, maxWidth: 460)

            reviewStage
        }
    }

    private var advancedWorkspace: some View {
        HSplitView {
            advancedSidebar
                .frame(minWidth: 340, idealWidth: 380, maxWidth: 460)

            NotationVisualizerView(demo: babyScratchDemo, capturedSnapshot: capturedNotationSnapshot ?? currentRoutineNotationSnapshot)
        }
    }

    private var practiceSidebar: some View {
        // Coach + practice controls sit at the top. Audio input, scratch
        // detection, ability rating, and quick workflow live behind a single
        // collapsed Diagnostics group so the coaching screen doesn't read like
        // a diagnostics dashboard.
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                practiceHeaderCard
                macDemoModeCard
                practiceControlCard

                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 18) {
                        practiceAudioCard
                        scratchCard
                        practiceFeedbackCard
                        practiceWorkflowCard
                    }
                    .padding(.top, 12)
                } label: {
                    Label("Diagnostics & workflow", systemImage: "slider.horizontal.3")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
            }
            .padding(24)
        }
    }

    private var macDemoModeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Demo")
                        .font(.system(size: 24, weight: .semibold))

                    Text("Hear the Baby Scratch reference and watch the coach react in real time.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Label("No hardware needed", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(nsColor: .systemGreen))
            }

            HStack(spacing: 10) {
                macDemoMetric(title: "Feedback", value: demoModeFeedbackTitle)
                macDemoMetric(title: "Direction", value: demoModeController.motionDirection.label)
            }

            Text(demoModeController.statusMessage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    startMacDemo()
                } label: {
                    Label(demoModeController.isReady ? "Replay" : "Listen", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    demoModeController.pauseDemo()
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!demoModeController.demoPlayer.isPlaying)
            }

            Button {
                exportMacDemoSession()
            } label: {
                HStack(spacing: 8) {
                    if isBuildingDemoExportPackage || sessionExportCoordinator.isPreparing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }

                    Text(demoModeExportButtonTitle)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isBuildingDemoExportPackage || sessionExportCoordinator.isPreparing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func macDemoMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var captureSidebar: some View {
        // Primary action chain stays visible (workflow, inputs, latest take).
        // The session list + workflow summary collapse behind a single
        // Sessions & workflow disclosure to remove the long debug-style scroll.
        VStack(alignment: .leading, spacing: 18) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    captureSessionWorkflowCard
                    captureInputStatusCard
                    captureLatestTakeCard

                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 18) {
                            captureSessionListCard
                            captureWorkflowSummaryCard
                        }
                        .padding(.top, 12)
                    } label: {
                        Label("Sessions & workflow", systemImage: "list.bullet.rectangle")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)
                }
                .padding(.bottom, 24)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
    }

    private var reviewSidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    reviewHeaderCard
                    reviewSessionListCard
                    reviewTakeCard
                    reviewExportCard
                }
                .padding(.bottom, 24)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
    }

    private var advancedSidebar: some View {
        // Header + section picker stay pinned. The right-hand cards are gated
        // by the selected AdvancedSection so the panel is no longer one
        // endless technical scroll. All cards remain reachable — pick a
        // section to bring them into view.
        VStack(alignment: .leading, spacing: 18) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    advancedHeaderCard
                    advancedSectionPickerCard

                    if let activeSession = routineSessionPresentation.activeSession {
                        activeRoutineSessionCard(activeSession)
                    }

                    advancedSelectedSectionContent
                }
                .padding(.bottom, 24)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
    }

    private var advancedSectionPickerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Advanced section")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Picker("Advanced section", selection: advancedSectionBinding) {
                ForEach(AdvancedSection.allCases) { section in
                    Label(section.title, systemImage: section.systemImage).tag(section)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var advancedSelectedSectionContent: some View {
        switch advancedSection {
        case .overview:
            VStack(alignment: .leading, spacing: 22) {
                advancedToolsCard
                performanceDiagnosticsCard
                routineSessionCard
                workflowCard
            }
        case .audio:
            VStack(alignment: .leading, spacing: 22) {
                audioCard
                    .disabled(captureEngine.isRoutineRecording)
                seratoScreenCard
                    .disabled(captureEngine.isRoutineRecording)
                scratchCard
            }
        case .cameraDeck:
            VStack(alignment: .leading, spacing: 22) {
                cameraCard
                    .disabled(captureEngine.isRoutineRecording)
                deckCalibrationCard
                    .disabled(captureEngine.isRoutineRecording)
                handMotionCard
                stageModeCard
                    .disabled(captureEngine.isRoutineRecording)
            }
        case .midiFader:
            VStack(alignment: .leading, spacing: 22) {
                midiMonitorCard
            }
        case .monitor:
            VStack(alignment: .leading, spacing: 22) {
                companionCard
                    .disabled(captureEngine.isRoutineRecording)
            }
        case .captureDetails:
            VStack(alignment: .leading, spacing: 22) {
                if selectedRoutineSession != nil {
                    routineRecordingCard
                }
                cxlCaptureCard
            }
        }
    }

    private var practiceStageHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Practice")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white)

                Text("Try the Baby Scratch demo, listen to the coach, and start a simple practice run.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
            }

            Spacer()

            Button(liveInputEnabled ? "Live input on" : "Start live input") {
                startMacLiveInput()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(liveInputEnabled)

            Button("Open Capture") {
                workspaceTab = .capture
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    private var captureStageHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Capture Session")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white)

                Text("Record clean takes with simple choices. Input routing, calibration, and raw details live in Advanced.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
            }

            Spacer()

            Button("Review Takes") {
                workspaceTab = .review
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    private var localCameraStage: some View {
        liveCameraStage(
            title: stageLayout == .desktopDeck ? "Deck Camera" : "Analyzer Camera",
            subtitle: "\(selectedCameraName) · \(captureEngine.selectedVideoSourceDescription)"
        )
    }

    @ViewBuilder
    private var practiceCameraStage: some View {
        if liveInputEnabled {
            liveCameraStage(
                title: "Practice Camera",
                subtitle: "\(selectedCameraName) · \(captureEngine.selectedVideoSourceDescription)"
            )
        } else {
            macDemoStage
        }
    }

    private var macDemoStage: some View {
        cameraStageCard(
            title: "Demo Feedback Stage",
            subtitle: "Bundled Baby Scratch audio · no camera or microphone required"
        ) {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(nsColor: .windowBackgroundColor),
                        Color(nsColor: .controlBackgroundColor)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                VStack(spacing: 20) {
                    ZStack {
                        Circle()
                            .stroke(demoModeFeedbackColor.opacity(0.24), lineWidth: 16)
                            .frame(width: 170, height: 170)

                        Circle()
                            .trim(from: 0, to: CGFloat(max(0.08, min(1, demoModeController.inputLevel))))
                            .stroke(demoModeFeedbackColor, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                            .frame(width: 170, height: 170)
                            .rotationEffect(.degrees(-90))

                        Image(systemName: "waveform")
                            .font(.system(size: 42, weight: .bold))
                            .foregroundStyle(demoModeFeedbackColor)
                    }

                    VStack(spacing: 6) {
                        Text(demoModeFeedbackTitle)
                            .font(.system(size: 38, weight: .semibold))
                            .foregroundStyle(.white)

                        Text(demoModeController.isReady ? "Coach animation and feedback are playing the bundled reference." : "Tap Listen to play the bundled Baby Scratch reference.")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.72))
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(24)
            }
        }
    }

    private func liveCameraStage(title: String, subtitle: String) -> some View {
        cameraStageCard(title: title, subtitle: subtitle) {
            ZStack(alignment: .topLeading) {
                MacCameraPreviewView(session: captureEngine.captureSession)
                    .overlay(Color.black.opacity(0.08))

                if captureEngine.showRigGuides {
                    DeckGamificationOverlay(detector: captureEngine)
                }

                previewPill
                    .padding(24)
            }
        }
    }

    private var companionStage: some View {
        cameraStageCard(
            title: "Companion Camera",
            subtitle: companionReceiver.connectedPeerNames.isEmpty
                ? "Device not connected"
                : "\(companionReceiver.frameStore.cameraPosition) view from \(companionReceiver.connectedPeerNames.joined(separator: ", "))"
        ) {
            CompanionStageContent(
                frameStore: companionReceiver.frameStore,
                discoveredPeers: companionReceiver.discoveredPeers
            )
        }
    }

    private var selectedCameraName: String {
        captureEngine.selectedVideoDeviceName
    }

    private var demoModeFeedbackTitle: String {
        demoModeController.motionFeedback?.balance.rawValue ?? ScratchMotionBalance.listening.rawValue
    }

    private var demoModeFeedbackColor: Color {
        switch demoModeController.motionFeedback?.balance ?? .listening {
        case .listening:
            return Color(nsColor: .systemBlue)
        case .balanced:
            return Color(nsColor: .systemGreen)
        case .unbalanced:
            return Color(nsColor: .systemRed)
        }
    }

    private var demoModeExportButtonTitle: String {
        if isBuildingDemoExportPackage || sessionExportCoordinator.isPreparing {
            return "Preparing Demo ZIP"
        }
        return "Export demo session"
    }

    private var selectedAudioDevice: AVCaptureDevice? {
        captureEngine.availableAudioDevices
            .first(where: { $0.uniqueID == captureEngine.selectedAudioDeviceUniqueID })
    }

    private var selectedAudioDeviceBinding: Binding<String> {
        Binding(
            get: { captureEngine.selectedAudioDeviceUniqueID },
            set: { captureEngine.selectAudioInput(uniqueID: $0) }
        )
    }

    private var selectedAudioDeviceName: String {
        captureEngine.selectedAudioDeviceName
    }

    private var selectedAudioLooksMic: Bool {
        guard let selectedAudioDevice else { return false }
        let lowercasedName = selectedAudioDevice.localizedName.lowercased()
        return lowercasedName.contains("mic")
            || lowercasedName.contains("microphone")
            || lowercasedName.contains("built-in")
            || lowercasedName.contains("internal")
    }

    private var mixerStatusValue: String {
        if selectedMixerMIDIDeviceName != nil {
            return captureEngine.midiListeningState
        }
        return "Mixer Optional"
    }

    private var mixerStatusColor: Color {
        selectedMixerMIDIDeviceName != nil ? .green : .secondary
    }

    private var mixerStatusDetail: String {
        guard let name = selectedMixerMIDIDeviceName else { return "Not Connected" }
        return "\(name) · \(captureEngine.lastMIDICCMessage)"
    }

    private var selectedMixerMIDIDeviceName: String? {
        captureEngine.availableMIDISources.isEmpty ? nil : captureEngine.selectedMIDIInputSourceName
    }

    private var midiSourceSelectionBinding: Binding<String> {
        Binding(
            get: { captureEngine.selectedMIDIInputSourceID },
            set: { captureEngine.selectedMIDIInputSourceID = $0 }
        )
    }

    private var midiSourcePickerRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MIDI Source")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Picker("MIDI Source", selection: midiSourceSelectionBinding) {
                if captureEngine.availableMIDISources.isEmpty {
                    Text("Not Connected").tag("")
                } else {
                    ForEach(captureEngine.availableMIDISources) { source in
                        Text(source.name).tag(source.id)
                    }
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .disabled(captureEngine.availableMIDISources.isEmpty)
        }
    }

    private var midiLearnStatusText: String {
        switch captureEngine.midiLearnState {
        case .idle:
            return captureEngine.midiCrossfaderMappingStatus
        case .listening:
            return captureEngine.midiLearnFeedback.isEmpty ? "Listening..." : captureEngine.midiLearnFeedback
        case .learned(let mapping):
            if captureEngine.lastMIDICCMessage == "CC -- Ch -- Value --" {
                return "Learned Xfader: \(mapping.displayName)"
            }
            return "Learned Xfader: \(mapping.displayName) · Received \(captureEngine.lastMIDICCMessage)"
        }
    }

    @ViewBuilder
    private var midiLearnRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(midiLearnStatusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                switch captureEngine.midiLearnState {
                case .idle:
                    Button("Learn crossfader") { captureEngine.startMIDILearn() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                case .listening:
                    Button("Cancel") { captureEngine.cancelMIDILearn() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                case .learned:
                    Button("Learn crossfader") { captureEngine.startMIDILearn() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Clear") { captureEngine.clearCrossfaderMapping() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Spacer()
            }
        }
    }

    private var watchStatusValue: String {
        relayedWatchCaptureStore.importedSessions.isEmpty ? "Watch Optional" : "Watch Connected"
    }

    private var watchStatusDetail: String {
        relayedWatchCaptureStore.importedSessions.isEmpty ? "Not connected" : "Motion data available"
    }

    private var diagnosticsCameraValue: String {
        guard captureEngine.isCameraActive else { return "false" }
        if captureEngine.isRoutineRecording || captureEngine.cxlIsRecording {
            return "true (Capture)"
        }
        if liveInputEnabled {
            return "true (Live Input)"
        }
        return "true"
    }

    private var diagnosticsTickRateValue: String {
        let tickRate = runtimeDiagnostics.notationTickRateHz
        let idle = !liveInputEnabled
            && babyScratchDemo.playbackState != .playing
            && !captureEngine.isRoutineRecording
            && !captureEngine.cxlIsRecording
        if idle {
            return String(format: "%.1f Hz (idle)", tickRate)
        }
        if liveInputEnabled
            && babyScratchDemo.playbackState != .playing
            && !captureEngine.isRoutineRecording
            && !captureEngine.cxlIsRecording {
            return String(format: "%.1f Hz (live preview)", tickRate)
        }
        return String(format: "%.1f Hz", tickRate)
    }

    private var hasReviewNotationPreview: Bool {
        currentRoutineNotationSnapshot?.recordMovementEvents.isEmpty == false
    }

    private var hasPartialReviewNotation: Bool {
        currentRoutineNotationSnapshot?.audioEvents.isEmpty == false && !hasReviewNotationPreview
    }

    private var lastRoutineTakeDisplayName: String {
        guard let lastRoutineRecordingURL = captureEngine.lastRoutineRecordingURL else {
            return fallbackTakeDisplayName()
        }
        // Use a friendly "Take N" label rather than leaking the underlying
        // `<UUID>_takeNNN_routine.mov` filename in primary UI surfaces.
        return Self.friendlyTakeLabel(from: lastRoutineRecordingURL)
    }

    private var selectedRawJSONURL: URL? {
        guard let lastRoutineRecordingURL = captureEngine.lastRoutineRecordingURL else {
            return nil
        }
        return CaptureCore.LocalRecordingFiles.sidecarURL(forMediaURL: lastRoutineRecordingURL)
    }

    private var routineStartButtonTitle: String {
        if routineCountInBeat != nil {
            return "Cancel Count-in"
        }
        return captureEngine.isRoutineRecording ? "Stop Recording" : "Start Recording"
    }

    private var routineStartDisabled: Bool {
        false
    }

    private var routineMetadataStatusMessage: String? {
        routineSessionSetup.firstValidationMessage
    }

    private var routineScratchTypeBinding: Binding<CaptureSessionScratchType?> {
        Binding(
            get: { routineSessionSetup.scratchType },
            set: { routineSessionSetup.scratchType = $0 }
        )
    }

    private var routineCaptureModeBinding: Binding<CaptureSessionCaptureMode> {
        Binding(
            get: { routineSessionSetup.captureMode },
            set: { routineSessionSetup.captureMode = $0 }
        )
    }

    private var routineBeatEngineModeBinding: Binding<BeatEngineMode> {
        Binding(
            get: { routineSessionSetup.beatEngineMode },
            set: { routineSessionSetup.beatEngineMode = $0 }
        )
    }

    private var routineDrillModeBinding: Binding<CaptureSessionDrillMode> {
        Binding(
            get: { routineSessionSetup.drillMode },
            set: { routineSessionSetup.drillMode = $0 }
        )
    }

    private var routineHandednessBinding: Binding<CaptureSessionHandedness> {
        Binding(
            get: { routineSessionSetup.handedness },
            set: { routineSessionSetup.handedness = $0 }
        )
    }

    private var routineBPMTextBinding: Binding<String> {
        Binding(
            get: { routineSessionSetup.bpmText },
            set: { routineSessionSetup.bpmText = $0 }
        )
    }

    private var routinePerformerBinding: Binding<String> {
        Binding(
            get: { routineSessionSetup.performerName },
            set: { routineSessionSetup.performerName = $0 }
        )
    }

    private var exportShareRequestBinding: Binding<SessionShareRequest?> {
        Binding(
            get: { sessionExportCoordinator.shareRequest },
            set: { sessionExportCoordinator.shareRequest = $0 }
        )
    }

    private var currentRoutineUploadJob: SessionUploadJob? {
        sessionUploadManager.job(for: captureEngine.lastRoutineRecordingSessionID)
    }

    private var selectedRoutineSession: RoutineSessionDraft? {
        routineSessionStore.selectedSession
    }

    private var hasRecordedTake: Bool {
        captureEngine.lastRoutineRecordingURL != nil
    }

    private var visibleTakeCount: Int {
        max(routineSessionSetup.config.takeCount, hasRecordedTake ? 1 : 0)
    }

    private var selectedCaptureTimingMode: CaptureTimingMode {
        if routineSessionSetup.captureMode == .calibrationNoClick {
            return captureTimingMode == .calibration ? .calibration : .noBeat
        }

        if routineSessionSetup.beatEngineMode == .clickTrack {
            return .click
        }

        if routineSessionSetup.beatEngineMode.beatEnabled {
            return .beat
        }

        return .noBeat
    }

    private var mainCaptureButtonTitle: String {
        if !liveInputEnabled {
            return "Start Capture"
        }
        return captureEngine.isRoutineRecording ? "Stop" : "Record"
    }

    private var reviewTakeID: String {
        captureEngine.lastRoutineRecordingURL?
            .deletingPathExtension()
            .lastPathComponent
            ?? selectedRoutineSession?.id
            ?? "No take"
    }

    private var reviewDetectedScratchLabel: String {
        // Friendly empty state — never surface "Unknown" as a primary label
        // when no detection has happened yet.
        currentRoutineArtifactStatus?.detectedLabel
            ?? captureEngine.lastScratchDetection?.scratchName
            ?? "Awaiting take"
    }

    private var reviewConfidenceLabel: String {
        guard let confidence = currentRoutineArtifactStatus?.labelConfidence
            ?? captureEngine.lastScratchDetection?.confidence else {
            return "Low"
        }
        if confidence >= 75 {
            return "High"
        }
        if confidence >= 45 {
            return "Medium"
        }
        return "Low"
    }

    private var reviewConfidenceColor: Color {
        switch reviewConfidenceLabel {
        case "High":
            return .green
        case "Medium":
            return .orange
        default:
            return .secondary
        }
    }

    private var reviewDecisionSummary: String {
        guard hasRecordedTake else {
            return "No take to review yet"
        }
        if let decision = reviewDecisionByTakeID[reviewTakeID] {
            return "Review label: \(decision.rawValue)"
        }
        if hasPartialReviewNotation {
            return "Audio-only take · No record movement detected."
        }
        return "Detected: \(reviewDetectedScratchLabel) · Confidence: \(reviewConfidenceLabel)"
    }

    private var currentRoutineArtifactStatus: TakeArtifactStatusSnapshot? {
        captureEngine.routineTakeArtifactStatuses.last
    }

    private var currentRoutineNotationSnapshot: CaptureCore.DetectedNotationSnapshot? {
        currentRoutineArtifactStatus?.detectedNotation ?? captureEngine.lastRoutineDetectedNotation
    }

    private var currentRoutineNotationPreview: ScratchNotation? {
        guard let snapshot = currentRoutineNotationSnapshot,
              snapshot.recordMovementEvents.isEmpty == false else {
            return nil
        }
        let scratchID = routineSessionSetup.scratchType?.rawValue ?? "detected_capture"
        return ScratchNotation.detectedPreview(
            scratchID: scratchID,
            events: snapshot.recordMovementEvents
        )
    }

    private var reviewStrokeCount: Int {
        currentRoutineNotationSnapshot?.recordMovementEvents.count ?? 0
    }

    private var reviewAudioEventCount: Int {
        currentRoutineNotationSnapshot?.audioEvents.count ?? 0
    }

    private var reviewFaderEventCount: Int {
        currentRoutineNotationSnapshot?.faderEvents.count ?? 0
    }

    private var reviewMixerMIDIEventCount: Int {
        currentRoutineNotationSnapshot?.mixerMidiEvents.count ?? 0
    }

    private var reviewArtifactStatusSummary: String {
        guard let status = currentRoutineArtifactStatus else {
            return "No take to review yet"
        }
        let takeLabel = "Take \(String(format: "%03d", status.takeNumber))"
        switch status.readiness {
        case .ready:
            return "\(takeLabel) is ready for review and export."
        case .recording:
            return "\(takeLabel) is still recording."
        case .finalizing:
            return "\(takeLabel) is finalizing audio/video."
        case .missingAudio:
            return "\(takeLabel) audio is missing. Retake it before export."
        case .missingVideo:
            return "\(takeLabel) video is missing. Retake it before export."
        case .failed(let message):
            return "\(takeLabel) failed: \(message)"
        }
    }

    private var reviewNotationAvailabilityMessage: String {
        if hasPartialReviewNotation {
            return "Audio-only take. Hand motion wasn't detected — review timing only."
        }
        return "Notation unavailable for this take. ScratchLab will only show a preview when real captured movement events were saved."
    }

    private var captureTargetBinding: Binding<CaptureTarget> {
        Binding(
            get: { CaptureTarget.target(for: routineSessionSetup.scratchType) },
            set: { target in
                routineSessionSetup.scratchType = target.scratchType
            }
        )
    }

    private var captureTimingModeBinding: Binding<CaptureTimingMode> {
        Binding(
            get: { selectedCaptureTimingMode },
            set: { mode in
                applyCaptureTimingMode(mode)
            }
        )
    }

    private var routineSessionPresentation: SessionListPresentationModel<RoutineSessionDraft> {
        routineSessionStore.sessionListPresentation
    }

    private var hasRoutineSessions: Bool {
        !routineSessionStore.sessions.isEmpty
    }

    private var createNewSessionAction: () -> Void {
        RoutineSessionUIActionFactory.makeCreateNewSessionAction(for: routineSessionStore) { _ in
            workspaceTab = .capture
        }
    }

    private var audioRoutingStatusMessage: String {
        guard let selectedAudioDevice else {
            return "Choose the input that already carries your deck audio."
        }

        if selectedAudioLooksMic {
            return "\"\(selectedAudioDevice.localizedName)\" is still a mic path. Route Serato into BlackHole, Loopback, or your interface loopback for cleaner scratch detection."
        }

        return "ScratchLab works best when your deck audio is routed here."
    }

    private var audioRoutingStatusIcon: String {
        selectedAudioLooksMic ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    }

    private var audioRoutingStatusColor: Color {
        selectedAudioLooksMic ? Color(nsColor: .systemOrange) : Color(nsColor: .systemGreen)
    }

    private var stageLayout: StageLayout {
        get { StageLayout(rawValue: stageLayoutRaw) ?? .desktopDeck }
        nonmutating set { stageLayoutRaw = newValue.rawValue }
    }

    private var practiceDuration: PracticeDuration {
        get { PracticeDuration(rawValue: practiceDurationRaw) ?? .fiveMinutes }
        nonmutating set { practiceDurationRaw = newValue.rawValue }
    }

    private var workspaceTab: WorkspaceTab {
        get { WorkspaceTab.resolved(from: workspaceTabRaw) }
        nonmutating set { workspaceTabRaw = newValue.rawValue }
    }

    private var stageLayoutBinding: Binding<StageLayout> {
        Binding(
            get: { stageLayout },
            set: { stageLayout = $0 }
        )
    }

    private var workspaceTabBinding: Binding<WorkspaceTab> {
        Binding(
            get: { workspaceTab },
            set: { workspaceTab = $0 }
        )
    }

    private var practiceDurationBinding: Binding<PracticeDuration> {
        Binding(
            get: { practiceDuration },
            set: { practiceDuration = $0 }
        )
    }

    private var coachScratchTypeID: String? {
        workspaceTab == .practice
            ? CaptureSessionScratchType.babyScratch.rawValue
            : routineSessionSetup.scratchType?.rawValue
    }

    private var coachScratchDisplayName: String? {
        workspaceTab == .practice
            ? CaptureSessionScratchType.babyScratch.title
            : routineSessionSetup.scratchType?.title
    }

    private var coachInstruction: ScratchCoachInstruction {
        ScratchCoachInstructionStore.shared.instruction(
            for: coachScratchTypeID.map { normalizeScratchType(input: $0) },
            scratchDisplayName: coachScratchDisplayName
        )
    }

    private var coachDemoInstructionKey: String {
        "\(coachInstruction.scratchType)|\(coachInstruction.demoAudioFile ?? "")|\(coachInstruction.demoAudioRole)"
    }

    private var coachDemoPlaybackBlocked: Bool {
        practiceBeatStore.isPlaying || captureEngine.isRoutineRecording
    }

    private var coachDemoStatusMessage: String {
        if coachInstruction.scratchType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Choose a scratch to load a coach demo."
        }
        if captureEngine.isRoutineRecording {
            return "Coach demo pauses during routine capture."
        }
        if practiceBeatStore.isPlaying {
            return "Stop the practice beat to hear the coach demo."
        }
        if !babyScratchDemo.isAudioAvailable {
            return "Demo audio unavailable for this scratch."
        }
        if let lastErrorMessage = babyScratchDemo.lastErrorMessage {
            return lastErrorMessage
        }
        return coachInstruction.demoAudioRole == "withBeat"
            ? "Coach demo includes beat and scratch together."
            : "Coach plays the scratch only — no beat behind it."
    }

    private var coachCardTheme: ScratchCoachCardTheme {
        ScratchCoachCardTheme(
            accentColor: Color(nsColor: .systemYellow),
            primaryTextColor: .primary,
            secondaryTextColor: .secondary,
            bubbleFill: Color.white.opacity(0.04),
            bubbleOutline: Color.white.opacity(0.08),
            illustrationFill: Color.white.opacity(0.04),
            detailFill: Color.white.opacity(0.04),
            controllerFill: Color.white.opacity(0.04),
            controllerTrackColor: Color.white.opacity(0.10),
            inactiveKnobColor: Color.white.opacity(0.32)
        )
    }

    private func synchronizeSelectedRoutineSession() {
        captureEngine.recordingSessionConfig = selectedRoutineSession?.config
        captureEngine.rescanRoutineCaptures()

        guard let selectedRoutineSession else { return }
        routineSessionSetup.applyPersistedConfig(selectedRoutineSession.config)
    }

    private func routineSessionTitle(for session: RoutineSessionDraft) -> String {
        // Treat empty or 1–2 character performer names as display-empty so
        // ad-hoc names like "k" / "h" never surface as primary card titles.
        // The raw stored value is preserved — display only.
        let performerName = session.config.performerName.trimmingCharacters(in: .whitespacesAndNewlines)
        if performerName.count >= 3 { return performerName }
        return "Untitled session"
    }

    private func routineSessionSubtitle(for session: RoutineSessionDraft) -> String {
        let scratchLabel = session.config.scratchType?.title ?? "Scratch type later"
        let bpmLabel = session.config.bpm.map { "\($0) BPM" } ?? "BPM later"
        return "\(scratchLabel) · \(bpmLabel)"
    }

    // MARK: - Display helpers

    /// Strips UUIDs and `.mov` filenames out of a status string so primary
    /// surfaces don't leak engineering identifiers. Replaces the UUID +
    /// filename block with "this take" when one is present.
    static func friendlyStatusMessage(_ raw: String) -> String {
        var cleaned = raw
        // Replace `<UUID>_takeNNN_routine.mov[.]` with `take N` (humanized).
        let uuidTakeFile = #"[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}_take(\d{1,4})(?:_[A-Za-z0-9_-]+)?\.mov\.?"#
        if let regex = try? NSRegularExpression(pattern: uuidTakeFile) {
            let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
            cleaned = regex.stringByReplacingMatches(in: cleaned, range: range, withTemplate: "take $1.")
        }
        // Strip any remaining bare UUID.
        let uuidOnly = #"[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}"#
        if let regex = try? NSRegularExpression(pattern: uuidOnly) {
            let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
            cleaned = regex.stringByReplacingMatches(in: cleaned, range: range, withTemplate: "this session")
        }
        // Drop any leftover trailing `.mov` filename clauses.
        let movFile = #"[A-Za-z0-9_-]+\.mov\.?"#
        if let regex = try? NSRegularExpression(pattern: movFile) {
            let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
            cleaned = regex.stringByReplacingMatches(in: cleaned, range: range, withTemplate: "this take")
        }
        // Collapse double spaces left behind by replacements.
        while cleaned.contains("  ") { cleaned = cleaned.replacingOccurrences(of: "  ", with: " ") }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Friendly take label from a recording URL, e.g. "Take 2".
    static func friendlyTakeLabel(from url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        if let regex = try? NSRegularExpression(pattern: #"_take(\d{1,4})"#),
           let match = regex.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)),
           let r = Range(match.range(at: 1), in: stem) {
            let n = Int(stem[r]) ?? 0
            return n > 0 ? "Take \(n)" : "Take"
        }
        return "Take"
    }

    /// Compact identifier string for "Copy ID" affordances.
    static func shortIdentifier(_ id: String) -> String {
        guard id.count > 12 else { return id }
        return String(id.prefix(8)) + "…" + String(id.suffix(4))
    }

    private func applyCaptureTimingMode(_ mode: CaptureTimingMode) {
        captureTimingMode = mode

        switch mode {
        case .noBeat:
            routineSessionSetup.captureMode = .calibrationNoClick
            routineSessionSetup.beatEngineMode = .silent
        case .click:
            routineSessionSetup.captureMode = .timedClick
            routineSessionSetup.beatEngineMode = .clickTrack
            if routineSessionSetup.bpmValue == nil {
                routineSessionSetup.bpmText = String(CaptureClickTrackDefaults.defaultTimedBPM)
            }
        case .beat:
            routineSessionSetup.captureMode = .timedClick
            routineSessionSetup.beatEngineMode = .boomBapTrainer
            if routineSessionSetup.bpmValue == nil {
                routineSessionSetup.bpmText = String(CaptureClickTrackDefaults.defaultTimedBPM)
            }
        case .calibration:
            routineSessionSetup.captureMode = .calibrationNoClick
            routineSessionSetup.beatEngineMode = .silent
        }
    }

    private func handleMainCaptureAction() {
        guard liveInputEnabled else {
            startMacLiveInput()
            return
        }

        if captureEngine.isRoutineRecording {
            if captureEngine.cxlIsRecording {
                captureEngine.stopCXLCapture()
            }
            Task {
                await handleRoutineRecordingButton()
            }
            return
        }

        guard ensureCaptureSessionForRecording() != nil else {
            return
        }

        if routineSessionSetup.scratchType == nil {
            routineSessionSetup.scratchType = .unknown
        }

        guard routineMetadataStatusMessage == nil,
              selectedAudioDevice != nil,
              !captureEngine.selectedVideoDeviceUniqueID.isEmpty else {
            Task {
                await handleRoutineRecordingButton()
            }
            return
        }

        captureEngine.startCXLCapture(
            scratchType: routineSessionSetup.scratchType?.rawValue ?? CaptureSessionScratchType.unknown.rawValue,
            mode: selectedCaptureTimingMode.title,
            bpm: routineSessionSetup.bpmValue
        )

        Task {
            await handleRoutineRecordingButton()
        }
    }

    private func markLastTakeSaved() {
        guard hasRecordedTake else { return }
        switch currentRoutineArtifactStatus?.readiness {
        case .ready:
            captureEngine.reportRoutineRecordingIssue("Take saved. Open Review to accept, correct, or leave the label unknown.")
        case .finalizing, .recording:
            captureEngine.reportRoutineRecordingIssue("Take saved. Audio/video are still finalizing before export.")
        case .missingAudio:
            captureEngine.reportRoutineRecordingIssue("The latest take is missing audio. Retake it before export.")
        case .missingVideo:
            captureEngine.reportRoutineRecordingIssue("The latest take is missing video. Retake it before export.")
        case .failed(let message):
            captureEngine.reportRoutineRecordingIssue("The latest take failed: \(message)")
        case .none:
            captureEngine.reportRoutineRecordingIssue("Take saved. ScratchLab is verifying the capture before export.")
        }
    }

    private func prepareRetake() {
        guard hasRecordedTake else { return }
        captureEngine.reportRoutineRecordingIssue("Retake selected. Press Record to capture the next take; the previous take remains stored.")
        workspaceTab = .capture
    }

    @discardableResult
    private func ensureCaptureSessionForRecording() -> RoutineSessionDraft? {
        if let selectedRoutineSession {
            return selectedRoutineSession
        }

        let currentConfig = routineSessionSetup.config
        guard let draft = routineSessionStore.createNewSessionFromUI() else {
            return nil
        }

        var persistedConfig = currentConfig
        persistedConfig.sessionID = draft.id
        persistedConfig.createdAt = draft.config.createdAt
        persistedConfig.updatedAt = draft.config.updatedAt
        persistedConfig.takeCount = draft.config.takeCount
        persistedConfig.takeDurationSeconds = draft.config.takeDurationSeconds
        routineSessionSetup.applyPersistedConfig(persistedConfig)
        captureEngine.recordingSessionConfig = persistedConfig
        return RoutineSessionDraft(config: persistedConfig)
    }

    private func resolvedCaptureConfigForRecording(now: Date = Date()) -> CaptureSessionConfig {
        var config = routineSessionSetup.config
        if config.performerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            config.performerName = "Unknown Performer"
        }
        if config.scratchType == nil {
            config.scratchType = .unknown
        }
        if config.captureMode == .timedClick, config.bpm == nil {
            config.bpm = CaptureClickTrackDefaults.defaultTimedBPM
        }
        config.updatedAt = now
        return config
    }

    private func acceptReviewLabel() {
        guard hasRecordedTake else { return }
        let acceptedLabel: ReviewCorrection
        switch captureEngine.lastScratchDetection?.scratchName.lowercased() {
        case .some(let label) where label.contains("baby"):
            acceptedLabel = .babyScratch
        case .some(let label) where label.contains("chirp"):
            acceptedLabel = .chirp
        case .some(let label) where label.contains("transform"):
            acceptedLabel = .transform
        case .some(let label) where label.contains("flare"):
            acceptedLabel = .flare
        default:
            acceptedLabel = .unknown
        }
        guard persistReviewDecision(acceptedLabel, status: .accepted) else { return }
        reviewStatusMessage = "Accepted \(acceptedLabel.rawValue) for \(reviewTakeID)."
    }

    private func correctReviewLabel() {
        guard hasRecordedTake else { return }
        guard persistReviewDecision(reviewCorrectionSelection, status: .corrected) else { return }
        reviewStatusMessage = "Corrected \(reviewTakeID) to \(reviewCorrectionSelection.rawValue)."
    }

    private func leaveReviewLabelUnknown() {
        guard hasRecordedTake else { return }
        guard persistReviewDecision(.unknown, status: .unknown) else { return }
        reviewStatusMessage = "Left \(reviewTakeID) as unknown."
    }

    @discardableResult
    private func persistReviewDecision(
        _ decision: ReviewCorrection,
        status: CaptureCore.CaptureReviewDecision.Status
    ) -> Bool {
        guard let mediaURL = captureEngine.lastRoutineRecordingURL else {
            reviewStatusMessage = "No recorded take is ready for review."
            return false
        }

        let sidecarURL = CaptureCore.LocalRecordingFiles.sidecarURL(forMediaURL: mediaURL)
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let sidecar = try decoder.decode(
                CaptureCore.LocalRecordingSidecar.self,
                from: Data(contentsOf: sidecarURL)
            )
            let updatedSidecar = sidecar.reviewed(
                status: status,
                label: decision.rawValue,
                detectedLabel: captureEngine.lastScratchDetection?.scratchName,
                confidence: captureEngine.lastScratchDetection?.confidence
            )
            try updatedSidecar.encodedData().write(to: sidecarURL, options: .atomic)
            reviewDecisionByTakeID[reviewTakeID] = decision
            return true
        } catch {
            reviewStatusMessage = "Could not save review for \(reviewTakeID): \(error.localizedDescription)"
            return false
        }
    }

    private func startMacLiveInput() {
        liveInputEnabled = true
        demoModeController.stopDemo()
        captureEngine.start()
        if stageLayout == .desktopDeck {
            captureEngine.preferMacCameraForDesktopDeck()
        }
    }

    private func startMacDemo() {
        if demoModeController.isReady {
            demoModeController.replayDemo()
        } else {
            demoModeController.startDemo()
        }
    }

    private func exportMacDemoSession() {
        guard !isBuildingDemoExportPackage, !sessionExportCoordinator.isPreparing else { return }
        isBuildingDemoExportPackage = true

        Task {
            do {
                let package = try await Task.detached(priority: .userInitiated) {
                    try ScratchLabDemoSessionBuilder().makePackage()
                }.value
                isBuildingDemoExportPackage = false
                sessionExportCoordinator.prepareShare(
                    for: .package(package),
                    options: SessionExportOptions(mixMode: .scratchOnly)
                )
            } catch {
                isBuildingDemoExportPackage = false
                sessionExportCoordinator.showFailure(.unableToPrepareExport)
            }
        }
    }

    private func shareLastRoutineSession() {
        guard let lastRoutineRecordingURL = captureEngine.lastRoutineRecordingURL else {
            sessionExportCoordinator.showFailure(.sessionFolderNotFound)
            return
        }
        sessionExportCoordinator.prepareShare(
            for: .localRecordingSession(
                lastRecordingURL: lastRoutineRecordingURL,
                sessionName: routineSessionSetup.sessionName(defaultAppName: "Untitled Session"),
                config: routineSessionSetup.config
            ),
            options: SessionExportOptions(mixMode: exportMixMode)
        )
    }

    private func saveLastRoutineSessionArchive() {
        guard let lastRoutineRecordingURL = captureEngine.lastRoutineRecordingURL else {
            sessionExportCoordinator.showFailure(.sessionFolderNotFound)
            return
        }
        sessionExportCoordinator.saveArchiveCopy(
            for: .localRecordingSession(
                lastRecordingURL: lastRoutineRecordingURL,
                sessionName: routineSessionSetup.sessionName(defaultAppName: "Untitled Session"),
                config: routineSessionSetup.config
            ),
            options: SessionExportOptions(mixMode: exportMixMode)
        )
    }

    private func uploadLastRoutineSession() {
        guard sessionUploadManager.isUploadAvailable else {
            captureEngine.reportRoutineRecordingIssue(
                sessionUploadManager.availabilityMessage ?? "Upload isn't available right now."
            )
            return
        }
        guard let lastRoutineRecordingURL = captureEngine.lastRoutineRecordingURL else {
            captureEngine.reportRoutineRecordingIssue("Record a routine first so ScratchLab has a session folder to upload.")
            return
        }
        sessionUploadManager.startUpload(
            for: .localRecordingSession(
                lastRecordingURL: lastRoutineRecordingURL,
                sessionName: routineSessionSetup.sessionName(defaultAppName: "Untitled Session"),
                config: routineSessionSetup.config
            )
        )
    }

    private func cameraStageCard<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)

                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
            }

            content()
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var captureEmptyStateStage: some View {
        cameraStageCard(
            title: "Capture Session",
            subtitle: "Create a session before you start a scratch capture."
        ) {
            VStack(spacing: 16) {
                Spacer()

                VStack(spacing: 10) {
                    Text("Create your first session")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundColor(.white)

                    Text("Name the session, choose a target, then record the first take.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.74))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }

                Button("New Session", action: createNewSessionAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(captureEngine.isRoutineRecording)

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white.opacity(0.03))
        }
    }

    private var advancedHeaderCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Advanced")
                        .font(.system(size: 28, weight: .semibold))

                    Text("ScratchLab")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    Button("New session", action: createNewSessionAction)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(captureEngine.isRoutineRecording)

                    Button("Open Performer Monitor") {
                        openWindow(id: "performer-monitor")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Text("Diagnostics, calibration, and notation tools.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                headerStatusPill(
                    title: "Audio",
                    value: captureEngine.selectedAudioDeviceUniqueID.isEmpty ? "Not connected" : "Ready",
                    color: captureEngine.selectedAudioDeviceUniqueID.isEmpty ? .secondary : .green
                )
                headerStatusPill(
                    title: "Device",
                    value: companionReceiver.connectedPeerNames.isEmpty ? "Searching…" : "Connected",
                    color: companionReceiver.connectedPeerNames.isEmpty ? .secondary : .green
                )
                headerStatusPill(
                    title: "Monitor",
                    value: performerBroadcaster.connectedPeerNames.isEmpty ? "Searching…" : "Connected",
                    color: performerBroadcaster.connectedPeerNames.isEmpty ? .secondary : .green
                )
            }

            Label(captureEngine.statusMessage, systemImage: captureEngine.statusIcon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(captureEngine.statusColor)

            Label(performerBroadcaster.connectionStatus, systemImage: performerBroadcaster.connectedPeerNames.isEmpty ? "ipad.landscape" : "dot.radiowaves.left.and.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(performerBroadcaster.connectedPeerNames.isEmpty ? Color.secondary : Color.green)

            DisclosureGroup("Connect manually") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Use this only if nearby discovery doesn't find ScratchLab.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text(performerBroadcaster.manualConnectAddress)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
            .font(.system(size: 12, weight: .semibold))

            Text("Open Performer Monitor and send that window to an external display, or run ScratchLab on a second device and tap Performer Monitor there.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var advancedToolsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Tools")
                .font(.headline)

            Text("Notation lab, input diagnostics, MIDI mapping, deck calibration, export manifest, raw sidecar inspection, watch motion, and timing checks.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Notation lab") {
                    babyScratchDemo.configureBabyScratchIfNeeded()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                #if DEBUG
                Button("Inspect raw sidecar") {
                    rawJSONInspector.openForCurrentSelection(selectedRawJSONURL)
                    isShowingRawJSONInspector = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                #endif
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var performanceDiagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Performance")
                .font(.headline)

            // Layer 1 — friendly status pills always visible.
            VStack(spacing: 8) {
                diagnosticRow(title: "Playback", value: friendlyPlaybackState)
                diagnosticRow(title: "Capture", value: (captureEngine.isRoutineRecording || captureEngine.cxlIsRecording) ? "Recording" : "Idle")
                diagnosticRow(title: "Camera", value: diagnosticsCameraValue)
                diagnosticRow(title: "Audio", value: captureEngine.selectedAudioDeviceName)
                diagnosticRow(title: "Signal", value: captureEngine.audioSignalStatusText)
                if let lastRoutineAudioWriterError = captureEngine.lastRoutineAudioWriterError,
                   !lastRoutineAudioWriterError.isEmpty {
                    diagnosticRow(title: "Last audio writer error", value: lastRoutineAudioWriterError)
                }
            }

            // Layer 2 — raw counters / timings / booleans tucked behind a
            // disclosure so the default view doesn't read like a print() log.
            DisclosureGroup {
                VStack(spacing: 8) {
                    diagnosticRow(title: "Audio time", value: String(format: "%.3fs", babyScratchDemo.currentAudioTime))
                    diagnosticRow(title: "Notation playing", value: babyScratchDemo.playbackState == .playing ? "true" : "false")
                    diagnosticRow(title: "Coach playing", value: babyScratchDemo.isPlaying ? "true" : "false")
                    diagnosticRow(title: "Recording", value: (captureEngine.isRoutineRecording || captureEngine.cxlIsRecording) ? "true" : "false")
                    diagnosticRow(
                        title: "Raw audio buffers",
                        value: "\(captureEngine.routineAudioBuffersAppended)/\(captureEngine.routineAudioBuffersReceived) appended"
                    )
                    diagnosticRow(title: "Audio buffers skipped", value: "\(captureEngine.routineAudioBuffersSkipped)")
                    #if DEBUG
                    if let movementDiagnostics = captureEngine.routineMovementDiagnostics {
                        diagnosticRow(
                            title: "Movement pipeline",
                            value: "\(movementDiagnostics.finalRecordMovementEvents) final / \(movementDiagnostics.trustedDirectionalEvents) trusted / \(movementDiagnostics.fusedMovementEvents) fused / \(movementDiagnostics.normalizedMovementEvents) normalized / \(movementDiagnostics.rawMovementEventsCreated) raw"
                        )
                        diagnosticRow(
                            title: "Movement samples",
                            value: "\(movementDiagnostics.observationsWithConfidence)/\(movementDiagnostics.handObservationsReceived) confident, \(movementDiagnostics.builderSamplesReceived) builder"
                        )
                        diagnosticRow(
                            title: "Movement directions",
                            value: "\(movementDiagnostics.semanticDirectionChanges) semantic / \(movementDiagnostics.rawDirectionChanges) raw"
                        )
                        diagnosticRow(
                            title: "Video frames",
                            value: "\(movementDiagnostics.framesAnalyzed)/\(movementDiagnostics.framesReceived) analyzed @ \(movementDiagnostics.handPoseIntervalMS)ms"
                        )
                        diagnosticRow(
                            title: "Movement drops",
                            value: "raw[\(MacCaptureEngine.summarizeDebugCounters(movementDiagnostics.rawDropReasons))] norm[\(MacCaptureEngine.summarizeDebugCounters(movementDiagnostics.normalizedDropReasons))] trust[\(MacCaptureEngine.summarizeDebugCounters(movementDiagnostics.trustDropReasons))]"
                        )
                    }
                    #endif
                    diagnosticRow(title: "Last notation tick", value: String(format: "%.2fms", runtimeDiagnostics.notationLastTickDurationMS))
                    diagnosticRow(title: "Approx tick rate", value: diagnosticsTickRateValue)
                    diagnosticRow(title: "Last coach update", value: String(format: "%.2fms", runtimeDiagnostics.coachLastUpdateDurationMS))
                }
                .padding(.top, 8)
            } label: {
                Label("Show technical details", systemImage: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var friendlyPlaybackState: String {
        switch babyScratchDemo.playbackState {
        case .playing:           return "Playing"
        case .paused:            return "Paused"
        case .stopped:           return "Idle"
        default:                 return "Idle"
        }
    }

    private func diagnosticRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private func artifactStatusBadge(_ status: TakeArtifactStatusSnapshot) -> some View {
        let color: Color
        switch status.readiness {
        case .ready:
            color = .green
        case .recording, .finalizing:
            color = .orange
        case .missingAudio, .missingVideo, .failed:
            color = .red
        }

        return Text(status.readiness.badgeTitle)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
    }

    private var routineSessionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Recent sessions")
                    .font(.headline)

                Spacer()

                if hasRoutineSessions {
                    Button("New Session", action: createNewSessionAction)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(captureEngine.isRoutineRecording)
                }
            }

            if hasRoutineSessions {
                VStack(alignment: .leading, spacing: 8) {
                    if routineSessionPresentation.recentSessions.isEmpty {
                        Text("No recent sessions beyond the active session.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(routineSessionPresentation.recentSessions) { session in
                            routineSessionButton(session)
                        }
                    }
                }

                DisclosureGroup("Show all sessions", isExpanded: $isShowingAllRoutineSessions) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(routineSessionPresentation.allSessions) { session in
                            routineSessionButton(session)
                        }
                    }
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.top, 4)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Create your first session")
                        .font(.system(size: 16, weight: .semibold))

                    Text("Start a scratch practice capture, add details, then export your session.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button("New Session", action: createNewSessionAction)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(captureEngine.isRoutineRecording)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func activeRoutineSessionCard(
        _ session: SessionListPresentationModel<RoutineSessionDraft>.Entry
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Active session")
                .font(.headline)

            Button {
                routineSessionStore.openSession(id: session.id)
            } label: {
                RoutineSessionRow(
                    title: routineSessionTitle(for: session.session),
                    subtitle: routineSessionSubtitle(for: session.session),
                    detail: nil,
                    copyableID: session.id,
                    isSelected: routineSessionStore.selectedSessionID == session.id
                )
            }
            .buttonStyle(.plain)
            .disabled(captureEngine.isRoutineRecording)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func routineSessionButton(
        _ session: SessionListPresentationModel<RoutineSessionDraft>.Entry
    ) -> some View {
        Button {
            routineSessionStore.openSession(id: session.id)
        } label: {
            RoutineSessionRow(
                title: routineSessionTitle(for: session.session),
                subtitle: routineSessionSubtitle(for: session.session),
                detail: nil,
                copyableID: session.id,
                isSelected: routineSessionStore.selectedSessionID == session.id
            )
        }
        .buttonStyle(.plain)
        .disabled(captureEngine.isRoutineRecording)
    }

    private var captureSessionWorkflowCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Capture")
                        .font(.system(size: 28, weight: .semibold))

                    Text("Record clean takes for review and export.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Button("New Session", action: createNewSessionAction)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(captureEngine.isRoutineRecording)
            }

            if selectedRoutineSession == nil {
                Text("Press Record to create an Untitled Session automatically. ScratchLab will keep audio, video, watch, timing, detection, and export data attached to the same session ID.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("New Session", action: createNewSessionAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(captureEngine.isRoutineRecording)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Audio source")
                        .font(.system(size: 13, weight: .semibold))

                    Picker("Source", selection: selectedAudioDeviceBinding) {
                        if captureEngine.availableAudioDevices.isEmpty {
                            Text("No audio inputs found").tag("")
                        } else {
                            ForEach(captureEngine.availableAudioDevices, id: \.uniqueID) { device in
                                Text(device.localizedName).tag(device.uniqueID)
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(captureEngine.isRoutineRecording || routineCountInBeat != nil)

                    Text(captureEngine.selectedAudioDeviceStatusLine)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if captureEngine.shouldOfferUseSeratoAudio {
                        Button("Use Serato Audio") {
                            captureEngine.usePreferredSeratoAudio()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(captureEngine.isRoutineRecording || routineCountInBeat != nil)
                    }
                }

                TextField("Session name", text: routinePerformerBinding)
                    .textFieldStyle(.roundedBorder)
                    .disabled(captureEngine.isRoutineRecording)

                Picker("Target", selection: captureTargetBinding) {
                    ForEach(CaptureTarget.allCases) { target in
                        Text(target.title).tag(target)
                    }
                }
                .pickerStyle(.menu)
                .disabled(captureEngine.isRoutineRecording)

                Picker("Mode", selection: captureTimingModeBinding) {
                    ForEach(CaptureTimingMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(captureEngine.isRoutineRecording)

                if selectedCaptureTimingMode == .click || selectedCaptureTimingMode == .beat {
                    RoutineTempoEditor(
                        bpmText: routineBPMTextBinding,
                        presetBPMs: routineSessionSetup.allowedBPMList
                    )
                    .disabled(captureEngine.isRoutineRecording)
                }

                Label(Self.friendlyStatusMessage(captureEngine.routineRecordingStatus), systemImage: captureEngine.isRoutineRecording ? "record.circle.fill" : "film.stack.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(captureEngine.isRoutineRecording ? Color(nsColor: .systemRed) : .secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let routineMetadataStatusMessage {
                    Label(routineMetadataStatusMessage, systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    handleMainCaptureAction()
                } label: {
                    Label(mainCaptureButtonTitle, systemImage: captureEngine.isRoutineRecording ? "stop.fill" : "record.circle")
                        .font(.system(size: 18, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(captureEngine.isRoutineRecording ? Color(nsColor: .systemRed) : Color(nsColor: .systemGreen))
                .disabled(routineCountInBeat != nil)

                // After a take exists, Review this take is the dominant
                // next step. Save Take / Retake demote to small bordered
                // utilities; Export Session lives in Review when ready.
                if hasRecordedTake {
                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            workspaceTab = .review
                        } label: {
                            Label("Review this take", systemImage: "checkmark.seal")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(captureEngine.isRoutineRecording)

                        HStack(spacing: 8) {
                            Button("Save Take") {
                                markLastTakeSaved()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(captureEngine.isRoutineRecording)

                            Button("Record another") {
                                prepareRetake()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(captureEngine.isRoutineRecording)

                            Spacer(minLength: 0)

                            Button("Discard") {
                                prepareRetake()
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .foregroundStyle(Color(nsColor: .systemRed))
                            .disabled(captureEngine.isRoutineRecording)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var captureInputStatusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Inputs")
                .font(.headline)

            LazyVGrid(columns: Self.practiceBeatModeColumns, spacing: 10) {
                captureInputStatusTile(
                    title: "Audio",
                    value: captureEngine.audioReadinessText,
                    detail: captureEngine.selectedAudioDeviceStatusLine,
                    systemImage: selectedAudioDevice == nil ? "waveform.slash" : "waveform",
                    color: selectedAudioDevice == nil ? .secondary : .green
                )
                captureInputStatusTile(
                    title: "Camera",
                    value: captureEngine.selectedVideoDeviceUniqueID.isEmpty ? "Missing" : "Camera Ready",
                    detail: captureEngine.selectedVideoDeviceName,
                    systemImage: captureEngine.selectedVideoDeviceUniqueID.isEmpty ? "video.slash.fill" : "video.fill",
                    color: captureEngine.selectedVideoDeviceUniqueID.isEmpty ? .secondary : .green
                )
                captureInputStatusTile(
                    title: "Mixer MIDI",
                    value: mixerStatusValue,
                    detail: mixerStatusDetail,
                    systemImage: "slider.horizontal.3",
                    color: mixerStatusColor
                )
                captureInputStatusTile(
                    title: "Watch",
                    value: watchStatusValue,
                    detail: watchStatusDetail,
                    systemImage: "applewatch",
                    color: relayedWatchCaptureStore.importedSessions.isEmpty ? .secondary : .green
                )
            }

            midiSourcePickerRow
            midiLearnRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var midiMonitorCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("MIDI Monitor")
                    .font(.headline)
                Spacer()
                Button("Refresh MIDI") {
                    captureEngine.refreshMIDISources()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            midiSourcePickerRow

            HStack(spacing: 8) {
                testLabMetricBadge(title: "State", value: captureEngine.midiListeningState, color: captureEngine.availableMIDISources.isEmpty ? .secondary : .green)
                testLabMetricBadge(title: "Events received", value: "\(captureEngine.midiEventsReceivedCount)", color: captureEngine.midiEventsReceivedCount == 0 ? .secondary : .green)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Last MIDI message")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(captureEngine.lastMIDIEventSummary)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                Text(captureEngine.lastMIDICCMessage)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(captureEngine.midiCrossfaderMappingStatus)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            midiLearnRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var captureLatestTakeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Last Take")
                .font(.headline)

            HStack(spacing: 8) {
                testLabMetricBadge(title: "Takes", value: "\(visibleTakeCount)", color: visibleTakeCount == 0 ? .secondary : .green)
                testLabMetricBadge(title: "Detected", value: reviewDetectedScratchLabel, color: captureEngine.lastScratchDetection == nil ? .secondary : .green)
                testLabMetricBadge(title: "Confidence", value: reviewConfidenceLabel, color: reviewConfidenceColor)
            }

            HStack(spacing: 8) {
                testLabMetricBadge(title: "Strokes", value: "\(captureEngine.scratchDetectionCount)", color: captureEngine.scratchDetectionCount == 0 ? .secondary : .green)
                testLabMetricBadge(title: "Fader events", value: "\(captureEngine.cxlEventCount)", color: captureEngine.cxlEventCount == 0 ? .secondary : .green)
            }

            if captureEngine.lastRoutineRecordingURL != nil {
                Text(lastRoutineTakeDisplayName)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Record a take to see the detected label, confidence, stroke count, fader events, and review actions.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var captureSessionListCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sessions")
                .font(.headline)

            if let activeSession = routineSessionPresentation.activeSession {
                routineSessionButton(activeSession)
            } else {
                Text("No capture session yet.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if !routineSessionPresentation.recentSessions.isEmpty {
                ForEach(routineSessionPresentation.recentSessions.prefix(2)) { session in
                    routineSessionButton(session)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var captureWorkflowSummaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Capture Workflow")
                .font(.headline)

            Text("1. Leave the session blank or name it now.\n2. Choose Auto Detect or the intended scratch.\n3. Choose No Beat, Click, Beat, or Calibration.\n4. Confirm Audio and Camera are ready.\n5. Record, stop, save the take, then review or export.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var reviewHeaderCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Review")
                .font(.system(size: 28, weight: .semibold))

            Text("Confirm the detected scratch type, or correct it before export. Audio and video stay untouched.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)

            Label(reviewStatusMessage, systemImage: "checkmark.seal.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var reviewSessionListCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Session / Take List")
                .font(.headline)

            if let activeSession = routineSessionPresentation.activeSession {
                routineSessionButton(activeSession)
            } else {
                Text("No session selected.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if !captureEngine.routineTakeArtifactStatuses.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(captureEngine.routineTakeArtifactStatuses) { status in
                        HStack(spacing: 10) {
                            Text("Take \(String(format: "%03d", status.takeNumber))")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))

                            if let bpm = status.bpm {
                                Text("\(bpm) BPM")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 8)
                            artifactStatusBadge(status)
                        }
                    }
                }
            } else if captureEngine.lastRoutineRecordingURL != nil {
                Label(lastRoutineTakeDisplayName, systemImage: "film.stack.fill")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Record a take in Capture to populate this list.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var reviewTakeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Take detail")
                .font(.headline)

            if hasRecordedTake {
                if let currentRoutineArtifactStatus {
                    HStack(spacing: 8) {
                        artifactStatusBadge(currentRoutineArtifactStatus)
                        Text(reviewArtifactStatusSummary)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 8) {
                    testLabMetricBadge(title: "Detected", value: reviewDetectedScratchLabel, color: (currentRoutineArtifactStatus?.detectedLabel ?? captureEngine.lastScratchDetection?.scratchName) == nil ? .secondary : .green)
                    testLabMetricBadge(title: "Confidence", value: reviewConfidenceLabel, color: reviewConfidenceColor)
                }

                // Zero-counter grid was reading like a debug dashboard.
                // Tucked behind a disclosure so it's available but not
                // dominant when every value is zero.
                DisclosureGroup {
                    HStack(spacing: 8) {
                        testLabMetricBadge(title: "Stroke count", value: "\(reviewStrokeCount)", color: reviewStrokeCount == 0 ? .secondary : .green)
                        testLabMetricBadge(title: "Audio event count", value: "\(reviewAudioEventCount)", color: reviewAudioEventCount == 0 ? .secondary : .green)
                        testLabMetricBadge(title: "Mixer MIDI count", value: "\(reviewMixerMIDIEventCount)", color: reviewMixerMIDIEventCount == 0 ? .secondary : .green)
                        testLabMetricBadge(title: "Fader event count", value: "\(reviewFaderEventCount)", color: reviewFaderEventCount == 0 ? .secondary : .green)
                    }
                    .padding(.top, 8)
                } label: {
                    Label("Show technical details", systemImage: "slider.horizontal.3")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                if hasReviewNotationPreview {
                    miniNotationTimeline
                } else {
                    Label(reviewNotationAvailabilityMessage, systemImage: hasPartialReviewNotation ? "waveform.path.badge.plus" : "waveform.path.ecg")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if currentRoutineNotationSnapshot != nil {
                    Button {
                        capturedNotationSnapshot = currentRoutineNotationSnapshot
                        workspaceTab = .advanced
                    } label: {
                        Label("View captured notation", systemImage: "waveform.path")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                }

                Picker("Correct Label", selection: $reviewCorrectionSelection) {
                    ForEach(ReviewCorrection.allCases) { correction in
                        Text(correction.rawValue).tag(correction)
                    }
                }
                .pickerStyle(.menu)

                HStack(spacing: 8) {
                    Button("Accept") {
                        acceptReviewLabel()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)

                    Button("Correct label") {
                        correctReviewLabel()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Leave unknown") {
                        leaveReviewLabelUnknown()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)

                    if currentRoutineArtifactStatus?.readiness != .ready {
                        Spacer(minLength: 0)
                        Button("Retake") {
                            prepareRetake()
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .foregroundStyle(Color(nsColor: .systemRed))
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No take to review yet")
                        .font(.system(size: 16, weight: .semibold))

                    Text("Record a take in Capture and it'll show up here.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var reviewExportCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export")
                .font(.headline)

            Text(sessionExportCoordinator.statusMessage ?? "Export a ZIP once you've reviewed the take.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    shareLastRoutineSession()
                } label: {
                    Label("Export ZIP", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(!hasRecordedTake || sessionExportCoordinator.isPreparing || captureEngine.isRoutineRecording)

                Spacer(minLength: 0)

                Button("Retake") {
                    prepareRetake()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(Color(nsColor: .systemRed))
                .disabled(!hasRecordedTake || captureEngine.isRoutineRecording)
            }

            if let lastExport = sessionExportCoordinator.lastResult {
                Text("\(lastExport.displayName) · \(lastExport.formattedArchiveSize)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var reviewStage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Review timeline")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)

                reviewTargetNotationStageCard
                reviewCapturedNotationStageCard
                reviewSummaryFooterCard
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color.black)
    }

    private var reviewTargetNotationStageCard: some View {
        let scratchType = routineSessionSetup.scratchType ?? .babyScratch
        let notation: ScratchNotation? = (scratchType == .babyScratch) ? ScratchNotation.babyScratch : nil
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Target notation")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                Text("Target: \(scratchType.title)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
            }
            Group {
                if let notation {
                    ScratchPhraseChartView(
                        source: .target(notation),
                        bpm: Double(routineSessionSetup.bpmValue ?? 90)
                    )
                    .frame(height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    Text("Target notation unavailable for this scratch type.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
                        .padding(12)
                        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            Text("Reference pattern. Stays visible even when no captured notation is available.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(16)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var reviewCapturedNotationStageCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Captured evidence")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                Text(reviewCapturedSourceLabel)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(reviewCapturedSourceColor)
            }
            if let snapshot = currentRoutineNotationSnapshot,
               snapshot.hasDetectedEvents {
                CapturedNotationDisplayView(snapshot: snapshot)
                    .frame(maxWidth: .infinity, minHeight: 320, maxHeight: 520)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if hasReviewNotationPreview {
                miniNotationTimeline
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No captured notation yet")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(reviewNotationAvailabilityMessage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var reviewSummaryFooterCard: some View {
        let scratchType = routineSessionSetup.scratchType ?? .babyScratch
        let detectedLabel: String = {
            if let label = currentRoutineArtifactStatus?.detectedLabel, !label.isEmpty {
                return label
            }
            if let label = captureEngine.lastScratchDetection?.scratchName, !label.isEmpty {
                return label
            }
            return "Pattern not confirmed"
        }()
        let confidence: String = reviewConfidenceLabel
        let source: String = reviewCapturedSourceLabel
        let exportReady: Bool = currentRoutineArtifactStatus?.readiness == .ready
        return HStack(alignment: .top, spacing: 12) {
            reviewFooterMetric(title: "Target", value: scratchType.title, color: .white)
            reviewFooterMetric(title: "Detected", value: detectedLabel, color: detectedLabel == "Pattern not confirmed" ? .secondary : .green)
            reviewFooterMetric(title: "Confidence", value: confidence, color: reviewConfidenceColor)
            reviewFooterMetric(title: "Source", value: source, color: reviewCapturedSourceColor)
            reviewFooterMetric(title: "Export", value: exportReady ? "Ready" : "Pending", color: exportReady ? .green : .secondary)
        }
        .padding(14)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func reviewFooterMetric(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var reviewCapturedSourceLabel: String {
        guard let snapshot = currentRoutineNotationSnapshot else { return "None" }
        if !snapshot.recordMovementEvents.isEmpty {
            return snapshot.notationSource == "detected" ? "Video movement" : "Movement recorded"
        }
        if !snapshot.faderEvents.isEmpty { return "Fader" }
        if !snapshot.audioEvents.isEmpty { return "Audio inferred" }
        if !snapshot.mixerMidiEvents.isEmpty { return "Raw MIDI unmapped" }
        return "None"
    }

    private var reviewCapturedSourceColor: Color {
        guard let snapshot = currentRoutineNotationSnapshot else { return .secondary }
        if !snapshot.recordMovementEvents.isEmpty {
            return snapshot.notationSource == "detected" ? .green : Color(red: 1.0, green: 0.72, blue: 0.10)
        }
        if !snapshot.faderEvents.isEmpty { return .green }
        if !snapshot.audioEvents.isEmpty { return Color(red: 1.0, green: 0.72, blue: 0.10) }
        return .secondary
    }

    private var practiceHeaderCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Practice")
                        .font(.system(size: 28, weight: .semibold))

                    Text("ScratchLab")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                    Button("Open Capture") {
                        workspaceTab = .capture
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            Text("Try the Baby Scratch demo, listen to the coach, and start a practice run.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                if liveInputEnabled {
                    headerStatusPill(
                        title: "Audio",
                        value: captureEngine.practiceAudioStatusText,
                        color: captureEngine.practiceAudioStatusColor
                    )
                } else {
                    headerStatusPill(
                        title: "Demo",
                        value: demoModeController.isReady ? "Replay ready" : "Demo",
                        color: .green
                    )
                }
                headerStatusPill(
                    title: "Matches",
                    value: "\(captureEngine.scratchDetectionCount)",
                    color: captureEngine.scratchDetectionCount == 0 ? .secondary : .green
                )
                headerStatusPill(
                    title: liveInputEnabled ? "Stars" : "Hardware",
                    value: liveInputEnabled ? "\(captureEngine.visibleStarCount)/5" : "Optional",
                    color: liveInputEnabled && captureEngine.visibleStarCount > 0 ? .green : .secondary
                )
            }

            Label(captureEngine.scratchStatusTitle, systemImage: captureEngine.scratchStatusIcon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(captureEngine.scratchStatusColor)

            Text("Record takes from the Capture tab.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var practiceControlCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Practice run")
                        .font(.headline)

                    Text(
                        isPracticeSessionActive
                            ? "This timed Baby Scratch run is live. Finish and save it to update your progress on Mac."
                            : "Time a Baby Scratch run and save it to your progress."
                    )
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                if isPracticeSessionActive {
                    Label("Live", systemImage: "record.circle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(nsColor: .systemRed))
                }
            }

            Picker("Duration", selection: practiceDurationBinding) {
                ForEach(PracticeDuration.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isPracticeSessionActive)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Practice beat")
                        .font(.system(size: 13, weight: .semibold))

                    Spacer()

                    Text(practiceBeatStore.isBeatEnabled ? "On" : "Off")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(practiceBeatStore.isBeatEnabled ? Color(nsColor: .systemGreen) : .secondary)
                }

                // No Beat / Beat On toggle uses the shared chip selection
                // style. Selected = accent (not yellow / green — those are
                // reserved for warning / health roles in the design system).
                HStack(spacing: 10) {
                    Chip(
                        isSelected: !practiceBeatStore.isBeatEnabled,
                        action: { practiceBeatStore.setBeatEnabled(false) }
                    ) {
                        Text("Off")
                            .frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("practice-beat-no-beat-button")

                    Chip(
                        isSelected: practiceBeatStore.isBeatEnabled,
                        action: { practiceBeatStore.setBeatEnabled(true) }
                    ) {
                        Text("On")
                            .frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("practice-beat-on-button")
                }

                if practiceBeatStore.isBeatEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Beat style")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)

                        // Beat-style picker uses the shared chip selection
                        // style. Selected = accent fill + accent border;
                        // checkmark glyph removed (selection is signified by
                        // the accent border alone, per design system).
                        LazyVGrid(columns: Self.practiceBeatModeColumns, spacing: 10) {
                            ForEach(practiceBeatStore.availableBeatModes) { mode in
                                Chip(
                                    isSelected: practiceBeatStore.selectedBeatMode == mode,
                                    action: { practiceBeatStore.selectBeatMode(mode) }
                                ) {
                                    Text(mode.title)
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .accessibilityIdentifier("practice-beat-mode-\(mode.rawValue)")
                            }
                        }
                    }
                } else {
                    Text("Beat off. Practise from live scratch audio only until you want timing guidance.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Button {
                            practiceBeatStore.stepBPM(by: -1)
                        } label: {
                            Image(systemName: "minus")
                                .font(.system(size: 13, weight: .bold))
                                .frame(width: 34, height: 34)
                                .background(
                                    Color(nsColor: .controlBackgroundColor),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        VStack(spacing: 2) {
                            Text("\(practiceBeatStore.bpmValue) BPM")
                                .font(.system(size: 18, weight: .bold, design: .monospaced))

                            Text("Range \(CaptureClickTrackDefaults.supportedBPMRange.lowerBound)-\(CaptureClickTrackDefaults.supportedBPMRange.upperBound)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            practiceBeatStore.stepBPM(by: 1)
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 13, weight: .bold))
                                .frame(width: 34, height: 34)
                                .background(
                                    Color(nsColor: .controlBackgroundColor),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                    }

                    HStack(spacing: 8) {
                        ForEach(practiceBeatStore.allowedBPMList, id: \.self) { bpm in
                            Chip(
                                isSelected: practiceBeatStore.bpmValue == bpm,
                                isNumeric: true,
                                action: { practiceBeatStore.setBPM(bpm) }
                            ) {
                                Text("\(bpm)")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }

                Button {
                    practiceBeatStore.togglePlayback()
                } label: {
                    Text(practiceBeatStore.isPlaying ? "Stop beat" : "Play beat")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            practiceBeatStore.isBeatEnabled
                                ? (practiceBeatStore.isPlaying
                                    ? Color(nsColor: .systemOrange)
                                    : Color(nsColor: .systemGreen))
                                : Color(nsColor: .disabledControlTextColor).opacity(0.25),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!practiceBeatStore.isBeatEnabled)
                .accessibilityIdentifier("practice-beat-playback-button")

                if let playbackErrorMessage = practiceBeatStore.playbackErrorMessage {
                    HStack(spacing: 8) {
                        Text(playbackErrorMessage)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color(nsColor: .systemOrange))
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Retry Beat") {
                            practiceBeatStore.retryPlayback()
                        }
                        .buttonStyle(.bordered)
                        .font(.system(size: 12, weight: .semibold))
                    }
                }
            }

            HStack(spacing: 8) {
                testLabMetricBadge(
                    title: "Timer",
                    value: formatPracticeTime(practiceTimeRemaining),
                    color: isPracticeSessionActive ? .white : .secondary
                )
                testLabMetricBadge(
                    title: "Score",
                    value: "\(practiceScore)",
                    color: practiceScore == 0 ? .secondary : .green
                )
                testLabMetricBadge(
                    title: "Hits",
                    value: "\(practiceDetectionCount)",
                    color: practiceDetectionCount == 0 ? .secondary : .green
                )
                testLabMetricBadge(
                    title: "Average",
                    value: "\(Int(practiceAverageAccuracy.rounded()))%",
                    color: practiceAverageAccuracy == 0 ? .secondary : .green
                )
            }

            if isPracticeSessionActive {
                Text(
                    "Best hit this run: \(Int(practiceBestAccuracy.rounded()))% · Best streak: \(practiceBestStreak)"
                )
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            }

            if isPracticeSessionActive, let detection = captureEngine.lastScratchDetection {
                Text(
                    detection.feedback.first
                        ?? "Latest match: \(Int(detection.accuracy))% accuracy at \(Int(detection.confidence))% confidence."
                )
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button(isPracticeSessionActive ? "Finish & save" : "Start practice") {
                    if isPracticeSessionActive {
                        finishPracticeSession(saveResult: true)
                    } else {
                        startPracticeSession()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                if isPracticeSessionActive {
                    Button("Cancel") {
                        cancelTestLabPracticeSession()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Divider()

            HStack(spacing: 8) {
                testLabMetricBadge(
                    title: "Best",
                    value: "\(Int((progressManager.babyScratchProgress?.bestAccuracy ?? 0).rounded()))%",
                    color: (progressManager.babyScratchProgress?.bestAccuracy ?? 0) == 0 ? .secondary : .green
                )
                testLabMetricBadge(
                    title: "Attempts",
                    value: "\(progressManager.babyScratchProgress?.practiceCount ?? 0)",
                    color: (progressManager.babyScratchProgress?.practiceCount ?? 0) == 0 ? .secondary : .green
                )
                testLabMetricBadge(
                    title: "Recent",
                    value: "\(Int((progressManager.babyScratchProgress?.averageAccuracy ?? 0).rounded()))%",
                    color: (progressManager.babyScratchProgress?.averageAccuracy ?? 0) == 0 ? .secondary : .green
                )
                testLabMetricBadge(
                    title: "Mastery",
                    value: progressManager.isScratchMastered("baby_scratch")
                        ? "Mastered"
                        : "\(Int((progressManager.babyScratchProgress?.progressToMastery ?? 0).rounded()))%",
                    color: progressManager.isScratchMastered("baby_scratch") ? .green : .secondary
                )
            }

            if let practiceLastSavedAt {
                Label(
                    "Saved \(Int(practiceLastSavedAccuracy.rounded()))% over \(formatPracticeTime(practiceLastSavedDuration)) at \(practiceLastSavedAt.formatted(date: .omitted, time: .shortened)).",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(nsColor: .systemGreen))
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No saved runs yet. Finish a practice run to start tracking.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func headerStatusPill(title: String, value: String, color: Color) -> some View {
        // Strip the title prefix from the value so we never render
        // "Audio · Audio Ready" — the design system requires "TITLE · STATE".
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            Text(Self.dedupedStatusValue(title: title, value: value))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// Drop the title token from the value when it appears as a prefix or
    /// echoes the title verbatim. Shared by every status pill / tile so the
    /// "Audio · Audio Ready" pattern can never reach the UI.
    static func dedupedStatusValue(title: String, value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "—" }
        let lowerTitle = title.lowercased()
        let lowerValue = trimmed.lowercased()
        if lowerValue == lowerTitle { return "—" }
        if lowerValue.hasPrefix(lowerTitle + " ") {
            return String(trimmed.dropFirst(title.count)).trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }

    private var stageModeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Stage Mode")
                .font(.headline)

            Picker("Layout", selection: stageLayoutBinding) {
                ForEach(StageLayout.allCases) { layout in
                    Text(layout.title).tag(layout)
                }
            }
            .pickerStyle(.segmented)

            Text(stageLayout == .desktopDeck
                 ? "Deck View gives the built-in camera the whole stage so you can aim it down at the decks and mixer."
                 : "Dual Cam keeps the companion angle available alongside the main analyzer camera.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Toggle(isOn: $captureEngine.manualRigGuideEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Manual rig fallback")
                        .font(.system(size: 12, weight: .semibold))

                    Text("Show deck and mixer boxes even when auto-detect misses the camera angle.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(captureEngine.calibrationLocked)

            Toggle(isOn: $captureEngine.useDJPerspective) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("DJ perspective deck labels")
                        .font(.system(size: 12, weight: .semibold))

                    Text(captureEngine.isUsingDeskViewCamera
                         ? "Desk View uses camera-side deck ordering automatically, so this only affects the other camera sources."
                         : "Swap left and right deck roles so the overlay matches the DJ's point of view instead of the camera's.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(captureEngine.calibrationLocked)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var seratoScreenCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Serato Screen")
                    .font(.headline)

                Spacer()

                HStack(spacing: 8) {
                    Button(seratoWindowMover.preferredDisplayButtonTitle) {
                        seratoWindowMover.moveSeratoToPreferredSecondaryDisplay()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button("Back to Main View") {
                        seratoWindowMover.moveSeratoToMainDisplay()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Text("Use this when the main screen is tilted down at the decks and you still want Serato DJ Pro visible on a connected display.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Text("The first move may trigger macOS Accessibility access so ScratchLab can reposition the Serato window for you.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Text(seratoWindowMover.statusMessage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(seratoWindowMover.statusColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var routineRecordingCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Routine Capture")
                    .font(.headline)

                Spacer()

                routineRecordingButton
            }

            Text("Record the current camera plus the selected routed audio feed into a routine take.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("Camera")
                    .font(.system(size: 13, weight: .semibold))

                Picker("Camera", selection: $captureEngine.selectedVideoDeviceUniqueID) {
                    if captureEngine.availableVideoDevices.isEmpty {
                        Text("No cameras found").tag("")
                    } else {
                        ForEach(captureEngine.availableVideoDevices, id: \.uniqueID) { device in
                            Text(device.localizedName).tag(device.uniqueID)
                        }
                    }
                }
                .pickerStyle(.menu)
                .disabled(captureEngine.isRoutineRecording || routineCountInBeat != nil)

                Text("Pick the camera Routine Capture should record before you start the take.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                if captureEngine.isUsingContinuityCamera || captureEngine.isUsingDeskViewCamera {
                    Label("If a device is already active as Continuity Camera or Desk View, it cannot also run Companion Camera at the same time.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if stageLayout == .desktopDeck && !captureEngine.isUsingMacCameraForDesktopDeck && !captureEngine.isUsingDeskViewCamera {
                    Button("Use Built-in Camera") {
                        captureEngine.preferMacCameraForDesktopDeck(force: true)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(captureEngine.isRoutineRecording || routineCountInBeat != nil)
                }

                Divider()

                Text("Session Setup")
                    .font(.system(size: 13, weight: .semibold))

                TextField("Performer name", text: routinePerformerBinding)
                    .textFieldStyle(.roundedBorder)

                Picker("Click track", selection: routineCaptureModeBinding) {
                    ForEach(CaptureSessionCaptureMode.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.menu)

                if routineSessionSetup.showsPracticeBeatSelector {
                    Picker("Practice beat", selection: routineBeatEngineModeBinding) {
                        ForEach(routineSessionSetup.availableBeatEngineModes) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Practice beat")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)

                        Text(BeatEngineMode.silent.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                }

                if routineSessionSetup.captureMode == .timedClick {
                    RoutineTempoEditor(
                        bpmText: routineBPMTextBinding,
                        presetBPMs: routineSessionSetup.allowedBPMList
                    )
                }

                Picker("Handedness", selection: routineHandednessBinding) {
                    ForEach(CaptureSessionHandedness.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.menu)

                Picker("Scratch Type", selection: routineScratchTypeBinding) {
                    Text("Choose scratch type").tag(Optional<CaptureSessionScratchType>.none)
                    ForEach(CaptureSessionScratchType.allCases, id: \.rawValue) { scratchType in
                        Text(scratchType.title).tag(Optional(scratchType))
                    }
                }
                .pickerStyle(.menu)

                Picker("Capture Mode", selection: routineDrillModeBinding) {
                    ForEach(CaptureSessionDrillMode.allCases) { drillMode in
                        Text(drillMode.title).tag(drillMode)
                    }
                }
                .pickerStyle(.menu)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Notes (optional)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)

                    TextField(
                        "Add a short note",
                        text: Binding(
                            get: { routineSessionSetup.notes },
                            set: { routineSessionSetup.notes = $0 }
                        ),
                        axis: .vertical
                    )
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...4)
                }

                if let routineMetadataStatusMessage {
                    Label(routineMetadataStatusMessage, systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Label(Self.friendlyStatusMessage(captureEngine.routineRecordingStatus), systemImage: captureEngine.isRoutineRecording ? "record.circle.fill" : "film.stack.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(captureEngine.isRoutineRecording ? Color(nsColor: .systemRed) : .secondary)
                .fixedSize(horizontal: false, vertical: true)

            if captureEngine.isRoutineRecording && routineSessionSetup.clickEnabled {
                Text("Click track on")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Label(selectedCameraName, systemImage: "video.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                Label(selectedAudioDeviceName, systemImage: "waveform")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selectedAudioLooksMic ? Color(nsColor: .systemOrange) : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let lastRoutineRecordingURL = captureEngine.lastRoutineRecordingURL {
                Text(Self.friendlyTakeLabel(from: lastRoutineRecordingURL))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Button("Show Last Recording in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([lastRoutineRecordingURL])
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if sessionUploadManager.isUploadAvailable || currentRoutineUploadJob != nil {
                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Upload Session")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)

                        Text(
                            currentRoutineUploadJob?.statusText
                                ?? (sessionUploadManager.isUploadAvailable
                                    ? "Ready to upload"
                                    : sessionUploadManager.availabilityMessage ?? "Upload isn't available right now.")
                        )
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                        if let currentRoutineUploadJob {
                            Text("Routine Capture · \(currentRoutineUploadJob.formattedFileSize)")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            if let progressFraction = currentRoutineUploadJob.progressFraction {
                                ProgressView(value: progressFraction)
                                    .controlSize(.small)
                            } else if currentRoutineUploadJob.state == .preparing || currentRoutineUploadJob.state == .requestingUploadURL {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }

                        Button(currentRoutineUploadJob?.state == .completed ? "Uploaded" : "Upload Session") {
                            uploadLastRoutineSession()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(
                            !sessionUploadManager.isUploadAvailable
                                || captureEngine.isRoutineRecording
                                || currentRoutineUploadJob?.state == .completed
                                || currentRoutineUploadJob?.state == .uploading
                                || currentRoutineUploadJob?.state == .requestingUploadURL
                                || currentRoutineUploadJob?.state == .preparing
                        )

                        if currentRoutineUploadJob?.canRetry == true,
                           let localSessionID = captureEngine.lastRoutineRecordingSessionID {
                            Button("Retry Upload") {
                                sessionUploadManager.retry(localSessionID: localSessionID)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }

                Button(sessionExportCoordinator.isPreparing ? "Saving..." : "Save ZIP...") {
                    saveLastRoutineSessionArchive()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(
                    captureEngine.isRoutineRecording
                        || sessionExportCoordinator.isPreparing
                )

                Divider()

                Text("Share Session")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(sessionExportCoordinator.statusMessage ?? "Export the current routine session as a ZIP archive.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                #if DEBUG
                Picker("Export mix", selection: $exportMixMode) {
                    ForEach(ExportMixMode.appReviewVisibleModes) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                #else
                HStack {
                    Text("Export mix")
                    Spacer()
                    Text(ExportMixMode.scratchOnly.title)
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12, weight: .semibold))
                .onAppear {
                    exportMixMode = .scratchOnly
                }
                #endif

                if let validationReport = sessionExportCoordinator.validationReport,
                   !validationReport.issues.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(validationReport.issues, id: \.self) { issue in
                            Text("• \(issue)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color(nsColor: .systemRed))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if let lastExport = sessionExportCoordinator.lastResult {
                    Text("\(lastExport.displayName) · \(lastExport.formattedArchiveSize)")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if let sizeWarning = sessionExportCoordinator.sizeWarning {
                    Text(sizeWarning)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if routineSessionSetup.timingPrintedToRecording.needsWarning {
                    Text("Timing may be present in this recording.")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(sessionExportCoordinator.isPreparing ? "Preparing..." : "Share Session") {
                    shareLastRoutineSession()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(sessionExportCoordinator.isPreparing || captureEngine.isRoutineRecording)

                #if DEBUG
                Button("Inspect Staging") {
                    isShowingStagingInspector = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                #endif

                if sessionExportCoordinator.lastResult != nil {
                    HStack(spacing: 10) {
                        Button("Reveal ZIP in Finder") {
                            sessionExportCoordinator.revealLastArchiveInFinder()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        #if DEBUG
                        Button("Copy Export Path") {
                            sessionExportCoordinator.copyLastArchivePath()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        #endif
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Watch Motion Relay")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(relayedWatchCaptureStore.lastImportStatus)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(relayedWatchCaptureStore.remoteControlState.statusText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let latestCapture = relayedWatchCaptureStore.importedSessions.first {
                    Text("Latest capture: \(Self.friendlyTakeLabel(from: latestCapture.fileURL))")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Button("Open Watch Capture Folder") {
                    NSWorkspace.shared.open(relayedWatchCaptureStore.captureDirectoryURL)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if let routineRecordingsFolderURL = captureEngine.routineRecordingsFolderURL {
                Button("Open Recordings Folder") {
                    NSWorkspace.shared.open(routineRecordingsFolderURL)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if selectedAudioLooksMic {
                Label("\"\(selectedAudioDeviceName)\" is still a mic path. Switch to a routed Serato or interface feed before you record a take.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private struct RoutineTempoEditor: View {
        @Binding var bpmText: String

        let presetBPMs: [Int]

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("Timed capture")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    ForEach(presetBPMs, id: \.self) { bpm in
                        Chip(
                            "\(bpm)",
                            isSelected: Int(bpmText) == bpm,
                            isNumeric: true,
                            action: { bpmText = String(bpm) }
                        )
                    }
                }

                TextField("Custom BPM · 60–140", text: $bpmText)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    @MainActor
    private func handleRoutineRecordingButton() async {
        practiceBeatStore.handleRecordingFlowStarted()

        if routineCountInBeat != nil {
            let cancelledTakeIdentity = captureEngine.cancelPendingRoutineReservation()
            beatEngine.stop()
            routineCountInBeat = nil
            companionReceiver.requestWatchCaptureStop(
                sessionID: cancelledTakeIdentity?.sessionID ?? routineSessionSetup.config.sessionID,
                takeID: cancelledTakeIdentity?.takeID
            )
            captureEngine.reportRoutineRecordingIssue("Count-in cancelled.")
            return
        }

        if !captureEngine.isRoutineRecording,
           let routineMetadataStatusMessage {
            captureEngine.reportRoutineRecordingIssue(routineMetadataStatusMessage)
            return
        }

        guard ensureCaptureSessionForRecording() != nil else {
            captureEngine.reportRoutineRecordingIssue("ScratchLab could not create a capture session.")
            return
        }

        let resolvedConfig = resolvedCaptureConfigForRecording()
        routineSessionSetup.applyPersistedConfig(resolvedConfig)
        captureEngine.recordingSessionConfig = resolvedConfig

        if captureEngine.isRoutineRecording {
            beatEngine.stop()
            companionReceiver.requestWatchCaptureStop(
                sessionID: routineSessionSetup.config.sessionID,
                takeID: nil
            )
            captureEngine.toggleRoutineRecording()
            return
        }

        do {
            let takeIdentity = try captureEngine.reserveNextRoutineTakeIdentity()
            let reply = await companionReceiver.requestWatchCaptureStart(
                sessionID: takeIdentity.sessionID,
                takeID: takeIdentity.takeID
            )
            captureEngine.applyPendingWatchReply(reply)
            if reply.syncState != .acknowledged {
                captureEngine.reportRoutineRecordingIssue(
                    reply.detail ?? "Watch motion did not acknowledge. Routine recording will continue in degraded mode."
                )
            }

            if routineSessionSetup.captureMode == .timedClick {
                var beatStartMetadata: BeatEngineStartMetadata?
                let startedBeat = try beatEngine.start(
                    mode: routineSessionSetup.beatEngineMode,
                    bpm: routineSessionSetup.bpmValue ?? CaptureClickTrackDefaults.defaultTimedBPM,
                    onCountInBeat: { beat in
                        Task { @MainActor in
                            routineCountInBeat = beat
                            captureEngine.reportRoutineRecordingIssue(
                                "Get ready. Count-in beat \(beat) of \(CaptureClickTrackDefaults.countInBeats)."
                            )
                        }
                    },
                    onRecordingStart: {
                        let captureTiming = CaptureTimingMetadata(
                            clickStartHostTime: beatStartMetadata?.clickStartHostTime,
                            recordingStartHostTime: beatStartMetadata?.recordingStartHostTime
                                ?? ScratchLabBeatEngine.currentHostTime()
                        )
                        Task { @MainActor in
                            routineCountInBeat = nil
                            captureEngine.recordingSessionConfig = routineSessionSetup.config
                            captureEngine.startRoutineRecording(captureTiming: captureTiming)
                        }
                    }
                )
                beatStartMetadata = startedBeat
                captureEngine.reportRoutineRecordingIssue("Get ready.")
                return
            }

            routineCountInBeat = nil
            captureEngine.startRoutineRecording(
                captureTiming: CaptureTimingMetadata(
                    clickStartHostTime: nil,
                    recordingStartHostTime: ScratchLabBeatEngine.currentHostTime()
                )
            )
        } catch {
            let cancelledTakeIdentity = captureEngine.cancelPendingRoutineReservation()
            beatEngine.stop()
            routineCountInBeat = nil
            companionReceiver.requestWatchCaptureStop(
                sessionID: cancelledTakeIdentity?.sessionID ?? routineSessionSetup.config.sessionID,
                takeID: cancelledTakeIdentity?.takeID
            )
            captureEngine.reportRoutineRecordingIssue(error.localizedDescription)
        }
    }

    private var audioCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Audio Input")
                .font(.headline)

            Picker("Source", selection: selectedAudioDeviceBinding) {
                if captureEngine.availableAudioDevices.isEmpty {
                    Text("No audio inputs found").tag("")
                } else {
                    ForEach(captureEngine.availableAudioDevices, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(device.uniqueID)
                    }
                }
            }
            .pickerStyle(.menu)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Signal")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(captureEngine.formattedAudioSignalPercent)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: Double(captureEngine.currentAudioSignalLevel))
                    .tint(captureEngine.audioMeterColor)

                Text(captureEngine.selectedAudioDeviceStatusLine)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text("ScratchLab works best when your deck audio is routed here.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Routing Setup")
                        .font(.subheadline.weight(.semibold))

                    Spacer()

                    Text(selectedAudioDeviceName)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if selectedAudioDevice != nil {
                    Label(audioRoutingStatusMessage, systemImage: audioRoutingStatusIcon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(audioRoutingStatusColor)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label("Choose the input that already carries your deck audio. BlackHole, Loopback, and hardware loopback all work here.", systemImage: "arrow.up.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 8) {
                    ForEach(AudioRoutingOption.allCases) { option in
                        AudioRoutingOptionRow(
                            title: option.title,
                            detail: option.detail,
                            icon: option.icon,
                            isActive: option.matches(deviceName: selectedAudioDeviceName)
                        )
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Direct Serato Capture")
                        .font(.subheadline.weight(.semibold))

                    Spacer()

                    if captureEngine.canUseDirectSeratoCapture && !captureEngine.isUsingDirectSeratoCapture {
                        Button("Use Direct Capture") {
                            captureEngine.useDirectSeratoCapture()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    } else {
                        Button("Check for Serato") {
                            captureEngine.refreshSeratoDirectCapture()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                Label(
                    captureEngine.directCaptureStatus,
                    systemImage: captureEngine.canUseDirectSeratoCapture ? "waveform.badge.magnifyingglass" : "app.connected.to.app.below.fill"
                )
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(captureEngine.canUseDirectSeratoCapture ? Color(nsColor: .systemGreen) : .secondary)
                .fixedSize(horizontal: false, vertical: true)

                Text("ScratchLab will use Serato Virtual Audio first when it is available, then fall back to Direct Capture when needed.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var practiceAudioCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Audio Input")
                .font(.headline)

            Picker("Source", selection: selectedAudioDeviceBinding) {
                if captureEngine.availableAudioDevices.isEmpty {
                    Text("No audio inputs found").tag("")
                } else {
                    ForEach(captureEngine.availableAudioDevices, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(device.uniqueID)
                    }
                }
            }
            .pickerStyle(.menu)
            .disabled(captureEngine.isRoutineRecording)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Signal")
                        .font(.subheadline.weight(.semibold))

                    Spacer()

                    Text(captureEngine.formattedAudioSignalPercent)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: Double(captureEngine.currentAudioSignalLevel))
                    .tint(captureEngine.audioMeterColor)

                Text(captureEngine.selectedAudioDeviceStatusLine)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)

                Text(selectedAudioLooksMic
                     ? "\"\(selectedAudioDeviceName)\" is still a mic path. For a cleaner rating run, switch to the routed DJ audio feed."
                     : "Keep the routed deck audio here so ScratchLab rates the performance from the same signal the DJ software is playing.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if captureEngine.canUseDirectSeratoCapture && !captureEngine.isUsingDirectSeratoCapture {
                Button("Use Direct Serato Capture") {
                    captureEngine.useDirectSeratoCapture()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(captureEngine.isRoutineRecording)
            }

            Label(captureEngine.directCaptureStatus, systemImage: captureEngine.canUseDirectSeratoCapture ? "waveform.badge.magnifyingglass" : "app.connected.to.app.below.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(captureEngine.canUseDirectSeratoCapture ? Color(nsColor: .systemGreen) : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var cameraCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Camera")
                .font(.headline)

            Picker("View", selection: $captureEngine.selectedVideoDeviceUniqueID) {
                if captureEngine.availableVideoDevices.isEmpty {
                    Text("No cameras found").tag("")
                } else {
                    ForEach(captureEngine.availableVideoDevices, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(device.uniqueID)
                    }
                }
            }
            .pickerStyle(.menu)

            Text(stageLayout == .desktopDeck
                 ? "Deck View is the single-camera workspace. Use the built-in camera here unless you intentionally want a different source."
                 : "If your device is active as an external camera, it should appear in this list automatically.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            if captureEngine.isUsingContinuityCamera || captureEngine.isUsingDeskViewCamera {
                Label("The same device cannot run ScratchLab Companion Camera while it is already being used as the main camera or Desk View.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .systemOrange))
            }

            if captureEngine.hasDeskViewCameraOption {
                Button("Use Desk View") {
                    captureEngine.preferDeskViewCamera(force: true)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if stageLayout == .desktopDeck && !captureEngine.isUsingMacCameraForDesktopDeck && !captureEngine.isUsingDeskViewCamera {
                Label("Deck View is still using \(selectedCameraName), not the built-in camera.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .systemOrange))

                Button("Use Built-in Camera") {
                    captureEngine.preferMacCameraForDesktopDeck(force: true)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var scratchCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Scratch Detection")
                .font(.headline)

            HStack(spacing: 10) {
                Image(systemName: captureEngine.scratchStatusIcon)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(captureEngine.scratchStatusColor)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text(captureEngine.scratchStatusTitle)
                        .font(.system(size: 14, weight: .bold))

                    Text(captureEngine.scratchStatusDetail)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            if let detection = captureEngine.lastScratchDetection {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Last match: \(detection.scratchName)")
                        .font(.system(size: 12, weight: .semibold))

                    Text("Accuracy \(Int(detection.accuracy))%  |  Confidence \(Int(detection.confidence))%")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)

                    if let firstFeedback = detection.feedback.first {
                        Text(firstFeedback)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Text("Scratch detection is tuned for Baby Scratch first. Audio drives the score, and camera framing supports the guide.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Divider()

            ScratchCoachCardContent(
                instruction: coachInstruction,
                demoStatusMessage: coachDemoStatusMessage,
                playbackTimeProvider: { babyScratchDemo.currentAudioTime },
                isPlayingProvider: { babyScratchDemo.isPlaying },
                animationStateProvider: { audioTime, _ in
                    let pose = BabyScratchDemoPlaybackCoordinator.coachPose(for: audioTime)
                    guard !babyScratchDemo.isStopped else { return .babyScratchOpen }
                    return BabyScratchDemoPlaybackCoordinator.coachAnimationState(for: pose)
                },
                theme: coachCardTheme
            ) {
                HStack(spacing: 10) {
                    coachDemoButton(
                        title: "Listen",
                        systemImage: "play.fill",
                        enabled: babyScratchDemo.isAudioAvailable && !coachDemoPlaybackBlocked,
                        action: babyScratchDemo.playBabyScratch
                    )

                    coachDemoButton(
                        title: "Pause",
                        systemImage: "pause.fill",
                        enabled: babyScratchDemo.isPlaying && !coachDemoPlaybackBlocked,
                        action: babyScratchDemo.pause
                    )

                    coachDemoButton(
                        title: "Replay",
                        systemImage: "gobackward",
                        enabled: babyScratchDemo.isAudioAvailable && !coachDemoPlaybackBlocked,
                        action: babyScratchDemo.replayBabyScratch
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func coachDemoButton(
        title: String,
        systemImage: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(enabled ? Color.black : .secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    enabled
                        ? Color(nsColor: .systemYellow)
                        : Color.white.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var deckCalibrationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Deck Calibration")
                    .font(.headline)

                Spacer()

                if captureEngine.practiceViewEnabled {
                    Button("Adjust Fit Again") {
                        captureEngine.practiceViewEnabled = false
                        captureEngine.calibrationLocked = false
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else if captureEngine.calibrationLocked {
                    Button("Unlock Fit") {
                        captureEngine.calibrationLocked = false
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button("Lock Fit") {
                        captureEngine.calibrationLocked = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                Button("Reset Fit") {
                    captureEngine.resetCalibration()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(captureEngine.practiceViewEnabled)
            }

            if captureEngine.isRoutineRecording || captureEngine.lastRoutineRecordingURL != nil {
                Text(captureEngine.routineRecordingStatus)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(captureEngine.isRoutineRecording ? Color(nsColor: .systemRed) : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            calibrationSlider(
                title: "Move Left / Right",
                value: $captureEngine.rigHorizontalOffset,
                range: captureEngine.calibrationOffsetRange,
                format: "%.2f"
            )

            calibrationSlider(
                title: "Move Up / Down",
                value: $captureEngine.rigVerticalOffset,
                range: captureEngine.calibrationOffsetRange,
                format: "%.2f"
            )

            calibrationSlider(
                title: "Rig Width",
                value: $captureEngine.rigWidthScale,
                range: captureEngine.calibrationScaleRange,
                format: "%.2f"
            )

            calibrationSlider(
                title: "Rig Height",
                value: $captureEngine.rigHeightScale,
                range: captureEngine.calibrationScaleRange,
                format: "%.2f"
            )

            calibrationSlider(
                title: "Mixer Width",
                value: $captureEngine.mixerWidthRatio,
                range: captureEngine.mixerWidthRange,
                format: "%.2f"
            )

            Text("The boxes stay fixed once they appear. Drag a deck or mixer box to position it, drag its corner handle to resize that zone, or use Reset Fit when you want a fresh starting layout. The sliders are still here for coarse nudges.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            if captureEngine.calibrationLocked && !captureEngine.practiceViewEnabled {
                Label("Layout locked. Press Space or use Start Recording when ready.", systemImage: "lock.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .systemGreen))
            }

            if captureEngine.practiceViewEnabled {
                Label("Practice view is live. The boxes are hidden, but the hit zones are still active.", systemImage: "gamecontroller.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            if captureEngine.isUsingManualRigGuide {
                Label("Deck position saved.", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .systemOrange))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var routineRecordingButton: some View {
        Button(routineStartButtonTitle) {
            Task {
                await handleRoutineRecordingButton()
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .tint(captureEngine.isRoutineRecording ? .red : nil)
        .keyboardShortcut(.space, modifiers: [])
        .disabled(routineStartDisabled)
    }

    private var handMotionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Baby Scratch Direction")
                    .font(.headline)

                Spacer()

                Button("Open Monitor View") {
                    openWindow(id: "performer-monitor")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            Text("Open the monitor here, then use Send to Device inside that window so Serato keeps the main screen.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                testLabMetricBadge(
                    title: "Direction",
                    value: captureEngine.babyScratchGuidanceTitle,
                    color: captureEngine.handMotionState.color
                )
                testLabMetricBadge(
                    title: "Conf",
                    value: captureEngine.coachConfidencePercent > 0 ? "\(captureEngine.coachConfidencePercent)%" : "—",
                    color: captureEngine.coachConfidencePercent > 0 ? .green : .secondary
                )
                testLabMetricBadge(
                    title: "Source",
                    value: captureEngine.coachSignalSource,
                    color: captureEngine.coachSignalSource == "Searching" ? .secondary : .green
                )
            }

            Text(captureEngine.babyScratchGuidanceCue)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(captureEngine.handMotionState.color)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(captureEngine.handMotionState.color.opacity(0.12), in: Capsule())

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: captureEngine.handMotionState.icon)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(captureEngine.handMotionState.color)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text(captureEngine.babyScratchGuidanceTitle)
                        .font(.system(size: 14, weight: .bold))

                    Text(captureEngine.babyScratchGuidanceDetail)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var companionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Companion Feed")
                .font(.headline)

            Text(companionReceiver.connectionStatus)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Text("ScratchLab discovers the iPhone relay link here. Keep the iPhone on the main ScratchLab menu for watch relay only, or open Companion Camera there when you also want the live deck video feed.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            if captureEngine.isUsingContinuityCamera || captureEngine.isUsingDeskViewCamera {
                Text("If this device is already your main camera or Desk View source, open Companion Camera on a different device or switch back to the built-in camera first.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if !companionReceiver.connectedPeerNames.isEmpty {
                if stageLayout == .desktopDeck {
                    Text("The iPhone relay is connected. Stay in Deck View for a single-camera routine, or switch to Dual Cam only if you want the live companion video feed visible too.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Button("Disconnect Companion Feed") {
                    companionReceiver.disconnect()
                }
                .buttonStyle(.bordered)
            } else if companionReceiver.discoveredPeers.isEmpty {
                Text("Open ScratchLab on the iPhone and keep it awake. For watch relay, the main menu is enough. For live deck video, open Companion Camera and switch it to Deck. ScratchLab will try to connect automatically when the device appears here.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(companionReceiver.discoveredPeers.count == 1
                         ? "ScratchLab will try to auto-connect to the only nearby iPhone. You can still connect manually below if needed."
                         : "Choose the nearby iPhone you want to use for watch relay or companion deck video.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)

                    ForEach(companionReceiver.discoveredPeers) { peer in
                        HStack {
                            Text(peer.name)
                                .font(.system(size: 12, weight: .semibold))

                            Spacer()

                            Button("Connect") {
                                companionReceiver.connect(to: peer)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var practiceFeedbackCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ability Rating")
                .font(.headline)

            HStack(spacing: 8) {
                testLabMetricBadge(
                    title: "Matches",
                    value: "\(captureEngine.scratchDetectionCount)",
                    color: captureEngine.scratchDetectionCount == 0 ? .secondary : .green
                )
                testLabMetricBadge(
                    title: "Stars",
                    value: "\(captureEngine.visibleStarCount)/5",
                    color: captureEngine.visibleStarCount == 0 ? .secondary : .green
                )
                testLabMetricBadge(
                    title: "Conf",
                    value: captureEngine.coachConfidencePercent > 0 ? "\(captureEngine.coachConfidencePercent)%" : "—",
                    color: captureEngine.coachConfidencePercent > 0 ? .green : .secondary
                )
            }

            HStack(spacing: 8) {
                testLabMetricBadge(
                    title: "Direction",
                    value: captureEngine.babyScratchGuidanceTitle,
                    color: captureEngine.handMotionState.color
                )
                testLabMetricBadge(
                    title: "Source",
                    value: captureEngine.coachSignalSource,
                    color: captureEngine.coachSignalSource == "Searching" ? .secondary : .green
                )
            }

            Text(captureEngine.babyScratchGuidanceCue)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(captureEngine.handMotionState.color)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(captureEngine.handMotionState.color.opacity(0.12), in: Capsule())

            Text(captureEngine.babyScratchGuidanceDetail)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let detection = captureEngine.lastScratchDetection {
                Label(
                    "Latest read: \(detection.scratchName) at \(Int(detection.accuracy))% accuracy and \(Int(detection.confidence))% confidence.",
                    systemImage: "checkmark.seal.fill"
                )
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(nsColor: .systemGreen))
                .fixedSize(horizontal: false, vertical: true)

                if let firstFeedback = detection.feedback.first {
                    Text(firstFeedback)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Label("Start playback, show the scratch hand, and ask for one clean baby scratch to create the first rating sample.", systemImage: "ear.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var workflowCard: some View {
        // Permanent step-by-step workflow used to dominate the Advanced
        // sidebar in screenshots. Tucked behind a "First time setting up?"
        // disclosure so it stays available without burning into App Store
        // screenshots.
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup {
                Text(stageLayout == .desktopDeck
                     ? "1. Put the built-in camera above or in front of the decks.\n2. Route your DJ app into a virtual audio device.\n3. Adjust Deck Calibration until the boxes line up with the rig.\n4. Start a routine recording when the view and audio are ready.\n5. If your DJ app feels crowded, open Performer Monitor and move it to a second display."
                     : "1. Route your DJ app into a virtual audio device.\n2. Pick that device here for clean audio.\n3. Bring a companion device into Dual Cam if you want the extra angle.\n4. Start a routine recording when the take is framed.\n5. Open Performer Monitor if you want the feedback window off the main screen.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            } label: {
                Label("First time setting up?", systemImage: "info.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var previewPill: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(captureEngine.handMotionState.color)
                .frame(width: 10, height: 10)

            Text(captureEngine.babyScratchGuidanceCue)
                .font(.system(size: 13, weight: .bold))

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .frame(maxWidth: 260)
    }

    private var practiceWorkflowCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quick Workflow")
                .font(.headline)

            Text("1. Pick the routed deck input.\n2. Keep the scratch hand visible in frame.\n3. Ask for a clean Baby Scratch.\n4. Watch the match, stars, and cue to judge the rating.\n5. Open Routine Capture when you need the fuller setup or a saved take.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var cxlCaptureCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Advanced Capture Details")
                    .font(.headline)
                Spacer()
                Circle()
                    .fill(captureEngine.cxlIsRecording ? Color(nsColor: .systemRed) : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(captureEngine.cxlIsRecording ? "Recording" : "Idle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(captureEngine.cxlIsRecording ? Color(nsColor: .systemRed) : .secondary)
            }

            if captureEngine.cxlIsRecording {
                HStack(spacing: 8) {
                    testLabMetricBadge(
                        title: "Events",
                        value: "\(captureEngine.cxlEventCount)",
                        color: .green
                    )
                    testLabMetricBadge(
                        title: "Samples",
                        value: "\(captureEngine.cxlSampleCount)",
                        color: .green
                    )
                }

                Text(captureEngine.cxlSessionId)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let exportPath = captureEngine.cxlLastExportPath {
                Text("Last export: \(exportPath)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let exportError = captureEngine.cxlLastExportError {
                Text("Export failed: \(exportError)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                if captureEngine.cxlIsRecording {
                    Button("Stop Capture") {
                        captureEngine.stopCXLCapture()
                    }
                    .buttonStyle(.bordered)
                    .tint(Color(nsColor: .systemRed))
                    .font(.system(size: 12, weight: .semibold))

                    Button("Export Session") {
                        captureEngine.exportCXLSession()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(nsColor: .systemBlue))
                    .font(.system(size: 12, weight: .semibold))
                } else {
                    Button("Start Dataset Capture") {
                        captureEngine.startCXLCapture(mode: "Advanced Capture Details")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(nsColor: .systemGreen))
                    .font(.system(size: 12, weight: .semibold))

                    if captureEngine.cxlEventCount > 0 || captureEngine.cxlSampleCount > 0 {
                        Button("Export Session") {
                            captureEngine.exportCXLSession()
                        }
                        .buttonStyle(.bordered)
                        .tint(Color(nsColor: .systemBlue))
                        .font(.system(size: 12, weight: .semibold))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func captureInputStatusTile(title: String, value: String, detail: String? = nil, systemImage: String, color: Color) -> some View {
        // Same TITLE · STATE deduplication rule as headerStatusPill.
        let cleanedValue = Self.dedupedStatusValue(title: title, value: value)
        let cleanedDetail: String? = {
            guard let detail else { return nil }
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            // Drop the detail line entirely if it is the same as the value
            // (after dedup) — the row was reading like "Audio Ready / Audio
            // Ready — Virtual audio device — No signal".
            return trimmed.isEmpty || trimmed.localizedCaseInsensitiveContains(cleanedValue) ? nil : trimmed
        }()
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                Text(cleanedValue)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color)

                if let cleanedDetail, !cleanedDetail.isEmpty {
                    Text(cleanedDetail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var miniNotationTimeline: some View {
        let notation = currentRoutineNotationPreview
        let hasTake = captureEngine.lastRoutineRecordingURL != nil

        return VStack(alignment: .leading, spacing: 8) {
            Text("Captured Notation")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            if let notation {
                ScratchNotationCanvasView(
                    notation: notation,
                    playbackTime: 0,
                    loopDuration: notation.timelineDuration
                )
                .frame(height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else if hasTake {
                VStack(alignment: .leading, spacing: 6) {
                    if hasPartialReviewNotation {
                        Text("Audio-only take")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text("No record movement detected.")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text("Hand motion wasn't detected — review timing only.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Notation unavailable for this take.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                .padding(12)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Text("Record a routine first to see notation here.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .center)
                    .padding(10)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private func fallbackTakeDisplayName(for date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        return "Take \(formatter.string(from: date))"
    }

    private func testLabMetricBadge(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func startPracticeSession() {
        practiceTimer?.invalidate()
        isPracticeSessionActive = true
        practiceTimeRemaining = practiceDuration.duration
        practiceDetectionCount = 0
        practiceAverageAccuracy = 0
        practiceBestAccuracy = 0
        practiceScore = 0
        practiceCurrentStreak = 0
        practiceBestStreak = 0
        practiceLastHandledDetectionAt = nil
        captureEngine.resetScratchRatingSession()

        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            if practiceTimeRemaining > 1 {
                practiceTimeRemaining -= 1
            } else {
                finishPracticeSession(saveResult: true)
            }
        }
        timer.tolerance = 0.2
        practiceTimer = timer
    }

    private func finishPracticeSession(saveResult: Bool) {
        guard isPracticeSessionActive else { return }

        practiceTimer?.invalidate()
        practiceTimer = nil

        let elapsedDuration = max(0, practiceDuration.duration - practiceTimeRemaining)
        isPracticeSessionActive = false

        guard saveResult else {
            practiceTimeRemaining = practiceDuration.duration
            practiceLastHandledDetectionAt = nil
            return
        }

        progressManager.recordScratchAttempt(
            scratchID: "baby_scratch",
            accuracy: practiceAverageAccuracy,
            duration: elapsedDuration
        )
        practiceLastSavedAt = Date()
        practiceLastSavedAccuracy = practiceAverageAccuracy
        practiceLastSavedDuration = elapsedDuration
        practiceTimeRemaining = practiceDuration.duration
    }

    private func cancelTestLabPracticeSession() {
        finishPracticeSession(saveResult: false)
        practiceDetectionCount = 0
        practiceAverageAccuracy = 0
        practiceBestAccuracy = 0
        practiceScore = 0
        practiceCurrentStreak = 0
        practiceBestStreak = 0
    }

    private func handlePracticeDetection(_ detection: MacScratchDetectionResult?) {
        guard isPracticeSessionActive, let detection else { return }
        guard practiceLastHandledDetectionAt != detection.detectedAt else { return }

        practiceLastHandledDetectionAt = detection.detectedAt
        practiceDetectionCount += 1

        if practiceDetectionCount == 1 {
            practiceAverageAccuracy = detection.accuracy
        } else {
            practiceAverageAccuracy =
                ((practiceAverageAccuracy * Double(practiceDetectionCount - 1)) + detection.accuracy)
                / Double(practiceDetectionCount)
        }

        practiceBestAccuracy = max(practiceBestAccuracy, detection.accuracy)

        let streakMultiplier = 1.0 + (Double(practiceCurrentStreak) * 0.1)
        practiceScore += Int(100.0 * (detection.accuracy / 100.0) * streakMultiplier)

        if detection.accuracy >= 70 {
            practiceCurrentStreak += 1
            practiceBestStreak = max(practiceBestStreak, practiceCurrentStreak)
        } else {
            practiceCurrentStreak = 0
        }
    }

    private func formatPracticeTime(_ seconds: TimeInterval) -> String {
        let clampedSeconds = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", clampedSeconds / 60, clampedSeconds % 60)
    }

    private func calibrationSlider(title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))

                Spacer()

                Text(String(format: format, value.wrappedValue))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Slider(value: value, in: range)
        }
        .disabled(captureEngine.calibrationLocked)
    }
}

private struct RoutineSessionRow: View {
    let title: String
    let subtitle: String
    /// Optional sub-detail (e.g. friendly date or status). Pass `nil` to omit.
    /// Raw UUIDs/filenames must NEVER be passed here — use `copyableID` instead.
    let detail: String?
    /// When non-nil, a small "Copy ID" affordance is rendered. The full ID is
    /// only ever placed on the clipboard; it is not displayed.
    let copyableID: String?
    let isSelected: Bool

    init(title: String, subtitle: String, detail: String? = nil, copyableID: String? = nil, isSelected: Bool) {
        self.title = title
        self.subtitle = subtitle
        self.detail = detail
        self.copyableID = copyableID
        self.isSelected = isSelected
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isSelected ? .white.opacity(0.84) : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isSelected ? .white.opacity(0.72) : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let copyableID, !copyableID.isEmpty {
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(copyableID, forType: .string)
                } label: {
                    Label("Copy ID", systemImage: "doc.on.doc")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(isSelected ? .white.opacity(0.85) : .secondary)
                .help("Copy session ID")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            (isSelected ? Color.accentColor : Color(nsColor: .windowBackgroundColor)),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(isSelected ? 0 : 0.08), lineWidth: 1)
        )
    }
}

private struct RoutineSessionErrorBanner: View {
    let title: String
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color(nsColor: .systemOrange))
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss session error")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.22), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
    }
}

private struct CompanionStageContent: View {
    @ObservedObject var frameStore: CompanionCameraReceiver.FrameStore
    let discoveredPeers: [CompanionCameraReceiver.PeerSummary]

    var body: some View {
        if let image = frameStore.image {
            ZStack(alignment: .topLeading) {
                Color.black

                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Text("\(frameStore.cameraPosition) cam")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .systemGreen), in: Capsule())
                    .padding(20)
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white.opacity(0.65))

                Text("Bring in the companion deck feed:")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)

                Text("1. For watch relay only, just keep ScratchLab open on the iPhone main menu and connect it from the sidebar.\n2. For live deck video, mount the companion device above the decks and open ScratchLab > Companion Camera.\n3. Choose Deck so it sends the top-down platter and mixer view.\n4. Keep that screen open until the device appears in the Companion Feed sidebar, then click Connect.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)

                if !discoveredPeers.isEmpty {
                    Text("Nearby device ready: \(discoveredPeers.map(\.name).joined(separator: ", ")). Use Connect in the sidebar to link the iPhone for watch relay or add its deck view as a second camera.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.horizontal, 20)
                } else {
                    Text("If no device appears yet, keep ScratchLab open on the iPhone, leave both devices nearby, and wait a few seconds while ScratchLab keeps searching.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white.opacity(0.06))
        }
    }
}

private struct AudioRoutingOptionRow: View {
    let title: String
    let detail: String
    let icon: String
    let isActive: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isActive ? Color(nsColor: .systemGreen) : .secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))

                    if isActive {
                        Text("ACTIVE")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(nsColor: .systemGreen).opacity(0.15), in: Capsule())
                            .foregroundStyle(Color(nsColor: .systemGreen))
                    }
                }

                Text(detail)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

final class PerformerMonitorBroadcaster: NSObject, ObservableObject, NetServiceDelegate {
    @Published var connectedPeerNames: [String] = []
    @Published var connectionStatus = "Searching for Performer Monitor on a nearby device"
    @Published private(set) var manualConnectAddress = ""

    private let serviceType = "_scrmonfeed._tcp"
    private let netServiceType = "_scrmonfeed._tcp."
    private let preferredListenerPort = NWEndpoint.Port(rawValue: 58585)!
    private let listenerQueue = DispatchQueue(label: "scratchlab.mac.performer.listener")
    private let logger = Logger(subsystem: "com.machelpnz.scratchlab.mac", category: "PerformerMonitorBroadcaster")
    private let encoder = PropertyListEncoder()
    private var listener: NWListener?
    private var publishedService: NetService?
    private var connections: [String: NWConnection] = [:]
    private var connectionNames: [String: String] = [:]

    init(startImmediately: Bool = true) {
        super.init()
        refreshManualConnectAddress(port: preferredListenerPort)
        if startImmediately {
            startAdvertising()
        }
    }

    deinit {
        stopAdvertising()
    }

    func send(frame: MacCaptureEngine.PerformerMonitorFrame) {
        guard !connections.isEmpty else { return }
        guard let data = try? encoder.encode(frame) else { return }
        var length = UInt32(data.count).bigEndian
        let lengthData = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        let packet = lengthData + data

        for (id, connection) in connections {
            connection.send(content: packet, completion: .contentProcessed { [weak self] error in
                guard let self, let error else { return }
                DispatchQueue.main.async {
                    self.logger.error("Performer feed send failed: \(error.localizedDescription, privacy: .public)")
                    self.removeConnection(id: id)
                    self.connectionStatus = "Unable to send to device. Check connection."
                }
            })
        }
    }

    func refreshAdvertising() {
        guard let listener else {
            startAdvertising()
            return
        }

        if let port = listener.port {
            refreshManualConnectAddress(port: port)
        }

        if publishedService == nil {
            publishBonjourService(for: listener)
        }
    }

    private func startAdvertising() {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true

        do {
            let listener = try NWListener(using: parameters, on: preferredListenerPort)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self.logger.info("Performer listener ready on port \(String(describing: listener.port?.rawValue), privacy: .public)")
                        self.publishBonjourService(for: listener)
                        if self.connectedPeerNames.isEmpty {
                            self.connectionStatus = "Searching for Performer Monitor on a nearby device"
                        }
                    case .waiting(let error):
                        self.logger.error("Performer listener waiting: \(error.localizedDescription, privacy: .public)")
                        self.connectionStatus = "Device connection paused. Check network."
                    case .failed(let error):
                        self.logger.error("Performer listener failed: \(error.localizedDescription, privacy: .public)")
                        self.connectionStatus = "Unable to start device sharing. Check network."
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.configure(connection: connection)
            }
            self.listener = listener
            listener.start(queue: listenerQueue)
        } catch {
            logger.error("Unable to start performer listener: \(error.localizedDescription, privacy: .public)")
            connectionStatus = "Unable to start device sharing. Check network."
        }
    }

    private func stopAdvertising(keepStatus: Bool = false) {
        listener?.cancel()
        listener = nil
        publishedService?.stop()
        publishedService?.delegate = nil
        publishedService = nil
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
        connectionNames.removeAll()
        connectedPeerNames = []
        if !keepStatus {
            connectionStatus = "Searching for Performer Monitor on a nearby device"
        }
    }

    private func configure(connection: NWConnection) {
        let id = UUID().uuidString
        connections[id] = connection
        let name = displayName(for: connection.endpoint)
        connectionNames[id] = name

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            DispatchQueue.main.async {
                switch state {
                case .setup, .preparing:
                    self.connectionStatus = "Connecting to \(name)"
                case .ready:
                    self.connectionNames[id] = name
                    self.refreshConnectedPeerNames()
                    self.connectionStatus = "Connected to \(name)"
                case .waiting(let error):
                    self.logger.error("Performer connection waiting: \(error.localizedDescription, privacy: .public)")
                    self.connectionStatus = "Connection to device paused. Check connection."
                case .failed(let error):
                    self.logger.error("Performer connection failed: \(error.localizedDescription, privacy: .public)")
                    self.removeConnection(id: id)
                    self.connectionStatus = "Connection to device lost."
                case .cancelled:
                    self.removeConnection(id: id)
                @unknown default:
                    self.connectionStatus = "Connection updated."
                }
            }
        }
        connection.start(queue: listenerQueue)
    }

    private func displayName(for endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .service(let name, _, _, _):
            return name.isEmpty ? "ScratchLab Performer Monitor" : name
        case .hostPort(let host, _):
            return host.debugDescription
        default:
            return endpoint.debugDescription
        }
    }

    private func removeConnection(id: String) {
        connections[id]?.cancel()
        connections[id] = nil
        connectionNames[id] = nil
        refreshConnectedPeerNames()
        if connectedPeerNames.isEmpty {
            connectionStatus = "Searching for Performer Monitor on a nearby device"
        }
    }

    private func refreshConnectedPeerNames() {
        connectedPeerNames = connectionNames.values.sorted()
    }

    private func publishBonjourService(for listener: NWListener) {
        guard let port = listener.port else {
            logger.error("Performer listener became ready without a port")
            connectionStatus = "Unable to prepare device sharing."
            return
        }

        refreshManualConnectAddress(port: port)
        publishedService?.stop()
        let serviceName = Host.current().localizedName ?? "ScratchLab"
        logger.info("Publishing performer service \(serviceName, privacy: .public) on port \(port.rawValue, privacy: .public)")
        let service = NetService(
            domain: "local.",
            type: netServiceType,
            name: serviceName,
            port: Int32(port.rawValue)
        )
        service.delegate = self
        service.includesPeerToPeer = true
        publishedService = service
        service.publish()
    }

    func netServiceDidPublish(_ sender: NetService) {
        logger.info("Published performer Bonjour service \(sender.name, privacy: .public)")
        if connectedPeerNames.isEmpty {
            connectionStatus = "Searching for Performer Monitor on a nearby device"
        }
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String : NSNumber]) {
        let errorCode = errorDict[NetService.errorCode]?.intValue ?? -1
        logger.error("Failed to publish performer Bonjour service \(sender.name, privacy: .public) with error \(errorCode, privacy: .public)")
        publishedService = nil
        connectionStatus = "Unable to start device sharing. Check network."
    }

    private func refreshManualConnectAddress(port: NWEndpoint.Port) {
        let host = normalizedManualConnectHost()
        manualConnectAddress = "\(host):\(port.rawValue)"
    }

    private func normalizedManualConnectHost() -> String {
        if let localAddress = preferredLocalIPv4Address() {
            return localAddress
        }

        let host = ProcessInfo.processInfo.hostName.lowercased()
        if host.hasSuffix(".local") {
            return host
        }
        return "\(host).local"
    }

    private func preferredLocalIPv4Address() -> String? {
        var interfacePointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfacePointer) == 0, let firstInterface = interfacePointer else {
            return nil
        }
        defer { freeifaddrs(interfacePointer) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = firstInterface
        while let interface = cursor {
            defer { cursor = interface.pointee.ifa_next }

            guard let addressPointer = interface.pointee.ifa_addr,
                  addressPointer.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            let flags = Int32(interface.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else {
                continue
            }

            let name = String(cString: interface.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                addressPointer,
                socklen_t(addressPointer.pointee.sa_len),
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }

            let address = String(cString: hostBuffer)
            guard !address.hasPrefix("169.254.") else { continue }
            return address
        }

        return nil
    }
}

struct MacPerformerMonitorView: View {
    private enum MonitorMode: String, CaseIterable, Identifiable {
        case cue
        case deck

        var id: String { rawValue }

        var title: String {
            switch self {
            case .cue:
                return "Cue"
            case .deck:
                return "Deck View"
            }
        }
    }

    @AppStorage("scratchlab.mac.performerMonitorMode") private var monitorModeRaw = MonitorMode.deck.rawValue
    @EnvironmentObject private var captureEngine: MacCaptureEngine
    @EnvironmentObject private var performerBroadcaster: PerformerMonitorBroadcaster
    @State private var performerWindow: NSWindow?
    @State private var moveStatus = "No external display detected yet."
    @State private var didAttemptAutoMove = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, Color(nsColor: .windowBackgroundColor)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                performerHeader

                if monitorMode == .cue {
                    cueMonitorContent
                } else {
                    deckMonitorContent
                }

                Spacer(minLength: 0)
            }
            .padding(24)
        }
        .background(
            PerformerMonitorWindowAccessor { window in
                bindWindow(window)
            }
        )
        .frame(minWidth: 900, minHeight: 620)
        .onAppear {
            performerBroadcaster.refreshAdvertising()
        }
    }

    private var monitorMode: MonitorMode {
        get { MonitorMode(rawValue: monitorModeRaw) ?? .cue }
        nonmutating set { monitorModeRaw = newValue.rawValue }
    }

    private var monitorModeBinding: Binding<MonitorMode> {
        Binding(
            get: { monitorMode },
            set: { monitorMode = $0 }
        )
    }

    private var performerHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Performer Monitor")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)

                    Text("Use Cue for the next drill instruction, or Deck View for the live camera, guide boxes, and scratch feedback.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))

                    DisclosureGroup("Advanced connection") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Use this only if nearby discovery does not find ScratchLab.")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.72))

                            Text(performerBroadcaster.manualConnectAddress)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.72))
                        }
                        .padding(.top, 4)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .tint(.white.opacity(0.8))
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 10) {
                    Picker("Mode", selection: monitorModeBinding) {
                        ForEach(MonitorMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)

                    HStack(spacing: 8) {
                        Button(preferredDisplayButtonTitle) {
                            moveWindowToPreferredSecondaryDisplay()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(preferredSecondaryScreen == nil)

                        Button("Back to Main View") {
                            moveWindowToMainDisplay()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            Text(moveStatus)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))

            Text(performerBroadcaster.connectionStatus)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(performerBroadcaster.connectedPeerNames.isEmpty ? .white.opacity(0.6) : .green)
        }
    }

    private var cueMonitorContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Text("NEXT CUE")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.58))

                Text(captureEngine.babyScratchGuidanceCue)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(captureEngine.handMotionState.color)

                Text(captureEngine.babyScratchGuidanceDetail)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.84))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20, style: .continuous))

            HStack(spacing: 14) {
                performerMetric(
                    title: "Scratch",
                    value: captureEngine.scratchStatusTitle,
                    detail: captureEngine.scratchStatusDetail
                )
                performerMetric(
                    title: "Audio",
                    value: captureEngine.formattedAudioPercent,
                    detail: "Routed DJ signal level"
                )
                performerMetric(
                    title: "Detections",
                    value: "\(captureEngine.scratchDetectionCount)",
                    detail: "Baby scratches matched"
                )
            }
        }
    }

    private var deckMonitorContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Deck Setup View")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)

                Spacer()

                Text("\(captureEngine.selectedVideoSourceDescription) · \(captureEngine.rigStatusTitle)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
            }

            ZStack(alignment: .topLeading) {
                MacCameraPreviewView(session: captureEngine.captureSession)
                    .overlay(Color.black.opacity(0.08))

                if captureEngine.showRigGuides {
                    DeckGamificationOverlay(detector: captureEngine)
                }

                VStack(alignment: .leading, spacing: 10) {
                    performerCuePill

                    HStack(spacing: 8) {
                        performerMetricBadge(title: "Audio", value: captureEngine.formattedAudioPercent)
                        performerMetricBadge(title: "Matches", value: "\(captureEngine.scratchDetectionCount)")
                    }
                }
                .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var performerCuePill: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(captureEngine.handMotionState.color)
                .frame(width: 10, height: 10)

            Text(captureEngine.babyScratchGuidanceCue)
                .font(.system(size: 13, weight: .bold))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .frame(maxWidth: 280)
    }

    private func performerMetricBadge(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.56))

            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var preferredDisplayButtonTitle: String {
        return "Send to Device"
    }

    private var preferredSecondaryScreen: NSScreen? {
        let nonPrimaryScreens = NSScreen.screens.filter { screen in
            guard let main = NSScreen.main else { return true }
            return screen !== main
        }

        if let sidecar = nonPrimaryScreens.first(where: {
            $0.localizedName.localizedCaseInsensitiveContains("ipad")
                || $0.localizedName.localizedCaseInsensitiveContains("sidecar")
        }) {
            return sidecar
        }

        return nonPrimaryScreens.first
    }

    private func bindWindow(_ window: NSWindow?) {
        guard let window else { return }
        let isNewWindowReference = performerWindow !== window
        performerWindow = window

        if isNewWindowReference {
            updateMoveStatus()

            guard !didAttemptAutoMove else { return }
            didAttemptAutoMove = true

            DispatchQueue.main.async {
                moveWindowToPreferredSecondaryDisplay()
            }
        }
    }

    private func moveWindowToPreferredSecondaryDisplay() {
        guard let window = performerWindow else {
            moveStatus = "Performer window is still loading."
            return
        }

        guard let screen = preferredSecondaryScreen else {
            moveStatus = "No external display detected. Open Performer Monitor on another device if needed."
            return
        }

        move(window: window, to: screen)
        moveStatus = "Performer Monitor moved to \(screen.localizedName)."
    }

    private func moveWindowToMainDisplay() {
        guard let window = performerWindow else {
            moveStatus = "Performer window is still loading."
            return
        }

        guard let mainScreen = NSScreen.main else {
            moveStatus = "Main display not available."
            return
        }

        move(window: window, to: mainScreen)
        moveStatus = "Performer Monitor moved back to \(mainScreen.localizedName)."
    }

    private func move(window: NSWindow, to screen: NSScreen) {
        let visibleFrame = screen.visibleFrame
        let targetWidth = min(max(window.frame.width, 900), visibleFrame.width * 0.96)
        let targetHeight = min(max(window.frame.height, 620), visibleFrame.height * 0.94)
        let targetOrigin = CGPoint(
            x: visibleFrame.midX - (targetWidth / 2),
            y: visibleFrame.midY - (targetHeight / 2)
        )
        let targetFrame = CGRect(origin: targetOrigin, size: CGSize(width: targetWidth, height: targetHeight))

        window.setFrame(targetFrame, display: true, animate: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateMoveStatus() {
        if let screen = performerWindow?.screen {
            if let secondary = preferredSecondaryScreen, secondary !== screen {
                moveStatus = "Showing on \(screen.localizedName). Ready to send to \(secondary.localizedName)."
            } else {
                moveStatus = "Showing on \(screen.localizedName)."
            }
            return
        }

        if let secondary = preferredSecondaryScreen {
            moveStatus = "Ready to send to \(secondary.localizedName)."
        } else {
            moveStatus = "No external display detected yet. Open Performer Monitor on another device if needed."
        }
    }

    private func performerMetric(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))

            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)

            Text(detail)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.68))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct PerformerMonitorWindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            onResolve(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onResolve(nsView.window)
        }
    }
}

@MainActor
private final class SeratoWindowMover: ObservableObject {
    private static let seratoBundleIdentifier = "com.serato.seratodj"

    @Published var statusMessage = "No external display detected yet."

    var statusColor: Color {
        if statusMessage.localizedCaseInsensitiveContains("moved")
            || statusMessage.localizedCaseInsensitiveContains("showing on") {
            return .green
        }
        if statusMessage.localizedCaseInsensitiveContains("accessibility")
            || statusMessage.localizedCaseInsensitiveContains("not installed")
            || statusMessage.localizedCaseInsensitiveContains("not detected")
            || statusMessage.localizedCaseInsensitiveContains("not running") {
            return .secondary
        }
        return .primary
    }

    var preferredDisplayButtonTitle: String {
        return "Send to Device"
    }

    func refreshStatus() {
        guard let secondary = preferredSecondaryScreen else {
            statusMessage = "No external display detected yet."
            return
        }

        guard let application = runningSeratoApplication else {
            statusMessage = "Ready to send Serato DJ Pro to \(secondary.localizedName) once Serato is open."
            return
        }

        if let windowElement = targetWindow(for: application),
           let currentScreen = screenContaining(window: windowElement) {
            if currentScreen.localizedName == secondary.localizedName {
                statusMessage = "Serato DJ Pro is already showing on \(currentScreen.localizedName)."
            } else {
                statusMessage = "Serato DJ Pro is on \(currentScreen.localizedName). Ready to send it to \(secondary.localizedName)."
            }
            return
        }

        statusMessage = "Serato DJ Pro is open. Use Send to move it to \(secondary.localizedName)."
    }

    func moveSeratoToPreferredSecondaryDisplay() {
        guard let screen = preferredSecondaryScreen else {
            statusMessage = "No external display detected. Connect another display and try again."
            return
        }

        moveSerato(to: screen)
    }

    func moveSeratoToMainDisplay() {
        guard let mainScreen = NSScreen.main else {
            statusMessage = "Main display not available."
            return
        }

        moveSerato(to: mainScreen)
    }

    private var preferredSecondaryScreen: NSScreen? {
        let nonPrimaryScreens = NSScreen.screens.filter { screen in
            guard let main = NSScreen.main else { return true }
            return screen !== main
        }

        if let sidecar = nonPrimaryScreens.first(where: {
            $0.localizedName.localizedCaseInsensitiveContains("ipad")
                || $0.localizedName.localizedCaseInsensitiveContains("sidecar")
        }) {
            return sidecar
        }

        return nonPrimaryScreens.first
    }

    private var runningSeratoApplication: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.seratoBundleIdentifier)
            .first(where: { !$0.isTerminated })
    }

    private func moveSerato(to screen: NSScreen) {
        guard ensureAccessibilityAccess() else {
            statusMessage = "Allow ScratchLab in System Settings > Privacy & Security > Accessibility, then press \(preferredDisplayButtonTitle) again."
            return
        }

        if runningSeratoApplication == nil {
            launchSeratoIfInstalled()
            statusMessage = "Opening Serato DJ Pro. Press \(preferredDisplayButtonTitle) again once its main window appears."
            return
        }

        guard let application = runningSeratoApplication else {
            statusMessage = "Serato DJ Pro is not running."
            return
        }

        application.activate(options: [.activateAllWindows])

        guard let window = targetWindow(for: application) else {
            statusMessage = "Serato DJ Pro is running, but its main window is not ready yet."
            return
        }

        let targetFrame = centeredFrame(for: screen, currentWindow: window)
        let didSetFrame = setFrame(targetFrame, on: window)

        if didSetFrame {
            statusMessage = "Serato DJ Pro moved to \(screen.localizedName)."
        } else {
            statusMessage = "ScratchLab could not move the Serato DJ Pro window. Make sure Serato's main window is open and unlocked."
        }
    }

    private func launchSeratoIfInstalled() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.seratoBundleIdentifier) else {
            statusMessage = "Serato DJ Pro is not installed in /Applications."
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
    }

    private func ensureAccessibilityAccess() -> Bool {
        if AXIsProcessTrusted() {
            return true
        }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func targetWindow(for application: NSRunningApplication) -> AXUIElement? {
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)

        if let focusedWindow = copyElementAttribute(kAXFocusedWindowAttribute as CFString, from: applicationElement) {
            return focusedWindow
        }

        if let mainWindow = copyElementAttribute(kAXMainWindowAttribute as CFString, from: applicationElement) {
            return mainWindow
        }

        if let windows = copyElementArrayAttribute(kAXWindowsAttribute as CFString, from: applicationElement) {
            return windows.first
        }

        return nil
    }

    private func centeredFrame(for screen: NSScreen, currentWindow: AXUIElement) -> CGRect {
        let visibleFrame = screen.visibleFrame
        let currentSize = currentSize(for: currentWindow) ?? CGSize(width: visibleFrame.width * 0.92, height: visibleFrame.height * 0.92)
        let targetWidth = min(max(currentSize.width, visibleFrame.width * 0.82), visibleFrame.width * 0.98)
        let targetHeight = min(max(currentSize.height, visibleFrame.height * 0.82), visibleFrame.height * 0.98)
        return CGRect(
            x: visibleFrame.midX - (targetWidth / 2),
            y: visibleFrame.midY - (targetHeight / 2),
            width: targetWidth,
            height: targetHeight
        )
    }

    private func currentSize(for window: AXUIElement) -> CGSize? {
        guard let value = copyAXValueAttribute(kAXSizeAttribute as CFString, from: window) else {
            return nil
        }

        var size = CGSize.zero
        guard AXValueGetType(value) == .cgSize, AXValueGetValue(value, .cgSize, &size) else {
            return nil
        }
        return size
    }

    private func screenContaining(window: AXUIElement) -> NSScreen? {
        guard let value = copyAXValueAttribute(kAXPositionAttribute as CFString, from: window) else {
            return nil
        }

        var position = CGPoint.zero
        guard AXValueGetType(value) == .cgPoint, AXValueGetValue(value, .cgPoint, &position) else {
            return nil
        }

        let cocoaPoint = CGPoint(x: position.x, y: globalDesktopTopEdge - position.y)
        return NSScreen.screens.first(where: { $0.frame.contains(cocoaPoint) })
    }

    private var globalDesktopTopEdge: CGFloat {
        NSScreen.screens.map(\.frame.maxY).max() ?? 0
    }

    private func setFrame(_ frame: CGRect, on window: AXUIElement) -> Bool {
        var size = CGSize(width: frame.width, height: frame.height)
        var position = CGPoint(x: frame.minX, y: globalDesktopTopEdge - frame.maxY)

        guard let sizeValue = AXValueCreate(.cgSize, &size),
              let positionValue = AXValueCreate(.cgPoint, &position) else {
            return false
        }

        let sizeResult = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        let positionResult = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)

        return sizeResult == .success || positionResult == .success
    }

    private func copyAttribute(_ attribute: CFString, from element: AXUIElement) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value
    }

    private func copyElementAttribute(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        guard let value = copyAttribute(attribute, from: element) else {
            return nil
        }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func copyElementArrayAttribute(_ attribute: CFString, from element: AXUIElement) -> [AXUIElement]? {
        guard let value = copyAttribute(attribute, from: element) else {
            return nil
        }
        return value as? [AXUIElement]
    }

    private func copyAXValueAttribute(_ attribute: CFString, from element: AXUIElement) -> AXValue? {
        guard let value = copyAttribute(attribute, from: element) else {
            return nil
        }
        guard CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXValue.self)
    }
}

// MARK: - Shared button hierarchy

/// Three sizes for the macOS workspace, designed so primary/secondary/tertiary
/// roles are visually obvious at App-Store screenshot scale. Apply via the
/// `.scratchLabPrimaryButton()` / `.scratchLabSecondaryButton()` /
/// `.scratchLabTertiaryButton()` view modifiers below.
private enum ScratchLabButtonRole {
    case primary
    case secondary
    case tertiary
    case destructive
}

private struct ScratchLabButtonStyle: ViewModifier {
    let role: ScratchLabButtonRole
    let fillsWidth: Bool

    func body(content: Content) -> some View {
        switch role {
        case .primary:
            content
                .font(.system(size: 14, weight: .semibold))
                .frame(minHeight: 36)
                .frame(maxWidth: fillsWidth ? .infinity : nil)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        case .secondary:
            content
                .font(.system(size: 13, weight: .semibold))
                .frame(minHeight: 30)
                .frame(maxWidth: fillsWidth ? .infinity : nil)
                .buttonStyle(.bordered)
                .controlSize(.regular)
        case .tertiary:
            content
                .font(.system(size: 12, weight: .medium))
                .frame(minHeight: 26)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(.secondary)
        case .destructive:
            content
                .font(.system(size: 12, weight: .medium))
                .frame(minHeight: 26)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(Color(nsColor: .systemRed))
        }
    }
}

extension View {
    /// One-per-section dominant action.
    func scratchLabPrimaryButton(fillsWidth: Bool = false) -> some View {
        modifier(ScratchLabButtonStyle(role: .primary, fillsWidth: fillsWidth))
    }
    /// Bordered medium-weight action.
    func scratchLabSecondaryButton(fillsWidth: Bool = false) -> some View {
        modifier(ScratchLabButtonStyle(role: .secondary, fillsWidth: fillsWidth))
    }
    /// Borderless subtle utility action.
    func scratchLabTertiaryButton() -> some View {
        modifier(ScratchLabButtonStyle(role: .tertiary, fillsWidth: false))
    }
    /// Subtle destructive action (Discard, Reset).
    func scratchLabDestructiveButton() -> some View {
        modifier(ScratchLabButtonStyle(role: .destructive, fillsWidth: false))
    }
}
