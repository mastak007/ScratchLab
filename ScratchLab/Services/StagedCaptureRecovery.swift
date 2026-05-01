import Foundation

enum StagedCaptureStorageKind: String, Codable, Sendable {
    case companion
    case routine
    case importedWatch
    case relayedWatch

    var title: String {
        switch self {
        case .companion:
            return "Companion Capture"
        case .routine:
            return "Routine Capture"
        case .importedWatch:
            return "Watch Capture"
        case .relayedWatch:
            return "Relayed Watch Capture"
        }
    }
}

enum StagedCaptureIssueSeverity: String, Codable, Sendable {
    case info
    case warning
    case blocking
}

enum StagedCaptureIssueCode: String, Codable, Sendable {
    case interruptedCaptureRecovered
    case linkedWatchCapture
    case quarantinedMissingMediaSidecar
    case quarantinedOrphanedMedia
    case quarantinedDuplicateWatchCapture
    case quarantinedUnlinkedWatchCapture
    case quarantinedInvalidWatchCapture
}

struct StagedCaptureIssue: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let storageKind: StagedCaptureStorageKind
    let severity: StagedCaptureIssueSeverity
    let code: StagedCaptureIssueCode
    let message: String
    let sessionID: String?
    let takeID: String?
    let fileName: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        storageKind: StagedCaptureStorageKind,
        severity: StagedCaptureIssueSeverity,
        code: StagedCaptureIssueCode,
        message: String,
        sessionID: String? = nil,
        takeID: String? = nil,
        fileName: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.storageKind = storageKind
        self.severity = severity
        self.code = code
        self.message = message
        self.sessionID = sessionID
        self.takeID = takeID
        self.fileName = fileName
    }
}

struct CaptureTakeAuditSummary: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let storageKind: StagedCaptureStorageKind
    let sessionID: String
    let takeID: String
    let takeNumber: Int
    let recordingStatus: String
    let watchSyncState: String
    let mediaFileName: String
    let sidecarFileName: String
    let linkedMotionFileName: String?
    let startedAt: Date
    let endedAt: Date?
    let updatedAt: Date
    let auditEventCount: Int
    let lastAuditCategory: String?
    let lastAuditDetail: String?

    init(
        storageKind: StagedCaptureStorageKind,
        sidecar: CaptureCore.LocalRecordingSidecar,
        updatedAt: Date = Date()
    ) {
        self.id = "\(sidecar.sessionID)::\(sidecar.takeID)"
        self.storageKind = storageKind
        self.sessionID = sidecar.sessionID
        self.takeID = sidecar.takeID
        self.takeNumber = sidecar.appLocalTakeNumber
        self.recordingStatus = sidecar.recordingStatus
        self.watchSyncState = sidecar.watchSyncState.rawValue
        self.mediaFileName = sidecar.mediaFileName
        self.sidecarFileName = sidecar.sidecarFileName
        self.linkedMotionFileName = sidecar.linkedMotionFileName
        self.startedAt = sidecar.startedAt
        self.endedAt = sidecar.endedAt
        self.updatedAt = updatedAt
        self.auditEventCount = sidecar.auditTrail.count
        self.lastAuditCategory = sidecar.auditTrail.last?.category
        self.lastAuditDetail = sidecar.auditTrail.last?.detail
    }

    init(
        id: String,
        storageKind: StagedCaptureStorageKind,
        sessionID: String,
        takeID: String,
        takeNumber: Int,
        recordingStatus: String,
        watchSyncState: String,
        mediaFileName: String,
        sidecarFileName: String,
        linkedMotionFileName: String?,
        startedAt: Date,
        endedAt: Date?,
        updatedAt: Date = Date(),
        auditEventCount: Int,
        lastAuditCategory: String?,
        lastAuditDetail: String?
    ) {
        self.id = id
        self.storageKind = storageKind
        self.sessionID = sessionID
        self.takeID = takeID
        self.takeNumber = takeNumber
        self.recordingStatus = recordingStatus
        self.watchSyncState = watchSyncState
        self.mediaFileName = mediaFileName
        self.sidecarFileName = sidecarFileName
        self.linkedMotionFileName = linkedMotionFileName
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.updatedAt = updatedAt
        self.auditEventCount = auditEventCount
        self.lastAuditCategory = lastAuditCategory
        self.lastAuditDetail = lastAuditDetail
    }
}

struct CaptureSessionAuditSummary: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let storageKind: StagedCaptureStorageKind
    let sessionID: String
    let updatedAt: Date
    let takeCount: Int
    let completedTakeCount: Int
    let interruptedTakeCount: Int
    let failedTakeCount: Int
    let linkedWatchTakeCount: Int
    let takeIDs: [String]
}

enum CaptureJournalEntryKind: String, Codable, Sendable {
    case transactionBegan
    case sidecarWriteCommitted
    case mediaWriteCommitted
    case transactionFinalized
    case recoveryScanCompleted
    case reconciliationCompleted
    case interruptedCaptureRecovered
    case watchCaptureLinked
    case artifactQuarantined
    case quarantineItemRestored
    case quarantineItemDeleted
    case validationBlocked
}

enum CaptureJournalArtifactRole: String, Codable, Sendable {
    case sidecar
    case media
    case watch
    case audio
    case session
}

struct CaptureJournalEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let storageKind: StagedCaptureStorageKind
    let kind: CaptureJournalEntryKind
    let message: String
    let sessionID: String?
    let takeID: String?
    let transactionID: String?
    let fileName: String?
    let artifactRole: CaptureJournalArtifactRole?
    let relatedFileNames: [String]
    let decisionReason: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        storageKind: StagedCaptureStorageKind,
        kind: CaptureJournalEntryKind,
        message: String,
        sessionID: String? = nil,
        takeID: String? = nil,
        transactionID: String? = nil,
        fileName: String? = nil,
        artifactRole: CaptureJournalArtifactRole? = nil,
        relatedFileNames: [String] = [],
        decisionReason: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.storageKind = storageKind
        self.kind = kind
        self.message = message
        self.sessionID = sessionID
        self.takeID = takeID
        self.transactionID = transactionID
        self.fileName = fileName
        self.artifactRole = artifactRole
        self.relatedFileNames = relatedFileNames
        self.decisionReason = decisionReason
    }

    static func transactionID(sessionID: String, takeID: String) -> String {
        "\(sessionID)::\(takeID)"
    }
}

enum CaptureTransactionState: String, Codable, Sendable {
    case beganNoArtifactsWritten
    case sidecarCommittedAwaitingMedia
    case mediaCommittedAwaitingFinalize
    case finalized
}

struct CaptureTransactionSnapshot: Identifiable, Equatable, Sendable {
    let id: String
    let storageKind: StagedCaptureStorageKind
    let sessionID: String?
    let takeID: String?
    let transactionID: String?
    let state: CaptureTransactionState
    let lastUpdatedAt: Date
    let relatedFileNames: [String]
    let entries: [CaptureJournalEntry]

    var displayLabel: String {
        switch state {
        case .beganNoArtifactsWritten:
            return "Began, no artifacts written"
        case .sidecarCommittedAwaitingMedia:
            return "Sidecar committed, media missing"
        case .mediaCommittedAwaitingFinalize:
            return "Media committed, finalize missing"
        case .finalized:
            return "Finalized"
        }
    }
}

