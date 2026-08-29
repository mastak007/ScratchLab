// MainMenuView.swift
// ScratchLab - Main Menu
// Primary companion home for capture and monitoring

import SwiftUI
import UIKit
import Network

struct MainMenuView: View {
    private enum WorkspaceTab: Hashable {
        case home
        case practice
        case capture
        case review
        case advanced
    }

    @EnvironmentObject var progressManager: ProgressManager
    @EnvironmentObject var companionRelayBroadcaster: CompanionCameraBroadcaster
    @EnvironmentObject var watchMotionCaptureStore: WatchMotionCaptureStore
    @EnvironmentObject var audioEngine: AudioEngine
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showingProfile = false
    @State private var showingSettings = false
    @State private var showingPracticeHub = false
    @State private var showingCaptureHub = false
    @State private var showingAdvancedHub = false
    @State private var selectedWorkspaceTab: WorkspaceTab = .home

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                BackgroundView()
                if usesNavigationSidebar(in: geometry.size) {
                    HStack(spacing: 0) {
                        AdaptiveSidebarView(
                            showingPracticeHub: $showingPracticeHub,
                            showingCaptureHub: $showingCaptureHub,
                            showingAdvancedHub: $showingAdvancedHub
                        )
                        .frame(width: 240)

                        homeScrollContent(geometry: geometry)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    compactWorkspaceNavigation(geometry: geometry)
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

    /// The persistent workspace rail is an iPad regular-width pattern. A wide
    /// iPhone can exceed the raw point threshold in landscape, so device idiom
    /// and size class gate the rail before the available canvas is considered.
    private func usesNavigationSidebar(in size: CGSize) -> Bool {
        UIDevice.current.userInterfaceIdiom == .pad
            && horizontalSizeClass == .regular
            && size.width > size.height
            && size.width >= 760
    }

    /// Figma's compact workspace navigation maps to a real system `TabView`.
    /// Destination taps continue to use the app's established presentation
    /// routes, so Practice/Capture/Advanced keep their existing back and
    /// dismissal semantics rather than being duplicated as tab-root flows.
    private func compactWorkspaceNavigation(geometry: GeometryProxy) -> some View {
        TabView(selection: $selectedWorkspaceTab) {
            homeScrollContent(geometry: geometry)
                .tabItem { Label("Home", systemImage: "house") }
                .tag(WorkspaceTab.home)

            practiceWorkspaceLanding
                .tabItem { Label("Practice", systemImage: "waveform") }
                .tag(WorkspaceTab.practice)

            captureWorkspaceLanding
                .tabItem { Label("Capture", systemImage: "record.circle") }
                .tag(WorkspaceTab.capture)

            reviewWorkspaceLanding
                .tabItem { Label("Review", systemImage: "checkmark.seal") }
                .tag(WorkspaceTab.review)

            NavigationStack {
                AdvancedHubView()
            }
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
                .tag(WorkspaceTab.advanced)
        }
        .tabViewStyle(.sidebarAdaptable)
        .tint(ScratchLabDesign.Sem.accent)
    }

    private var practiceWorkspaceLanding: some View {
        WorkspaceLandingSurface(
            eyebrow: "PRACTICE",
            title: "Baby Scratch",
            subtitle: "Watch the target, hear the motion, then copy it.",
            status: "READY",
            primaryTitle: "Start session",
            primaryAction: { showingPracticeHub = true }
        ) {
            VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.sm) {
                Text("TARGET REFERENCE")
                    .font(ScratchLabDesign.Typo.metricLabel)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                Text("One smooth push forward and one smooth pull back. Keep the fader open for the whole cycle.")
                    .font(ScratchLabDesign.Typo.body)
                    .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Mic or wired USB input · results stay on device")
                    .font(ScratchLabDesign.Typo.caption)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
            }
            .scratchLabCard(.standard)
        }
    }

    private var captureWorkspaceLanding: some View {
        WorkspaceLandingSurface(
            eyebrow: "CAPTURE",
            title: "Setup Required",
            subtitle: "Complete the setup checklist before recording.",
            status: "NO SESSION",
            primaryTitle: "Start session",
            primaryAction: { showingCaptureHub = true }
        ) {
            Button {
                showingCaptureHub = true
            } label: {
                HStack(spacing: ScratchLabDesign.Spacing.md) {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                    VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.xxs) {
                        Text("Camera / visual guide")
                            .font(ScratchLabDesign.Typo.controlValue)
                            .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                        Text("Available during session setup")
                            .font(ScratchLabDesign.Typo.caption)
                            .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                    }
                    Spacer()
                    Text("OPEN")
                        .font(ScratchLabDesign.Typo.statusPill)
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                }
                .padding(.horizontal, ScratchLabDesign.Spacing.lg)
                .frame(minHeight: 60)
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
            .accessibilityHint("Opens Capture setup, where the camera guide is available")
        }
    }

    private var reviewWorkspaceLanding: some View {
        WorkspaceLandingSurface(
            eyebrow: "REVIEW",
            title: "No Take Ready",
            subtitle: "Record or keep a take before reviewing it.",
            status: nil,
            primaryTitle: "Open Capture",
            primaryAction: { showingCaptureHub = true }
        ) {
            VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.sm) {
                Text("No captured take")
                    .font(ScratchLabDesign.Typo.cardHeading)
                    .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                Text("Review opens automatically from the existing Capture flow after a take is recorded.")
                    .font(ScratchLabDesign.Typo.bodySmall)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .scratchLabCard(.standard)
        }
    }

    private var workspaceTabSelection: Binding<WorkspaceTab> {
        Binding(
            get: { selectedWorkspaceTab },
            set: { destination in
                switch destination {
                case .home:
                    selectedWorkspaceTab = .home
                case .practice:
                    showingPracticeHub = true
                    selectedWorkspaceTab = .home
                case .capture, .review:
                    showingCaptureHub = true
                    selectedWorkspaceTab = .home
                case .advanced:
                    showingAdvancedHub = true
                    selectedWorkspaceTab = .home
                }
            }
        )
    }

    private func workspaceOpeningView(_ title: String) -> some View {
        ZStack {
            BackgroundView()
            ProgressView(title)
                .tint(ScratchLabDesign.Sem.accent)
                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
        }
    }

    // The Home body shared by every adaptive mode — a sidebar frames it on
    // regular landscape (Figma 34:2), and it stands alone in portrait/compact.
    @ViewBuilder
    private func homeScrollContent(geometry: GeometryProxy) -> some View {
        if UIDevice.current.userInterfaceIdiom == .phone,
           geometry.size.width > geometry.size.height {
            phoneLandscapeHomeContent(geometry: geometry)
        } else if geometry.size.width > geometry.size.height {
            ViewThatFits(in: .vertical) {
                landscapeHomeContent(geometry: geometry)

                // Dynamic Type can legitimately outgrow a short Stage Manager
                // window. Keep that accessibility fallback without making the
                // normal landscape workspace a scrolling portrait stack.
                ScrollView(showsIndicators: false) {
                    landscapeHomeContent(geometry: geometry)
                }
            }
        } else {
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
    }

    /// iPhone landscape has enough horizontal room for a workspace carousel,
    /// but not for an iPad-style hero plus a three-column grid. Each destination
    /// keeps a usable minimum width and the row clears the floating tab bar.
    private func phoneLandscapeHomeContent(geometry: GeometryProxy) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            landscapeHeaderView

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    phoneLandscapePracticeCard
                        .frame(width: 286)

                    captureLandscapeTile(isExtraCompact: false)
                        .frame(width: 214)
                    reviewLandscapeTile(isExtraCompact: false)
                        .frame(width: 214)
                    advancedLandscapeTile(isExtraCompact: false)
                        .frame(width: 248)
                    landscapeInfoTile(
                        title: "Recent result",
                        detail: recentResultDetail,
                        systemImage: "clock.arrow.circlepath"
                    )
                    .frame(width: 220)
                    landscapeInfoTile(
                        title: "Device status",
                        detail: deviceStatusDetail,
                        systemImage: "waveform.badge.mic"
                    )
                    .frame(width: 220)
                }
                .padding(.trailing, 16)
            }
        }
        .padding(.leading, max(geometry.safeAreaInsets.leading, 16))
        .padding(.trailing, max(geometry.safeAreaInsets.trailing, 16))
        .padding(.top, max(geometry.safeAreaInsets.top, 8))
        .padding(.bottom, max(geometry.safeAreaInsets.bottom, 8) + 76)
    }

    private var phoneLandscapePracticeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CURRENT LESSON")
                .font(ScratchLabDesign.Typo.metricLabel)
                .foregroundStyle(ScratchLabDesign.Sem.accent)

            Label("Baby Scratch", systemImage: "figure.disc.sports")
                .font(ScratchLabDesign.Typo.title3)
                .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                .lineLimit(1)

            Text("One smooth push forward and pull back, with the fader open.")
                .font(ScratchLabDesign.Typo.bodySecondary)
                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                .lineLimit(1)

            HStack(spacing: 12) {
                Label(
                    audioEngine.isRunning ? "Audio ready" : "Audio setup",
                    systemImage: "waveform"
                )
                Label("Hardware optional", systemImage: "cable.connector")
            }
            .font(ScratchLabDesign.Typo.caption)
            .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
            .lineLimit(1)

            Button(action: { showingPracticeHub = true }) {
                Label("Start practice", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .scratchLabPrimaryButton(fillsWidth: true)
        }
        .frame(maxWidth: .infinity, minHeight: 136, alignment: .topLeading)
        .scratchLabCard(.lessonHero)
    }

    private func landscapeHomeContent(geometry: GeometryProxy) -> some View {
        let hasSidebar = usesNavigationSidebar(in: geometry.size)

        return VStack(alignment: .leading, spacing: 12) {
            landscapeHeaderView

            HStack(alignment: .top, spacing: 12) {
                landscapePracticeCard(isExtraCompact: !hasSidebar)
                    .frame(
                        minWidth: hasSidebar ? 280 : 240,
                        maxWidth: hasSidebar ? 340 : 290
                    )

                landscapeWorkspaceGrid(isExtraCompact: !hasSidebar)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, max(geometry.safeAreaInsets.top, 8))
        .padding(.bottom, max(geometry.safeAreaInsets.bottom, 8))
    }

    private var landscapeHeaderView: some View {
        HStack(spacing: 12) {
            profileControl

            VStack(alignment: .leading, spacing: 2) {
                Text("ScratchLab")
                    .font(ScratchLabDesign.Typo.title2)
                    .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                Text("Hear it. See the notation. Copy it.")
                    .font(ScratchLabDesign.Typo.bodySecondary)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
            }

            Spacer()
            settingsControl
        }
    }

    private func landscapePracticeCard(isExtraCompact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CURRENT LESSON")
                .font(ScratchLabDesign.Typo.metricLabel)
                .foregroundStyle(ScratchLabDesign.Sem.accent)

            Label("Baby Scratch", systemImage: "figure.disc.sports")
                .font(isExtraCompact ? ScratchLabDesign.Typo.title3 : ScratchLabDesign.Typo.title2)
                .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

            Text("One smooth push forward, one smooth pull back, with the fader open.")
                .font(ScratchLabDesign.Typo.body)
                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                .lineLimit(isExtraCompact ? 2 : nil)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                StatusBadge(
                    title: "Audio",
                    value: audioEngine.isRunning ? "Ready" : "Set up",
                    variant: audioEngine.isRunning ? .success : .ready,
                    systemImage: "waveform"
                )
                StatusBadge(
                    title: "Hardware",
                    value: "Optional",
                    variant: .neutral,
                    systemImage: "cable.connector"
                )
            }

            if !isExtraCompact {
                Text("Mic or wired USB input · results stay on device.")
                    .font(ScratchLabDesign.Typo.bodySecondary)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
            }

            Button(action: { showingPracticeHub = true }) {
                Label("Start practice", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .scratchLabPrimaryButton(fillsWidth: true)
            .accessibilityHint("Opens the Baby Scratch practice lesson")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .scratchLabCard(.lessonHero)
    }

    @ViewBuilder
    private func landscapeWorkspaceGrid(isExtraCompact: Bool) -> some View {
        if isExtraCompact {
            VStack(spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    captureLandscapeTile(isExtraCompact: true)
                    reviewLandscapeTile(isExtraCompact: true)
                    advancedLandscapeTile(isExtraCompact: true)
                }

                HStack(alignment: .top, spacing: 10) {
                    landscapeInfoTile(
                        title: "Recent result",
                        detail: recentResultDetail,
                        systemImage: "clock.arrow.circlepath"
                    )
                    landscapeInfoTile(
                        title: "Device status",
                        detail: deviceStatusDetail,
                        systemImage: "waveform.badge.mic"
                    )
                }
            }
        } else {
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    captureLandscapeTile(isExtraCompact: false)
                    reviewLandscapeTile(isExtraCompact: false)
                }

                advancedLandscapeTile(isExtraCompact: false)
                    .gridCellColumns(2)

                GridRow {
                    landscapeInfoTile(
                        title: "Recent result",
                        detail: recentResultDetail,
                        systemImage: "clock.arrow.circlepath"
                    )
                    landscapeInfoTile(
                        title: "Device status",
                        detail: deviceStatusDetail,
                        systemImage: "waveform.badge.mic"
                    )
                }
            }
        }
    }

    private func captureLandscapeTile(isExtraCompact: Bool) -> some View {
        landscapeWorkspaceTile(
            eyebrow: "CAPTURE",
            title: "Capture Session",
            detail: "Check camera and audio, then record a clean take.",
            systemImage: "record.circle",
            status: audioEngine.isRunning ? "Audio ready" : "Setup required",
            action: { showingCaptureHub = true },
            minimumHeight: isExtraCompact ? 80 : 108,
            isExtraCompact: isExtraCompact
        )
    }

    private func reviewLandscapeTile(isExtraCompact: Bool) -> some View {
        landscapeWorkspaceTile(
            eyebrow: "REVIEW",
            title: "Review Take",
            detail: "Capture a take, then inspect sync and quality.",
            systemImage: "checkmark.seal",
            status: "After capture",
            action: { showingCaptureHub = true },
            minimumHeight: isExtraCompact ? 80 : 108,
            isExtraCompact: isExtraCompact
        )
    }

    private func advancedLandscapeTile(isExtraCompact: Bool) -> some View {
        landscapeWorkspaceTile(
            eyebrow: "ADVANCED",
            title: "Advanced / Mac Companion",
            detail: "Mac relay, hardware routing, Watch and performer tools.",
            systemImage: "slider.horizontal.3",
            status: companionRelayBroadcaster.connectedPeerNames.isEmpty ? "Mac not linked" : "Mac linked",
            action: { showingAdvancedHub = true },
            minimumHeight: isExtraCompact ? 80 : 92,
            isExtraCompact: isExtraCompact
        )
    }

    private func landscapeWorkspaceTile(
        eyebrow: String,
        title: String,
        detail: String,
        systemImage: String,
        status: String,
        action: @escaping () -> Void,
        minimumHeight: CGFloat = 108,
        isExtraCompact: Bool = false
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: systemImage)
                        .foregroundStyle(ScratchLabDesign.Sem.accent)
                    Text(eyebrow)
                        .font(ScratchLabDesign.Typo.metricLabel)
                        .foregroundStyle(ScratchLabDesign.Sem.accent)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ScratchLabDesign.Sem.textTertiary)
                }

                Text(title)
                    .font(ScratchLabDesign.Typo.cardHeading)
                    .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(detail)
                    .font(ScratchLabDesign.Typo.bodySecondary)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                    .lineLimit(isExtraCompact ? 1 : 2)

                if !isExtraCompact {
                    Text(status)
                        .font(ScratchLabDesign.Typo.statusPill)
                        .foregroundStyle(ScratchLabDesign.Sem.textTertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .topLeading)
            .scratchLabCard(.standard)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title): \(detail). \(status)")
    }

    private func landscapeInfoTile(title: String, detail: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(ScratchLabDesign.Typo.cardHeading)
                .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
            Text(detail)
                .font(ScratchLabDesign.Typo.bodySecondary)
                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
        .scratchLabCard(.standard)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Header
    
    private var headerView: some View {
        VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.itemTight) {
            HStack(spacing: 12) {
                profileControl

                Spacer()

                settingsControl
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

    private var profileControl: some View {
        Button(action: { showingProfile = true }) {
            HStack(spacing: 8) {
                Text(progressManager.playerProfile?.avatarEmoji ?? "🎧")
                    .font(.system(size: 20))
                Text(progressManager.playerProfile?.displayName ?? "New DJ")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(ScratchLabDesign.Sem.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(ScratchLabDesign.Surface.subtleFill, in: RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous)
                    .stroke(ScratchLabDesign.Surface.controlFill, lineWidth: 1)
            )
        }
        .accessibilityLabel("Profile: \(progressManager.playerProfile?.displayName ?? "New DJ")")
    }

    private var settingsControl: some View {
        Button(action: { showingSettings = true }) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(ScratchLabDesign.Sem.textPrimary)
                .frame(width: 44, height: 44)
                .background(ScratchLabDesign.Surface.subtleFill, in: RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous)
                        .stroke(ScratchLabDesign.Surface.controlFill, lineWidth: 1)
                )
        }
        .accessibilityLabel("Settings")
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

    // MARK: - Advanced status copy

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

private struct WorkspaceLandingSurface<Content: View>: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    let status: String?
    let primaryTitle: String
    let primaryAction: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { proxy in
            let horizontalInset: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 24 : 16
            let floatingTabBarClearance: CGFloat = UIDevice.current.userInterfaceIdiom == .phone
                && proxy.size.width > proxy.size.height ? 88 : 0

            ZStack {
                BackgroundView()

                VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.cardSection) {
                    VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.xs) {
                        Text(eyebrow)
                            .font(ScratchLabDesign.Typo.metricLabel)
                            .foregroundStyle(ScratchLabDesign.Sem.textSecondary)

                        HStack(spacing: ScratchLabDesign.Spacing.sm) {
                            Text(title)
                                .font(ScratchLabDesign.Typo.title2)
                                .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                            if let status {
                                StatusBadge(title: "", value: status, variant: .ready)
                            }
                            Spacer(minLength: ScratchLabDesign.Spacing.sm)
                        }

                        Text(subtitle)
                            .font(ScratchLabDesign.Typo.bodySmall)
                            .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(ScratchLabDesign.Spacing.lg)
                    .background(ScratchLabDesign.Surface.canvas)

                    content

                    Spacer(minLength: 0)

                    Button(primaryTitle, action: primaryAction)
                        .scratchLabPrimaryButton(fillsWidth: true)
                }
                .padding(.horizontal, horizontalInset)
                .padding(.top, max(proxy.safeAreaInsets.top, ScratchLabDesign.Spacing.md))
                .padding(
                    .bottom,
                    max(proxy.safeAreaInsets.bottom, ScratchLabDesign.Spacing.md) + floatingTabBarClearance
                )
                .frame(maxWidth: 1100, maxHeight: .infinity, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
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

private struct AdvancedHubView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
    @State private var showingAudioDVS = false
    @State private var showingMIDIController = false
    #if DEBUG
    @State private var showingVirtualPlatterPrototype = false
    #endif

    private var isIOSAppOnMac: Bool {
        ProcessInfo.processInfo.isiOSAppOnMac
    }

    var body: some View {
        ZStack {
            BackgroundView()

            GeometryReader { proxy in
                if proxy.size.width > proxy.size.height && !dynamicTypeSize.isAccessibilitySize {
                    advancedOverviewContent
                } else {
                    ScrollView(showsIndicators: false) {
                        advancedOverviewContent
                    }
                }
            }
        }
        .navigationTitle("Advanced")
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
        .navigationDestination(isPresented: $showingAudioDVS) {
            AdvancedAudioDVSView()
        }
        .navigationDestination(isPresented: $showingMIDIController) {
            AdvancedMIDIControllerView()
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

    private var audioHardwareCard: some View {
        AudioHardwareInputCard(
            routeState: audioEngine.audioHardwareRouteState,
            onSelectStereoPair: { audioEngine.selectStereoPair($0) }
        )
    }

    private var advancedOverviewContent: some View {
        VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.cardSection) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: ScratchLabDesign.Spacing.lg) {
                    advancedHeading
                    Spacer(minLength: ScratchLabDesign.Spacing.md)
                    compactControllerStatus
                }

                VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.sm) {
                    advancedHeading
                    compactControllerStatus
                }
            }

            AdvancedNavigationRow(
                title: "Audio & DVS",
                subtitle: "Signal health, channel pairs, and timecode system",
                action: { showingAudioDVS = true }
            )

            AdvancedNavigationRow(
                title: "MIDI & Controller",
                subtitle: "Select, learn, and assign RANE faders and Hot Cue samples",
                action: { showingMIDIController = true }
            )

            AdvancedNavigationRow(
                title: "Performer Monitor",
                subtitle: "Read-only connection status · controlled by Mac",
                action: { showingPerformerMonitor = true }
            )
        }
        .padding(.horizontal, UIDevice.current.userInterfaceIdiom == .pad ? 24 : 16)
        .padding(.top, UIDevice.current.userInterfaceIdiom == .pad ? 16 : 12)
        .padding(.bottom, UIDevice.current.userInterfaceIdiom == .phone ? 100 : 16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var advancedHeading: some View {
        VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.xs) {
            Text("ADVANCED")
                .font(ScratchLabDesign.Typo.metricLabel)
                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)

            AdaptiveWorkspaceHeader(
                title: "Hardware & Setup",
                status: .standard,
                detail: "Manage your controller, audio, and monitor connections"
            )
        }
    }

    private var compactControllerStatus: some View {
        let isReady = audioEngine.audioHardwareRouteState.isInputActive

        return Button {
            showingMIDIController = true
        } label: {
            HStack(spacing: ScratchLabDesign.Spacing.sm) {
                Image(systemName: isReady ? "checkmark.circle.fill" : "cable.connector")
                    .foregroundStyle(isReady ? ScratchLabDesign.Sem.success : ScratchLabDesign.Sem.warning)

                VStack(alignment: .leading, spacing: 2) {
                    Text("RANE ONE MKII")
                        .font(ScratchLabDesign.Typo.controlValue)
                        .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                    Text(isReady ? "READY" : "SETUP REQUIRED")
                        .font(ScratchLabDesign.Typo.metricLabel)
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                }

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(ScratchLabDesign.Sem.textTertiary)
            }
            .padding(.horizontal, ScratchLabDesign.Spacing.md)
            .padding(.vertical, ScratchLabDesign.Spacing.sm)
            .background(
                ScratchLabDesign.Surface.raised,
                in: RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous)
                    .stroke(isReady ? ScratchLabDesign.Sem.success.opacity(0.55) : ScratchLabDesign.Border.default, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens MIDI and controller setup")
    }

    private var advancedLandscapeContent: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text("CONNECTION & INPUT")
                    .font(ScratchLabDesign.Typo.metricLabel)
                    .foregroundStyle(ScratchLabDesign.Sem.textTertiary)
                audioHardwareCard
                relayStatusCard
            }
            .frame(minWidth: 300, idealWidth: 340, maxWidth: 400, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 12) {
                Text("TOOLS")
                    .font(ScratchLabDesign.Typo.metricLabel)
                    .foregroundStyle(ScratchLabDesign.Sem.textTertiary)
                advancedMenuGrid
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(16)
    }

    /// The phone has enough landscape width for the full tool set, but not
    /// enough height for the regular hardware and relay cards. Keep the live
    /// state and every action while presenting them as a single status strip
    /// above a fixed two-row grid. Accessibility Dynamic Type intentionally
    /// falls back to the scroll container in `body` rather than clipping text.
    private var advancedPhoneLandscapeContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            advancedPhoneConnectionStrip

            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 8, alignment: .top),
                    count: 3
                ),
                alignment: .leading,
                spacing: 8
            ) {
                productionMenuItems(isCompact: true, usesPhoneLandscapeCard: true)

                #if DEBUG
                advancedDeveloperMenu
                #endif
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var advancedPhoneConnectionStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ScratchLabDesign.Sem.accent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("INPUT")
                    .font(ScratchLabDesign.Typo.metricLabel)
                    .foregroundStyle(ScratchLabDesign.Sem.textTertiary)
                Text(audioEngine.audioHardwareRouteState.deviceName ?? "No input connected")
                    .font(ScratchLabDesign.Typo.caption)
                    .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                    .lineLimit(1)
            }
            .frame(maxWidth: 140, alignment: .leading)

            compactInputPairControl

            Rectangle()
                .fill(ScratchLabDesign.Surface.divider)
                .frame(width: 1, height: 28)
                .padding(.horizontal, 2)
                .accessibilityHidden(true)

            if localNetworkRationaleAccepted {
                compactConnectionStatus(
                    title: companionRelayBroadcaster.connectedPeerNames.isEmpty ? "Mac waiting" : "Mac linked",
                    systemImage: "bolt.horizontal",
                    color: companionRelayBroadcaster.connectedPeerNames.isEmpty
                        ? ScratchLabDesign.Sem.textSecondary
                        : ScratchLabDesign.Sem.success
                )

                compactConnectionStatus(
                    title: watchMotionCaptureStore.isWatchReachable ? "Watch ready" : "Watch offline",
                    systemImage: "applewatch.side.right",
                    color: watchMotionCaptureStore.isWatchReachable
                        ? ScratchLabDesign.Sem.success
                        : ScratchLabDesign.Sem.textSecondary
                )
            } else {
                Text("Mac link off")
                    .font(ScratchLabDesign.Typo.caption)
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Button {
                    localNetworkRationaleAccepted = true
                    companionRelayBroadcaster.startRelayAdvertisingIfNeeded()
                } label: {
                    Label("Connect Mac", systemImage: "bolt.horizontal")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
        .background(
            ScratchLabDesign.Surface.card,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(ScratchLabDesign.Surface.divider, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var compactInputPairControl: some View {
        let routeState = audioEngine.audioHardwareRouteState

        if routeState.availableStereoPairs.count > 1 {
            Picker(
                "Stereo pair",
                selection: Binding(
                    get: { routeState.selectedStereoPair },
                    set: { newValue in
                        if let newValue { audioEngine.selectStereoPair(newValue) }
                    }
                )
            ) {
                ForEach(routeState.availableStereoPairs) { pair in
                    Text(pair.displayName).tag(Optional(pair))
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .tint(ScratchLabDesign.Sem.accent)
        } else if let selectedPair = routeState.selectedStereoPair {
            Text(selectedPair.displayName)
                .font(ScratchLabDesign.Typo.caption)
                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                .lineLimit(1)
        } else {
            Text(routeState.isInputActive ? "Active" : "Idle")
                .font(ScratchLabDesign.Typo.caption)
                .foregroundStyle(
                    routeState.isInputActive
                        ? ScratchLabDesign.Sem.success
                        : ScratchLabDesign.Sem.textSecondary
                )
                .lineLimit(1)
        }
    }

    private func compactConnectionStatus(
        title: String,
        systemImage: String,
        color: Color
    ) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                color.opacity(0.10),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
    }

    #if DEBUG
    private var advancedDeveloperMenu: some View {
        Menu {
            #if canImport(RealityKit)
            Button {
                showingCoachPreview = true
            } label: {
                Label("3D Coach Demo", systemImage: "cube.transparent")
            }
            #endif

            Button {
                showingVirtualPlatterPrototype = true
            } label: {
                Label("Virtual Platter Prototype", systemImage: "circle.circle")
            }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(ScratchLabDesign.Sem.warning.opacity(0.16))
                    .frame(width: 34, height: 34)
                    .overlay {
                        Image(systemName: "wrench.and.screwdriver.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(ScratchLabDesign.Sem.warning)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Developer tools")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                    Text("Experimental previews")
                        .font(ScratchLabDesign.Typo.caption)
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ScratchLabDesign.Sem.textTertiary)
            }
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .padding(10)
            .background(
                ScratchLabDesign.Surface.card,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(ScratchLabDesign.Surface.divider, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Developer tools")
        .accessibilityHint("Shows experimental preview tools")
    }
    #endif

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
            productionMenuItems(isCompact: false)

            #if DEBUG
            developerSectionHeader
            developerMenuItems(isCompact: false)
            #endif
        }
    }

    private var advancedMenuGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())],
                alignment: .leading,
                spacing: 12
            ) {
                productionMenuItems(isCompact: true)
            }

            #if DEBUG
            developerSectionHeader
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())],
                alignment: .leading,
                spacing: 12
            ) {
                developerMenuItems(isCompact: true)
            }
            #endif
        }
    }

    @ViewBuilder
    private func productionMenuItems(
        isCompact: Bool,
        usesPhoneLandscapeCard: Bool = false
    ) -> some View {
        MenuButton(
            title: "Practice modes",
            subtitle: "Full setup: beat/BPM, assist modes, Chirp Flare, and the Baby Flow combo challenge.",
            icon: "waveform",
            accent: Color(hex: "22C55E"),
            isCompact: isCompact,
            usesPhoneLandscapeCard: usesPhoneLandscapeCard,
            action: { showingPracticeModes = true }
        )

        MenuButton(
            title: "Try Demo",
            subtitle: "See scratch feedback instantly",
            icon: "play.circle.fill",
            accent: ScratchLabDesign.Sem.accent,
            isCompact: isCompact,
            usesPhoneLandscapeCard: usesPhoneLandscapeCard,
            action: { showingDemoMode = true }
        )

        MenuButton(
            title: "Companion Camera",
            subtitle: isIOSAppOnMac
                ? "Use ScratchLabDesktop on Mac for capture. Companion Camera is for iPhone hardware."
                : "Send deck video to your main device",
            icon: "iphone.gen3.radiowaves.left.and.right",
            accent: Color(hex: "F59E0B"),
            isCompact: isCompact,
            usesPhoneLandscapeCard: usesPhoneLandscapeCard,
            action: { showingCompanionCam = true }
        )

        MenuButton(
            title: "Performer Monitor",
            subtitle: performerMonitorSubtitle,
            icon: performerMonitorIcon,
            accent: Color(hex: "0EA5E9"),
            isCompact: isCompact,
            usesPhoneLandscapeCard: usesPhoneLandscapeCard,
            action: { showingPerformerMonitor = true }
        )

        MenuButton(
            title: "Watch Capture",
            subtitle: "Import wrist motion and relay it back to Mac capture",
            icon: "applewatch.side.right",
            accent: Color(hex: "6366F1"),
            isCompact: isCompact,
            usesPhoneLandscapeCard: usesPhoneLandscapeCard,
            action: { showingWatchCapture = true }
        )
    }

    #if DEBUG
    @ViewBuilder
    private func developerMenuItems(isCompact: Bool) -> some View {
        #if canImport(RealityKit)
        MenuButton(
            title: "3D Coach Demo",
            subtitle: "Preview the 3D coach model animation",
            icon: "cube.transparent",
            accent: Color(hex: "8B5CF6"),
            isCompact: isCompact,
            action: { showingCoachPreview = true }
        )
        #endif

        MenuButton(
            title: "Virtual Platter Prototype",
            subtitle: "Developer-only scratch-on-glass slice (no capture/ML)",
            icon: "circle.circle",
            accent: Color(hex: "F59E0B"),
            isCompact: isCompact,
            action: { showingVirtualPlatterPrototype = true }
        )
    }
    #endif

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

