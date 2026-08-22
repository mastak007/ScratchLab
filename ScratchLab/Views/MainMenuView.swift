// MainMenuView.swift
// ScratchLab - Main Menu
// Primary companion home for capture and monitoring

import SwiftUI
import UIKit
import Network

struct MainMenuView: View {
    @EnvironmentObject var progressManager: ProgressManager
    @EnvironmentObject var companionRelayBroadcaster: CompanionCameraBroadcaster
    @EnvironmentObject var watchMotionCaptureStore: WatchMotionCaptureStore
    @EnvironmentObject var audioEngine: AudioEngine
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var showingProfile = false
    @State private var showingSettings = false
    @State private var showingPracticeHub = false
    @State private var showingCaptureHub = false
    @State private var showingAdvancedHub = false

    private var layoutMode: ScratchLabAdaptiveLayout.LayoutMode {
        ScratchLabAdaptiveLayout.layoutMode(
            horizontalSizeClass: horizontalSizeClass ?? .compact,
            verticalSizeClass: verticalSizeClass ?? .regular
        )
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                BackgroundView()

                if layoutMode == .regularLandscape {
                    HStack(spacing: 0) {
                        AdaptiveSidebarView(
                            showingPracticeHub: $showingPracticeHub,
                            showingAdvancedHub: $showingAdvancedHub
                        )
                        .frame(width: 240)
                        Divider().overlay(Color.white.opacity(0.08))

                        homeScrollContent(geometry: geometry)
                    }
                } else {
                    homeScrollContent(geometry: geometry)
                }
            }
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $showingProfile) {
            ProfileView()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .onAppear {
            if progressManager.playerProfile == nil {
                progressManager.createProfile(displayName: "New DJ")
            }
        }
        .fullScreenCover(isPresented: $showingPracticeHub) {
            PracticeModeView(
                scratch: ScratchLibrary.shared.scratch(byID: "baby_scratch") ?? ScratchLibrary.shared.allScratches[0],
                usesSimplifiedReady: true
            )
            .environmentObject(audioEngine)
            .environmentObject(progressManager)
        }
        .navigationDestination(isPresented: $showingAdvancedHub) {
            AdvancedHubView()
        }
        .navigationDestination(isPresented: $showingCaptureHub) {
            if ProcessInfo.processInfo.isiOSAppOnMac {
                UnsupportedCompanionCameraView()
            } else {
                CompanionCameraView()
            }
        }
    }

    // The Home body shared by every adaptive mode — a sidebar frames it on
    // regular landscape (Figma 34:2), and it stands alone in portrait/compact.
    private func homeScrollContent(geometry: GeometryProxy) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.itemRow) {
                headerView
                homeContent
            }
            .padding(.horizontal, 20)
            .padding(.top, geometry.safeAreaInsets.top + 12)
            .padding(.bottom, max(geometry.safeAreaInsets.bottom, 16) + 28)
        }
    }

    // MARK: - Header
    
    private var headerView: some View {
        VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.itemTight) {
            HStack(spacing: 12) {
                Button(action: { showingProfile = true }) {
                    HStack(spacing: 8) {
                        Text(progressManager.playerProfile?.avatarEmoji ?? "🎧")
                            .font(.system(size: 20))
                        Text(progressManager.playerProfile?.displayName ?? "New DJ")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
                }
                .accessibilityLabel("Profile: \(progressManager.playerProfile?.displayName ?? "New DJ")")

                Spacer()

                Button(action: { showingSettings = true }) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                }
                .accessibilityLabel("Settings")
            }

            // V3.2 Home brand block — matches the approved Figma "iPhone / Home"
            // frame (node 33:2). Reuses the shared page-title/subtitle tokens
            // rather than Figma's literal 30px/14px-regular values, per the
            // instruction to prefer the design system's semantic hierarchy
            // over pixel-exact one-off sizes.
            Text("ScratchLab")
                .font(ScratchLabDesign.Typo.pageTitle)
                .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

            Text("Hear it. See the notation. Copy it.")
                .font(ScratchLabDesign.Typo.pageSubtitle)
                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
        }
    }

    // MARK: - V3.2 Home content (Figma node 33:2)

    /// The Home body: a lesson-focused Practice hero matching macOS's Current
    /// Lesson hierarchy, an entry into the existing on-device Capture flow,
    /// an entry into Review, an entry into the existing Advanced / Mac
    /// Companion hub, a Recent result card driven by real session history,
    /// and a Device status card driven by real audio-engine state. Camera
    /// and DVS/timecode sync are described with static, honest copy — camera
    /// is genuinely optional for Practice and DVS sync is genuinely not part
    /// of the iPhone flow in this app (a macOS + controller workflow), so
    /// neither line is a placeholder or an invented capability claim.
    private var homeContent: some View {
        VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.itemRow) {
            practiceEntryCard

            captureEntryCard

            reviewEntryCard

            advancedEntryCard

            HomeInfoCard(title: "Recent result", detail: recentResultDetail)

            HomeInfoCard(title: "Device status", detail: deviceStatusDetail)
        }
    }

    /// iOS entry counterpart of macOS's `practiceHeaderCard`: one coherent
    /// Current Lesson card instead of a detached information card and generic
    /// button. Readiness badges use only state already available on Home; the
    /// existing Practice destination remains the sole owner of session setup.
    private var practiceEntryCard: some View {
        VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.cardSection) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.itemTight) {
                    Text("CURRENT LESSON")
                        .font(ScratchLabDesign.Typo.metricLabel)
                        .foregroundStyle(ScratchLabDesign.Sem.accent)

                    Label("Baby Scratch", systemImage: "figure.disc.sports")
                        .font(ScratchLabDesign.Typo.pageTitle)
                        .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

                    Text("One smooth push forward, one smooth pull back, with the fader open.")
                        .font(ScratchLabDesign.Typo.body)
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Label("Beginner", systemImage: "graduationcap.fill")
                    .font(ScratchLabDesign.Typo.statusPill)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 88), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                StatusBadge(
                    title: "Audio",
                    value: audioEngine.isRunning ? "Ready" : "Set up in Practice",
                    variant: audioEngine.isRunning ? .success : .ready,
                    systemImage: "waveform"
                )
                StatusBadge(
                    title: "Results",
                    value: progressManager.sessionHistory.isEmpty ? "None yet" : "Saved",
                    variant: progressManager.sessionHistory.isEmpty ? .neutral : .success,
                    systemImage: progressManager.sessionHistory.isEmpty ? "circle.dashed" : "checkmark.seal.fill"
                )
                StatusBadge(
                    title: "Hardware",
                    value: "Optional",
                    variant: .neutral,
                    systemImage: "cable.connector"
                )
            }

            Text("Mic or wired USB input · session results stay on device.")
                .font(ScratchLabDesign.Typo.bodySecondary)
                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)

            Button(action: { showingPracticeHub = true }) {
                Label("Start practice", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .scratchLabPrimaryButton(fillsWidth: true)
            .accessibilityHint("Opens the Baby Scratch practice lesson")
        }
        .scratchLabCard(.lessonHero)
    }

    /// Mobile counterpart of macOS's Capture Session header. This opens the
    /// existing guided capture implementation; setup and readiness remain
    /// owned by that flow so Home does not duplicate capture configuration.
    private var captureEntryCard: some View {
        VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.cardSection) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.itemTight) {
                    Text("CAPTURE")
                        .font(ScratchLabDesign.Typo.metricLabel)
                        .foregroundStyle(ScratchLabDesign.Sem.accent)

                    Label("Capture Session", systemImage: "record.circle")
                        .font(ScratchLabDesign.Typo.cardHeading)
                        .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

                    Text("Record clean takes with simple choices. Input routing, calibration, and raw details live in Advanced.")
                        .font(ScratchLabDesign.Typo.body)
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                StatusBadge(
                    title: "Audio",
                    value: audioEngine.isRunning ? "Ready" : "Check in Capture",
                    variant: audioEngine.isRunning ? .success : .ready,
                    systemImage: "waveform"
                )
            }

            Text("Camera, audio, and optional Watch motion are checked before recording.")
                .font(ScratchLabDesign.Typo.bodySecondary)
                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)

            Button(action: { showingCaptureHub = true }) {
                Label("Open Capture", systemImage: "arrow.right")
                    .frame(maxWidth: .infinity)
            }
            .scratchLabSecondaryButton(fillsWidth: true)
            .accessibilityHint("Opens guided session setup and recording controls")
        }
        .scratchLabCard(.standard)
    }

    /// Review on iOS is the real post-recording stage owned by
    /// `CompanionCameraView`; there is not yet a persisted standalone take
    /// browser. Keep the Home entry honest by sending the user into Capture,
    /// where every completed take proceeds directly to Review.
    private var reviewEntryCard: some View {
        VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.cardSection) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.itemTight) {
                    Text("REVIEW")
                        .font(ScratchLabDesign.Typo.metricLabel)
                        .foregroundStyle(ScratchLabDesign.Sem.accent)

                    Label("Review Take", systemImage: "checkmark.seal")
                        .font(ScratchLabDesign.Typo.cardHeading)
                        .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

                    Text("Check sync, audio, motion, quality, and take details immediately after recording.")
                        .font(ScratchLabDesign.Typo.body)
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                StatusBadge(
                    title: "Available",
                    value: "After Capture",
                    variant: .neutral,
                    systemImage: "arrow.turn.down.right"
                )
            }

            Text("Finish a take in Capture to open its Review screen automatically.")
                .font(ScratchLabDesign.Typo.bodySecondary)
                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)

            Button(action: { showingCaptureHub = true }) {
                Label("Capture a take to review", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .scratchLabSecondaryButton(fillsWidth: true)
            .accessibilityHint("Opens Capture; Review follows after recording a take")
        }
        .scratchLabCard(.standard)
    }

    /// Entry into the existing `AdvancedHubView` — the same destination the
    /// iPad regular-landscape sidebar already links to via `showingAdvancedHub`
    /// (`AdaptiveSidebarView`, below). This card replaces the old de-emphasized
    /// footer link so Advanced/Mac Companion has one Home-reachable entry
    /// point instead of two; it does not introduce a second Advanced surface.
    /// Copy names only what `AdvancedHubView` actually contains today (Mac
    /// relay, audio hardware routing, Watch Capture, Companion Camera,
    /// Performer Monitor) and the Mac badge reflects the same live
    /// `companionRelayBroadcaster.connectedPeerNames` state `relayActiveCard`
    /// already uses.
    private var advancedEntryCard: some View {
        VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.cardSection) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.itemTight) {
                    Text("ADVANCED")
                        .font(ScratchLabDesign.Typo.metricLabel)
                        .foregroundStyle(ScratchLabDesign.Sem.accent)

                    Label("Advanced / Mac Companion", systemImage: "slider.horizontal.3")
                        .font(ScratchLabDesign.Typo.cardHeading)
                        .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

                    Text("Mac relay, audio hardware routing, Watch Capture, Companion Camera, and Performer Monitor tools live here.")
                        .font(ScratchLabDesign.Typo.body)
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                StatusBadge(
                    title: "Mac",
                    value: companionRelayBroadcaster.connectedPeerNames.isEmpty ? "Not linked" : "Linked",
                    variant: companionRelayBroadcaster.connectedPeerNames.isEmpty ? .neutral : .success,
                    systemImage: "bolt.horizontal"
                )
            }

            Text("Optional tools for Mac-connected capture and DJ hardware setup.")
                .font(ScratchLabDesign.Typo.bodySecondary)
                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)

            Button(action: { showingAdvancedHub = true }) {
                Label("Open Advanced", systemImage: "arrow.right")
                    .frame(maxWidth: .infinity)
            }
            .scratchLabSecondaryButton(fillsWidth: true)
            .accessibilityHint("Opens Mac relay, audio routing, Watch Capture, Companion Camera, and Performer Monitor tools")
        }
        .scratchLabCard(.standard)
    }

    /// Most recent real session, or an honest first-run message — never a
    /// fabricated score. Matches the codebase's existing accuracy convention
    /// (already 0–100, e.g. `LevelSelectView.swift` `bestAccuracy`/`comboAccuracy`
    /// usages) — no additional ×100 scaling.
    private var recentResultDetail: String {
        guard let recent = progressManager.sessionHistory.max(by: { $0.timestamp < $1.timestamp }) else {
            return "No sessions yet — practice once to see your result here."
        }
        let name = recent.scratchName ?? "Scratch"
        let percent = Int(recent.finalAccuracy.rounded())
        let relative = RelativeDateTimeFormatter().localizedString(for: recent.timestamp, relativeTo: Date())
        return "\(name) · \(percent)% · \(relative)"
    }

    /// Audio reflects the real, live `AudioEngine.isRunning` signal. Camera
    /// and sync are static, accurate architectural facts (see doc comment
    /// on `homeContent`), not derived from a live capability check.
    private var deviceStatusDetail: String {
        let audioPart = audioEngine.isRunning ? "Audio ready" : "Audio idle"
        return "\(audioPart) · camera optional · sync off"
    }

    // MARK: - Menu Buttons

    // V3.2: Home's card list (Practice/Capture/Review) is retired as separate
    // legacy-style entries. "Practice" duplicated the V3.2 Practice button in
    // `homeContent`, which already routes to the same `showingPracticeHub`
    // destination. Capture/Review were DEBUG-only placeholders — Figma's
    // approved Home explicitly states they must not appear as active V3.2
    // Home cards, so they're no longer Home-reachable (their placeholder
    // destinations are untouched; this only removes the premature entry
    // point). Advanced/Mac Companion is real, currently-shipping
    // functionality (Demo Mode, Watch Capture, Companion Cam, Performer
    // Monitor) — it now has its own Home card (`advancedEntryCard`, above)
    // instead of the de-emphasized footer link this section used to hold, so
    // there is exactly one Home entry point into `AdvancedHubView`.

    private var performerMonitorSubtitle: String {
        "Receive deck view on this device"
    }

    private var performerMonitorIcon: String {
        UIDevice.current.userInterfaceIdiom == .pad
            ? "ipad.landscape.badge.play"
            : "iphone.badge.play"
    }

    private var watchRelayStatusText: String {
        if companionRelayBroadcaster.connectedPeerNames.isEmpty {
            return "The iPhone relay is active. Open ScratchLab on macOS and connect Companion Camera when you want watch motion files to bounce back to the Mac."
        }

        if watchMotionCaptureStore.isWatchReachable {
            return "Relay is live between Mac and Watch. Mac record commands can start watch capture, and imported watch motion will return through this iPhone."
        }

        return "Mac relay is connected, but the watch is not currently reachable. Keep the watch app open and the devices nearby for live motion capture."
    }
}

