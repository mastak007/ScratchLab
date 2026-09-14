import SwiftUI
import AppKit

private enum ScratchLabDesktopWindowID {
    static let mainWindow = "main-window"
    static let performerMonitor = "performer-monitor"
    #if DEBUG
    static let travelLaneDebug = "travel-lane-debug"
    #endif
}

enum CXLReleaseRouteContract {
    static let displayName = "SL Capture"
    static let minimumWidth: CGFloat = 900
    static let minimumHeight: CGFloat = 700
    static let normalWidth: CGFloat = 1180
    static let normalHeight: CGFloat = 820
    static let stages = ["Setup", "Capture", "Review & Export"]
}

@main
struct ScratchLabDesktopApp: App {
    @StateObject private var relayedWatchCaptureStore: RelayedWatchCaptureStore
    @StateObject private var captureEngine: MacCaptureEngine
    @StateObject private var companionReceiver: CompanionCameraReceiver
    @StateObject private var performerBroadcaster: PerformerMonitorBroadcaster
    @StateObject private var sessionUploadManager: SessionUploadManager
    @StateObject private var routineSessionStore: RoutineSessionStore
    @StateObject private var progressManager: ProgressManager
    @StateObject private var practiceBeatStore = PracticeBeatStore()

    private let isRunningTests: Bool

    init() {
        let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        self.isRunningTests = isRunningTests
        #if CXL_AUTHORING
        let activateAuxiliaryServices = false
        #else
        let activateAuxiliaryServices = !isRunningTests
        #endif
        let watchCaptureStore = RelayedWatchCaptureStore()
        _relayedWatchCaptureStore = StateObject(wrappedValue: watchCaptureStore)
        _captureEngine = StateObject(
            wrappedValue: MacCaptureEngine(
                autoRefreshDevices: !isRunningTests,
                allowsSeratoDirectCaptureDiscovery: activateAuxiliaryServices,
                prefersPhysicalCaptureAudio: true
            )
        )
        _companionReceiver = StateObject(
            wrappedValue: CompanionCameraReceiver(
                relayedWatchCaptureStore: watchCaptureStore,
                autoStartBrowsing: activateAuxiliaryServices
            )
        )
        _performerBroadcaster = StateObject(
            wrappedValue: PerformerMonitorBroadcaster(startImmediately: activateAuxiliaryServices)
        )
        _sessionUploadManager = StateObject(
            wrappedValue: SessionUploadManager(activateImmediately: activateAuxiliaryServices)
        )
        _routineSessionStore = StateObject(wrappedValue: RoutineSessionStore())
        _progressManager = StateObject(wrappedValue: ProgressManager())
    }

    var body: some Scene {
        #if CXL_AUTHORING
        Window(CXLReleaseRouteContract.displayName, id: ScratchLabDesktopWindowID.mainWindow) {
            cxlReleaseContent
        }
        .defaultSize(
            width: CXLReleaseRouteContract.normalWidth,
            height: CXLReleaseRouteContract.normalHeight
        )
        .windowResizability(.contentMinSize)
        #else
        Window("ScratchLab", id: ScratchLabDesktopWindowID.mainWindow) {
            rootContent
        }
        .defaultSize(width: 1440, height: 900)
        .windowResizability(.contentSize)
        .commands {
            ScratchLabDesktopCommands(
                routineSessionStore: routineSessionStore,
                captureEngine: captureEngine
            )
        }

        WindowGroup("Performer Monitor", id: ScratchLabDesktopWindowID.performerMonitor) {
            performerMonitorContent
        }
        .windowResizability(.contentSize)

        #if DEBUG
        // DEBUG-only: a separate window hosting the self-contained TravelLaneDebugView (travel-vs-
        // speed-bucket A/B + recorded-timeline loader). Opened on demand from the Window menu; this
        // scene is compiled out of release builds and carries no production state.
        Window("Travel Lane Debug", id: ScratchLabDesktopWindowID.travelLaneDebug) {
            TravelLaneDebugView()
        }
        .windowResizability(.contentSize)
        #endif
        #endif
    }

    @ViewBuilder
    private var cxlReleaseContent: some View {
        if isRunningTests {
            Color.clear.frame(width: 1, height: 1)
        } else {
            NDAAgreementGateView {
                ReferenceAuthoringView(
                    engine: captureEngine,
                    companionReceiver: companionReceiver,
                    operatorName: NSFullUserName()
                )
                .frame(
                    minWidth: CXLReleaseRouteContract.minimumWidth,
                    minHeight: CXLReleaseRouteContract.minimumHeight
                )
            }
        }
    }