private struct AdvancedNavigationRow: View {
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: ScratchLabDesign.Spacing.md) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)

                VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.xxs) {
                    Text(title)
                        .font(ScratchLabDesign.Typo.controlValue)
                        .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                    Text(subtitle)
                        .font(ScratchLabDesign.Typo.caption)
                        .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                        .lineLimit(2)
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
        .accessibilityHint("Opens \(title)")
    }
}

private struct AdvancedAudioDVSView: View {
    @EnvironmentObject private var audioEngine: AudioEngine

    var body: some View {
        ZStack {
            BackgroundView()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.cardSection) {
                    VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.xs) {
                        Text("ADVANCED")
                            .font(ScratchLabDesign.Typo.metricLabel)
                            .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                        AdaptiveWorkspaceHeader(
                            title: "Audio & DVS",
                            status: audioEngine.audioHardwareRouteState.isInputActive ? .ready : .needsAttention,
                            detail: "Signal health, channel pairs, and timecode input"
                        )
                    }

                    AudioHardwareInputCard(
                        routeState: audioEngine.audioHardwareRouteState,
                        onSelectStereoPair: { audioEngine.selectStereoPair($0) }
                    )

                    VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.sm) {
                        Text("DVS SIGNAL")
                            .font(ScratchLabDesign.Typo.metricLabel)
                            .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                        Text(audioEngine.audioHardwareRouteState.isInputActive
                             ? "Input is active. Signal classification remains owned by the existing capture analyzer."
                             : "Connect and select a supported USB audio input to expose DVS signal health.")
                            .font(ScratchLabDesign.Typo.bodySmall)
                            .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .scratchLabCard(.standard)
                }
                .padding(UIDevice.current.userInterfaceIdiom == .pad ? 24 : 16)
            }
        }
        .navigationTitle("Audio & DVS")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AdvancedMIDIControllerView: View {
    @EnvironmentObject private var midiManager: IOSMIDIManager
    @EnvironmentObject private var midiLearnCoordinator: IOSMIDILearnCoordinator
    @EnvironmentObject private var midiControllerDispatcher: IOSMIDIControllerDispatcher
    @EnvironmentObject private var scratchPlaybackEngine: IOScratchPlaybackEngine
    @AppStorage(MIDISelectionSettings.selectedSourceIDKey) private var selectedMIDISourceID = ""

    private var selectedSource: IOSMIDIManager.Source? {
        midiManager.sources.first(where: { $0.id == selectedMIDISourceID })
    }

    private var selectedSourceIsRane: Bool {
        selectedSource.map { RaneOneMKIIVerifiedLearnedMapping.matches(deviceName: $0.name) } == true
    }

    private var hotCueOneControl: MIDILearnedControl? {
        midiLearnCoordinator.control(for: .hotCue1)
    }

    private var isLearningHotCueOne: Bool {
        midiLearnCoordinator.activeAction == .hotCue1
    }

    private var hardwareReadiness: InputReadinessState {
        switch midiManager.readinessState {
        case .unavailable: return .setupRequired
        case .deviceConnected: return .detected
        case .receivingMessages: return .ready
        }
    }

    var body: some View {
        ZStack {
            BackgroundView()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.cardSection) {
                    VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.xs) {
                        Text("ADVANCED")
                            .font(ScratchLabDesign.Typo.metricLabel)
                            .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                        AdaptiveWorkspaceHeader(
                            title: "MIDI & Controller",
                            status: midiManager.readinessState == .receivingMessages ? .ready : .needsAttention,
                            detail: "Select a source, map Hot Cue 1, and assign ScratchLab AHHH"
                        )
                    }

                    HardwareProfileCard(
                        name: selectedSource?.name ?? "No MIDI Controller Selected",
                        classification: selectedSource == nil
                            ? "Connect or select the controller source ScratchLab should listen to."
                            : "MIDI source · local ScratchLab sample control",
                        tier: .testedNotYetVerified,
                        readiness: hardwareReadiness
                    )

                    midiSourceCard

                    VStack(spacing: 0) {
                        AdvancedMappingRow(label: "Crossfader", value: mappingDescription(for: .crossfader))
                        Divider().overlay(ScratchLabDesign.Border.default)
                        AdvancedMappingRow(label: "Left upfader", value: mappingDescription(for: .leftUpfader))
                        Divider().overlay(ScratchLabDesign.Border.default)
                        AdvancedMappingRow(label: "Right upfader", value: mappingDescription(for: .rightUpfader))
                        Divider().overlay(ScratchLabDesign.Border.default)
                        AdvancedMappingRow(
                            label: "Right-deck pads",
                            value: RaneOneMKIIVerifiedLearnedMapping.isComplete(midiLearnCoordinator.currentMapping)
                                ? "Hot Cues 1–8 mapped"
                                : "Mapping incomplete"
                        )
                        Divider().overlay(ScratchLabDesign.Border.default)
                        AdvancedMappingRow(label: "Hot Cue 1", value: hotCueOneDescription)
                    }
                    .scratchLabCard(.standard)

                    hotCueOneCard
                }
                .padding(UIDevice.current.userInterfaceIdiom == .pad ? 24 : 16)
                .padding(.bottom, UIDevice.current.userInterfaceIdiom == .phone ? 88 : 16)
            }
        }
        .navigationTitle("MIDI & Controller")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            midiManager.refreshSources()
            if let selectedSource {
                selectMIDISource(selectedSource)
            }
        }
    }

    private var midiSourceCard: some View {
        VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.sm) {
            Text("MIDI SOURCE")
                .font(ScratchLabDesign.Typo.metricLabel)
                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)

            if midiManager.sources.isEmpty {
                Label(
                    "No MIDI source detected. Connect the controller, then refresh.",
                    systemImage: "cable.connector"
                )
                .font(ScratchLabDesign.Typo.bodySmall)
                .foregroundStyle(ScratchLabDesign.Sem.warning)
            } else {
                ForEach(midiManager.sources) { source in
                    Button {
                        selectMIDISource(source)
                    } label: {
                        HStack(spacing: ScratchLabDesign.Spacing.sm) {
                            Image(systemName: source.id == selectedMIDISourceID
                                  ? "checkmark.circle.fill"
                                  : "circle")
                                .foregroundStyle(ScratchLabDesign.Sem.accent)
                            VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.xxs) {
                                Text(source.name)
                                    .font(ScratchLabDesign.Typo.controlValue)
                                    .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                                Text(source.id)
                                    .font(ScratchLabDesign.Typo.caption)
                                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(ScratchLabDesign.Spacing.sm)
                        .background(
                            source.id == selectedMIDISourceID
                                ? ScratchLabDesign.Sem.accent.opacity(0.12)
                                : ScratchLabDesign.Surface.raised,
                            in: RoundedRectangle(
                                cornerRadius: ScratchLabDesign.Radius.control,
                                style: .continuous
                            )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Button("Refresh MIDI Devices") {
                midiManager.refreshSources()
            }
            .scratchLabSecondaryButton(fillsWidth: true)

            Button("Apply Verified RANE Mapping") {
                guard let selectedSource else { return }
                selectMIDISource(selectedSource)
                midiLearnCoordinator.applyVerifiedRaneOneMKIIMapping()
            }
            .scratchLabPrimaryButton(fillsWidth: true)
            .disabled(!selectedSourceIsRane || midiLearnCoordinator.activeAction != nil)
            .accessibilityIdentifier("advanced-apply-rane-mapping")
        }
        .scratchLabCard(.standard)
    }

    private var hotCueOneCard: some View {
        VStack(alignment: .leading, spacing: ScratchLabDesign.Spacing.sm) {
            Text("HOT CUE 1 · AHHH")
                .font(ScratchLabDesign.Typo.metricLabel)
                .foregroundStyle(ScratchLabDesign.Sem.accent)

            Text(hotCueOneControl == nil
                 ? "Map Hot Cue 1 first. On a RANE ONE MKII, learning the pad automatically assigns the local AHHH sample."
                 : "Hot Cue 1 can arm ScratchLab's local AHHH even while Serato owns deck transport. Audio starts when the right platter moves.")
                .font(ScratchLabDesign.Typo.bodySmall)
                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: ScratchLabDesign.Spacing.sm) {
                    hotCueActions
                }

                VStack(spacing: ScratchLabDesign.Spacing.sm) {
                    hotCueActions
                }
            }

            Text("RANE setup: the channel-assign switch above the fader must be fully left so the normal Hot Cue pads transmit MIDI.")
                .font(ScratchLabDesign.Typo.caption)
                .foregroundStyle(ScratchLabDesign.Sem.warning)
                .fixedSize(horizontal: false, vertical: true)

            Text(scratchPlaybackEngine.platterSampleStatus)
                .font(ScratchLabDesign.Typo.bodySmall)
                .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("advanced-platter-sample-status")

            if !midiLearnCoordinator.feedback.isEmpty {
                Text(midiLearnCoordinator.feedback)
                    .font(ScratchLabDesign.Typo.bodySmall)
                    .foregroundStyle(ScratchLabDesign.Sem.accent)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("advanced-midi-learn-feedback")
            }
        }
        .scratchLabCard(.standard)
    }

    @ViewBuilder
    private var hotCueActions: some View {
        Button(hotCueOneControl == nil ? "Assign AHHH" : "Reassign AHHH") {
            midiLearnCoordinator.assignSample("dvs_ahhh", to: .hotCue1)
        }
        .scratchLabSecondaryButton(fillsWidth: true)
        .disabled(hotCueOneControl == nil)
        .accessibilityIdentifier("advanced-assign-ahhh-hot-cue-1")

        Button("Load AHHH") {
            scratchPlaybackEngine.loadPlatterAHHH()
        }
        .scratchLabSecondaryButton(fillsWidth: true)
        .accessibilityIdentifier("advanced-load-platter-ahhh")

        Button(isLearningHotCueOne ? "Cancel Learn" : (hotCueOneControl == nil ? "Learn Hot Cue 1" : "Relearn Hot Cue 1")) {
            if isLearningHotCueOne {
                midiLearnCoordinator.cancelLearning()
            } else {
                midiLearnCoordinator.startLearning(.hotCue1)
            }
        }
        .scratchLabPrimaryButton(fillsWidth: true)
        .disabled(selectedSource == nil && !isLearningHotCueOne)
        .accessibilityIdentifier("advanced-midi-learn-hotCue1")
    }

    private func selectMIDISource(_ source: IOSMIDIManager.Source) {
        selectedMIDISourceID = source.id
        midiLearnCoordinator.selectDevice(id: source.id, name: source.name)
        midiControllerDispatcher.updateMapping(deviceIdentifier: source.id)
    }

    private func mappingDescription(for action: MIDISemanticAction) -> String {
        guard let control = midiLearnCoordinator.control(for: action) else { return "Not mapped" }
        let type = control.messageType == .controlChange ? "CC" : "Note"
        return "Channel \(control.channel) · \(type)\(control.controlNumber)"
    }

    private var hotCueOneDescription: String {
        guard let control = hotCueOneControl else { return "Not mapped · no sample" }
        let sample = control.assignedSampleID == "dvs_ahhh"
            ? "AHHH"
            : (control.assignedSampleID ?? "No sample")
        return "Channel \(control.channel) · Note\(control.controlNumber) · \(sample)"
    }
}

