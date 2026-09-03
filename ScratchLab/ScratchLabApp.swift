// ScratchLabApp.swift
// ScratchLab
// Main application entry point

import SwiftUI
import Combine
#if canImport(UIKit)
import UIKit
#endif

enum QuickStartSettings {
    static let hasSeenKey = "hasSeenQuickStart"
    static let versionKey = "quickStartVersion"
    static let currentVersion = 1
}

enum MIDISelectionSettings {
    static let selectedSourceIDKey = "selectedMIDISourceID"
}

@main
struct ScratchLabApp: App {
    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(ScratchLabAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            AppLaunchContainerView()
                .preferredColorScheme(.dark)
        }
    }
}

/// Keeps first paint independent from the app's audio, MIDI, camera-relay,
/// watch, and upload services. Those objects are intentionally constructed
/// only after the lightweight SwiftUI splash has rendered and completed.
private struct AppLaunchContainerView: View {
    @State private var showSplash = true

    var body: some View {
        ZStack {
            ScratchLabDesign.Surface.applicationBackground
                .ignoresSafeArea()

            if showSplash {
                SplashView(showSplash: $showSplash)
            } else {
                RootContainerView()
            }
        }
    }
}

private struct RootContainerView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var gameState = GameState()
    @StateObject private var audioEngine = AudioEngine()
    @StateObject private var midiManager = IOSMIDIManager()
    @StateObject private var midiLearnCoordinator = IOSMIDILearnCoordinator()
    @StateObject private var transportState: TransportState
    @StateObject private var scratchPlaybackEngine: IOScratchPlaybackEngine
    @StateObject private var midiControllerDispatcher: IOSMIDIControllerDispatcher
    @StateObject private var progressManager = ProgressManager()
    @StateObject private var practiceBeatStore = PracticeBeatStore()
    @StateObject private var companionRelayBroadcaster = CompanionCameraBroadcaster()
    @StateObject private var watchMotionCaptureStore = WatchMotionCaptureStore()
    @StateObject private var sessionUploadManager = SessionUploadManager()
    @AppStorage("localNetworkRationaleAccepted") private var localNetworkRationaleAccepted = false
    @AppStorage(MIDISelectionSettings.selectedSourceIDKey) private var selectedMIDISourceID = ""
    private let watchRelayHeartbeat = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    init() {
        let transportState = TransportState()
        let scratchPlaybackEngine = IOScratchPlaybackEngine()
        _transportState = StateObject(wrappedValue: transportState)
        _scratchPlaybackEngine = StateObject(wrappedValue: scratchPlaybackEngine)
        _midiControllerDispatcher = StateObject(wrappedValue: IOSMIDIControllerDispatcher(
            transportState: transportState,
            playbackEngine: scratchPlaybackEngine
        ))
    }

    var body: some View {
        ContentView()
            .environmentObject(gameState)
            .environmentObject(audioEngine)
            .environmentObject(midiManager)
            .environmentObject(midiLearnCoordinator)
            .environmentObject(transportState)
            .environmentObject(scratchPlaybackEngine)
            .environmentObject(midiControllerDispatcher)
            .environmentObject(progressManager)
            .environmentObject(practiceBeatStore)
            .environmentObject(companionRelayBroadcaster)
            .environmentObject(watchMotionCaptureStore)
            .environmentObject(sessionUploadManager)
            .onAppear {
                configureMIDILearn()
                configureWatchRelay()
                refreshWatchCapturePipelineIfNeeded()
                syncWatchStateWithMac()
                sessionUploadManager.refresh()
            }
            .onChange(of: companionRelayBroadcaster.pendingWatchControlCommand) { _, command in
                guard let command else { return }
                handleRemoteWatchControlCommand(command)
            }
            .onChange(of: midiManager.sources) { _, _ in
                configureMIDILearnDevice()
            }
            .onChange(of: selectedMIDISourceID) { _, _ in
                configureMIDILearnDevice()
            }
            .onChange(of: companionRelayBroadcaster.connectedPeerNames) { _, peers in
                watchMotionCaptureStore.updateMacConnection(isConnected: !peers.isEmpty)
                if !peers.isEmpty {
                    syncWatchStateWithMac()
                }
            }
            .onReceive(watchRelayHeartbeat) { _ in
                watchMotionCaptureStore.sendRelayHeartbeat()
                companionRelayBroadcaster.sendWatchAvailability(
                    isPaired: watchMotionCaptureStore.isWatchPaired,
                    isInstalled: watchMotionCaptureStore.isWatchAppInstalled,
                    isReachable: watchMotionCaptureStore.isWatchReachable
                )
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else {
                    practiceBeatStore.handleAppDidBecomeInactive()
                    return
                }
                configureWatchRelay()
                refreshWatchCapturePipelineIfNeeded()
                syncWatchStateWithMac()
                sessionUploadManager.refresh()
            }
    }

    private func configureMIDILearn() {
        midiLearnCoordinator.onMappingChanged = { [weak midiControllerDispatcher] deviceID in
            midiControllerDispatcher?.updateMapping(deviceIdentifier: deviceID)
        }
        midiManager.setPlatterAudioMessageHandler { [weak midiControllerDispatcher] message in
            midiControllerDispatcher?.receivePlatterAudioMessage(message)
        }
        midiManager.onMessage = { [weak midiLearnCoordinator, weak midiControllerDispatcher] message in
            midiLearnCoordinator?.receive(message)
            midiControllerDispatcher?.receive(message)
        }
        configureMIDILearnDevice()
    }

    private func configureMIDILearnDevice() {
        let persistedSource = midiManager.sources.first(where: { $0.id == selectedMIDISourceID })
        let source = persistedSource ?? (selectedMIDISourceID.isEmpty && midiManager.sources.count == 1
            ? midiManager.sources.first
            : nil)

        guard let source else {
            midiLearnCoordinator.clearDeviceSelection()
            midiControllerDispatcher.updateMapping(deviceIdentifier: nil)
            return
        }

        if selectedMIDISourceID != source.id {
            selectedMIDISourceID = source.id
        }
        midiLearnCoordinator.selectDevice(id: source.id, name: source.name)
        if RaneOneMKIIVerifiedLearnedMapping.matches(deviceName: source.name),
           !RaneOneMKIIVerifiedLearnedMapping.isComplete(midiLearnCoordinator.currentMapping) {
            midiLearnCoordinator.applyVerifiedRaneOneMKIIMapping()
        }
        midiControllerDispatcher.updateMapping(deviceIdentifier: source.id, deviceName: source.name)
    }

    private func configureWatchRelay() {
        if localNetworkRationaleAccepted {
            companionRelayBroadcaster.startRelayAdvertisingIfNeeded()
        }
        watchMotionCaptureStore.onImportedCapture = { importedCapture in
            companionRelayBroadcaster.sendWatchCaptureSession(
                importedCapture.session,
                fileName: importedCapture.fileURL.lastPathComponent
            )
        }
        watchMotionCaptureStore.onAvailabilityChange = { isPaired, isInstalled, isReachable in
            companionRelayBroadcaster.sendWatchAvailability(
                isPaired: isPaired,
                isInstalled: isInstalled,
                isReachable: isReachable
            )
        }
        watchMotionCaptureStore.onLiveMotionBatch = { batch in
            companionRelayBroadcaster.sendWatchMotionBatch(batch)
        }
        watchMotionCaptureStore.onRelayLifecycle = { event, context, detail in
            companionRelayBroadcaster.sendWatchRelayLifecycle(event, context: context, detail: detail)
        }
        companionRelayBroadcaster.onWatchCaptureAcknowledged = { id in
            watchMotionCaptureStore.markAcknowledgedByMac(id)
        }
        watchMotionCaptureStore.updateMacConnection(
            isConnected: !companionRelayBroadcaster.connectedPeerNames.isEmpty
        )
    }

    private func refreshWatchCapturePipelineIfNeeded() {
        watchMotionCaptureStore.activateIfNeeded()
        watchMotionCaptureStore.checkForPendingImports()
    }

    /// Pushes current watch availability and every not-yet-acknowledged capture to a connected
    /// Mac. Called on peer connect, app foreground, and launch so a Mac that connects after takes
    /// were already queued still gets the full backlog, not just the most recent one.
    private func syncWatchStateWithMac() {
        guard !companionRelayBroadcaster.connectedPeerNames.isEmpty else { return }
        companionRelayBroadcaster.sendWatchAvailability(
            isPaired: watchMotionCaptureStore.isWatchPaired,
            isInstalled: watchMotionCaptureStore.isWatchAppInstalled,
            isReachable: watchMotionCaptureStore.isWatchReachable
        )
        for capture in watchMotionCaptureStore.unsentCaptures() {
            companionRelayBroadcaster.sendWatchCaptureSession(
                capture.session,
                fileName: capture.fileURL.lastPathComponent
            )
        }
    }

    private func handleRemoteWatchControlCommand(_ command: CompanionCameraBroadcaster.WatchControlCommandEvent) {
        switch command.payload.command {
        case .start:
            watchMotionCaptureStore.requestRemoteCaptureStart(
                sessionID: command.payload.sessionID,
                takeID: command.payload.takeID ?? "",
                takeNumber: command.payload.takeNumber,
                watchWrist: command.payload.watchWrist
            ) { reply in
                companionRelayBroadcaster.sendWatchControlStatus(reply)
            }
        case .stop:
            watchMotionCaptureStore.requestRemoteCaptureStop(
                sessionID: command.payload.sessionID,
                takeID: command.payload.takeID
            ) { reply in
                companionRelayBroadcaster.sendWatchControlStatus(reply)
            }
        @unknown default:
            companionRelayBroadcaster.sendWatchControlStatus(
                WatchCaptureControlReply(
                    commandID: command.payload.commandID,
                    sessionID: command.payload.sessionID,
                    takeID: command.payload.takeID,
                    syncState: .failed,
                    detail: "Unknown watch motion control command."
                )
            )
        }

        companionRelayBroadcaster.clearPendingWatchControlCommand()
    }
}

