import SwiftUI
import AVFoundation
import AppKit
import ApplicationServices
import Network
import OSLog
import Darwin

enum MacWorkspaceRouting {
    static let workspaceTabStorageKey = "scratchlab.mac.workspaceTab"
    static let testLabWorkspaceID = "testLab"
    static let routineCaptureWorkspaceID = "routineLab"

    static func showRoutineCapture(defaults: UserDefaults = .standard) {
        defaults.set(routineCaptureWorkspaceID, forKey: workspaceTabStorageKey)
    }
}

struct MacAnalyzerView: View {
    private static let practiceBeatModeColumns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    private enum WorkspaceTab: String, CaseIterable, Identifiable {
        case testLab
        case routineLab

        var id: String { rawValue }

        var title: String {
            switch self {
            case .testLab: return "Scratch Rating"
            case .routineLab: return "Routine Capture"
            }
        }

        var systemImage: String {
            switch self {
            case .testLab: return "checkmark.seal.fill"
            case .routineLab: return "waveform.badge.mic"
            }
        }
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

    @AppStorage(MacWorkspaceRouting.workspaceTabStorageKey) private var workspaceTabRaw = WorkspaceTab.testLab.rawValue
    @AppStorage("scratchlab.mac.stageLayout") private var stageLayoutRaw = StageLayout.desktopDeck.rawValue
    @AppStorage("scratchlab.mac.practiceDuration") private var practiceDurationRaw = PracticeDuration.fiveMinutes.rawValue
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
    @StateObject private var coachDemoPlayer = ScratchCoachDemoAudioPlayer()
    @State private var exportMixMode: ExportMixMode = .scratchOnly
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
            testLabWorkspace
                .tabItem {
                    Label(WorkspaceTab.testLab.title, systemImage: WorkspaceTab.testLab.systemImage)
                }
                .tag(WorkspaceTab.testLab)

            routineLabWorkspace
                .tabItem {
                    Label(WorkspaceTab.routineLab.title, systemImage: WorkspaceTab.routineLab.systemImage)
                }
                .tag(WorkspaceTab.routineLab)
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
            captureEngine.start()
            performerBroadcaster.refreshAdvertising()
            sessionUploadManager.refresh()
            captureEngine.setPerformerMonitorStreamingEnabled(!performerBroadcaster.connectedPeerNames.isEmpty)
            practiceBeatStore.configurePracticeContext(scratchID: CaptureSessionScratchType.babyScratch.rawValue)
            seratoWindowMover.refreshStatus()
            synchronizeSelectedRoutineSession()
            coachDemoPlayer.configure(with: coachInstruction)
            stageLayout = .desktopDeck
            if !isPracticeSessionActive {
                practiceTimeRemaining = practiceDuration.duration
            }
            if stageLayout == .desktopDeck {
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
            coachDemoPlayer.stop()
            practiceBeatStore.handleLeavingPractice()
            cancelTestLabPracticeSession()
            captureEngine.setPerformerMonitorStreamingEnabled(false)
        }
        .onChange(of: stageLayoutRaw) { _, newValue in
            guard StageLayout(rawValue: newValue) == .desktopDeck else { return }
            captureEngine.preferMacCameraForDesktopDeck()
        }
        .onChange(of: workspaceTabRaw) { _, newValue in
            guard WorkspaceTab(rawValue: newValue) != .testLab else { return }
            coachDemoPlayer.stop()
            practiceBeatStore.handleLeavingPractice()
            cancelTestLabPracticeSession()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase != .active else { return }
            coachDemoPlayer.stop()
            practiceBeatStore.handleAppDidBecomeInactive()
        }
        .onChange(of: practiceDurationRaw) { _, _ in
            guard !isPracticeSessionActive else { return }
            practiceTimeRemaining = practiceDuration.duration
        }
        .onChange(of: coachDemoInstructionKey) { _, _ in
            coachDemoPlayer.configure(with: coachInstruction)
        }
        .onChange(of: coachDemoPlaybackBlocked) { _, isBlocked in
            guard isBlocked else { return }
            coachDemoPlayer.stop()
        }
        .onReceive(captureEngine.$availableVideoDevices) { _ in
            guard stageLayout == .desktopDeck else { return }
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
        #if DEBUG
        .sheet(isPresented: $isShowingStagingInspector) {
            StagingInspectorView(contexts: stagingInspectorContexts)
        }
        #endif
    }

    private var testLabWorkspace: some View {
        HSplitView {
            testLabSidebar
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 400)

            VStack(spacing: 18) {
                testLabStageHeader
                testLabCameraStage
            }
            .padding(18)
            .background(Color.black)
        }
    }