struct CaptureQuarantineRestoreAssessment: Equatable, Sendable {
    let itemFileName: String
    let sessionID: String?
    let takeID: String?
    let artifactRole: CaptureJournalArtifactRole?
    let decisionReason: String?
    let conflictingCandidates: [String]
    let isAmbiguous: Bool
    let transactionSnapshot: CaptureTransactionSnapshot?
}

struct StagedCaptureRecoveryReport: Equatable, Sendable {
    let storageKind: StagedCaptureStorageKind
    let issues: [StagedCaptureIssue]

    var blockingIssues: [StagedCaptureIssue] {
        issues.filter { $0.severity == .blocking }
    }

    var recoveredInterruptedCount: Int {
        issues.filter { $0.code == .interruptedCaptureRecovered }.count
    }

    var quarantinedArtifactCount: Int {
        issues.filter {
            switch $0.code {
            case .quarantinedMissingMediaSidecar,
                    .quarantinedOrphanedMedia,
                    .quarantinedDuplicateWatchCapture,
                    .quarantinedUnlinkedWatchCapture,
                    .quarantinedInvalidWatchCapture:
                return true
            case .interruptedCaptureRecovered,
                    .linkedWatchCapture:
                return false
            }
        }.count
    }

    var summaryText: String? {
        guard !issues.isEmpty else { return nil }
        let recoveredText = recoveredInterruptedCount > 0 ? "recovered \(recoveredInterruptedCount) interrupted take\(recoveredInterruptedCount == 1 ? "" : "s")" : nil
        let quarantinedText = quarantinedArtifactCount > 0 ? "quarantined \(quarantinedArtifactCount) orphaned artifact\(quarantinedArtifactCount == 1 ? "" : "s")" : nil
        let parts = [recoveredText, quarantinedText].compactMap { $0 }
        guard !parts.isEmpty else { return "\(storageKind.title) needs attention." }
        return "\(storageKind.title): \(parts.joined(separator: ", "))."
    }

    static func empty(for storageKind: StagedCaptureStorageKind) -> StagedCaptureRecoveryReport {
        StagedCaptureRecoveryReport(storageKind: storageKind, issues: [])
    }
}

enum CaptureAuditStore {
    private static func auditRootURL(fileManager: FileManager, rootDirectoryOverride: URL?) -> URL {
        if let rootDirectoryOverride {
            return rootDirectoryOverride
        }
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return baseURL
            .appendingPathComponent("ScratchLab", isDirectory: true)
            .appendingPathComponent("AuditSummaries", isDirectory: true)
    }

    private static func takeSummaryDirectoryURL(
        storageKind: StagedCaptureStorageKind,
        fileManager: FileManager,
        rootDirectoryOverride: URL?
    ) -> URL {
        auditRootURL(fileManager: fileManager, rootDirectoryOverride: rootDirectoryOverride)
            .appendingPathComponent(storageKind.rawValue, isDirectory: true)
            .appendingPathComponent("takes", isDirectory: true)
    }