private struct UnsupportedCompanionCameraView: View {
    var body: some View {
        ZStack {
            BackgroundView()

            VStack(alignment: .leading, spacing: 16) {
                Text("Companion Camera Unavailable")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.white)

                Text("This iOS app running on Mac does not support the iPhone companion-camera capture flow. Use the ScratchLab desktop app on macOS for camera capture and routine recording.")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
        }
        .navigationTitle("Companion Camera")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// Retained future placeholders (currently unreferenced): Capture and Review
// are intentionally absent from the V3.2 production Home, but their "coming
// soon" views and copy are kept so the future mobile Capture/Review surfaces
// have a ready entry point to re-wire. No production route reaches them today.
private struct CapturePlaceholderView: View {
    var body: some View {
        ZStack {
            BackgroundView()

            VStack(alignment: .leading, spacing: 20) {
                Text("Capture")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.white)

                Text("On-device take capture is coming. For now, use Mac Companion capture tools under Advanced.")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)

                NavigationLink {
                    AdvancedHubView()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 14, weight: .bold))
                        Text("Open Mac Companion Tools")
                            .font(.system(size: 15, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )
                }
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
        }
        .navigationTitle("Capture")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ReviewPlaceholderView: View {
    var body: some View {
        ZStack {
            BackgroundView()

            VStack(alignment: .leading, spacing: 20) {
                Text("Review")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.white)

                Text("On-device Review is coming. Full take review currently runs on the ScratchLab Mac app.")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AdvancedHubView: View {
    @EnvironmentObject private var companionRelayBroadcaster: CompanionCameraBroadcaster
    @EnvironmentObject private var watchMotionCaptureStore: WatchMotionCaptureStore
    @EnvironmentObject private var audioEngine: AudioEngine
    @AppStorage("localNetworkRationaleAccepted") private var localNetworkRationaleAccepted = false

    @State private var showingDemoMode = false
    @State private var showingCompanionCam = false
    @State private var showingPerformerMonitor = false
    @State private var showingWatchCapture = false
    @State private var showingCoachPreview = false
    @State private var showingPracticeModes = false
    #if DEBUG
    @State private var showingVirtualPlatterPrototype = false
    #endif

    private var isIOSAppOnMac: Bool {
        ProcessInfo.processInfo.isiOSAppOnMac
    }

    var body: some View {
        ZStack {
            BackgroundView()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    AudioHardwareInputCard(
                        routeState: audioEngine.audioHardwareRouteState,
                        onSelectStereoPair: { audioEngine.selectStereoPair($0) }
                    )
                    relayStatusCard
                    advancedMenuButtons
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("Advanced / Mac Companion")
        .navigationBarTitleDisplayMode(.inline)
        #if DEBUG && canImport(RealityKit)
        .sheet(isPresented: $showingCoachPreview) {
            NavigationStack {
                CoachPreviewView()
            }
        }
        #endif
        .navigationDestination(isPresented: $showingDemoMode) {
            DemoModeView()
        }
        .navigationDestination(isPresented: $showingPracticeModes) {
            LevelSelectView()
        }
        #if DEBUG
        .navigationDestination(isPresented: $showingVirtualPlatterPrototype) {
            VirtualPlatterPrototypeView()
        }
        #endif
        .navigationDestination(isPresented: $showingCompanionCam) {
            if isIOSAppOnMac {
                UnsupportedCompanionCameraView()
            } else {
                CompanionCameraView()
            }
        }
        .navigationDestination(isPresented: $showingWatchCapture) {
            WatchCaptureHubView()
        }
        .navigationDestination(isPresented: $showingPerformerMonitor) {
            IPadPerformerMonitorView()
        }
    }

    private var relayStatusCard: some View {
        Group {
            if localNetworkRationaleAccepted {
                relayActiveCard
            } else {
                localNetworkRationaleCard
            }
        }
    }

    private var localNetworkRationaleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MAC & COMPANION CONNECTION")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(hex: "A78BFA"))

            Text("Local network access lets ScratchLab find your Mac or companion device on your Wi-Fi. Nothing is uploaded.")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.86))
                .fixedSize(horizontal: false, vertical: true)

            Button {
                localNetworkRationaleAccepted = true
                companionRelayBroadcaster.startRelayAdvertisingIfNeeded()
            } label: {
                Text("Connect to Mac")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(height: 36)
                    .frame(maxWidth: .infinity)
                    .background(Color(hex: "A78BFA"))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(hex: "A78BFA").opacity(0.3), lineWidth: 1)
        )
    }

    private var relayActiveCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WATCH RELAY")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(hex: "A78BFA"))

            Text(watchRelayStatusText)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.86))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                StatusBadge(
                    title: "Relay",
                    value: companionRelayBroadcaster.connectedPeerNames.isEmpty ? "Waiting for Mac" : "Mac linked",
                    variant: companionRelayBroadcaster.connectedPeerNames.isEmpty ? .neutral : .success,
                    systemImage: "bolt.horizontal"
                )
                StatusBadge(
                    title: "Watch",
                    value: watchMotionCaptureStore.isWatchReachable ? "Reachable" : "Not reachable",
                    variant: watchMotionCaptureStore.isWatchReachable ? .success : .neutral,
                    systemImage: "applewatch.side.right"
                )
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var advancedMenuButtons: some View {
        VStack(spacing: 16) {
            MenuButton(
                title: "Practice modes",
                subtitle: "Full setup: beat/BPM, assist modes, Chirp Flare, and the Baby Flow combo challenge.",
                icon: "waveform",
                accent: Color(hex: "22C55E"),
                action: { showingPracticeModes = true }
            )

            MenuButton(
                title: "Try Demo",
                subtitle: "See scratch feedback instantly",
                icon: "play.circle.fill",
                accent: ScratchLabDesign.Sem.accent,
                action: { showingDemoMode = true }
            )

            MenuButton(
                title: "Companion Camera",
                subtitle: isIOSAppOnMac
                    ? "Use ScratchLabDesktop on Mac for capture. Companion Camera is for iPhone hardware."
                    : "Send deck video to your main device",
                icon: "iphone.gen3.radiowaves.left.and.right",
                accent: Color(hex: "F59E0B"),
                action: { showingCompanionCam = true }
            )

            MenuButton(
                title: "Performer Monitor",
                subtitle: performerMonitorSubtitle,
                icon: performerMonitorIcon,
                accent: Color(hex: "0EA5E9"),
                action: { showingPerformerMonitor = true }
            )

            MenuButton(
                title: "Watch Capture",
                subtitle: "Import wrist motion and relay it back to Mac capture",
                icon: "applewatch.side.right",
                accent: Color(hex: "6366F1"),
                action: { showingWatchCapture = true }
            )

            #if DEBUG
            developerSectionHeader

            #if canImport(RealityKit)
            MenuButton(
                title: "3D Coach Demo",
                subtitle: "Preview the 3D coach model animation",
                icon: "cube.transparent",
                accent: Color(hex: "8B5CF6"),
                action: { showingCoachPreview = true }
            )
            #endif

            MenuButton(
                title: "Virtual Platter Prototype",
                subtitle: "Developer-only scratch-on-glass slice (no capture/ML)",
                icon: "circle.circle",
                accent: Color(hex: "F59E0B"),
                action: { showingVirtualPlatterPrototype = true }
            )
            #endif
        }
    }

