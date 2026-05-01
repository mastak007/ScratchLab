import SwiftUI

@main
struct ScratchLabWatchApp: App {
    @StateObject private var recorder = WatchMotionRecorder()

    var body: some Scene {
        WindowGroup {
            WatchCaptureView()
                .environmentObject(recorder)
        }

        WKNotificationScene(controller: ScratchLabNotificationController.self, category: ScratchLabNotificationController.category)
    }
}