    private static func sessionSummaryDirectoryURL(
        storageKind: StagedCaptureStorageKind,
        fileManager: FileManager,
        rootDirectoryOverride: URL?
    ) -> URL {
        auditRootURL(fileManager: fileManager, rootDirectoryOverride: rootDirectoryOverride)
            .appendingPathComponent(storageKind.rawValue, isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    private static func takeSummaryURL(
        sessionID: String,
        takeID: String,
        storageKind: StagedCaptureStorageKind,
        fileManager: FileManager,
        rootDirectoryOverride: URL?
    ) -> URL {
        takeSummaryDirectoryURL(storageKind: storageKind, fileManager: fileManager, rootDirectoryOverride: rootDirectoryOverride)
            .appendingPathComponent("\(sessionID)__\(takeID).json")
    }

    private static func sessionSummaryURL(
        sessionID: String,
        storageKind: StagedCaptureStorageKind,
        fileManager: FileManager,
        rootDirectoryOverride: URL?
    ) -> URL {
        sessionSummaryDirectoryURL(storageKind: storageKind, fileManager: fileManager, rootDirectoryOverride: rootDirectoryOverride)
            .appendingPathComponent("\(sessionID).json")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func persist(
        sidecar: CaptureCore.LocalRecordingSidecar,
        storageKind: StagedCaptureStorageKind,
        fileManager: FileManager = .default,
        rootDirectoryOverride: URL? = nil
    ) throws {
        let takeSummaryDirectory = takeSummaryDirectoryURL(
            storageKind: storageKind,
            fileManager: fileManager,
            rootDirectoryOverride: rootDirectoryOverride
        )
        let sessionSummaryDirectory = sessionSummaryDirectoryURL(
            storageKind: storageKind,
            fileManager: fileManager,
            rootDirectoryOverride: rootDirectoryOverride
        )
        try fileManager.createDirectory(at: takeSummaryDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sessionSummaryDirectory, withIntermediateDirectories: true)

        let takeSummary = CaptureTakeAuditSummary(storageKind: storageKind, sidecar: sidecar)
        let takeURL = takeSummaryURL(
            sessionID: sidecar.sessionID,
            takeID: sidecar.takeID,
            storageKind: storageKind,
            fileManager: fileManager,
            rootDirectoryOverride: rootDirectoryOverride
        )
        try encoder.encode(takeSummary).write(to: takeURL, options: .atomic)

        let summaries = try loadTakeSummaries(
            sessionID: sidecar.sessionID,
            storageKind: storageKind,
            fileManager: fileManager,
            rootDirectoryOverride: rootDirectoryOverride
        )
        let sessionSummary = CaptureSessionAuditSummary(
            id: sidecar.sessionID,
            storageKind: storageKind,
            sessionID: sidecar.sessionID,
            updatedAt: Date(),
            takeCount: summaries.count,
            completedTakeCount: summaries.filter { $0.recordingStatus == "completed" }.count,
            interruptedTakeCount: summaries.filter { $0.recordingStatus == "interrupted" }.count,
            failedTakeCount: summaries.filter { $0.recordingStatus == "failed" }.count,
            linkedWatchTakeCount: summaries.filter { $0.linkedMotionFileName != nil }.count,
            takeIDs: summaries.map(\.takeID).sorted()
        )
        let sessionURL = sessionSummaryURL(
            sessionID: sidecar.sessionID,
            storageKind: storageKind,
            fileManager: fileManager,
            rootDirectoryOverride: rootDirectoryOverride
        )
        try encoder.encode(sessionSummary).write(to: sessionURL, options: .atomic)

        try? CaptureJournalStore.append(
            CaptureJournalEntry(
                storageKind: storageKind,
                kind: .sidecarWriteCommitted,
                message: "\(storageKind.title) persisted \(sidecar.recordingStatus) state for \(sidecar.takeID).",
                sessionID: sidecar.sessionID,
                takeID: sidecar.takeID,
                transactionID: CaptureJournalEntry.transactionID(sessionID: sidecar.sessionID, takeID: sidecar.takeID),
                fileName: sidecar.sidecarFileName,
                artifactRole: .sidecar,
                relatedFileNames: [sidecar.sidecarFileName, sidecar.mediaFileName],
                decisionReason: sidecar.errorDescription
            ),
            fileManager: fileManager,
            rootDirectoryOverride: rootDirectoryOverride
        )
    }

    static func persist(
        takeSummary: CaptureTakeAuditSummary,
        storageKind: StagedCaptureStorageKind,
        fileManager: FileManager = .default,
        rootDirectoryOverride: URL? = nil
    ) throws {
        let takeSummaryDirectory = takeSummaryDirectoryURL(
            storageKind: storageKind,
            fileManager: fileManager,
            rootDirectoryOverride: rootDirectoryOverride
        )
        let sessionSummaryDirectory = sessionSummaryDirectoryURL(
            storageKind: storageKind,
            fileManager: fileManager,
            rootDirectoryOverride: rootDirectoryOverride
        )
        try fileManager.createDirectory(at: takeSummaryDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sessionSummaryDirectory, withIntermediateDirectories: true)

        let takeURL = takeSummaryURL(
            sessionID: takeSummary.sessionID,
            takeID: takeSummary.takeID,
            storageKind: storageKind,
            fileManager: fileManager,
            rootDirectoryOverride: rootDirectoryOverride
        )
        try encoder.encode(takeSummary).write(to: takeURL, options: .atomic)

        let summaries = try loadTakeSummaries(
            sessionID: takeSummary.sessionID,
            storageKind: storageKind,
            fileManager: fileManager,
            rootDirectoryOverride: rootDirectoryOverride
        )
        let sessionSummary = CaptureSessionAuditSummary(
            id: takeSummary.sessionID,
            storageKind: storageKind,
            sessionID: takeSummary.sessionID,
            updatedAt: Date(),
            takeCount: summaries.count,
            completedTakeCount: summaries.filter { $0.recordingStatus == "completed" }.count,
            interruptedTakeCount: summaries.filter { $0.recordingStatus == "interrupted" }.count,
            failedTakeCount: summaries.filter { $0.recordingStatus == "failed" }.count,
            linkedWatchTakeCount: summaries.filter { $0.linkedMotionFileName != nil }.count,
            takeIDs: summaries.map(\.takeID).sorted()
        )
        let sessionURL = sessionSummaryURL(
            sessionID: takeSummary.sessionID,
            storageKind: storageKind,
            fileManager: fileManager,
            rootDirectoryOverride: rootDirectoryOverride
        )
        try encoder.encode(sessionSummary).write(to: sessionURL, options: .atomic)
    }

    static func loadTakeSummaries(
        sessionID: String? = nil,
        storageKind: StagedCaptureStorageKind,
        fileManager: FileManager = .default,
        rootDirectoryOverride: URL? = nil
    ) throws -> [CaptureTakeAuditSummary] {
        let directory = takeSummaryDirectoryURL(
            storageKind: storageKind,
            fileManager: fileManager,
            rootDirectoryOverride: rootDirectoryOverride
        )
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(CaptureTakeAuditSummary.self, from: data)
            }
            .filter { summary in
                guard let sessionID else { return true }
                return summary.sessionID == sessionID
            }
            .sorted { lhs, rhs in
                if lhs.startedAt == rhs.startedAt {
                    return lhs.takeNumber < rhs.takeNumber
                }
                return lhs.startedAt < rhs.startedAt
            }
    }

    static func loadSessionSummary(
        sessionID: String,
        storageKind: StagedCaptureStorageKind,
        fileManager: FileManager = .default,
        rootDirectoryOverride: URL? = nil
    ) throws -> CaptureSessionAuditSummary? {
        let url = sessionSummaryURL(
            sessionID: sessionID,
            storageKind: storageKind,
            fileManager: fileManager,
            rootDirectoryOverride: rootDirectoryOverride
        )
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try decoder.decode(CaptureSessionAuditSummary.self, from: data)
    }

    static func loadSessionSummaries(
        storageKind: StagedCaptureStorageKind,
        fileManager: FileManager = .default,
        rootDirectoryOverride: URL? = nil
    ) throws -> [CaptureSessionAuditSummary] {
        let directory = sessionSummaryDirectoryURL(
            storageKind: storageKind,
            fileManager: fileManager,
            rootDirectoryOverride: rootDirectoryOverride
        )
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(CaptureSessionAuditSummary.self, from: data)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
}

enum CaptureJournalStore {
    private static func journalRootURL(fileManager: FileManager, rootDirectoryOverride: URL?) -> URL {
        if let rootDirectoryOverride {
            return rootDirectoryOverride
        }
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return baseURL
            .appendingPathComponent("ScratchLab", isDirectory: true)
            .appendingPathComponent("CaptureJournal", isDirectory: true)
    }

    private static func entryDirectoryURL(
        storageKind: StagedCaptureStorageKind,
        fileManager: FileManager,
        rootDirectoryOverride: URL?
    ) -> URL {
        journalRootURL(fileManager: fileManager, rootDirectoryOverride: rootDirectoryOverride)
            .appendingPathComponent(storageKind.rawValue, isDirectory: true)
            .appendingPathComponent("entries", isDirectory: true)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func append(
        _ entry: CaptureJournalEntry,
        fileManager: FileManager = .default,
        rootDirectoryOverride: URL? = nil
    ) throws {
        let directory = entryDirectoryURL(
            storageKind: entry.storageKind,
            fileManager: fileManager,
            rootDirectoryOverride: rootDirectoryOverride
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let timestampToken = String(format: "%.0f", entry.timestamp.timeIntervalSince1970 * 1_000)
        let url = directory.appendingPathComponent("\(timestampToken)-\(entry.id.uuidString.lowercased()).json")
        try encoder.encode(entry).write(to: url, options: .atomic)
    }

    static func loadEntries(
        storageKind: StagedCaptureStorageKind,
        sessionID: String? = nil,
        takeID: String? = nil,
        fileName: String? = nil,
        limit: Int? = nil,
        fileManager: FileManager = .default,
        rootDirectoryOverride: URL? = nil
    ) throws -> [CaptureJournalEntry] {
        let directory = entryDirectoryURL(
            storageKind: storageKind,
            fileManager: fileManager,
            rootDirectoryOverride: rootDirectoryOverride
        )
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let entries: [CaptureJournalEntry] = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(CaptureJournalEntry.self, from: data)
            }
            .filter { entry in
                if let sessionID, entry.sessionID != sessionID {
                    return false
                }
                if let takeID, entry.takeID != takeID {
                    return false
                }
                if let fileName,
                   entry.fileName != fileName,
                   !entry.relatedFileNames.contains(fileName) {
                    return false
                }
                return true
            }
            .sorted { $0.timestamp > $1.timestamp }
        if let limit {
            return Array(entries.prefix(limit))
        }
        return entries
    }

    static func loadTransactionSnapshots(
        storageKind: StagedCaptureStorageKind,
        sessionID: String? = nil,
        takeID: String? = nil,
        fileManager: FileManager = .default,
        rootDirectoryOverride: URL? = nil
    ) throws -> [CaptureTransactionSnapshot] {
        let entries = try loadEntries(
            storageKind: storageKind,
            sessionID: sessionID,
            takeID: takeID,
            fileManager: fileManager,
            rootDirectoryOverride: rootDirectoryOverride
        )
        let grouped = Dictionary(grouping: entries) { entry -> String in
            if let transactionID = entry.transactionID {
                return transactionID
            }
            let sessionToken = entry.sessionID ?? "unknown-session"
            let takeToken = entry.takeID ?? "unknown-take"
            return "\(sessionToken)::\(takeToken)"
        }

        return grouped.values.compactMap { groupedEntries in
            snapshot(for: groupedEntries)
        }
        .sorted { $0.lastUpdatedAt > $1.lastUpdatedAt }
    }

    static func snapshot(for entries: [CaptureJournalEntry]) -> CaptureTransactionSnapshot? {
        guard !entries.isEmpty else { return nil }
        let sortedAscending = entries.sorted { lhs, rhs in
            if lhs.timestamp == rhs.timestamp {
                return lhs.kind.rawValue < rhs.kind.rawValue
            }
            return lhs.timestamp < rhs.timestamp
        }
        let sortedDescending = sortedAscending.reversed()
        let latest = sortedAscending.last!
        let relatedFileNames = Array(Set(sortedAscending.flatMap(\.relatedFileNames) + sortedAscending.compactMap(\.fileName))).sorted()
        let state: CaptureTransactionState
        if sortedAscending.contains(where: { $0.kind == .transactionFinalized }) {
            state = .finalized
        } else if sortedAscending.contains(where: { $0.kind == .mediaWriteCommitted }) {
            state = .mediaCommittedAwaitingFinalize
        } else if sortedAscending.contains(where: { $0.kind == .sidecarWriteCommitted }) {
            state = .sidecarCommittedAwaitingMedia
        } else {
            state = .beganNoArtifactsWritten
        }

        let sessionTakeID = [latest.sessionID, latest.takeID].compactMap { $0 }
        let snapshotID = latest.transactionID
            ?? (sessionTakeID.isEmpty ? latest.id.uuidString.lowercased() : sessionTakeID.joined(separator: "::"))

        return CaptureTransactionSnapshot(
            id: snapshotID,
            storageKind: latest.storageKind,
            sessionID: latest.sessionID,
            takeID: latest.takeID,
            transactionID: latest.transactionID,
            state: state,
            lastUpdatedAt: latest.timestamp,
            relatedFileNames: relatedFileNames,
            entries: Array(sortedDescending)
        )
    }

    static func appendTransactionBegan(
        storageKind: StagedCaptureStorageKind,
        sessionID: String,
        takeID: String,
        sidecarFileName: String,
        mediaFileName: String,
        fileManager: FileManager = .default,
        rootDirectoryOverride: URL? = nil
    ) throws {
        try append(
            CaptureJournalEntry(
                storageKind: storageKind,
                kind: .transactionBegan,
                message: "\(storageKind.title) began staged capture transaction for \(takeID).",
                sessionID: sessionID,
                takeID: takeID,
                transactionID: CaptureJournalEntry.transactionID(sessionID: sessionID, takeID: takeID),
                fileName: sidecarFileName,
                artifactRole: .session,
                relatedFileNames: [sidecarFileName, mediaFileName]
            ),
            fileManager: fileManager,
            rootDirectoryOverride: rootDirectoryOverride
        )
    }

    static func appendMediaCommitted(
        storageKind: StagedCaptureStorageKind,
        sidecar: CaptureCore.LocalRecordingSidecar,
        fileManager: FileManager = .default,
        rootDirectoryOverride: URL? = nil
    ) throws {
        try append(
            CaptureJournalEntry(
                storageKind: storageKind,
                kind: .mediaWriteCommitted,
                message: "\(storageKind.title) committed media artifact for \(sidecar.takeID).",
                sessionID: sidecar.sessionID,
                takeID: sidecar.takeID,
                transactionID: CaptureJournalEntry.transactionID(sessionID: sidecar.sessionID, takeID: sidecar.takeID),
                fileName: sidecar.mediaFileName,
                artifactRole: .media,
                relatedFileNames: [sidecar.sidecarFileName, sidecar.mediaFileName]
            ),
            fileManager: fileManager,
            rootDirectoryOverride: rootDirectoryOverride
        )
    }

    static func appendTransactionFinalized(
        storageKind: StagedCaptureStorageKind,
        sidecar: CaptureCore.LocalRecordingSidecar,
        fileManager: FileManager = .default,
        rootDirectoryOverride: URL? = nil
    ) throws {
        try append(
            CaptureJournalEntry(
                storageKind: storageKind,
                kind: .transactionFinalized,
                message: "\(storageKind.title) finalized staged capture transaction for \(sidecar.takeID) with status \(sidecar.recordingStatus).",
                sessionID: sidecar.sessionID,
                takeID: sidecar.takeID,
                transactionID: CaptureJournalEntry.transactionID(sessionID: sidecar.sessionID, takeID: sidecar.takeID),
                fileName: sidecar.sidecarFileName,
                artifactRole: .session,
                relatedFileNames: [sidecar.sidecarFileName, sidecar.mediaFileName],
                decisionReason: sidecar.errorDescription
            ),
            fileManager: fileManager,
            rootDirectoryOverride: rootDirectoryOverride
        )
    }

    static func appendValidationBlocked(
        storageKind: StagedCaptureStorageKind,
        sessionID: String,
        takeID: String? = nil,
        relatedFileNames: [String] = [],
        issues: [String],
        fileManager: FileManager = .default,
        rootDirectoryOverride: URL? = nil
    ) throws {
        try append(
            CaptureJournalEntry(
                storageKind: storageKind,
                kind: .validationBlocked,
                message: "\(storageKind.title) export validation blocked session \(sessionID).",
                sessionID: sessionID,
                takeID: takeID,
                transactionID: takeID.map { CaptureJournalEntry.transactionID(sessionID: sessionID, takeID: $0) },
                artifactRole: .session,
                relatedFileNames: relatedFileNames,
                decisionReason: issues.joined(separator: " | ")
            ),
            fileManager: fileManager,
            rootDirectoryOverride: rootDirectoryOverride
        )
    }
}

enum CaptureQuarantineActionError: LocalizedError, Equatable {
    case itemNotFound
    case destinationAlreadyExists
    case ambiguousContext(String)
    case unableToDelete

    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "ScratchLab could not find this quarantined item."
        case .destinationAlreadyExists:
            return "ScratchLab cannot restore this item because an active staged file already uses that name."
        case .ambiguousContext(let detail):
            return detail
        case .unableToDelete:
            return "ScratchLab could not delete this quarantined item."
        }
    }
}

struct CaptureQuarantineManager {
    let fileManager: FileManager
    let nowProvider: @Sendable () -> Date
    let journalRootDirectoryOverride: URL?

    init(
        fileManager: FileManager = .default,
        nowProvider: @escaping @Sendable () -> Date = { Date() },
        journalRootDirectoryOverride: URL? = nil
    ) {
        self.fileManager = fileManager
        self.nowProvider = nowProvider
        self.journalRootDirectoryOverride = journalRootDirectoryOverride
    }

    func restoreItem(
        named fileName: String,
        from captureDirectoryURL: URL,
        storageKind: StagedCaptureStorageKind,
        sessionID: String?,
        takeID: String?
    ) throws -> URL {
        let assessment = assessRestoreCandidate(
            named: fileName,
            from: captureDirectoryURL,
            storageKind: storageKind,
            sessionID: sessionID,
            takeID: takeID
        )
        if assessment.isAmbiguous {
            let candidateText = assessment.conflictingCandidates.isEmpty
                ? "ScratchLab could not prove a single staged owner for this artifact."
                : "ScratchLab found multiple candidate staged artifacts: \(assessment.conflictingCandidates.joined(separator: ", "))."
            throw CaptureQuarantineActionError.ambiguousContext(candidateText)
        }
        let quarantineDirectory = captureDirectoryURL.appendingPathComponent("Quarantine", isDirectory: true)
        let sourceURL = quarantineDirectory.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw CaptureQuarantineActionError.itemNotFound
        }
        let destinationURL = captureDirectoryURL.appendingPathComponent(fileName)
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw CaptureQuarantineActionError.destinationAlreadyExists
        }
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
        try? CaptureJournalStore.append(
            CaptureJournalEntry(
                timestamp: nowProvider(),
                storageKind: storageKind,
                kind: .quarantineItemRestored,
                message: "\(storageKind.title) restored quarantined artifact \(fileName) for operator review.",
                sessionID: assessment.sessionID,
                takeID: assessment.takeID,
                transactionID: assessment.transactionSnapshot?.transactionID ?? makeTransactionID(sessionID: assessment.sessionID, takeID: assessment.takeID),
                fileName: fileName,
                artifactRole: assessment.artifactRole,
                relatedFileNames: [fileName] + assessment.conflictingCandidates,
                decisionReason: assessment.decisionReason
            ),
            fileManager: fileManager,
            rootDirectoryOverride: journalRootDirectoryOverride
        )
        return destinationURL
    }