    #if DEBUG
    // Visually separates developer/experimental tools from the production
    // menu above so a DEBUG build doesn't read as a developer menu end to
    // end. Compiles out entirely in Release — the cards below it already
    // do too, this only adds the divider/label around them. Reuses the
    // existing card-heading + secondary-body tokens (see `MenuButton`
    // above) rather than introducing a new style.
    private var developerSectionHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("DEVELOPER")
                .font(ScratchLabDesign.Typo.sectionLabel)
                .foregroundStyle(ScratchLabDesign.Sem.warning)
            Text("Experimental tools")
                .font(ScratchLabDesign.Typo.caption)
                .foregroundStyle(ScratchLabDesign.Sem.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, ScratchLabDesign.Spacing.xs)
    }
    #endif

    private var watchRelayStatusText: String {
        if companionRelayBroadcaster.connectedPeerNames.isEmpty {
            return "The iPhone relay is active. Open ScratchLab on macOS and connect Companion Camera when you want watch motion files to bounce back to the Mac."
        }
        if watchMotionCaptureStore.isWatchReachable {
            return "Relay is live between Mac and Watch. Mac record commands can start watch capture, and imported watch motion will return through this iPhone."
        }
        return "Mac relay is connected, but the watch is not currently reachable. Keep the watch app open and the devices nearby for live motion capture."
    }

    private var performerMonitorSubtitle: String {
        "Receive deck view on this device"
    }

    private var performerMonitorIcon: String {
        UIDevice.current.userInterfaceIdiom == .pad
            ? "ipad.landscape.badge.play"
            : "iphone.badge.play"
    }
}

