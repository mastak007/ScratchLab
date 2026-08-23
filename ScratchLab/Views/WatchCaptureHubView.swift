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
                .font(ScratchLabDesign.Typo.pageTitle)
                .foregroundColor(ScratchLabDesign.Sem.textPrimary)

            Text(watchMotionCaptureStore.connectionSummary)
                .font(ScratchLabDesign.Typo.pageSubtitle)
                .foregroundColor(ScratchLabDesign.Sem.textSecondary)

            VStack(alignment: .leading, spacing: 8) {
                statusRow(
                    label: "Paired Watch",
                    value: watchMotionCaptureStore.isWatchPaired ? "Yes" : "No",
                    isPositive: watchMotionCaptureStore.isWatchPaired
                )
                statusRow(
                    label: "Watch App Installed",
                    value: watchMotionCaptureStore.isWatchAppInstalled ? "Yes" : "No",
                    isPositive: watchMotionCaptureStore.isWatchAppInstalled
                )
                statusRow(
                    label: "Reachable Right Now",
                    value: watchMotionCaptureStore.isWatchReachable ? "Yes" : "No",
                    isPositive: watchMotionCaptureStore.isWatchReachable
                )
                statusRow(label: "Import Status", value: watchMotionCaptureStore.lastImportStatus, isPositive: nil)
            }
        }
        .scratchLabCard(.selected)
    }

    private var workflowCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quick flow")
                .font(ScratchLabDesign.Typo.cardHeading)
                .foregroundColor(ScratchLabDesign.Sem.textPrimary)

            Text("1. Open ScratchLab on the watch and paired device.")
                .font(ScratchLabDesign.Typo.body)
                .foregroundColor(ScratchLabDesign.Sem.textSecondary)

            Text("2. Tap Start on the watch, perform the take, then tap Stop.")
                .font(ScratchLabDesign.Typo.body)
                .foregroundColor(ScratchLabDesign.Sem.textSecondary)

            Text("3. Keep the watch app open until the transfer finishes.")
                .font(ScratchLabDesign.Typo.body)
                .foregroundColor(ScratchLabDesign.Sem.textSecondary)

            Text("4. Export JSON or CSV here when you need to share the motion log.")
                .font(ScratchLabDesign.Typo.body)
                .foregroundColor(ScratchLabDesign.Sem.textSecondary)
        }
        .scratchLabCard(.standard)
    }

    private var sessionsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Imported Sessions")
                .font(ScratchLabDesign.Typo.cardHeading)
                .foregroundColor(ScratchLabDesign.Sem.textPrimary)

            if watchMotionCaptureStore.importedSessions.isEmpty {
                Text("No motion sessions have been imported yet.")
                    .font(ScratchLabDesign.Typo.pageSubtitle)
                    .foregroundColor(ScratchLabDesign.Sem.textSecondary)
                    .padding(.vertical, 12)
            } else {
                ForEach(watchMotionCaptureStore.importedSessions) { capture in
                    WatchCaptureSessionCard(capture: capture)
                        .environmentObject(watchMotionCaptureStore)
                }
            }
        }
        .scratchLabCard(.standard)
    }

    private func statusRow(label: String, value: String, isPositive: Bool?) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(ScratchLabDesign.Typo.metricLabel)
                .foregroundColor(ScratchLabDesign.Sem.textAccent)
                .frame(width: 124, alignment: .leading)

            Text(value)
                .font(ScratchLabDesign.Typo.bodySecondary)
                .foregroundColor(statusRowValueColor(isPositive: isPositive))
        }
    }

    /// `isPositive == nil` is a free-text status (e.g. Import Status), which
    /// stays neutral text rather than being force-fit into success/muted —
    /// only the three genuine yes/no connectivity facts get a semantic tint,
    /// and even "Yes" only reaches `Sem.info` ("connected"), never
    /// `Sem.success`, since pairing/installation/reachability are connection
    /// facts, not proof the watch is ready to capture.
    private func statusRowValueColor(isPositive: Bool?) -> Color {
        switch isPositive {
        case true:  return ScratchLabDesign.Sem.info
        case false: return ScratchLabDesign.Sem.textTertiary
        case nil:   return ScratchLabDesign.Sem.textSecondary
        }
    }
}

private struct WatchCaptureSessionCard: View {
    @EnvironmentObject private var watchMotionCaptureStore: WatchMotionCaptureStore

    let capture: ImportedWatchMotionCapture

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(dateFormatter.string(from: capture.session.startedAt))
                .font(ScratchLabDesign.Typo.title3)
                .foregroundColor(ScratchLabDesign.Sem.textPrimary)

            Text("Motion: \(capture.session.sampleCount) • \(durationString(capture.session.duration))")
                .font(ScratchLabDesign.Typo.bodySecondary)
                .foregroundColor(ScratchLabDesign.Sem.textSecondary)

            HStack(spacing: 12) {
                ShareLink(item: watchMotionCaptureStore.jsonExportURL(for: capture)) {
                    exportBadge(title: "Share JSON", color: ScratchLabDesign.Sem.accent)
                }

                if let csvURL = watchMotionCaptureStore.csvExportURL(for: capture) {
                    ShareLink(item: csvURL) {
                        exportBadge(title: "Share CSV", color: ScratchLabDesign.Sem.success)
                    }
                }
            }
        }
        .padding(ScratchLabDesign.Card.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ScratchLabDesign.Surface.surface, in: RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.card, style: .continuous))
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
            .font(ScratchLabDesign.Typo.chipLabel)
            .foregroundColor(ScratchLabDesign.Sem.textOnAccent)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(color, in: RoundedRectangle(cornerRadius: ScratchLabDesign.Radius.control, style: .continuous))
    }
}
