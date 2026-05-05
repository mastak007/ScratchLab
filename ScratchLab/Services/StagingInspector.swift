import Foundation
import SwiftUI

enum InspectorState: Equatable, Sendable {
    case idle
    case empty
    case loading
    case loaded
    case failed(String)
}

@MainActor
final class RawJSONInspectorViewModel: ObservableObject {
    @Published var state: InspectorState = .idle
    @Published var selectedFileName: String?
    @Published var previewText: String = ""
    @Published var fileSizeDescription: String?
    @Published var errorMessage: String?

    private let previewByteLimit: Int
    private let previewLineLimit: Int
    private var loadTask: Task<Void, Never>?

    init(previewByteLimit: Int = 100 * 1024, previewLineLimit: Int = 2_000) {
        self.previewByteLimit = previewByteLimit
        self.previewLineLimit = previewLineLimit
    }

    func openForCurrentSelection(_ url: URL?) {
        loadTask?.cancel()
        selectedFileName = url?.lastPathComponent
        previewText = ""
        fileSizeDescription = nil
        errorMessage = nil

        guard let url else {
            state = .empty
            return
        }

        loadPreview(url: url)
    }

    func loadPreview(url: URL) {
        loadTask?.cancel()
        selectedFileName = url.lastPathComponent
        previewText = ""
        fileSizeDescription = nil
        errorMessage = nil
        state = .loading

        loadTask = Task { [previewByteLimit, previewLineLimit] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try RawJSONPreviewLoader.loadPreview(
                        from: url,
                        previewByteLimit: previewByteLimit,
                        previewLineLimit: previewLineLimit
                    )
                }.value

                guard !Task.isCancelled else { return }
                previewText = result.previewText
                fileSizeDescription = result.fileSizeDescription
                errorMessage = result.errorMessage
                state = result.state
            } catch {
                guard !Task.isCancelled else { return }
                let message = (error as? LocalizedError)?.errorDescription
                    ?? "ScratchLab could not open \(url.lastPathComponent)."
                selectedFileName = url.lastPathComponent
                previewText = ""
                fileSizeDescription = nil
                errorMessage = message
                state = .failed(message)
            }
        }
    }

    func close() {
        loadTask?.cancel()
        loadTask = nil
        selectedFileName = nil
        previewText = ""
        fileSizeDescription = nil
        errorMessage = nil
        state = .idle
    }
}

private enum RawJSONPreviewLoader {
    fileprivate struct PreviewResult: Sendable {
        let state: InspectorState
        let previewText: String
        let fileSizeDescription: String?
        let errorMessage: String?
    }

    fileprivate static func loadPreview(
        from url: URL,
        previewByteLimit: Int,
        previewLineLimit: Int,
        fileManager: FileManager = .default
    ) throws -> PreviewResult {
        guard fileManager.fileExists(atPath: url.path) else {
            let message = "ScratchLab could not find \(url.lastPathComponent)."
            return PreviewResult(
                state: .failed(message),
                previewText: "",
                fileSizeDescription: nil,
                errorMessage: message
            )
        }

        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        let fileSize = values.fileSize ?? 0
        let fileSizeDescription = ByteCountFormatter.string(
            fromByteCount: Int64(fileSize),
            countStyle: .file
        )

        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }

        let previewData = try handle.read(upToCount: previewByteLimit + 1) ?? Data()
        let wasByteTruncated = previewData.count > previewByteLimit || fileSize > previewByteLimit
        let boundedData = wasByteTruncated ? previewData.prefix(previewByteLimit) : previewData[...]
        let rawPreview = String(decoding: boundedData, as: UTF8.self)
        let lineLimitedPreview = truncatedLinePreview(rawPreview, lineLimit: previewLineLimit)

        var previewText = lineLimitedPreview.text
        var errorMessage: String?
        let wasTruncated = wasByteTruncated || lineLimitedPreview.wasTruncated

        if !wasByteTruncated {
            do {
                _ = try JSONSerialization.jsonObject(with: Data(boundedData), options: [])
            } catch {
                errorMessage = "JSON validation failed: \(error.localizedDescription)"
            }
        }

