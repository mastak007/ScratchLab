import SwiftUI

struct RawJSONInspectorView: View {
    @ObservedObject var viewModel: RawJSONInspectorViewModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Raw JSON / Sidecar")
                            .font(.title2.weight(.bold))
                        Text("Advanced technical view")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Close") {
                        viewModel.close()
                        dismiss()
                    }
                }

                statusContent

                if let fileName = viewModel.selectedFileName, !fileName.isEmpty {
                    HStack(spacing: 8) {
                        Text(fileName)
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if let fileSizeDescription = viewModel.fileSizeDescription {
                            Text(fileSizeDescription)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !viewModel.previewText.isEmpty {
                    ScrollView {
                        Text(viewModel.previewText)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(12)
                    }
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .padding(20)
            .frame(minWidth: 720, minHeight: 520, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        switch viewModel.state {
        case .idle:
            Text("Choose a take to inspect.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .empty:
            VStack(alignment: .leading, spacing: 6) {
                Text("No JSON or sidecar selected")
                    .font(.headline)
                Text("Record or select a take, then open inspection.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("Loading preview...")
                    .font(.subheadline.weight(.semibold))
            }
        case .loaded:
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
            } else {
                Text("Preview ready")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.headline)
                    .foregroundStyle(.orange)
                if !viewModel.previewText.isEmpty {
                    Text("Showing the bounded raw preview below.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct StagingInspectorView: View {
    let contexts: [StagingInspectorContext]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedContextID: String

    init(contexts: [StagingInspectorContext]) {
        self.contexts = contexts
        _selectedContextID = State(initialValue: contexts.first?.id ?? "")
    }

    private var selectedContext: StagingInspectorContext? {
        contexts.first(where: { $0.id == selectedContextID }) ?? contexts.first
    }

    private var isCompactWidth: Bool {
        horizontalSizeClass == .compact
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                if isCompactWidth {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Staging Inspector")
                                .font(.title2.weight(.bold))
                            Spacer()
                            Button("Close") {
                                dismiss()
                            }
                        }

                        Text("Review blocked sessions, quarantined artifacts, watch linkage, and recent recovery activity before export.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Staging Inspector")
                                .font(.title2.weight(.bold))
                            Text("Review blocked sessions, quarantined artifacts, watch linkage, and recent recovery activity before export.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("Close") {
                            dismiss()
                        }
                    }
                }

                if contexts.count > 1 {
                    if isCompactWidth {
                        Picker("Storage", selection: $selectedContextID) {
                            ForEach(contexts) { context in
                                Text(context.title).tag(context.id)
                            }
                        }
                        .pickerStyle(.menu)
                    } else {
                        Picker("Storage", selection: $selectedContextID) {
                            ForEach(contexts) { context in
                                Text(context.title).tag(context.id)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                if let selectedContext {
                    StagingInspectorContextView(context: selectedContext)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("No Staging Context", systemImage: "tray")
                            .font(.headline)
                        Text("ScratchLab could not load a staging inspector context.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .padding(isCompactWidth ? 16 : 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .frame(minWidth: isCompactWidth ? nil : 760, minHeight: isCompactWidth ? nil : 560, alignment: .topLeading)
        }
    }
}

private struct StagingInspectorContextView: View {
    @StateObject private var store: StagingInspectorStore

    init(context: StagingInspectorContext) {
        _store = StateObject(wrappedValue: StagingInspectorStore(context: context))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                statusCard
                sessionsCard
                quarantineCard
                journalCard
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 8)
        }
    }

    private var statusCard: some View {
        InspectorCard(title: store.context.title, systemImage: "checklist") {
            VStack(alignment: .leading, spacing: 12) {
                Text(store.latestStatusText.isEmpty ? "No current status message." : store.latestStatusText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        summaryBadge("\(store.blockedSessionCount) blocked", tint: .orange)
                        summaryBadge("\(store.readySessionCount) ready", tint: .green)
                        summaryBadge("\(store.quarantineItems.count) quarantined", tint: .secondary)
                        if store.ambiguousQuarantineCount > 0 {
                            summaryBadge("\(store.ambiguousQuarantineCount) restore-blocked", tint: .red)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            summaryBadge("\(store.blockedSessionCount) blocked", tint: .orange)
                            summaryBadge("\(store.readySessionCount) ready", tint: .green)
                        }
                        HStack(spacing: 10) {
                            summaryBadge("\(store.quarantineItems.count) quarantined", tint: .secondary)
                            if store.ambiguousQuarantineCount > 0 {
                                summaryBadge("\(store.ambiguousQuarantineCount) restore-blocked", tint: .red)
                            }
                        }
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        Button("Refresh") {
                            store.refresh()
                        }
                        .buttonStyle(.bordered)

                        if let actionTitle = store.context.actionTitle,
                           store.context.runAction != nil {
                            Button(actionTitle) {
                                store.runRecoveryAction()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Button("Refresh") {
                            store.refresh()
                        }
                        .buttonStyle(.bordered)

                        if let actionTitle = store.context.actionTitle,
                           store.context.runAction != nil {
                            Button(actionTitle) {
                                store.runRecoveryAction()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
        }
    }

    private var sessionsCard: some View {
        InspectorCard(title: "Staged Sessions", systemImage: "externaldrive.badge.checkmark") {
            if store.sessions.isEmpty {
                Text("No staged sessions are available in this area.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(store.sessions) { session in
                        sessionCard(session)
                    }
                }
            }
        }
    }

    private func sessionCard(_ session: StagedSessionInspection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.summary.sessionID)
                            .font(.system(.headline, design: .monospaced))
                        Text("\(session.summary.takeCount) take(s) · \(session.summary.completedTakeCount) completed · \(session.summary.interruptedTakeCount) interrupted · \(session.summary.linkedWatchTakeCount) watch-linked")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    readinessBadge(for: session)
                }

                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.summary.sessionID)
                            .font(.system(.headline, design: .monospaced))
                        Text("\(session.summary.takeCount) take(s) · \(session.summary.completedTakeCount) completed · \(session.summary.interruptedTakeCount) interrupted · \(session.summary.linkedWatchTakeCount) watch-linked")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    readinessBadge(for: session)
                }
            }

            if !session.blockingIssues.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(session.blockingIssues, id: \.self) { issue in
                        Label(issue, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Text(session.nextActionText)
                .font(.caption.weight(.medium))
                .foregroundStyle(session.isExportReady ? Color.green : Color.orange)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(session.takes) { take in
                    takeRow(take)
                }
            }

            if !session.recentJournalEntries.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent session activity")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(session.recentJournalEntries.prefix(3)) { entry in
                        Text(journalSummary(entry))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func takeRow(_ take: StagedTakeInspection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(take.summary.takeID) · take \(take.summary.takeNumber)")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(take.summary.recordingStatus.capitalized)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(take.summary.recordingStatus == "completed" ? Color.secondary : Color.orange)
            }

            Text("Media: \(take.summary.mediaFileName)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            Text("Watch: \(take.summary.watchSyncState)\(take.summary.linkedMotionFileName.map { " · \($0)" } ?? " · unlinked")")
                .font(.caption)
                .foregroundStyle(take.isWatchLinked ? Color.secondary : Color.orange)

            if let transactionStateLabel = take.transactionSnapshot?.displayLabel {
                Text("Transaction: \(transactionStateLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let lastAuditDetail = take.summary.lastAuditDetail,
               let lastAuditCategory = take.summary.lastAuditCategory {
                Text("Audit: \(lastAuditCategory) · \(lastAuditDetail)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !take.journalEntries.isEmpty {
                DisclosureGroup("Artifact History") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(take.journalEntries) { entry in
                            Text(journalSummary(entry))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let decisionReason = entry.decisionReason,
                               !decisionReason.isEmpty {
                                Text(decisionReason)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.caption.weight(.semibold))
                .tint(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var quarantineCard: some View {
        InspectorCard(title: "Quarantine", systemImage: "tray.full.fill") {
            if store.quarantineItems.isEmpty {
                Text("No quarantined artifacts are waiting for review.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(store.quarantineItems) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.fileName)
                                .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                            Text(item.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let sessionID = item.sessionID {
                                Text("Session \(sessionID)\(item.takeID.map { " · \($0)" } ?? "")")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if let artifactRole = item.artifactRole {
                                Text("Artifact role: \(artifactRole.rawValue)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if let transactionStateLabel = item.transactionStateLabel {
                                Text("Transaction: \(transactionStateLabel)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if let decisionReason = item.decisionReason,
                               !decisionReason.isEmpty {
                                Text(decisionReason)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if !item.conflictingCandidates.isEmpty {
                                Text("Related staged artifacts: \(item.conflictingCandidates.joined(separator: ", "))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 10) {
                                    Button("Restore") {
                                        store.restoreQuarantineItem(item)
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(item.isRestoreAmbiguous)

                                    Button("Delete") {
                                        store.deleteQuarantineItem(item)
                                    }
                                    .buttonStyle(.bordered)
                                }

                                VStack(alignment: .leading, spacing: 10) {
                                    Button("Restore") {
                                        store.restoreQuarantineItem(item)
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(item.isRestoreAmbiguous)

                                    Button("Delete") {
                                        store.deleteQuarantineItem(item)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .padding(.top, 4)

                            if item.isRestoreAmbiguous {
                                Text(item.nextActionText)
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text(item.nextActionText)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            if !item.journalEntries.isEmpty {
                                DisclosureGroup("Decision History") {
                                    VStack(alignment: .leading, spacing: 6) {
                                        ForEach(item.journalEntries) { entry in
                                            Text(journalSummary(entry))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                            if let decisionReason = entry.decisionReason,
                                               !decisionReason.isEmpty {
                                                Text(decisionReason)
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }
                                        }
                                    }
                                    .padding(.top, 4)
                                }
                                .font(.caption.weight(.semibold))
                                .tint(.secondary)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }
        }
    }

    private var journalCard: some View {
        InspectorCard(title: "Recent Audit Trail", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90") {
            if store.recentJournalEntries.isEmpty {
                Text("No recent staging journal entries were found.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(store.recentJournalEntries) { entry in
                        Text(journalSummary(entry))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func journalSummary(_ entry: CaptureJournalEntry) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        let timeText = formatter.string(from: entry.timestamp)
        let target = [entry.sessionID, entry.takeID, entry.fileName, entry.transactionID].compactMap { $0 }.joined(separator: " · ")
        return [timeText, entry.kind.rawValue, target.isEmpty ? nil : target, entry.message]
            .compactMap { $0 }
            .joined(separator: " — ")
    }

    private func summaryBadge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
    }

    private func readinessBadge(for session: StagedSessionInspection) -> some View {
        Text(session.exportReadinessLabel)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(session.isExportReady ? Color.green.opacity(0.18) : Color.orange.opacity(0.2), in: Capsule())
            .foregroundStyle(session.isExportReady ? Color.green : Color.orange)
    }
}

private struct InspectorCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