#if canImport(UIKit)
final class ScratchLabAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        SessionUploadBackgroundEvents.shared.register(identifier: identifier, completionHandler: completionHandler)
    }
}
#endif

// MARK: - Content View (Root Navigation)
struct ContentView: View {
    @State private var showingQuickStart = false
    @AppStorage(QuickStartSettings.hasSeenKey) private var hasSeenQuickStart = false
    @AppStorage(QuickStartSettings.versionKey) private var quickStartVersion = 0
    
    var body: some View {
        ZStack {
            ScratchLabDesign.Surface.applicationBackground
                .ignoresSafeArea()

            NavigationStack {
                MainMenuView()
            }
        }
        .onAppear {
            presentQuickStartIfNeeded()
        }
        .fullScreenCover(isPresented: $showingQuickStart) {
            QuickStartView(onFinish: completeQuickStart)
                .interactiveDismissDisabled()
        }
    }

    private var needsQuickStart: Bool {
        !hasSeenQuickStart || quickStartVersion < QuickStartSettings.currentVersion
    }

    private func presentQuickStartIfNeeded() {
        guard needsQuickStart else { return }
        showingQuickStart = true
    }

    private func completeQuickStart() {
        hasSeenQuickStart = true
        quickStartVersion = QuickStartSettings.currentVersion
        showingQuickStart = false
    }
}