        if wasTruncated {
            previewText += (previewText.isEmpty ? "" : "\n\n") + "Preview truncated for performance."
        }

        if let errorMessage {
            return PreviewResult(
                state: .failed(errorMessage),
                previewText: previewText,
                fileSizeDescription: fileSizeDescription,
                errorMessage: errorMessage
            )
        }

        return PreviewResult(
            state: .loaded,
            previewText: previewText,
            fileSizeDescription: fileSizeDescription,
            errorMessage: nil
        )
    }

    private static func truncatedLinePreview(_ text: String, lineLimit: Int) -> (text: String, wasTruncated: Bool) {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard lines.count > lineLimit else {
            return (text, false)
        }

        let limitedLines = lines.prefix(lineLimit).map(String.init)
        return (limitedLines.joined(separator: "\n"), true)
    }
}

struct StagingInspectorContext: Identifiable {
    let storageKind: StagedCaptureStorageKind
    let title: String
    let actionTitle: String?
    let captureDirectoryURLProvider: () -> URL?
    let statusTextProvider: () -> String
    let runAction: (() -> Void)?
    let validationReportProvider: ((String, [CaptureTakeAuditSummary], URL) -> SessionValidationReport?)?

    var id: String { storageKind.rawValue }
}

struct StagedTakeInspection: Identifiable, Equatable {
    let summary: CaptureTakeAuditSummary
    let journalEntries: [CaptureJournalEntry]
    let transactionSnapshot: CaptureTransactionSnapshot?

    var id: String { summary.id }
    var isWatchLinked: Bool { summary.linkedMotionFileName != nil }
}

struct StagedSessionInspection: Identifiable, Equatable {
    let summary: CaptureSessionAuditSummary
    let takes: [StagedTakeInspection]
    let blockingIssues: [String]
    let recentJournalEntries: [CaptureJournalEntry]

    var id: String { summary.id }

    var exportReadinessLabel: String {
        if blockingIssues.isEmpty {
            return "Ready"
        }
        return "Blocked"
    }

    var isExportReady: Bool {
        blockingIssues.isEmpty
    }

    var blockingIssueCount: Int {
        blockingIssues.count
    }

    var nextActionText: String {
        if blockingIssues.isEmpty {
            return "Ready for export, share, or upload."
        }
        if takes.contains(where: { $0.summary.recordingStatus == "interrupted" }) {
            return "Review interrupted takes before attempting export again."
        }
        if takes.contains(where: { $0.transactionSnapshot?.state == .sidecarCommittedAwaitingMedia }) {
            return "A staged sidecar is missing its media artifact. Reconcile or quarantine it before export."
        }
        if takes.contains(where: { $0.transactionSnapshot?.state == .mediaCommittedAwaitingFinalize }) {
            return "A media artifact was written without finalize. Re-scan staging and confirm the take before export."
        }
        return "Resolve the blocking validation issues below before export."
    }
}

struct StagedQuarantineInspectionItem: Identifiable, Equatable {
    let id: String
    let fileName: String
    let message: String
    let timestamp: Date?
    let sessionID: String?
    let takeID: String?
    let journalEntries: [CaptureJournalEntry]
    let artifactRole: CaptureJournalArtifactRole?
    let decisionReason: String?
    let conflictingCandidates: [String]
    let isRestoreAmbiguous: Bool
    let transactionStateLabel: String?

    var nextActionText: String {
        if isRestoreAmbiguous {
            return "Restore is blocked because ScratchLab found conflicting origin candidates. Keep this item quarantined until you can prove the correct owner."
        }
        return "Restore is allowed for manual review. Run the staging re-scan or reconcile action after restore."
    }
}

@MainActor
final class StagingInspectorStore: ObservableObject {
    @Published private(set) var latestStatusText = ""
    @Published private(set) var sessions: [StagedSessionInspection] = []
    @Published private(set) var quarantineItems: [StagedQuarantineInspectionItem] = []
    @Published private(set) var recentJournalEntries: [CaptureJournalEntry] = []
    @Published private(set) var isRefreshing = false

    let context: StagingInspectorContext

