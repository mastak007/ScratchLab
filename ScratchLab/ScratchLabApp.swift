// ScratchLabApp.swift
// ScratchLab
// Main application entry point

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum QuickStartSettings {
    static let hasSeenKey = "hasSeenQuickStart"
    static let versionKey = "quickStartVersion"
    static let currentVersion = 1
}

@main
struct ScratchLabApp: App {
    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(ScratchLabAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            RootContainerView()
                .preferredColorScheme(.dark)
        }
    }
}

private struct RootContainerView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var gameState = GameState()
    @StateObject private var audioEngine = AudioEngine()
    @StateObject private var progressManager = ProgressManager()
    @StateObject private var practiceBeatStore = PracticeBeatStore()
    @StateObject private var companionRelayBroadcaster = CompanionCameraBroadcaster()
    @StateObject private var watchMotionCaptureStore = WatchMotionCaptureStore()
    @StateObject private var sessionUploadManager = SessionUploadManager()

    var body: some View {
        ContentView()
            .environmentObject(gameState)
            .environmentObject(audioEngine)
            .environmentObject(progressManager)
            .environmentObject(practiceBeatStore)
            .environmentObject(companionRelayBroadcaster)
            .environmentObject(watchMotionCaptureStore)
            .environmentObject(sessionUploadManager)
            .onAppear {
                configureWatchRelay()
                refreshWatchCapturePipelineIfNeeded()
                sessionUploadManager.refresh()
            }
            .onChange(of: companionRelayBroadcaster.pendingWatchControlCommand) { _, command in
                guard let command else { return }
                handleRemoteWatchControlCommand(command)
            }
            .onChange(of: companionRelayBroadcaster.connectedPeerNames) { _, peers in
                guard !peers.isEmpty, let latestCapture = watchMotionCaptureStore.importedSessions.first else { return }
                companionRelayBroadcaster.sendWatchCaptureSession(
                    latestCapture.session,
                    fileName: latestCapture.fileURL.lastPathComponent
                )
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else {
                    practiceBeatStore.handleAppDidBecomeInactive()
                    return
                }
                configureWatchRelay()
                refreshWatchCapturePipelineIfNeeded()
                sessionUploadManager.refresh()
            }
    }

    private func configureWatchRelay() {
        companionRelayBroadcaster.startRelayAdvertisingIfNeeded()
        watchMotionCaptureStore.onImportedCapture = { importedCapture in
            companionRelayBroadcaster.sendWatchCaptureSession(
                importedCapture.session,
                fileName: importedCapture.fileURL.lastPathComponent
            )
        }
    }

    private func refreshWatchCapturePipelineIfNeeded() {
        watchMotionCaptureStore.activateIfNeeded()
        watchMotionCaptureStore.checkForPendingImports()
    }

    private func handleRemoteWatchControlCommand(_ command: CompanionCameraBroadcaster.WatchControlCommandEvent) {
        switch command.payload.command {
        case .start:
            watchMotionCaptureStore.requestRemoteCaptureStart(
                sessionID: command.payload.sessionID,
                takeID: command.payload.takeID ?? ""
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
    @EnvironmentObject var gameState: GameState
    @State private var showSplash = true
    @State private var showingQuickStart = false
    @AppStorage(QuickStartSettings.hasSeenKey) private var hasSeenQuickStart = false
    @AppStorage(QuickStartSettings.versionKey) private var quickStartVersion = 0
    
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
            
            if showSplash {
                SplashView(showSplash: $showSplash)
            } else {
                NavigationStack {
                    MainMenuView()
                }
            }
        }
        .onAppear {
            presentQuickStartIfNeeded()
        }
        .onChange(of: showSplash) { _, isShowingSplash in
            if !isShowingSplash {
                presentQuickStartIfNeeded()
            }
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
        guard !showSplash, needsQuickStart else { return }
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

            VStack(spacing: 24) {
                HStack {
                    if currentPage > 0 {
                        Button("Back") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                currentPage -= 1
                            }
                        }
                        .font(.headline)
                        .foregroundColor(.white.opacity(0.86))
                        .accessibilityLabel("Back")
                    } else {
                        Color.clear
                            .frame(width: 44, height: 24)
                            .accessibilityHidden(true)
                    }

                    Spacer()

                    Button("Skip") {
                        onFinish()
                    }
                    .font(.headline)
                    .foregroundColor(Color(hex: "00D4FF"))
                    .accessibilityLabel("Skip Quick Start")
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)

                TabView(selection: $currentPage) {
                    ForEach(pages) { page in
                        QuickStartPageView(page: page)
                            .padding(.horizontal, 24)
                            .tag(page.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .interactive))

                Button(action: advanceOrFinish) {
                    Text(currentPage == pages.count - 1 ? "Start Session" : "Next")
                        .font(.headline)
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(Color(hex: "00D4FF"))
                        .cornerRadius(8)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
                .accessibilityLabel(currentPage == pages.count - 1 ? "Start Session" : "Next quick start page")
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

private struct QuickStartPageView: View {
    let page: QuickStartPage

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 20)

            Image(systemName: page.icon)
                .font(.system(size: 56, weight: .semibold))
                .foregroundColor(Color(hex: "00D4FF"))
                .accessibilityHidden(true)

            Text(page.title)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.85)
                .accessibilityLabel(page.title)

            VStack(spacing: 14) {
                ForEach(page.lines, id: \.self) { line in
                    HStack(alignment: .top, spacing: 12) {
                        Circle()
                            .fill(Color(hex: "00D4FF"))
                            .frame(width: 8, height: 8)
                            .padding(.top, 7)
                            .accessibilityHidden(true)

                        Text(line)
                            .font(.title3.weight(.medium))
                            .foregroundColor(.white.opacity(0.84))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(maxWidth: 520)

            Spacer(minLength: 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