// MARK: - Splash Screen
struct SplashView: View {
    @Binding var showSplash: Bool
    @State private var logoScale: CGFloat = 0.5
    @State private var logoOpacity: Double = 0
    @State private var logoLift: CGFloat = 16
    
    var body: some View {
        ZStack {
            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        .frame(width: 244, height: 244)
                        .overlay {
                            Circle()
                                .fill(Color.black.opacity(0.28))
                                .frame(width: 186, height: 186)
                        }
                        .overlay {
                            Circle()
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                .frame(width: 122, height: 122)
                        }
                        .overlay(alignment: .bottomTrailing) {
                            Circle()
                                .fill(Color(hex: "0EA5E9"))
                                .frame(width: 18, height: 18)
                                .offset(x: -34, y: -34)
                        }

                    Image("ScratchLabLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 148, height: 148)
                        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                        .shadow(color: Color.black.opacity(0.35), radius: 18, y: 12)
                        .accessibilityHidden(true)
                }

                VStack(spacing: 12) {
                    Text("ScratchLab")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundColor(.white)

                    Text("Practice, capture, and monitor")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.66))
                }
            }
            .scaleEffect(logoScale)
            .opacity(logoOpacity)
            .offset(y: logoLift)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.8)) {
                logoScale = 1.0
                logoOpacity = 1.0
                logoLift = 0
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(.easeInOut(duration: 0.5)) {
                    showSplash = false
                }
            }
        }
    }
}