    private let fileManager: FileManager
    private let auditRootDirectoryOverride: URL?
    private let journalRootDirectoryOverride: URL?
    private let quarantineManager: CaptureQuarantineManager

    var blockedSessionCount: Int {
        sessions.filter { !$0.isExportReady }.count
    }

    var readySessionCount: Int {
        sessions.filter(\.isExportReady).count
    }

    var ambiguousQuarantineCount: Int {
        quarantineItems.filter(\.isRestoreAmbiguous).count
    }

    var restorableQuarantineCount: Int {
        quarantineItems.filter { !$0.isRestoreAmbiguous }.count
    }

    init(
        context: StagingInspectorContext,
        fileManager: FileManager = .default,
        auditRootDirectoryOverride: URL? = nil,
        journalRootDirectoryOverride: URL? = nil
    ) {
        self.context = context
        self.fileManager = fileManager
        self.auditRootDirectoryOverride = auditRootDirectoryOverride
        self.journalRootDirectoryOverride = journalRootDirectoryOverride
        self.quarantineManager = CaptureQuarantineManager(
            fileManager: fileManager,
            journalRootDirectoryOverride: journalRootDirectoryOverride
        )
        refresh()
    }

    func refresh() {
        isRefreshing = true
        defer { isRefreshing = false }

        latestStatusText = context.statusTextProvider()
        recentJournalEntries = (try? CaptureJournalStore.loadEntries(
            storageKind: context.storageKind,
            limit: 20,
            fileManager: fileManager,
            rootDirectoryOverride: journalRootDirectoryOverride
        )) ?? []

        guard let captureDirectoryURL = context.captureDirectoryURLProvider() else {
            sessions = []
            quarantineItems = []
            return
        }

        let sessionSummaries = (try? CaptureAuditStore.loadSessionSummaries(
            storageKind: context.storageKind,
            fileManager: fileManager,
            rootDirectoryOverride: auditRootDirectoryOverride
        )) ?? []

        sessions = sessionSummaries
            .sorted(by: { $0.updatedAt > $1.updatedAt })
            .map { summary in
            let takeSummaries = (try? CaptureAuditStore.loadTakeSummaries(
                sessionID: summary.sessionID,
                storageKind: context.storageKind,
                fileManager: fileManager,
                rootDirectoryOverride: auditRootDirectoryOverride
            )) ?? []
            let takeInspections = takeSummaries.map { takeSummary in
                let journalEntries = (try? CaptureJournalStore.loadEntries(
                    storageKind: context.storageKind,
                    sessionID: takeSummary.sessionID,
                    takeID: takeSummary.takeID,
                    limit: 12,
                    fileManager: fileManager,
                    rootDirectoryOverride: journalRootDirectoryOverride
                )) ?? []
                return StagedTakeInspection(
                    summary: takeSummary,
                    journalEntries: journalEntries,
                    transactionSnapshot: CaptureJournalStore.snapshot(for: journalEntries)
                )
            }
            let blockingIssues = validationIssues(
                for: summary.sessionID,
                takeSummaries: takeInspections.map(\.summary),
                captureDirectoryURL: captureDirectoryURL
            )
            let journalEntries = (try? CaptureJournalStore.loadEntries(
                storageKind: context.storageKind,
                sessionID: summary.sessionID,
                limit: 10,
                fileManager: fileManager,
                rootDirectoryOverride: journalRootDirectoryOverride
            )) ?? []
            return StagedSessionInspection(
                summary: summary,
                takes: takeInspections,
                blockingIssues: blockingIssues,
                recentJournalEntries: journalEntries
            )
        }

        quarantineItems = makeQuarantineItems(
            captureDirectoryURL: captureDirectoryURL,
            journalEntries: recentJournalEntries
        )
    }

    func runRecoveryAction() {
        context.runAction?()
        refresh()
    }

