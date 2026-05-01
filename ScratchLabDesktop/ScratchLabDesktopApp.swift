import SwiftUI

private enum ScratchLabDesktopWindowID {
    static let mainWindow = "main-window"
    static let performerMonitor = "performer-monitor"
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
        let watchCaptureStore = RelayedWatchCaptureStore()
        _relayedWatchCaptureStore = StateObject(wrappedValue: watchCaptureStore)
        _captureEngine = StateObject(wrappedValue: MacCaptureEngine(autoRefreshDevices: !isRunningTests))
        _companionReceiver = StateObject(
            wrappedValue: CompanionCameraReceiver(
                relayedWatchCaptureStore: watchCaptureStore,
                autoStartBrowsing: !isRunningTests
            )
        )
        _performerBroadcaster = StateObject(
            wrappedValue: PerformerMonitorBroadcaster(startImmediately: !isRunningTests)
        )
        _sessionUploadManager = StateObject(
            wrappedValue: SessionUploadManager(activateImmediately: !isRunningTests)
        )
        _routineSessionStore = StateObject(wrappedValue: RoutineSessionStore())
        _progressManager = StateObject(wrappedValue: ProgressManager())
    }

    var body: some Scene {
        Window("ScratchLab", id: ScratchLabDesktopWindowID.mainWindow) {
            rootContent
        }
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
        }
    }
}