private struct QuickStartPage: Identifiable {
    let id: Int
    let icon: String
    let title: String
    let lines: [String]
}

struct QuickStartView: View {
    let onFinish: () -> Void

    @State private var currentPage = 0

    private let pages = [
        QuickStartPage(
            id: 0,
            icon: "camera.viewfinder",
            title: "Capture Clean Takes",
            lines: [
                "Use one drill per take.",
                "Keep the camera steady.",
                "Record clean, repeatable movements."
            ]
        ),
        QuickStartPage(
            id: 1,
            icon: "slider.horizontal.3",
            title: "Check Your Setup",
            lines: [
                "Route deck audio into ScratchLab.",
                "Keep both decks and mixer visible.",
                "Wear the motion device on your active hand."
            ]
        ),
        QuickStartPage(
            id: 2,
            icon: "record.circle",
            title: "Record Your Take",
            lines: [
                "Pause before starting.",
                "Perform your drill.",
                "Stop and review."
            ]
        )
    ]

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ScratchLabDesign.Surface.applicationBackground
                    .ignoresSafeArea()

                VStack(spacing: ScratchLabDesign.Spacing.lg) {
                    HStack {
                        if currentPage > 0 {
                            Button("Back") {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    currentPage -= 1
                                }
                            }
                            .scratchLabTertiaryButton()
                            .frame(minWidth: 64, alignment: .leading)
                            .accessibilityLabel("Back")
                        } else {
                            Color.clear
                                .frame(width: 64)
                                .accessibilityHidden(true)
                        }

                        Spacer()

                        HStack(spacing: ScratchLabDesign.Spacing.sm) {
                            Image("ScratchLabLogo")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 32, height: 32)
                                .accessibilityHidden(true)

                            Text("ScratchLab")
                                .font(ScratchLabDesign.Typo.title3)
                                .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                        }

                        Spacer()

                        Button("Skip") {
                            onFinish()
                        }
                        .scratchLabTertiaryButton()
                        .frame(minWidth: 64, alignment: .trailing)
                        .accessibilityLabel("Skip Quick Start")
                    }
                    .padding(.horizontal, ScratchLabDesign.Spacing.xxl)
                    .padding(.top, ScratchLabDesign.Spacing.lg)

                    QuickStartProgressView(
                        pageCount: pages.count,
                        currentPage: currentPage
                    )

                    TabView(selection: $currentPage) {
                        ForEach(pages) { page in
                            QuickStartPageView(page: page)
                                .padding(.horizontal, ScratchLabDesign.Spacing.xxl)
                                .tag(page.id)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))

                    Button(action: advanceOrFinish) {
                        Text(currentPage == pages.count - 1 ? "Go to ScratchLab" : "Next")
                    }
                    .scratchLabPrimaryButton(fillsWidth: true)
                    .frame(maxWidth: 560)
                    .padding(.horizontal, ScratchLabDesign.Spacing.xxl)
                    .padding(.bottom, ScratchLabDesign.Spacing.xxl)
                    .accessibilityLabel(currentPage == pages.count - 1 ? "Go to ScratchLab" : "Next quick start page")
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
    }

    private func advanceOrFinish() {
        guard currentPage < pages.count - 1 else {
            onFinish()
            return
        }

        withAnimation(.easeInOut(duration: 0.25)) {
            currentPage += 1
        }
    }
}

private struct QuickStartProgressView: View {
    let pageCount: Int
    let currentPage: Int