    func deleteItem(
        named fileName: String,
        from captureDirectoryURL: URL,
        storageKind: StagedCaptureStorageKind,
        sessionID: String?,
        takeID: String?
    ) throws {
        let quarantineDirectory = captureDirectoryURL.appendingPathComponent("Quarantine", isDirectory: true)
        let sourceURL = quarantineDirectory.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw CaptureQuarantineActionError.itemNotFound
        }
        do {
            try fileManager.removeItem(at: sourceURL)
        } catch {
            throw CaptureQuarantineActionError.unableToDelete
        }
        try? CaptureJournalStore.append(
            CaptureJournalEntry(
                timestamp: nowProvider(),
                storageKind: storageKind,
                kind: .quarantineItemDeleted,
                message: "\(storageKind.title) deleted quarantined artifact \(fileName).",
                sessionID: sessionID,
                takeID: takeID,
                transactionID: makeTransactionID(sessionID: sessionID, takeID: takeID),
                fileName: fileName,
                relatedFileNames: [fileName]
            ),
            fileManager: fileManager,
            rootDirectoryOverride: journalRootDirectoryOverride
        )
    }

    private func makeTransactionID(sessionID: String?, takeID: String?) -> String? {
        guard let sessionID, let takeID else { return nil }
        return CaptureJournalEntry.transactionID(sessionID: sessionID, takeID: takeID)
    }

    private func inferredArtifactRole(for fileName: String) -> CaptureJournalArtifactRole? {
        switch URL(fileURLWithPath: fileName).pathExtension.lowercased() {
        case "json":
            if fileName.localizedCaseInsensitiveContains("watch") {
                return .watch
            }
            return .sidecar
        case "mov", "mp4", "m4v":
            return .media
        case "wav", "aif", "aiff", "m4a", "caf":
            return .audio
        default:
            return nil
        }
    }

    func assessRestoreCandidate(
        named fileName: String,
        from captureDirectoryURL: URL,
        storageKind: StagedCaptureStorageKind,
        sessionID: String?,
        takeID: String?
    ) -> CaptureQuarantineRestoreAssessment {
        let itemHistory = (try? CaptureJournalStore.loadEntries(
            storageKind: storageKind,
            fileName: fileName,
            fileManager: fileManager,
            rootDirectoryOverride: journalRootDirectoryOverride
        )) ?? []
        let snapshot = CaptureJournalStore.snapshot(for: itemHistory)
        let uniqueTransactions = Set(itemHistory.compactMap(\.transactionID))
        let uniqueSessionTakePairs = Set(itemHistory.compactMap { entry -> String? in
            guard let sessionID = entry.sessionID, let takeID = entry.takeID else { return nil }
            return "\(sessionID)::\(takeID)"
        })
        let originCandidates = Array(uniqueTransactions.union(uniqueSessionTakePairs)).sorted()
        let artifactRoles = Array(Set(itemHistory.compactMap(\.artifactRole)))
        let artifactRole = itemHistory.compactMap(\.artifactRole).first ?? inferredArtifactRole(for: fileName)
        let relatedCandidates = Array(
            Set(itemHistory.flatMap(\.relatedFileNames).filter { candidate in
                candidate != fileName && fileManager.fileExists(atPath: captureDirectoryURL.appendingPathComponent(candidate).path)
            })
        ).sorted()
        let resolvedSessionID = itemHistory.compactMap(\.sessionID).first ?? sessionID
        let resolvedTakeID = itemHistory.compactMap(\.takeID).first ?? takeID
        let decisionReason = itemHistory.compactMap(\.decisionReason).first

        let ambiguousByOrigin = uniqueTransactions.count > 1 || uniqueSessionTakePairs.count > 1
        let ambiguousByRole = artifactRoles.count > 1
        let conflictingCandidates = originCandidates.isEmpty ? relatedCandidates : originCandidates
        let isAmbiguous = ambiguousByOrigin || ambiguousByRole

        return CaptureQuarantineRestoreAssessment(
            itemFileName: fileName,
            sessionID: resolvedSessionID,
            takeID: resolvedTakeID,
            artifactRole: artifactRole,
            decisionReason: decisionReason,
            conflictingCandidates: conflictingCandidates,
            isAmbiguous: isAmbiguous,
            transactionSnapshot: snapshot
        )
    }
}