private struct DemoModeView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var demoController = ScratchLabDemoModeController()
    @StateObject private var exportCoordinator = SessionExportCoordinator()
    @State private var isBuildingExportPackage = false

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

    private var exportShareRequestBinding: Binding<SessionShareRequest?> {
        Binding(
            get: { exportCoordinator.shareRequest },
            set: { exportCoordinator.shareRequest = $0 }
        )
    }

    private var motionBalanceText: String {
        demoController.motionFeedback?.balance.rawValue ?? ScratchMotionBalance.listening.rawValue
    }

    private var motionBalanceColor: Color {
        switch demoController.motionFeedback?.balance ?? .listening {
        case .listening:
            return Color(hex: "38BDF8")
        case .balanced:
            return Color(hex: "22C55E")
        case .unbalanced:
            return Color(hex: "EF4444")
        }
    }

    private var timingErrorText: String {
        guard let timingErrorMilliseconds = demoController.motionFeedback?.timingErrorMilliseconds else {
            return "Analyzing"
        }
        return "\(timingErrorMilliseconds) ms"
    }

    private var exportButtonTitle: String {
        if isBuildingExportPackage || exportCoordinator.isPreparing {
            return "Preparing ZIP"
        }
        return "Export Demo ZIP"
    }

    private var exportStatusText: String {
        if let statusMessage = exportCoordinator.statusMessage {
            return statusMessage
        }
        return "Scratch Only export is ready for this demo session."
    }

    var body: some View {
        ZStack {
            BackgroundView()

            ScrollView(showsIndicators: true) {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    feedbackCard
                    // 2D Coach Rig quarantined from the Try-Demo surface — the
                    // rig's animation no longer matches the notation lane's
                    // SXRATCH-style continuous timeline, so showing it here
                    // makes the demo feel inconsistent. The `coachCard`
                    // property and `ScratchCoachCardContent` view are kept
                    // defined (no code deleted, so the rig can be brought
                    // back into a different surface) — only the mount is
                    // removed from this surface.
                    exportCard
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 32)
            }
        }
        .navigationBarHidden(true)
        .background(
            SessionSharePresenter(
                request: exportShareRequestBinding,
                onPresented: {
                    exportCoordinator.markSharePresented()
                },
                onOutcome: { outcome in
                    exportCoordinator.handleShareOutcome(outcome)
                }
            )
        )
        .onAppear {
            demoController.startDemo()
        }
        .onDisappear {
            demoController.stopDemo()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 42, height: 42)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                .accessibilityLabel("Back")

                Spacer()

                HStack(spacing: 7) {
                    Circle()
                        .fill(demoController.isReady ? Color(hex: "22C55E") : Color(hex: "F59E0B"))
                        .frame(width: 8, height: 8)

                    Text("Demo Mode")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white.opacity(0.76))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.08), in: Capsule())
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Try Demo")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundColor(.white)

                Text("Bundled baby scratch audio is playing through the feedback engine now.")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white.opacity(0.74))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                demoStatusBadge(label: "Audio", value: "Bundled WAV", color: ScratchLabDesign.Sem.accent)
                demoStatusBadge(label: "Hardware", value: "Not Required", color: Color(hex: "22C55E"))
            }
        }
    }

    private var feedbackCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Motion Feedback")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white.opacity(0.58))

                    Text(motionBalanceText)
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundColor(.white)
                }

                Spacer()

                ZStack {
                    Circle()
                        .stroke(motionBalanceColor.opacity(0.24), lineWidth: 9)
                        .frame(width: 82, height: 82)

                    Circle()
                        .trim(from: 0, to: CGFloat(max(0.08, min(1, demoController.inputLevel))))
                        .stroke(motionBalanceColor, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                        .frame(width: 82, height: 82)
                        .rotationEffect(.degrees(-90))

                    Image(systemName: "waveform")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(motionBalanceColor)
                }
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                demoMetric(title: "Direction", value: demoController.motionDirection.label)
                demoMetric(title: "Timing Error", value: timingErrorText)
            }

            Text(demoController.statusMessage)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.68))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(motionBalanceColor.opacity(0.32), lineWidth: 1)
        )
    }

    private var coachCard: some View {
        ScratchCoachCardContent(
            instruction: demoController.instruction,
            demoStatusMessage: "Coach animation follows the bundled baby scratch demo.",
            playbackTimeProvider: { demoController.demoPlayer.currentPlaybackTime },
            isPlayingProvider: { demoController.demoPlayer.isActivelyPlayingAudio },
            animationStateProvider: { playbackTime, isPlaying in
                demoController.coachAnimationState(
                    playbackTime: playbackTime,
                    isPlaying: isPlaying
                )
            },
            theme: theme
        ) {
            HStack(spacing: 10) {
                demoControlButton(
                    title: "Pause",
                    icon: "pause.fill",
                    enabled: demoController.demoPlayer.isPlaying,
                    action: demoController.pauseDemo
                )

                demoControlButton(
                    title: "Replay",
                    icon: "gobackward",
                    enabled: demoController.isReady,
                    action: demoController.replayDemo
                )
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private var exportCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Demo Export")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)

                    Text(exportStatusText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.68))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }

            Button(action: exportDemoSession) {
                HStack(spacing: 8) {
                    if isBuildingExportPackage || exportCoordinator.isPreparing {
                        ProgressView()
                            .tint(.black)
                            .controlSize(.small)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 14, weight: .bold))
                    }

                    Text(exportButtonTitle)
                        .font(.system(size: 14, weight: .bold))
                }
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(ScratchLabDesign.Sem.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .disabled(isBuildingExportPackage || exportCoordinator.isPreparing)
        }
        .padding(16)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private func exportDemoSession() {
        guard !isBuildingExportPackage, !exportCoordinator.isPreparing else { return }
        isBuildingExportPackage = true

        Task {
            do {
                let package = try await Task.detached(priority: .userInitiated) {
                    try ScratchLabDemoSessionBuilder().makePackage()
                }.value
                isBuildingExportPackage = false
                exportCoordinator.prepareShare(
                    for: .package(package),
                    options: SessionExportOptions(mixMode: .scratchOnly)
                )
            } catch {
                isBuildingExportPackage = false
                exportCoordinator.showFailure(.unableToPrepareExport)
            }
        }
    }

    private func demoStatusBadge(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.56))

            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func demoMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white.opacity(0.48))

            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func demoControlButton(
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
            .background(enabled ? ScratchLabDesign.Sem.accent : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .disabled(!enabled)
    }
}

