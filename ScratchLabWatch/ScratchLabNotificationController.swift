import SwiftUI
import UserNotifications
import WatchKit

struct ScratchLabNotificationView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding()
    }
}

final class ScratchLabNotificationController: WKUserNotificationHostingController<ScratchLabNotificationView> {
    static let category = "SCRATCHLAB_NOTIFICATION"

    private var title = "ScratchLab"
    private var message = "Watch capture alerts appear here."

    override var body: ScratchLabNotificationView {
        ScratchLabNotificationView(title: title, message: message)
    }

    override func didReceive(_ notification: UNNotification) {
        title = notification.request.content.title.isEmpty ? "ScratchLab" : notification.request.content.title
        message = notification.request.content.body.isEmpty ? "Watch capture alerts appear here." : notification.request.content.body
    }
}
