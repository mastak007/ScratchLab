import SwiftUI

struct WatchCaptureHubView: View {
    @EnvironmentObject private var watchMotionCaptureStore: WatchMotionCaptureStore

    var body: some View {
        ZStack {
            BackgroundView()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    headerCard
                    workflowCard
                    sessionsCard
                }
                .padding(20)
            }
        }
        .navigationTitle("Watch Capture")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            watchMotionCaptureStore.activateIfNeeded()
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Watch Capture")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white)

            Text(watchMotionCaptureStore.connectionSummary)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.72))

            VStack(alignment: .leading, spacing: 8) {
                statusRow(label: "Paired Watch", value: watchMotionCaptureStore.isWatchPaired ? "Yes" : "No")
                statusRow(label: "Watch App Installed", value: watchMotionCaptureStore.isWatchAppInstalled ? "Yes" : "No")
                statusRow(label: "Reachable Right Now", value: watchMotionCaptureStore.isWatchReachable ? "Yes" : "No")
                statusRow(label: "Import Status", value: watchMotionCaptureStore.lastImportStatus)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(hex: "3B82F6").opacity(0.35), lineWidth: 1)
        )
        .cornerRadius(8)
    }

    private var workflowCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quick flow")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)

            Text("1. Open ScratchLab on the watch and paired device.")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.75))

            Text("2. Tap Start on the watch, perform the take, then tap Stop.")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.75))

            Text("3. Keep the watch app open until the transfer finishes.")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.75))

            Text("4. Export JSON or CSV here when you need to share the motion log.")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.75))
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06))
        .cornerRadius(8)
    }

    private var sessionsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Imported Sessions")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)

            if watchMotionCaptureStore.importedSessions.isEmpty {
                Text("No motion sessions have been imported yet.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.65))
                    .padding(.vertical, 12)
            } else {
                ForEach(watchMotionCaptureStore.importedSessions) { capture in
                    WatchCaptureSessionCard(capture: capture)
                        .environmentObject(watchMotionCaptureStore)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06))
        .cornerRadius(8)
    }

    private func statusRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(Color(hex: "93C5FD"))
                .frame(width: 124, alignment: .leading)

            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.82))
        }
    }
}

private struct WatchCaptureSessionCard: View {
    @EnvironmentObject private var watchMotionCaptureStore: WatchMotionCaptureStore

    let capture: ImportedWatchMotionCapture

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(dateFormatter.string(from: capture.session.startedAt))
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)

            Text("Motion: \(capture.session.sampleCount) • \(durationString(capture.session.duration))")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.68))

            HStack(spacing: 12) {
                ShareLink(item: watchMotionCaptureStore.jsonExportURL(for: capture)) {
                    exportBadge(title: "Share JSON", color: Color(hex: "0EA5E9"))
                }

                if let csvURL = watchMotionCaptureStore.csvExportURL(for: capture) {
                    ShareLink(item: csvURL) {
                        exportBadge(title: "Share CSV", color: Color(hex: "10B981"))
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.18))
        .cornerRadius(8)
    }

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }

    private func durationString(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }

    private func exportBadge(title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(color)
            .cornerRadius(8)
    }
}