// MARK: - Menu Button Component

// MARK: - Home info card (V3.2)

/// Small Home-specific presentation component matching the Figma
/// `SurfaceCard` contract (title + supporting detail, default/emphasized
/// tone) — built entirely from shared `ScratchLabDesign` tokens and the
/// existing `scratchLabCard(_:)` styles rather than a new bespoke theme.
/// Figma's own component description notes no 1:1 SurfaceCard code
/// component exists yet and screens build the equivalent inline; this is
/// that inline equivalent, factored out once since Home uses it three times.
// The regular-landscape navigation sidebar (Figma 34:2). Lists only real
// destinations — Practice and the Advanced hub — routing through the same
// state MainMenuView owns, so there is no duplicate navigation state.
private struct AdaptiveSidebarView: View {
    @Binding var showingPracticeHub: Bool
    @Binding var showingAdvancedHub: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ScratchLab")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

            Text("PRACTICE")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            sidebarLink("Practice", systemImage: "waveform") { showingPracticeHub = true }
            sidebarLink("Advanced / Mac Companion", systemImage: "slider.horizontal.3") { showingAdvancedHub = true }

            Spacer()

            Text("Capture and Review are intentionally absent until implemented.")
                .font(.caption)
                .foregroundStyle(ScratchLabDesign.Sem.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(ScratchLabDesign.Surface.card)
    }