struct StagedCaptureRecoveryManager {
    let fileManager: FileManager
    let nowProvider: @Sendable () -> Date
    let auditRootDirectoryOverride: URL?

    init(
        fileManager: FileManager = .default,
        nowProvider: @escaping @Sendable () -> Date = { Date() },
        auditRootDirectoryOverride: URL? = nil
    ) {
        self.fileManager = fileManager
        self.nowProvider = nowProvider
        self.auditRootDirectoryOverride = auditRootDirectoryOverride
    }

    func recoverRecordingDirectory(
        at directoryURL: URL,
        storageKind: StagedCaptureStorageKind
    ) -> StagedCaptureRecoveryReport {
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return .empty(for: storageKind)
        }

        let contents = (try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        let sidecarURLs = contents.filter { $0.pathExtension.lowercased() == "json" }
        let sidecars = sidecarURLs.compactMap { url -> (URL, CaptureCore.LocalRecordingSidecar)? in
            guard let data = try? Data(contentsOf: url),
                  let sidecar = try? JSONDecoder.captureCoreDecoder.decode(CaptureCore.LocalRecordingSidecar.self, from: data) else {
                return nil
            }
            return (url, sidecar)
        }

        var issues: [StagedCaptureIssue] = []
        var sidecarBaseNames = Set<String>()

        for (sidecarURL, sidecar) in sidecars {
            sidecarBaseNames.insert(sidecarURL.deletingPathExtension().lastPathComponent)
            let mediaURL = directoryURL.appendingPathComponent(sidecar.mediaFileName)
            if !fileManager.fileExists(atPath: mediaURL.path) {
                let quarantinedURL = quarantine(sidecarURL, within: directoryURL)
                issues.append(
                    StagedCaptureIssue(
                        timestamp: nowProvider(),
                        storageKind: storageKind,
                        severity: .blocking,
                        code: .quarantinedMissingMediaSidecar,
                        message: "\(storageKind.title) quarantined \(sidecar.sidecarFileName) because \(sidecar.mediaFileName) is missing.",
                        sessionID: sidecar.sessionID,
                        takeID: sidecar.takeID,
                        fileName: quarantinedURL.lastPathComponent
                    )
                )
                try? CaptureJournalStore.append(
                    CaptureJournalEntry(
                        timestamp: nowProvider(),
                        storageKind: storageKind,
                        kind: .artifactQuarantined,
                        message: "\(storageKind.title) quarantined \(sidecar.sidecarFileName) because \(sidecar.mediaFileName) is missing.",
                        sessionID: sidecar.sessionID,
                        takeID: sidecar.takeID,
                        fileName: quarantinedURL.lastPathComponent
                    ),
                    fileManager: fileManager,
                    rootDirectoryOverride: auditRootDirectoryOverride
                )
                continue
            }

            var updatedSidecar = sidecar
            if sidecar.recordingStatus == "recording" {
                updatedSidecar.endedAt = updatedSidecar.endedAt ?? nowProvider()
                updatedSidecar.recordingStatus = "interrupted"
                updatedSidecar.errorDescription = "Capture was interrupted before ScratchLab finished recording."
                updatedSidecar.auditTrail.append(
                    CaptureAuditEvent(
                        timestamp: updatedSidecar.endedAt ?? nowProvider(),
                        category: "recovered_interrupted",
                        detail: "ScratchLab recovered this take after app relaunch."
                    )
                )
                do {
                    try updatedSidecar.encodedData().write(to: sidecarURL, options: .atomic)
                    try? CaptureAuditStore.persist(
                        sidecar: updatedSidecar,
                        storageKind: storageKind,
                        fileManager: fileManager,
                        rootDirectoryOverride: auditRootDirectoryOverride
                    )
                    issues.append(
                        StagedCaptureIssue(
                            timestamp: updatedSidecar.endedAt ?? nowProvider(),
                            storageKind: storageKind,
                            severity: .blocking,
                            code: .interruptedCaptureRecovered,
                            message: "\(storageKind.title) recovered interrupted take \(updatedSidecar.takeID). Review or discard it before export.",
                            sessionID: updatedSidecar.sessionID,
                            takeID: updatedSidecar.takeID,
                            fileName: updatedSidecar.sidecarFileName
                        )
                    )
                    try? CaptureJournalStore.append(
                        CaptureJournalEntry(
                            timestamp: updatedSidecar.endedAt ?? nowProvider(),
                            storageKind: storageKind,
                            kind: .interruptedCaptureRecovered,
                            message: "\(storageKind.title) recovered interrupted take \(updatedSidecar.takeID).",
                            sessionID: updatedSidecar.sessionID,
                            takeID: updatedSidecar.takeID,
                            fileName: updatedSidecar.sidecarFileName
                        ),
                        fileManager: fileManager,
                        rootDirectoryOverride: auditRootDirectoryOverride
                    )
                } catch {
                    let quarantinedURL = quarantine(sidecarURL, within: directoryURL)
                    issues.append(
                        StagedCaptureIssue(
                            timestamp: nowProvider(),
                            storageKind: storageKind,
                            severity: .blocking,
                            code: .quarantinedMissingMediaSidecar,
                            message: "\(storageKind.title) quarantined \(sidecar.sidecarFileName) because recovery metadata could not be saved.",
                            sessionID: sidecar.sessionID,
                            takeID: sidecar.takeID,
                            fileName: quarantinedURL.lastPathComponent
                        )
                    )
                    try? CaptureJournalStore.append(
                        CaptureJournalEntry(
                            timestamp: nowProvider(),
                            storageKind: storageKind,
                            kind: .artifactQuarantined,
                            message: "\(storageKind.title) quarantined \(sidecar.sidecarFileName) because recovery metadata could not be saved.",
                            sessionID: sidecar.sessionID,
                            takeID: sidecar.takeID,
                            fileName: quarantinedURL.lastPathComponent
                        ),
                        fileManager: fileManager,
                        rootDirectoryOverride: auditRootDirectoryOverride
                    )
                }
            } else {
                try? CaptureAuditStore.persist(
                    sidecar: updatedSidecar,
                    storageKind: storageKind,
                    fileManager: fileManager,
                    rootDirectoryOverride: auditRootDirectoryOverride
                )
            }
        }

        let orphanedMediaURLs = contents.filter { url in
            guard !url.hasDirectoryPath else { return false }
            let lowercasedExtension = url.pathExtension.lowercased()
            guard ["mov", "wav"].contains(lowercasedExtension) else { return false }
            return !sidecarBaseNames.contains(url.deletingPathExtension().lastPathComponent)
        }

        for orphanedURL in orphanedMediaURLs {
            let relatedEntries = (try? CaptureJournalStore.loadEntries(
                storageKind: storageKind,
                fileName: orphanedURL.lastPathComponent,
                fileManager: fileManager,
                rootDirectoryOverride: auditRootDirectoryOverride
            )) ?? []
            let latestTransactionEntry = relatedEntries.first(where: {
                $0.kind == .transactionBegan || $0.kind == .sidecarWriteCommitted || $0.kind == .mediaWriteCommitted
            })
            let finalizedTransactionIDs = Set(
                relatedEntries
                    .filter { $0.kind == .transactionFinalized }
                    .compactMap(\.transactionID)
            )
            let decisionReason: String
            if let latestTransactionEntry,
               let transactionID = latestTransactionEntry.transactionID,
               !finalizedTransactionIDs.contains(transactionID) {
                decisionReason = "ScratchLab found an interrupted staged write for \(transactionID) without a matching finalize event."
            } else {
                decisionReason = "ScratchLab found no complete staged transaction history for this media artifact."
            }
            let quarantinedURL = quarantine(orphanedURL, within: directoryURL)
            issues.append(
                StagedCaptureIssue(
                    timestamp: nowProvider(),
                    storageKind: storageKind,
                    severity: .blocking,
                    code: .quarantinedOrphanedMedia,
                    message: "\(storageKind.title) quarantined orphaned \(orphanedURL.lastPathComponent). \(decisionReason)",
                    sessionID: latestTransactionEntry?.sessionID,
                    takeID: latestTransactionEntry?.takeID,
                    fileName: quarantinedURL.lastPathComponent
                )
            )
            try? CaptureJournalStore.append(
                CaptureJournalEntry(
                    timestamp: nowProvider(),
                    storageKind: storageKind,
                    kind: .artifactQuarantined,
                    message: "\(storageKind.title) quarantined orphaned \(orphanedURL.lastPathComponent).",
                    sessionID: latestTransactionEntry?.sessionID,
                    takeID: latestTransactionEntry?.takeID,
                    transactionID: latestTransactionEntry?.transactionID,
                    fileName: quarantinedURL.lastPathComponent,
                    artifactRole: .media,
                    relatedFileNames: [orphanedURL.lastPathComponent, quarantinedURL.lastPathComponent],
                    decisionReason: decisionReason
                ),
                fileManager: fileManager,
                rootDirectoryOverride: auditRootDirectoryOverride
            )
        }

        if !issues.isEmpty {
            try? CaptureJournalStore.append(
                CaptureJournalEntry(
                    timestamp: nowProvider(),
                    storageKind: storageKind,
                    kind: .recoveryScanCompleted,
                    message: reportMessage(for: storageKind, issues: issues)
                ),
                fileManager: fileManager,
                rootDirectoryOverride: auditRootDirectoryOverride
            )
        }
        return StagedCaptureRecoveryReport(storageKind: storageKind, issues: issues)
    }