    private var routineLabWorkspace: some View {
        HSplitView {
            analyzerSidebar
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 420)

            VStack(spacing: 18) {
                routineStageHeader

                if !hasRoutineSessions {
                    routineEmptyStateStage
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

    private var testLabSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                testLabHeaderCard
                testLabPracticeCard
                testLabAudioCard
                scratchCard
                testLabRatingCard
                testLabWorkflowCard
            }
            .padding(24)
        }
    }

    private var analyzerSidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            headerCard

            if let activeSession = routineSessionPresentation.activeSession {
                activeRoutineSessionCard(activeSession)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    routineSessionCard
                    if selectedRoutineSession != nil {
                        routineRecordingCard
                    }
                    Group {
                        seratoScreenCard
                        stageModeCard
                        audioCard
                        cameraCard
                        deckCalibrationCard
                        companionCard
                    }
                    .disabled(captureEngine.isRoutineRecording)
                    scratchCard
                    handMotionCard
                    workflowCard
                }
                .padding(.bottom, 24)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
    }

    private var testLabStageHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Scratch Rating Stage")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white)

                Text("Use one camera and one routed deck feed here for a quick Baby Scratch rating pass.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
            }

            Spacer()

            Button("Open Routine Capture") {
                workspaceTab = .routineLab
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    private var routineStageHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(stageLayout == .desktopDeck ? "Analyzer Stage" : "Dual Camera Stage")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white)

                Text(stageLayout == .desktopDeck
                     ? "Use the built-in camera as the main deck view and line the guide boxes up with Deck Calibration."
                     : "Keep both camera angles side by side while you check the rig.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
            }

            Spacer()

            Picker("Layout", selection: stageLayoutBinding) {
                ForEach(StageLayout.allCases) { layout in
                    Text(layout.title).tag(layout)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)
        }
    }

    private var localCameraStage: some View {
        liveCameraStage(
            title: stageLayout == .desktopDeck ? "Deck Camera" : "Analyzer Camera",
            subtitle: "\(selectedCameraName) · \(captureEngine.selectedVideoSourceDescription)"
        )
    }

    private var testLabCameraStage: some View {
        liveCameraStage(
            title: "Scratch Rating Camera",
            subtitle: "\(selectedCameraName) · \(captureEngine.selectedVideoSourceDescription)"
        )
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
        captureEngine.availableVideoDevices
            .first(where: { $0.uniqueID == captureEngine.selectedVideoDeviceUniqueID })?
            .localizedName ?? "No camera selected"
    }

    private var selectedAudioDevice: AVCaptureDevice? {
        captureEngine.availableAudioDevices
            .first(where: { $0.uniqueID == captureEngine.selectedAudioDeviceUniqueID })
    }

    private var selectedAudioDeviceName: String {
        selectedAudioDevice?.localizedName ?? "No audio input selected"
    }

    private var selectedAudioLooksMic: Bool {
        guard let selectedAudioDevice else { return false }
        let lowercasedName = selectedAudioDevice.localizedName.lowercased()
        return lowercasedName.contains("mic")
            || lowercasedName.contains("microphone")
            || lowercasedName.contains("built-in")
            || lowercasedName.contains("internal")
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

    private var routineSessionPresentation: SessionListPresentationModel<RoutineSessionDraft> {
        routineSessionStore.sessionListPresentation
    }

    private var hasRoutineSessions: Bool {
        !routineSessionStore.sessions.isEmpty
    }

    private var createNewSessionAction: () -> Void {
        RoutineSessionUIActionFactory.makeCreateNewSessionAction(for: routineSessionStore)
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
        get { WorkspaceTab(rawValue: workspaceTabRaw) ?? .testLab }
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
        workspaceTab == .testLab
            ? CaptureSessionScratchType.babyScratch.rawValue
            : routineSessionSetup.scratchType?.rawValue
    }

    private var coachScratchDisplayName: String? {
        workspaceTab == .testLab
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
        if !coachDemoPlayer.isAudioAvailable {
            return "Demo audio unavailable for this scratch."
        }
        return coachInstruction.demoAudioRole == "withBeat"
            ? "Coach demo includes beat and scratch together."
            : "Coach demo is isolated for scratch focus."
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
        workspaceTab = .routineLab
        routineSessionSetup.applyPersistedConfig(selectedRoutineSession.config)
    }

    private func routineSessionTitle(for session: RoutineSessionDraft) -> String {
        let performerName = session.config.performerName.trimmingCharacters(in: .whitespacesAndNewlines)
        return performerName.isEmpty ? "Untitled Session" : performerName
    }

    private func routineSessionSubtitle(for session: RoutineSessionDraft) -> String {
        let scratchLabel = session.config.scratchType?.title ?? "Scratch type later"
        let bpmLabel = session.config.bpm.map { "\($0) BPM" } ?? "BPM later"
        return "\(scratchLabel) · \(bpmLabel)"
    }

    private func shareLastRoutineSession() {
        guard let lastRoutineRecordingURL = captureEngine.lastRoutineRecordingURL else {
            sessionExportCoordinator.showFailure(.sessionFolderNotFound)
            return
        }
        sessionExportCoordinator.prepareShare(
            for: .localRecordingSession(
                lastRecordingURL: lastRoutineRecordingURL,
                sessionName: routineSessionSetup.sessionName(defaultAppName: "Routine Capture"),
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
                sessionName: routineSessionSetup.sessionName(defaultAppName: "Routine Capture"),
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
                sessionName: routineSessionSetup.sessionName(defaultAppName: "Routine Capture"),
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

    private var routineEmptyStateStage: some View {
        cameraStageCard(
            title: "Routine Sessions",
            subtitle: "Create a session before you start a scratch capture."
        ) {
            VStack(spacing: 16) {
                Spacer()

                VStack(spacing: 10) {
                    Text("Create your first session")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundColor(.white)

                    Text("Start a scratch practice capture, add details, then export your session.")
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

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Routine Capture")
                        .font(.system(size: 28, weight: .semibold))

                    Text("ScratchLab")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    Button("New Session", action: createNewSessionAction)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(captureEngine.isRoutineRecording)

                    Button("Open Monitor View") {
                        openWindow(id: "performer-monitor")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Text("Set up audio, align the camera, then record your routine.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                headerStatusPill(
                    title: "Audio",
                    value: captureEngine.selectedAudioDeviceUniqueID.isEmpty ? "Not Connected" : "Ready",
                    color: captureEngine.selectedAudioDeviceUniqueID.isEmpty ? .secondary : .green
                )
                headerStatusPill(
                    title: "Device",
                    value: companionReceiver.connectedPeerNames.isEmpty ? "Searching" : "Connected",
                    color: companionReceiver.connectedPeerNames.isEmpty ? .secondary : .green
                )
                headerStatusPill(
                    title: "Monitor",
                    value: performerBroadcaster.connectedPeerNames.isEmpty ? "Searching" : "Connected",
                    color: performerBroadcaster.connectedPeerNames.isEmpty ? .secondary : .green
                )
            }

            Label(captureEngine.statusMessage, systemImage: captureEngine.statusIcon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(captureEngine.statusColor)

            Label(performerBroadcaster.connectionStatus, systemImage: performerBroadcaster.connectedPeerNames.isEmpty ? "ipad.landscape" : "dot.radiowaves.left.and.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(performerBroadcaster.connectedPeerNames.isEmpty ? Color.secondary : Color.green)

            DisclosureGroup("Advanced connection") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Use this only if nearby discovery does not find ScratchLab.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text(performerBroadcaster.manualConnectAddress)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
            .font(.system(size: 12, weight: .semibold))

            Text("Open Performer Monitor here, then send that window to an external display if one is available. If not, open ScratchLab on another device and tap Performer Monitor to receive the same deck view directly.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var routineSessionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Recent Sessions")
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

                DisclosureGroup("All Sessions", isExpanded: $isShowingAllRoutineSessions) {
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
            Text("Active Session")
                .font(.headline)

            Button {
                routineSessionStore.openSession(id: session.id)
            } label: {
                RoutineSessionRow(
                    title: routineSessionTitle(for: session.session),
                    subtitle: routineSessionSubtitle(for: session.session),
                    detail: session.id,
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
                detail: session.id,
                isSelected: routineSessionStore.selectedSessionID == session.id
            )
        }
        .buttonStyle(.plain)
        .disabled(captureEngine.isRoutineRecording)
    }

    private var testLabHeaderCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Scratch Rating")
                        .font(.system(size: 28, weight: .semibold))

                    Text("ScratchLab")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Button("Open Routine Capture") {
                    workspaceTab = .routineLab
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            Text("Use one routed input and one camera view here for a quick scratch rating check.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                headerStatusPill(
                    title: "Audio",
                    value: captureEngine.selectedAudioDeviceUniqueID.isEmpty ? "Choose input" : captureEngine.formattedAudioPercent,
                    color: captureEngine.selectedAudioDeviceUniqueID.isEmpty ? .secondary : captureEngine.audioMeterColor
                )
                headerStatusPill(
                    title: "Matches",
                    value: "\(captureEngine.scratchDetectionCount)",
                    color: captureEngine.scratchDetectionCount == 0 ? .secondary : .green
                )
                headerStatusPill(
                    title: "Stars",
                    value: "\(captureEngine.visibleStarCount)/5",
                    color: captureEngine.visibleStarCount == 0 ? .secondary : .green
                )
            }

            Label(captureEngine.scratchStatusTitle, systemImage: captureEngine.scratchStatusIcon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(captureEngine.scratchStatusColor)

            Text("Open Routine Capture when you need the second camera, deck calibration, monitor tools, or a saved take.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var testLabPracticeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Practice Log")
                        .font(.headline)

                    Text(
                        isPracticeSessionActive
                            ? "This timed Baby Scratch run is live. Finish and save it to update your progress on Mac."
                            : "Start a timed Baby Scratch run here and save the result into the same progress model the iPhone practice flow uses."
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

                    Text(practiceBeatStore.isBeatEnabled ? "Beat On" : "No Beat")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(practiceBeatStore.isBeatEnabled ? Color(nsColor: .systemGreen) : .secondary)
                }

                HStack(spacing: 10) {
                    Button {
                        practiceBeatStore.setBeatEnabled(false)
                    } label: {
                        Text("No Beat")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(!practiceBeatStore.isBeatEnabled ? Color.black : Color.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                !practiceBeatStore.isBeatEnabled
                                    ? Color(nsColor: .systemYellow)
                                    : Color(nsColor: .controlBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("practice-beat-no-beat-button")

                    Button {
                        practiceBeatStore.setBeatEnabled(true)
                    } label: {
                        Text("Beat On")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(practiceBeatStore.isBeatEnabled ? Color.black : Color.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                practiceBeatStore.isBeatEnabled
                                    ? Color(nsColor: .systemGreen)
                                    : Color(nsColor: .controlBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("practice-beat-on-button")
                }

                if practiceBeatStore.isBeatEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Beat style")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)

                        LazyVGrid(columns: Self.practiceBeatModeColumns, spacing: 10) {
                            ForEach(practiceBeatStore.availableBeatModes) { mode in
                                Button {
                                    practiceBeatStore.selectBeatMode(mode)
                                } label: {
                                    HStack(spacing: 8) {
                                        Text(mode.title)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(practiceBeatStore.selectedBeatMode == mode ? Color.black : Color.primary)
                                            .multilineTextAlignment(.leading)

                                        Spacer(minLength: 0)

                                        if practiceBeatStore.selectedBeatMode == mode {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(Color.black.opacity(0.78))
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 10)
                                    .background(
                                        practiceBeatStore.selectedBeatMode == mode
                                            ? Color(nsColor: .systemYellow)
                                            : Color(nsColor: .controlBackgroundColor),
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("practice-beat-mode-\(mode.rawValue)")
                            }
                        }
                    }
                } else {
                    Text("No Beat. Practise from live scratch audio only until you want timing guidance.")
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
                            Button {
                                practiceBeatStore.setBPM(bpm)
                            } label: {
                                Text("\(bpm)")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(practiceBeatStore.bpmValue == bpm ? Color.black : Color.primary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(
                                        practiceBeatStore.bpmValue == bpm
                                            ? Color(nsColor: .systemYellow)
                                            : Color(nsColor: .controlBackgroundColor),
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Button {
                    practiceBeatStore.togglePlayback()
                } label: {
                    Text(practiceBeatStore.isPlaying ? "Stop Beat" : "Play Beat")
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
                    Text(playbackErrorMessage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .fixedSize(horizontal: false, vertical: true)
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
                Button(isPracticeSessionActive ? "Finish & Save" : "Start Practice") {
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
                    title: "Recent Avg",
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
                Text("No Mac practice run saved yet. Start a session here, then finish and save it to build your Baby Scratch stats.")
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
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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

            Label(captureEngine.routineRecordingStatus, systemImage: captureEngine.isRoutineRecording ? "record.circle.fill" : "film.stack.fill")
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
                Text(lastRoutineRecordingURL.lastPathComponent)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

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
                    Text("Latest capture: \(latestCapture.fileURL.lastPathComponent)")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
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
                        Button {
                            bpmText = String(bpm)
                        } label: {
                            Text("\(bpm)")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Int(bpmText) == bpm ? Color.black : Color.primary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(
                                    Int(bpmText) == bpm
                                        ? Color(nsColor: .systemGreen)
                                        : Color(nsColor: .controlBackgroundColor),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }

                TextField("Custom BPM (60–140)", text: $bpmText)
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

        captureEngine.recordingSessionConfig = routineSessionSetup.config

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

            Picker("Source", selection: $captureEngine.selectedAudioDeviceUniqueID) {
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
                    Text(captureEngine.formattedAudioPercent)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: Double(captureEngine.audioLevel))
                    .tint(captureEngine.audioMeterColor)

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

    private var testLabAudioCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Audio Input")
                .font(.headline)

            Picker("Source", selection: $captureEngine.selectedAudioDeviceUniqueID) {
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

                    Text(captureEngine.formattedAudioPercent)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: Double(captureEngine.audioLevel))
                    .tint(captureEngine.audioMeterColor)

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
                playbackTimeProvider: { coachDemoPlayer.currentPlaybackTime },
                isPlayingProvider: { coachDemoPlayer.isActivelyPlayingAudio },
                theme: coachCardTheme
            ) {
                HStack(spacing: 10) {
                    coachDemoButton(
                        title: "Listen",
                        systemImage: "play.fill",
                        enabled: coachDemoPlayer.isAudioAvailable && !coachDemoPlaybackBlocked,
                        action: coachDemoPlayer.play
                    )

                    coachDemoButton(
                        title: "Pause",
                        systemImage: "pause.fill",
                        enabled: coachDemoPlayer.isPlaying && !coachDemoPlaybackBlocked,
                        action: coachDemoPlayer.pause
                    )

                    coachDemoButton(
                        title: "Replay",
                        systemImage: "gobackward",
                        enabled: coachDemoPlayer.isAudioAvailable && !coachDemoPlaybackBlocked,
                        action: coachDemoPlayer.replay
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
                Label("Manual deck guide is active right now.", systemImage: "slider.horizontal.3")
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

    private var testLabRatingCard: some View {
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
                    title: "Cue",
                    value: captureEngine.handDetected ? "Live" : "Need hand",
                    color: captureEngine.handMotionState.color
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
        VStack(alignment: .leading, spacing: 10) {
            Text("Routine Workflow")
                .font(.headline)

            Text(stageLayout == .desktopDeck
                 ? "1. Put the built-in camera above or in front of the decks.\n2. Route DJ software into a virtual audio device.\n3. Adjust Deck Calibration until the boxes line up with the rig.\n4. Start a Routine Recording when the view and audio are ready.\n5. If Serato feels crowded, open Monitor View and move it to a second display."
                 : "1. Route DJ software into a virtual audio device.\n2. Pick that device here for clean audio.\n3. Bring a companion device into Dual Cam if you want the extra angle.\n4. Start a Routine Recording when the take is framed.\n5. Open Monitor View if you want the feedback window off the main screen.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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

    private var testLabWorkflowCard: some View {
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
    let detail: String
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? .white : .primary)

            Text(subtitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? .white.opacity(0.84) : .secondary)

            Text(detail)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(isSelected ? .white.opacity(0.72) : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
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