    private func sidebarLink(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
        .accessibilityLabel(title)
    }
}

private struct HomeInfoCard: View {
    let title: String
    let detail: String
    var isEmphasized: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.itemTight) {
            Text(title)
                .font(ScratchLabDesign.Typo.cardHeading)
                .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
            Text(detail)
                .font(ScratchLabDesign.Typo.bodySecondary)
                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .scratchLabCard(isEmphasized ? .lessonHero : .standard)
        .accessibilityElement(children: .combine)
    }
}

struct MenuButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 16) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(accent.opacity(0.16))
                    .frame(width: 48, height: 48)
                    .overlay {
                        Image(systemName: icon)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(accent)
                    }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(ScratchLabDesign.Typo.cardHeading)
                        .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

                    Text(subtitle)
                        .font(ScratchLabDesign.Typo.bodySecondary)
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .scratchLabCard(.standard)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(subtitle)")
    }
}

// MARK: - Background View

struct BackgroundView: View {
    var body: some View {
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
}

// MARK: - Placeholder Views (to be implemented)

struct ProfileView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var progressManager: ProgressManager

    var body: some View {
        NavigationStack {
            ZStack {
                BackgroundView()

                VStack(spacing: 24) {
                    Text(progressManager.playerProfile?.avatarEmoji ?? "🎧")
                        .font(.system(size: 80))
                        .padding()
                        .background(Color.white.opacity(0.1))
                        .clipShape(Circle())

                    Text(progressManager.playerProfile?.displayName ?? "DJ")
                        .font(ScratchLabDesign.Typo.pageTitle)
                        .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

                    HStack(spacing: 8) {
                        StatusBadge(
                            title: "Level",
                            value: "\(progressManager.playerProfile?.level ?? 1)",
                            variant: .accent,
                            systemImage: "chart.bar.fill"
                        )
                        StatusBadge(
                            title: "Practice estimate",
                            value: "\(progressManager.playerProfile?.totalScore ?? 0)",
                            variant: .warning,
                            systemImage: "star.fill"
                        )
                    }

                    Spacer()
                }
                .padding(.top, 40)
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var audioEngine: AudioEngine
    @State private var selectedInput: AudioInputSource = .microphone
    
    var body: some View {
        NavigationStack {
            ZStack {
                BackgroundView()

                List {
                    Section("Audio Input") {
                        ForEach(visibleInputSources, id: \.self) { source in
                            Button(action: {
                                selectedInput = source
                                audioEngine.selectInputSource(source)
                            }) {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(source.rawValue)
                                            .foregroundColor(.white)
                                        Text(source.description)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if selectedInput == source {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(ScratchLabDesign.Sem.accent)
                                    }
                                }
                            }
                        }
                    }

                    Section("About") {
                        HStack {
                            Text("Version")
                            Spacer()
                            Text(appVersionLabel)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .onAppear {
                selectedInput = audioEngine.currentInputSource
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var visibleInputSources: [AudioInputSource] {
        AudioInputSource.allCases.filter { $0 != .djApp }
    }

    private var appVersionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

private struct PerformerMonitorZonePacket: Codable, Identifiable {
    let role: String
    let title: String
    let minX: Double
    let minY: Double
    let width: Double
    let height: Double

    var id: String { role }
}

private struct PerformerMonitorFramePacket: Codable {
    let timestamp: TimeInterval
    let jpegData: Data
    let guidanceCue: String
    let guidanceDetail: String
    let scratchStatusTitle: String
    let rigStatusTitle: String
    let audioPercent: String
    let detectionCount: Int
    let highlightedZoneRole: String
    let zones: [PerformerMonitorZonePacket]
}

private final class IPadPerformerMonitorReceiver: NSObject, ObservableObject {
    struct MacSummary: Identifiable, Equatable {
        let id: String
        let name: String
    }

    @Published var discoveredPeers: [MacSummary] = []
    @Published var connectedPeerNames: [String] = []
    @Published var connectionStatus = "Searching for nearby ScratchLab"
    @Published private(set) var latestFrameImage: UIImage?
    @Published private(set) var latestFramePacket: PerformerMonitorFramePacket?

    /// This device is a read-only monitor client — the Mac is the controlling
    /// device. A connected peer is `.controlledByMac`, never `.connected`.
    var state: PerformerMonitorConnectionState {
        connectedPeerNames.isEmpty
            ? PerformerMonitorConnectionState.disconnectedState(fromStatus: connectionStatus)
            : .controlledByMac
    }

    private let serviceType = "_scrmonfeed._tcp"
    private let defaultManualPort = NWEndpoint.Port(rawValue: 58585)!
    private let browserQueue = DispatchQueue(label: "scratchlab.ipad.performer.browser")
    private let decoder = PropertyListDecoder()
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var endpointLookup: [String: NWEndpoint] = [:]
    private var attemptedAutoConnectPeerIDs: Set<String> = []
    private let maxFrameSize = 6_000_000

    override init() {
        super.init()
        startBrowsing()
    }

    deinit {
        browser?.cancel()
        connection?.cancel()
    }

    func refresh() {
        disconnect()
        discoveredPeers = []
        endpointLookup.removeAll()
        latestFrameImage = nil
        latestFramePacket = nil
        attemptedAutoConnectPeerIDs.removeAll()
        startBrowsing()
        connectionStatus = "Searching for nearby ScratchLab"
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        connectedPeerNames = []
        latestFrameImage = nil
        latestFramePacket = nil
        connectionStatus = "Searching for nearby ScratchLab"
    }

    func connect(to peer: MacSummary) {
        guard let endpoint = endpointLookup[peer.id] else { return }
        connect(to: endpoint, displayName: peer.name)
    }

    func connect(hostname rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            connectionStatus = "Enter the connection name shown in ScratchLab"
            return
        }

        let pieces = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
        let hostPart = String(pieces.first ?? "")
        let normalizedHost = normalizedManualHost(hostPart)
        let port = manualPort(from: pieces.count > 1 ? String(pieces[1]) : nil)
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(normalizedHost), port: port)
        connect(to: endpoint, displayName: normalizedHost)
    }

    private func connect(to endpoint: NWEndpoint, displayName: String) {
        connection?.cancel()
        connectionStatus = "Connecting to \(displayName)"
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            DispatchQueue.main.async {
                switch state {
                case .setup, .preparing:
                    self.connectionStatus = "Connecting to \(displayName)"
                case .ready:
                    self.connectedPeerNames = [displayName]
                    self.connectionStatus = "Connected to \(displayName)"
                    self.receiveNextFrameLength(on: connection, peerName: displayName)
                case .waiting(let error):
                    print("Performer monitor waiting for \(displayName): \(error.localizedDescription)")
                    self.connectedPeerNames = []
                    self.connectionStatus = "Connection to \(displayName) paused. Check network."
                case .failed(let error):
                    print("Performer monitor connection failed for \(displayName): \(error.localizedDescription)")
                    self.connectedPeerNames = []
                    self.connectionStatus = "Connection to \(displayName) lost."
                case .cancelled:
                    self.connectedPeerNames = []
                    self.connectionStatus = "Searching for nearby ScratchLab"
                @unknown default:
                    self.connectionStatus = "Performer monitor connection changed"
                }
            }
        }
        connection.start(queue: browserQueue)
    }

    private func normalizedManualHost(_ rawHost: String) -> String {
        let host = rawHost.lowercased()
        if host.hasSuffix(".local") || host.contains(".") {
            return host
        }
        return "\(host).local"
    }

    private func manualPort(from rawPort: String?) -> NWEndpoint.Port {
        guard let rawPort,
              let portValue = UInt16(rawPort),
              let port = NWEndpoint.Port(rawValue: portValue) else {
            return defaultManualPort
        }
        return port
    }

    private func autoConnectIfNeeded() {
        guard connectedPeerNames.isEmpty else { return }
        guard discoveredPeers.count == 1, let onlyPeer = discoveredPeers.first else { return }
        guard !attemptedAutoConnectPeerIDs.contains(onlyPeer.id) else { return }

        attemptedAutoConnectPeerIDs.insert(onlyPeer.id)
        connect(to: onlyPeer)
    }

    private func startBrowsing() {
        browser?.cancel()
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: parameters)
        self.browser = browser

        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    if self.connectedPeerNames.isEmpty, self.discoveredPeers.isEmpty {
                        self.connectionStatus = "Searching for nearby ScratchLab"
                    }
                case .waiting(let error):
                    print("Performer monitor browse waiting: \(error.localizedDescription)")
                    self.connectionStatus = "Searching paused. Check network."
                case .failed(let error):
                    print("Performer monitor browse failed: \(error.localizedDescription)")
                    self.connectionStatus = "Unable to search for nearby device. Check network."
                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            let summaries = results.compactMap { result -> MacSummary? in
                guard case let .service(name: name, type: _, domain: _, interface: _) = result.endpoint else {
                    return nil
                }
                let id = result.endpoint.debugDescription
                return MacSummary(id: id, name: name.isEmpty ? "ScratchLab" : name)
            }
            .sorted { $0.name < $1.name }

            let nextLookup = Dictionary(uniqueKeysWithValues: results.map { ($0.endpoint.debugDescription, $0.endpoint) })

            DispatchQueue.main.async {
                self.discoveredPeers = summaries
                self.endpointLookup = nextLookup
                if self.connectedPeerNames.isEmpty {
                    self.connectionStatus = summaries.isEmpty
                        ? "Searching for nearby ScratchLab"
                        : "Found \(summaries.count == 1 ? summaries[0].name : "\(summaries.count) nearby ScratchLab devices"). Connect when ready."
                }
                self.autoConnectIfNeeded()
            }
        }

        browser.start(queue: browserQueue)
    }

    private func receiveNextFrameLength(on connection: NWConnection, peerName: String) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                print("Performer monitor frame header receive failed for \(peerName): \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.connectedPeerNames = []
                    self.connectionStatus = "Connection to \(peerName) lost."
                }
                return
            }

            guard let data, data.count == 4 else {
                if isComplete {
                    DispatchQueue.main.async {
                        self.connectedPeerNames = []
                        self.connectionStatus = "Searching for nearby ScratchLab"
                    }
                }
                return
            }

            let frameLength = data.withUnsafeBytes { rawBuffer -> Int in
                let value = rawBuffer.load(as: UInt32.self)
                return Int(UInt32(bigEndian: value))
            }
            self.receiveFrameBody(length: frameLength, on: connection, peerName: peerName)
        }
    }

    private func receiveFrameBody(length: Int, on connection: NWConnection, peerName: String) {
        guard length > 0, length <= maxFrameSize else {
            DispatchQueue.main.async {
                self.connectedPeerNames = []
                self.connectionStatus = "Received an invalid frame from \(peerName)"
            }
            return
        }

        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                print("Performer monitor frame receive failed for \(peerName): \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.connectedPeerNames = []
                    self.connectionStatus = "Connection to \(peerName) lost."
                }
                return
            }

            guard let data,
                  let packet = try? self.decoder.decode(PerformerMonitorFramePacket.self, from: data),
              let image = UIImage(data: packet.jpegData) else {
                if isComplete {
                    DispatchQueue.main.async {
                        self.connectedPeerNames = []
                        self.connectionStatus = "Searching for nearby ScratchLab"
                    }
                }
                return
            }

            DispatchQueue.main.async {
                self.latestFramePacket = packet
                self.latestFrameImage = image
                self.connectionStatus = "Connected to \(peerName)"
            }

            self.receiveNextFrameLength(on: connection, peerName: peerName)
        }
    }
}