    var body: some View {
        HStack(spacing: ScratchLabDesign.Spacing.sm) {
            ForEach(0..<pageCount, id: \.self) { page in
                Capsule()
                    .fill(progressColor(for: page))
                    .frame(width: page == currentPage ? 32 : 20, height: 4)
                    .animation(.easeInOut(duration: 0.2), value: currentPage)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Quick Start progress")
        .accessibilityValue("Step \(currentPage + 1) of \(pageCount)")
    }

    private func progressColor(for page: Int) -> Color {
        if page < currentPage {
            return ScratchLabDesign.Sem.success
        }
        if page == currentPage {
            return ScratchLabDesign.Sem.accent
        }
        return ScratchLabDesign.Surface.disabledFill
    }
}

private struct QuickStartPageView: View {
    let page: QuickStartPage

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            let usesWidePortraitLayout = !isLandscape && geometry.size.width >= 700

            Group {
                if isLandscape && !dynamicTypeSize.isAccessibilitySize {
                    landscapeContent
                } else {
                    ScrollView(showsIndicators: false) {
                        if isLandscape || usesWidePortraitLayout {
                            HStack(alignment: .center, spacing: ScratchLabDesign.Spacing.xxxl) {
                                introduction(isCompact: isLandscape)
                                    .frame(maxWidth: isLandscape ? 220 : 260)

                                instructions(isCompact: isLandscape)
                                    .frame(maxWidth: isLandscape ? 520 : 440)
                            }
                            .frame(maxWidth: 800)
                            .frame(maxWidth: .infinity, minHeight: isLandscape ? 180 : 360)
                            .padding(.vertical, isLandscape ? ScratchLabDesign.Spacing.sm : ScratchLabDesign.Spacing.xl)
                        } else {
                            VStack(spacing: ScratchLabDesign.Spacing.xxl) {
                                introduction(isCompact: false)
                                instructions(isCompact: false)
                            }
                            .frame(maxWidth: 760)
                            .frame(maxWidth: .infinity, minHeight: 360)
                            .padding(.vertical, ScratchLabDesign.Spacing.xl)
                        }
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var landscapeContent: some View {
        HStack(alignment: .center, spacing: ScratchLabDesign.Spacing.xxxl) {
            introduction(isCompact: true)
                .frame(maxWidth: 220)

            instructions(isCompact: true)
                .frame(maxWidth: 520)
        }
        .frame(maxWidth: 800)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, ScratchLabDesign.Spacing.sm)
    }

    private func introduction(isCompact: Bool) -> some View {
        VStack(spacing: isCompact ? ScratchLabDesign.Spacing.md : ScratchLabDesign.Spacing.lg) {
            Image(systemName: page.icon)
                .font(.system(size: isCompact ? 26 : 36, weight: .semibold))
                .foregroundStyle(ScratchLabDesign.Sem.accent)
                .frame(width: isCompact ? 52 : 72, height: isCompact ? 52 : 72)
                .background(
                    ScratchLabDesign.Sem.accent.opacity(0.12),
                    in: RoundedRectangle(
                        cornerRadius: isCompact ? ScratchLabDesign.Radius.card : ScratchLabDesign.Radius.hero,
                        style: .continuous
                    )
                )
                .accessibilityHidden(true)

            Text(page.title)
                .font(isCompact ? ScratchLabDesign.Typo.title2 : ScratchLabDesign.Typo.title1)
                .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(page.title)
        }
        .frame(maxWidth: .infinity)
    }

    private func instructions(isCompact: Bool) -> some View {
        VStack(spacing: isCompact ? ScratchLabDesign.Spacing.sm : ScratchLabDesign.Spacing.lg) {
            ForEach(page.lines, id: \.self) { line in
                HStack(alignment: .top, spacing: ScratchLabDesign.Spacing.md) {
                    Circle()
                        .fill(ScratchLabDesign.Sem.accent)
                        .frame(width: ScratchLabDesign.Spacing.sm, height: ScratchLabDesign.Spacing.sm)
                        .padding(.top, ScratchLabDesign.Spacing.xs)
                        .accessibilityHidden(true)

                    Text(line)
                        .font(ScratchLabDesign.Typo.bodyDefault)
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)
                }
            }
        }
        .padding(isCompact ? ScratchLabDesign.Card.compactPadding : ScratchLabDesign.Card.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ScratchLabDesign.Surface.card,
            in: RoundedRectangle(
                cornerRadius: isCompact ? ScratchLabDesign.Card.compactCornerRadius : ScratchLabDesign.Card.cornerRadius,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: isCompact ? ScratchLabDesign.Card.compactCornerRadius : ScratchLabDesign.Card.cornerRadius,
                style: .continuous
            )
            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }
}

// MARK: - Color Extension
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

#if DEBUG
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(GameState())
            .environmentObject(AudioEngine())
            .environmentObject(ProgressManager())
            .environmentObject(WatchMotionCaptureStore())
    }
}
#endif