    func restoreQuarantineItem(_ item: StagedQuarantineInspectionItem) {
        guard let captureDirectoryURL = context.captureDirectoryURLProvider() else { return }
        let statusMessage: String
        do {
            _ = try quarantineManager.restoreItem(
                named: item.fileName,
                from: captureDirectoryURL,
                storageKind: context.storageKind,
                sessionID: item.sessionID,
                takeID: item.takeID
            )
            statusMessage = "Restored \(item.fileName). Run the staging action to reconcile it."
        } catch {
            statusMessage = (error as? LocalizedError)?.errorDescription ?? "ScratchLab could not restore \(item.fileName)."
        }
        refresh()
        latestStatusText = statusMessage
    }

    func deleteQuarantineItem(_ item: StagedQuarantineInspectionItem) {
        guard let captureDirectoryURL = context.captureDirectoryURLProvider() else { return }
        let statusMessage: String
        do {
            try quarantineManager.deleteItem(
                named: item.fileName,
                from: captureDirectoryURL,
                storageKind: context.storageKind,
                sessionID: item.sessionID,
                takeID: item.takeID
            )
            statusMessage = "Deleted quarantined artifact \(item.fileName)."
        } catch {
            statusMessage = (error as? LocalizedError)?.errorDescription ?? "ScratchLab could not delete \(item.fileName)."
        }
        refresh()
        latestStatusText = statusMessage
    }

    private func validationIssues(
        for sessionID: String,
        takeSummaries: [CaptureTakeAuditSummary],
        captureDirectoryURL: URL
    ) -> [String] {
        guard context.storageKind == .companion || context.storageKind == .routine else {
            return []
        }
        guard let latestTake = takeSummaries.max(by: { lhs, rhs in
            if lhs.startedAt == rhs.startedAt {
                return lhs.takeNumber < rhs.takeNumber
            }
            return lhs.startedAt < rhs.startedAt
        }) else {
            return ["No staged takes are available for this session."]
        }

        if let validationReportProvider = context.validationReportProvider,
           let report = validationReportProvider(sessionID, takeSummaries, captureDirectoryURL) {
            return report.issues
        }

        let latestRecordingURL = captureDirectoryURL.appendingPathComponent(latestTake.mediaFileName)
        let report = SessionArchiveBuilder().validationReport(
            for: .localRecordingSession(
                lastRecordingURL: latestRecordingURL,
                sessionName: sessionID,
                config: nil
            )
        )
        return report?.issues ?? []
    }

    private func makeQuarantineItems(
        captureDirectoryURL: URL,
        journalEntries: [CaptureJournalEntry]
    ) -> [StagedQuarantineInspectionItem] {
        let quarantineDirectory = captureDirectoryURL.appendingPathComponent("Quarantine", isDirectory: true)
        let fileURLs = (try? fileManager.contentsOfDirectory(
            at: quarantineDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return fileURLs.map { url in
            let itemHistory = (try? CaptureJournalStore.loadEntries(
                storageKind: context.storageKind,
                fileName: url.lastPathComponent,
                limit: 12,
                fileManager: fileManager,
                rootDirectoryOverride: journalRootDirectoryOverride
            )) ?? []
            let matchingEntry = itemHistory.first ?? journalEntries.first(where: { $0.fileName == url.lastPathComponent })
            let assessment = quarantineManager.assessRestoreCandidate(
                named: url.lastPathComponent,
                from: captureDirectoryURL,
                storageKind: context.storageKind,
                sessionID: matchingEntry?.sessionID,
                takeID: matchingEntry?.takeID
            )
            return StagedQuarantineInspectionItem(
                id: url.lastPathComponent,
                fileName: url.lastPathComponent,
                message: matchingEntry?.message ?? "Quarantined artifact requires operator review.",
                timestamp: matchingEntry?.timestamp,
                sessionID: matchingEntry?.sessionID,
                takeID: matchingEntry?.takeID,
                journalEntries: itemHistory,
                artifactRole: assessment.artifactRole,
                decisionReason: assessment.decisionReason,
                conflictingCandidates: assessment.conflictingCandidates,
                isRestoreAmbiguous: assessment.isAmbiguous,
                transactionStateLabel: assessment.transactionSnapshot?.displayLabel
            )
        }
        .sorted { lhs, rhs in
            switch (lhs.timestamp, rhs.timestamp) {
            case let (left?, right?):
                return left > right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return lhs.fileName < rhs.fileName
            }
        }
    }
}