    func reconcileWatchDirectory(
        at directoryURL: URL,
        storageKind: StagedCaptureStorageKind,
        sidecarDirectories: [URL],
        sidecarStorageKind: StagedCaptureStorageKind
    ) -> StagedCaptureRecoveryReport {
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return .empty(for: storageKind)
        }

        let contents = (try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        var issues: [StagedCaptureIssue] = []
        let sidecars = loadSidecars(in: sidecarDirectories)
        var linkedTakeKeys = Set(sidecars.compactMap { entry -> String? in
            guard let linkedMotionFileName = entry.sidecar.linkedMotionFileName else { return nil }
            return "\(entry.sidecar.sessionID)::\(entry.sidecar.takeID)::\(linkedMotionFileName)"
        })

        for fileURL in contents where fileURL.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: fileURL),
                  let captureSession = try? WatchMotionCaptureCodec.decoder.decode(WatchMotionCaptureSession.self, from: data) else {
                let quarantinedURL = quarantine(fileURL, within: directoryURL)
                issues.append(
                    StagedCaptureIssue(
                        timestamp: nowProvider(),
                        storageKind: storageKind,
                        severity: .blocking,
                        code: .quarantinedInvalidWatchCapture,
                        message: "\(storageKind.title) quarantined unreadable watch file \(fileURL.lastPathComponent).",
                        fileName: quarantinedURL.lastPathComponent
                    )
                )
                try? CaptureJournalStore.append(
                    CaptureJournalEntry(
                        timestamp: nowProvider(),
                        storageKind: storageKind,
                        kind: .artifactQuarantined,
                        message: "\(storageKind.title) quarantined unreadable watch file \(fileURL.lastPathComponent).",
                        fileName: quarantinedURL.lastPathComponent
                    ),
                    fileManager: fileManager,
                    rootDirectoryOverride: auditRootDirectoryOverride
                )
                continue
            }