private struct IPadPerformerMonitorView: View {
    @StateObject private var receiver = IPadPerformerMonitorReceiver()
    @State private var manualHost = ""

    var body: some View {
        ZStack {
            BackgroundView()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    performerHeader

                    if let image = receiver.latestFrameImage,
                       let packet = receiver.latestFramePacket {
                        IPadPerformerMonitorStage(image: image, packet: packet)
                    } else {
                        emptyStateCard
                    }

                    connectionCard
                    controlRow
                }
                .padding(24)
            }
        }
        .navigationTitle("Performer Monitor")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            receiver.refresh()
        }
    }

    // Figma Performer Monitor header (35:210 / 35:220): eyebrow + status badge
    // + headline. The real connection state drives the badge and headline.
    // This device is read-only and controlled by the Mac, so a connected peer
    // is labelled CONTROLLED BY MAC (never a fabricated transport capability).
    private var performerHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("PERFORMER MONITOR")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(ScratchLabDesign.Sem.accent)
                Spacer()
                StatusBadge(
                    title: "Status",
                    value: receiver.connectedPeerNames.isEmpty ? "Waiting" : PerformerMonitorConnectionState.controlledByMac.label,
                    variant: receiver.connectedPeerNames.isEmpty ? .neutral : .ready,
                    systemImage: receiver.connectedPeerNames.isEmpty ? "ipad.landscape" : "dot.radiowaves.left.and.right"
                )
            }
            Text(receiver.connectedPeerNames.isEmpty ? "Waiting for nearby ScratchLab" : "Read-only — controlled by Mac")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private var emptyStateCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("No nearby feed yet")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
            Text("1. Open ScratchLab on your main device running Serato.\n2. Stay on the analyzer screen or open Performer Monitor there.\n3. Keep both devices on the same local network.\n4. This screen auto-connects when the nearby feed appears.\n5. If Nearby ScratchLab stays empty, use Advanced connection.")
                .font(ScratchLabDesign.Typo.body)
                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 280, alignment: .leading)
        .scratchLabCard(.standard)
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(receiver.connectionStatus)
                .font(ScratchLabDesign.Typo.cardHeading)
                .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

            if !receiver.discoveredPeers.isEmpty && receiver.connectedPeerNames.isEmpty {
                ForEach(receiver.discoveredPeers) { peer in
                    HStack(spacing: 12) {
                        Text(peer.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white)
                        Spacer()
                        Button("Connect") { receiver.connect(to: peer) }
                            .scratchLabPrimaryButton()
                    }
                }
            }

            if receiver.connectedPeerNames.isEmpty {
                HStack(spacing: 10) {
                    TextField("Device name or address", text: $manualHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(12)
                    Button("Connect") { receiver.connect(hostname: manualHost) }
                        .scratchLabPrimaryButton()
                }
                Text("Use this only if nearby discovery does not find ScratchLab.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .scratchLabCard(.standard)
    }

    private var controlRow: some View {
        HStack(spacing: 12) {
            Button("Reconnect") { receiver.refresh() }
                .scratchLabPrimaryButton()
            Button("Disconnect") { receiver.disconnect() }
                .scratchLabSecondaryButton()
            Spacer()
        }
    }

}

private struct IPadPerformerMonitorStage: View {
    let image: UIImage
    let packet: PerformerMonitorFramePacket

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()

                ForEach(packet.zones) { zone in
                    zoneOverlay(zone, in: proxy.size)
                }

                VStack(alignment: .leading, spacing: 10) {
                    cuePill

                    HStack(spacing: 8) {
                        metricBadge(title: "Audio", value: packet.audioPercent)
                        metricBadge(title: "Matches", value: "\(packet.detectionCount)")
                    }
                }
                .padding(20)

                VStack(alignment: .leading, spacing: 6) {
                    Spacer()

                    Text(packet.scratchStatusTitle)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)

                    Text(packet.guidanceDetail)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.82))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
        .aspectRatio(imageAspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.55))
        .cornerRadius(20)
    }

    private var imageAspectRatio: CGFloat {
        let width = max(image.size.width, 1)
        let height = max(image.size.height, 1)
        return width / height
    }

    private var cuePill: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(highlightColor(for: packet.highlightedZoneRole))
                .frame(width: 10, height: 10)

            Text(packet.guidanceCue)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.62))
        .cornerRadius(18)
        .frame(maxWidth: 320)
    }

    private func metricBadge(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white.opacity(0.58))

            Text(value)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.62))
        .cornerRadius(14)
    }

    private func zoneOverlay(_ zone: PerformerMonitorZonePacket, in size: CGSize) -> some View {
        let zoneRect = CGRect(
            x: zone.minX * size.width,
            y: (1 - zone.minY - zone.height) * size.height,
            width: zone.width * size.width,
            height: zone.height * size.height
        )
        let isHighlighted = packet.highlightedZoneRole == zone.role
        let strokeColor = highlightColor(for: zone.role)

        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16)
                .stroke(strokeColor.opacity(isHighlighted ? 1 : 0.72), lineWidth: isHighlighted ? 4 : 2.5)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(strokeColor.opacity(isHighlighted ? 0.14 : 0.06))
                )

            Text(zone.title)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.72))
                .cornerRadius(12)
                .padding(10)
        }
        .frame(width: zoneRect.width, height: zoneRect.height)
        .position(x: zoneRect.midX, y: zoneRect.midY)
    }

    private func highlightColor(for role: String) -> Color {
        switch role {
        case "leftDeck":
            return Color(hex: "F59E0B")
        case "mixer":
            return Color(hex: "06B6D4")
        case "rightDeck":
            return Color(hex: "22C55E")
        default:
            return Color.white
        }
    }
}

// MARK: - Preview

#if DEBUG
struct MainMenuView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            MainMenuView()
        }
        .environmentObject(GameState())
        .environmentObject(AudioEngine())
        .environmentObject(ProgressManager())
    }
}
#endif