private struct AdvancedMappingRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: ScratchLabDesign.Spacing.md) {
            Text(label)
                .font(ScratchLabDesign.Typo.controlValue)
                .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
            Spacer(minLength: ScratchLabDesign.Spacing.md)
            Text(value)
                .font(ScratchLabDesign.Typo.technical)
                .foregroundStyle(ScratchLabDesign.Sem.accent)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, ScratchLabDesign.Spacing.sm)
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

            GeometryReader { proxy in
                if proxy.size.width > proxy.size.height {
                    ViewThatFits(in: .vertical) {
                        demoLandscapeContent

                        ScrollView(showsIndicators: true) {
                            demoLandscapeContent
                        }
                    }
                } else {
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

    private var demoLandscapeContent: some View {
        HStack(alignment: .top, spacing: 14) {
            header
                .frame(minWidth: 190, idealWidth: 230, maxWidth: 280, alignment: .topLeading)

            feedbackCard
                .frame(maxWidth: .infinity, alignment: .topLeading)

            exportCard
                .frame(minWidth: 190, idealWidth: 220, maxWidth: 260, alignment: .topLeading)
        }
        .padding(16)
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
// The regular-landscape navigation sidebar routes through the same Practice,
// Capture/Review, and Advanced state MainMenuView owns, so there is no
// duplicate navigation state or alternate workflow.
private struct AdaptiveSidebarView: View {
    @Binding var showingPracticeHub: Bool
    @Binding var showingCaptureHub: Bool
    @Binding var showingAdvancedHub: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ScratchLab")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(ScratchLabDesign.Sem.textPrimary)

            Text("WORKSPACES")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            sidebarLink("Practice", systemImage: "waveform") { showingPracticeHub = true }
            sidebarLink("Capture", systemImage: "record.circle") { showingCaptureHub = true }
            sidebarLink("Review via Capture", systemImage: "checkmark.seal") { showingCaptureHub = true }
            sidebarLink("Advanced / Mac Companion", systemImage: "slider.horizontal.3") { showingAdvancedHub = true }

            Spacer()
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
    var isCompact: Bool = false
    var usesPhoneLandscapeCard: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            menuContent
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(subtitle)")
    }

    private var menuContent: some View {
        HStack(
            alignment: .top,
            spacing: usesPhoneLandscapeCard ? 8 : (isCompact ? 10 : 16)
        ) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(accent.opacity(0.16))
                .frame(
                    width: usesPhoneLandscapeCard ? 34 : (isCompact ? 40 : 48),
                    height: usesPhoneLandscapeCard ? 34 : (isCompact ? 40 : 48)
                )
                .overlay {
                    Image(systemName: icon)
                        .font(
                            .system(
                                size: usesPhoneLandscapeCard ? 14 : (isCompact ? 16 : 18),
                                weight: .semibold
                            )
                        )
                        .foregroundColor(accent)
                }

            VStack(alignment: .leading, spacing: usesPhoneLandscapeCard ? 2 : 4) {
                Text(title)
                    .font(
                        usesPhoneLandscapeCard
                            ? .system(size: 14, weight: .semibold)
                            : ScratchLabDesign.Typo.cardHeading
                    )
                    .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                    .lineLimit(usesPhoneLandscapeCard ? 1 : nil)

                Text(subtitle)
                    .font(
                        usesPhoneLandscapeCard
                            ? ScratchLabDesign.Typo.caption
                            : ScratchLabDesign.Typo.bodySecondary
                    )
                    .foregroundStyle(ScratchLabDesign.Sem.textSecondary)
                    .lineLimit(isCompact ? 2 : nil)
                    .fixedSize(horizontal: false, vertical: !isCompact)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: usesPhoneLandscapeCard ? 11 : 14, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: usesPhoneLandscapeCard ? 56 : (isCompact ? 64 : nil),
            alignment: .leading
        )
        .modifier(MenuCardSurfaceModifier(usesPhoneLandscapeCard: usesPhoneLandscapeCard))
        .contentShape(Rectangle())
    }
}

private struct MenuCardSurfaceModifier: ViewModifier {
    let usesPhoneLandscapeCard: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if usesPhoneLandscapeCard {
            content
                .padding(10)
                .background(
                    ScratchLabDesign.Surface.card,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(ScratchLabDesign.Surface.divider, lineWidth: 1)
                }
        } else {
            content
                .scratchLabCard(.standard)
        }
    }
}

// MARK: - Background View

struct BackgroundView: View {
    var body: some View {
        ScratchLabDesign.Surface.applicationBackground
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

                GeometryReader { proxy in
                    if proxy.size.width > proxy.size.height {
                        HStack(spacing: 28) {
                            profileIdentity(isCompact: true)

                            Rectangle()
                                .fill(ScratchLabDesign.Border.default)
                                .frame(width: 1, height: 96)

                            profileBadges
                                .frame(maxWidth: 360)
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    } else {
                        VStack(spacing: 24) {
                            profileIdentity(isCompact: false)
                            profileBadges
                            Spacer()
                        }
                        .padding(.top, 40)
                    }
                }
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

    private func profileIdentity(isCompact: Bool) -> some View {
        VStack(spacing: isCompact ? 12 : 24) {
            Text(progressManager.playerProfile?.avatarEmoji ?? "🎧")
                .font(.system(size: isCompact ? 56 : 80))
                .padding(isCompact ? 12 : 16)
                .background(Color.white.opacity(0.1))
                .clipShape(Circle())

            Text(progressManager.playerProfile?.displayName ?? "DJ")
                .font(ScratchLabDesign.Typo.pageTitle)
                .foregroundStyle(ScratchLabDesign.Sem.textPrimary)
                .lineLimit(1)
        }
    }

    private var profileBadges: some View {
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
    @Environment(\.dismiss) private var dismiss
    @StateObject private var receiver = IPadPerformerMonitorReceiver()
    @State private var manualHost = ""

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width > proxy.size.height,
               let image = receiver.latestFrameImage,
               let packet = receiver.latestFramePacket {
                connectedLandscapeMonitor(image: image, packet: packet, in: proxy)
                    .toolbar(.hidden, for: .navigationBar)
                    .navigationBarBackButtonHidden(true)
            } else {
                regularMonitor
                    .toolbar(.visible, for: .navigationBar)
                    .navigationBarBackButtonHidden(false)
            }
        }
        .background {
            BackgroundView()
        }
        .navigationTitle("Performer Monitor")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            receiver.refresh()
        }
    }

    /// A connected landscape monitor is a viewing surface, not a settings
    /// form. The remote camera therefore owns the entire canvas while the
    /// existing packet guidance and connection actions remain reachable as
    /// compact, translucent overlays.
    private func connectedLandscapeMonitor(
        image: UIImage,
        packet: PerformerMonitorFramePacket,
        in proxy: GeometryProxy
    ) -> some View {
        ZStack(alignment: .top) {
            Color.black
                .ignoresSafeArea()

            IPadPerformerMonitorStage(
                image: image,
                packet: packet,
                fillsAvailableSpace: true
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()

            landscapeConnectionChrome
                .padding(.horizontal, 16)
                .padding(.top, max(proxy.safeAreaInsets.top, 12))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    private var landscapeConnectionChrome: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .tint(.white)
            .accessibilityLabel("Back")

            HStack(spacing: 8) {
                Circle()
                    .fill(ScratchLabDesign.Sem.success)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 1) {
                    Text("CONTROLLED BY MAC")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                    Text(receiver.connectionStatus)
                        .font(.caption)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())

            Spacer(minLength: 12)

            Button {
                receiver.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.headline)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .tint(.white)
            .accessibilityLabel("Reconnect")

            Button(role: .destructive) {
                receiver.disconnect()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .tint(ScratchLabDesign.Sem.danger)
            .accessibilityLabel("Disconnect")
        }
    }

    private var regularMonitor: some View {
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
                        .disabled(manualHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityHint(
                            manualHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? "Enter a device name or address first"
                                : "Connects to the entered ScratchLab device"
                        )
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
                .disabled(receiver.connectedPeerNames.isEmpty)
                .accessibilityHint(
                    receiver.connectedPeerNames.isEmpty
                        ? "Unavailable because no ScratchLab peer is connected"
                        : "Disconnects the current ScratchLab peer"
                )
            Spacer()
        }
    }

}

private struct IPadPerformerMonitorStage: View {
    let image: UIImage
    let packet: PerformerMonitorFramePacket
    let fillsAvailableSpace: Bool

    init(
        image: UIImage,
        packet: PerformerMonitorFramePacket,
        fillsAvailableSpace: Bool = false
    ) {
        self.image = image
        self.packet = packet
        self.fillsAvailableSpace = fillsAvailableSpace
    }

    @ViewBuilder
    var body: some View {
        if fillsAvailableSpace {
            stageSurface
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .clipped()
        } else {
            stageSurface
                .aspectRatio(imageAspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.55))
                .cornerRadius(20)
                .clipped()
        }
    }

    private var stageSurface: some View {
        GeometryReader { proxy in
            let imageRect = aspectFillImageRect(in: proxy.size)

            ZStack(alignment: .topLeading) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()

                ForEach(packet.zones) { zone in
                    zoneOverlay(zone, in: imageRect)
                }

                VStack(alignment: .leading, spacing: 10) {
                    cuePill

                    HStack(spacing: 8) {
                        metricBadge(title: "Audio", value: packet.audioPercent)
                        metricBadge(title: "Matches", value: "\(packet.detectionCount)")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, fillsAvailableSpace ? 84 : 20)

                LinearGradient(
                    colors: [.clear, Color.black.opacity(0.72)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)

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

    /// Zones are normalized against the source frame. In landscape the source
    /// image is aspect-filled, so map them through that rendered image rect
    /// (including any centered crop) rather than the device canvas itself.
    private func zoneOverlay(_ zone: PerformerMonitorZonePacket, in imageRect: CGRect) -> some View {
        let zoneRect = CGRect(
            x: imageRect.minX + (zone.minX * imageRect.width),
            y: imageRect.minY + ((1 - zone.minY - zone.height) * imageRect.height),
            width: zone.width * imageRect.width,
            height: zone.height * imageRect.height
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

    private func aspectFillImageRect(in canvasSize: CGSize) -> CGRect {
        let sourceWidth = max(image.size.width, 1)
        let sourceHeight = max(image.size.height, 1)
        let scale = max(canvasSize.width / sourceWidth, canvasSize.height / sourceHeight)
        let renderedSize = CGSize(width: sourceWidth * scale, height: sourceHeight * scale)

        return CGRect(
            x: (canvasSize.width - renderedSize.width) / 2,
            y: (canvasSize.height - renderedSize.height) / 2,
            width: renderedSize.width,
            height: renderedSize.height
        )
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