            guard let takeID = captureSession.takeID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !captureSession.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !takeID.isEmpty else {
                let quarantinedURL = quarantine(fileURL, within: directoryURL)
                issues.append(
                    StagedCaptureIssue(
                        timestamp: nowProvider(),
                        storageKind: storageKind,
                        severity: .blocking,
                        code: .quarantinedUnlinkedWatchCapture,
                        message: "\(storageKind.title) quarantined unlinked watch capture \(fileURL.lastPathComponent).",
                        fileName: quarantinedURL.lastPathComponent
                    )
                )
                try? CaptureJournalStore.append(
                    CaptureJournalEntry(
                        timestamp: nowProvider(),
                        storageKind: storageKind,
                        kind: .artifactQuarantined,
                        message: "\(storageKind.title) quarantined unlinked watch capture \(fileURL.lastPathComponent).",
                        fileName: quarantinedURL.lastPathComponent
                    ),
                    fileManager: fileManager,
                    rootDirectoryOverride: auditRootDirectoryOverride
                )
                continue
            }

            guard WatchAssociationResolver.isLinkedCaptureValid(
                sessionID: captureSession.sessionID,
                takeID: takeID,
                captureSession: captureSession
            ) else {
                let quarantinedURL = quarantine(fileURL, within: directoryURL)
                issues.append(
                    StagedCaptureIssue(
                        timestamp: nowProvider(),
                        storageKind: storageKind,
                        severity: .blocking,
                        code: .quarantinedInvalidWatchCapture,
                        message: "\(storageKind.title) quarantined invalid watch capture \(fileURL.lastPathComponent).",
                        sessionID: captureSession.sessionID,
                        takeID: takeID,
                        fileName: quarantinedURL.lastPathComponent
                    )
                )
                try? CaptureJournalStore.append(
                    CaptureJournalEntry(
                        timestamp: nowProvider(),
                        storageKind: storageKind,
                        kind: .artifactQuarantined,
                        message: "\(storageKind.title) quarantined invalid watch capture \(fileURL.lastPathComponent).",
                        sessionID: captureSession.sessionID,
                        takeID: takeID,
                        fileName: quarantinedURL.lastPathComponent
                    ),
                    fileManager: fileManager,
                    rootDirectoryOverride: auditRootDirectoryOverride
                )
                continue
            }

            guard let sidecarMatch = sidecars.first(where: {
                $0.sidecar.sessionID == captureSession.sessionID && $0.sidecar.takeID == takeID
            }) else {
                let quarantinedURL = quarantine(fileURL, within: directoryURL)
                issues.append(
                    StagedCaptureIssue(
                        timestamp: nowProvider(),
                        storageKind: storageKind,
                        severity: .blocking,
                        code: .quarantinedUnlinkedWatchCapture,
                        message: "\(storageKind.title) quarantined \(fileURL.lastPathComponent) because no matching staged take exists.",
                        sessionID: captureSession.sessionID,
                        takeID: takeID,
                        fileName: quarantinedURL.lastPathComponent
                    )
                )
                try? CaptureJournalStore.append(
                    CaptureJournalEntry(
                        timestamp: nowProvider(),
                        storageKind: storageKind,
                        kind: .artifactQuarantined,
                        message: "\(storageKind.title) quarantined \(fileURL.lastPathComponent) because no matching staged take exists.",
                        sessionID: captureSession.sessionID,
                        takeID: takeID,
                        fileName: quarantinedURL.lastPathComponent
                    ),
                    fileManager: fileManager,
                    rootDirectoryOverride: auditRootDirectoryOverride
                )
                continue
            }

            var sidecarForRelayAudit = sidecarMatch.sidecar