    @ViewBuilder
    private var rootContent: some View {
        if isRunningTests {
            Color.clear
                .frame(width: 1, height: 1)
        } else {
            MacAnalyzerView()
                .environmentObject(captureEngine)
                .environmentObject(companionReceiver)
                .environmentObject(relayedWatchCaptureStore)
                .environmentObject(performerBroadcaster)
                .environmentObject(practiceBeatStore)
                .environmentObject(sessionUploadManager)
                .environmentObject(routineSessionStore)
                .environmentObject(progressManager)
                .frame(minWidth: 1180, minHeight: 760)
        }
    }

    @ViewBuilder
    private var performerMonitorContent: some View {
        if isRunningTests {
            Color.clear
                .frame(width: 1, height: 1)
        } else {
            MacPerformerMonitorView()
                .environmentObject(captureEngine)
                .environmentObject(performerBroadcaster)
                .environmentObject(sessionUploadManager)
                .environmentObject(progressManager)
                .frame(minWidth: 900, minHeight: 620)
        }
    }
}

private enum NDAAgreement {
    static let version = "2026-09-14"
    static let storageKey = "SLCapture.NDAAgreementVersion"
    static let title = "Non-Disclosure Agreement"
    static let summary = ""
        + "By selecting Agree, you agree to keep SL Capture confidential. "
        + "You must not share or publish recordings, screenshots, or details of the app, "
        + "or discuss it publicly or with other DJs. Audio, video, motion, and other data "
        + "captured through the app belongs to ScratchLab. ScratchLab may revoke access at any time."
}

private struct NDAAgreementStore {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hasAcceptedCurrentVersion: Bool {
        defaults.string(forKey: NDAAgreement.storageKey) == NDAAgreement.version
    }

    func acceptCurrentVersion() {
        defaults.set(NDAAgreement.version, forKey: NDAAgreement.storageKey)
    }
}

private struct NDAAgreementGateView<Content: View>: View {
    @State private var isAccepted: Bool
    private let store: NDAAgreementStore
    private let content: () -> Content

    init(
        store: NDAAgreementStore = NDAAgreementStore(),
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.store = store
        self.content = content
        _isAccepted = State(initialValue: store.hasAcceptedCurrentVersion)
    }

    var body: some View {
        if isAccepted {
            content()
        } else {
            NDAAgreementView(
                onAgree: {
                    store.acceptCurrentVersion()
                    isAccepted = true
                },
                onDecline: {
                    NSApplication.shared.terminate(nil)
                }
            )
        }
    }
}

private struct NDAAgreementView: View {
    let onAgree: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)

            Text(NDAAgreement.title)
                .font(.title.bold())

            Text(NDAAgreement.summary)
                .font(.body)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 620)

            Text("You must agree before SL Capture can open.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Decline and Quit", role: .cancel, action: onDecline)
                Button("Agree and Continue", action: onAgree)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }
}

private struct ScratchLabDesktopCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    @ObservedObject var routineSessionStore: RoutineSessionStore
    @ObservedObject var captureEngine: MacCaptureEngine

    private var createNewSessionAction: () -> Void {
        RoutineSessionUIActionFactory.makeCreateNewSessionAction(for: routineSessionStore) { _ in
            MacWorkspaceRouting.showRoutineCapture()
            openWindow(id: ScratchLabDesktopWindowID.mainWindow)
        }
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session", action: createNewSessionAction)
                .keyboardShortcut("n", modifiers: [.command])
                .disabled(captureEngine.isRoutineRecording)

            Button("New Performer Monitor Window") {
                openWindow(id: ScratchLabDesktopWindowID.performerMonitor)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandGroup(after: .windowArrangement) {
            Button("Show ScratchLab") {
                openWindow(id: ScratchLabDesktopWindowID.mainWindow)
            }

            Button("Show Performer Monitor") {
                openWindow(id: ScratchLabDesktopWindowID.performerMonitor)
            }

            #if DEBUG
            Button("Travel Lane Debug") {
                openWindow(id: ScratchLabDesktopWindowID.travelLaneDebug)
            }
            #endif
        }
    }
}