            if sidecarMatch.sidecar.linkedMotionFileName == nil {
                var updatedSidecar = sidecarMatch.sidecar.linkingWatchCapture(
                    id: captureSession.id,
                    fileName: fileURL.lastPathComponent
                )
                updatedSidecar.auditTrail.append(
                    CaptureAuditEvent(
                        timestamp: nowProvider(),
                        category: "watch_reconciled",
                        detail: "Recovered watch link from \(fileURL.lastPathComponent)."
                    )
                )
                do {
                    try updatedSidecar.encodedData().write(to: sidecarMatch.url, options: Data.WritingOptions.atomic)
                    try? CaptureAuditStore.persist(
                        sidecar: updatedSidecar,
                        storageKind: sidecarStorageKind,
                        fileManager: fileManager,
                        rootDirectoryOverride: auditRootDirectoryOverride
                    )
                    sidecarForRelayAudit = updatedSidecar
                    linkedTakeKeys.insert("\(updatedSidecar.sessionID)::\(updatedSidecar.takeID)::\(fileURL.lastPathComponent)")
                    issues.append(
                        StagedCaptureIssue(
                            timestamp: nowProvider(),
                            storageKind: storageKind,
                            severity: .info,
                            code: .linkedWatchCapture,
                            message: "\(storageKind.title) linked \(fileURL.lastPathComponent) to \(updatedSidecar.takeID).",
                            sessionID: updatedSidecar.sessionID,
                            takeID: updatedSidecar.takeID,
                            fileName: fileURL.lastPathComponent
                        )
                    )
                    try? CaptureJournalStore.append(
                        CaptureJournalEntry(
                            timestamp: nowProvider(),
                            storageKind: storageKind,
                            kind: .watchCaptureLinked,
                            message: "\(storageKind.title) linked \(fileURL.lastPathComponent) to \(updatedSidecar.takeID).",
                            sessionID: updatedSidecar.sessionID,
                            takeID: updatedSidecar.takeID,
                            fileName: fileURL.lastPathComponent
                        ),
                        fileManager: fileManager,
                        rootDirectoryOverride: auditRootDirectoryOverride
                    )
                } catch {
                    let quarantinedURL = quarantine(fileURL, within: directoryURL)
                    issues.append(
                        StagedCaptureIssue(
                            timestamp: nowProvider(),
                            storageKind: storageKind,
                            severity: .blocking,
                            code: .quarantinedDuplicateWatchCapture,
                            message: "\(storageKind.title) quarantined \(fileURL.lastPathComponent) because the matching take could not be updated.",
                            sessionID: captureSession.sessionID,
                            takeID: takeID,
                            fileName: quarantinedURL.lastPathComponent
                        )
                    )
                    try? CaptureJournalStore.append(
                        CaptureJournalEntry(
                            timestamp: nowProvider(),
                            storageKind: storageKind,
                            kind: .artifactQuarantined,
                            message: "\(storageKind.title) quarantined \(fileURL.lastPathComponent) because the matching take could not be updated.",
                            sessionID: captureSession.sessionID,
                            takeID: takeID,
                            fileName: quarantinedURL.lastPathComponent
                        ),
                        fileManager: fileManager,
                        rootDirectoryOverride: auditRootDirectoryOverride
                    )
                }
            } else if !linkedTakeKeys.contains("\(captureSession.sessionID)::\(takeID)::\(fileURL.lastPathComponent)") {
                let quarantinedURL = quarantine(fileURL, within: directoryURL)
                issues.append(
                    StagedCaptureIssue(
                        timestamp: nowProvider(),
                        storageKind: storageKind,
                        severity: .blocking,
                        code: .quarantinedDuplicateWatchCapture,
                        message: "\(storageKind.title) quarantined duplicate watch capture \(fileURL.lastPathComponent) for \(takeID).",
                        sessionID: captureSession.sessionID,
                        takeID: takeID,
                        fileName: quarantinedURL.lastPathComponent
                    )
                )
                try? CaptureJournalStore.append(
                    CaptureJournalEntry(
                        timestamp: nowProvider(),
                        storageKind: storageKind,
                        kind: .artifactQuarantined,
                        message: "\(storageKind.title) quarantined duplicate watch capture \(fileURL.lastPathComponent) for \(takeID).",
                        sessionID: captureSession.sessionID,
                        takeID: takeID,
                        fileName: quarantinedURL.lastPathComponent
                    ),
                    fileManager: fileManager,
                    rootDirectoryOverride: auditRootDirectoryOverride
                )
                continue
            }

            let relayTakeSummary = CaptureTakeAuditSummary(
                id: "\(captureSession.sessionID)::\(takeID)",
                storageKind: storageKind,
                sessionID: captureSession.sessionID,
                takeID: takeID,
                takeNumber: sidecarForRelayAudit.appLocalTakeNumber,
                recordingStatus: "completed",
                watchSyncState: (captureSession.syncState ?? sidecarForRelayAudit.watchSyncState).rawValue,
                mediaFileName: fileURL.lastPathComponent,
                sidecarFileName: sidecarForRelayAudit.sidecarFileName,
                linkedMotionFileName: fileURL.lastPathComponent,
                startedAt: captureSession.deviceRecordedAtStart,
                endedAt: captureSession.deviceRecordedAtEnd ?? captureSession.endedAt,
                auditEventCount: 1,
                lastAuditCategory: "watch_relay_imported",
                lastAuditDetail: "Relayed watch capture \(fileURL.lastPathComponent) matched to \(takeID)."
            )
            try? CaptureAuditStore.persist(
                takeSummary: relayTakeSummary,
                storageKind: storageKind,
                fileManager: fileManager,
                rootDirectoryOverride: auditRootDirectoryOverride
            )
        }

        if !issues.isEmpty {
            try? CaptureJournalStore.append(
                CaptureJournalEntry(
                    timestamp: nowProvider(),
                    storageKind: storageKind,
                    kind: .reconciliationCompleted,
                    message: reportMessage(for: storageKind, issues: issues)
                ),
                fileManager: fileManager,
                rootDirectoryOverride: auditRootDirectoryOverride
            )
        }
        return StagedCaptureRecoveryReport(storageKind: storageKind, issues: issues)
    }

    private func reportMessage(for storageKind: StagedCaptureStorageKind, issues: [StagedCaptureIssue]) -> String {
        let report = StagedCaptureRecoveryReport(storageKind: storageKind, issues: issues)
        return report.summaryText ?? "\(storageKind.title) scan completed."
    }

    private func loadSidecars(in directories: [URL]) -> [(url: URL, sidecar: CaptureCore.LocalRecordingSidecar)] {
        directories.flatMap { directory -> [(url: URL, sidecar: CaptureCore.LocalRecordingSidecar)] in
            let contents = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            return contents.compactMap { url in
                guard url.pathExtension.lowercased() == "json",
                      let data = try? Data(contentsOf: url),
                      let sidecar = try? JSONDecoder.captureCoreDecoder.decode(CaptureCore.LocalRecordingSidecar.self, from: data) else {
                    return nil
                }
                return (url, sidecar)
            }
        }
    }

    @discardableResult
    private func quarantine(_ fileURL: URL, within directoryURL: URL) -> URL {
        let quarantineDirectory = directoryURL.appendingPathComponent("Quarantine", isDirectory: true)
        try? fileManager.createDirectory(at: quarantineDirectory, withIntermediateDirectories: true)

        var destinationURL = quarantineDirectory.appendingPathComponent(fileURL.lastPathComponent)
        if fileManager.fileExists(atPath: destinationURL.path) {
            let baseName = fileURL.deletingPathExtension().lastPathComponent
            let extensionSuffix = fileURL.pathExtension.isEmpty ? "" : ".\(fileURL.pathExtension)"
            destinationURL = quarantineDirectory.appendingPathComponent("\(baseName)-\(UUID().uuidString)\(extensionSuffix)")
        }

        try? fileManager.moveItem(at: fileURL, to: destinationURL)
        return destinationURL
    }
}

private extension JSONDecoder {
    static var captureCoreDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
