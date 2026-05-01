import Foundation

enum CaptureCanonicalRules {
    static let scratchTypeID = "baby_scratch"
    static let scratchTypeName = "baby"
    static let allowedBPMs: Set<Int> = [70, 90, 110]
    static let minimumWatchSampleCount = 10
    static let specVersion = "capture_spec_v1"
    static let allowedBPMList = [70, 90, 110]
    static let segmentCount = 3

    static let watchCSVHeader = [
        "elapsed_time",
        "core_motion_timestamp",
        "attitude_roll",
        "attitude_pitch",
        "attitude_yaw",
        "quaternion_x",
        "quaternion_y",
        "quaternion_z",
        "quaternion_w",
        "gravity_x",
        "gravity_y",
        "gravity_z",
        "user_accel_x",
        "user_accel_y",
        "user_accel_z",
        "rotation_rate_x",
        "rotation_rate_y",
        "rotation_rate_z"
    ]

    static let takeLogColumns = [
        "bpm",
        "take_number",
        "raw_camA",
        "raw_camB",
        "raw_audio",
        "raw_watch",
        "verbal_slate_used",
        "sync_clap_used",
        "notes"
    ]
}

enum SessionIdentity {
    static func makeSessionID() -> String {
        UUID().uuidString.lowercased()
    }
}

struct TakeIdentity: Codable, Equatable, Sendable {
    let sessionID: String
    let takeID: String
    let takeNumber: Int
}

enum CaptureWatchSyncState: String, Codable, Equatable, Sendable {
    case notRequested
    case requested
    case acknowledged
    case timedOut
    case unavailable
    case failed

    var isSynchronized: Bool {
        self == .acknowledged
    }
}

struct CaptureAuditEvent: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let timestamp: Date
    let category: String
    let detail: String

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        category: String,
        detail: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.detail = detail
    }
}

struct WatchCaptureCommandPayload: Codable, Equatable, Sendable {
    static let packetKind = "watch_motion_control_command_v2"

    enum Command: String, Codable, Equatable, Sendable {
        case start
        case stop
    }

    let kind: String
    let commandID: String
    let command: Command
    let sessionID: String
    let takeID: String?
    let requestedAt: Date

    init(
        commandID: String = UUID().uuidString.lowercased(),
        command: Command,
        sessionID: String,
        takeID: String?,
        requestedAt: Date = Date()
    ) {
        self.kind = Self.packetKind
        self.commandID = commandID
        self.command = command
        self.sessionID = sessionID
        self.takeID = takeID
        self.requestedAt = requestedAt
    }
}

struct WatchCaptureControlReply: Codable, Equatable, Sendable {
    static let packetKind = "watch_motion_control_status_v2"

    let kind: String
    let commandID: String
    let sessionID: String
    let takeID: String?
    let syncState: CaptureWatchSyncState
    let detail: String?
    let acknowledgedAt: Date?

    init(
        commandID: String,
        sessionID: String,
        takeID: String?,
        syncState: CaptureWatchSyncState,
        detail: String?,
        acknowledgedAt: Date? = nil
    ) {
        self.kind = Self.packetKind
        self.commandID = commandID
        self.sessionID = sessionID
        self.takeID = takeID
        self.syncState = syncState
        self.detail = detail
        self.acknowledgedAt = acknowledgedAt
    }
}

enum WatchAssociationResolver {
    static func isLinkedCaptureValid(
        sessionID: String,
        takeID: String,
        captureSession: WatchMotionCaptureSession
    ) -> Bool {
        guard captureSession.sessionID == sessionID else { return false }
        guard captureSession.takeID == takeID else { return false }
        guard captureSession.sampleCount >= CaptureCanonicalRules.minimumWatchSampleCount else { return false }
        guard captureSession.deviceRecordedAtEnd != nil else { return false }
        return captureSession.duration > 0
    }
}

enum CaptureCanonicalFormatting {
    static func sanitizeDJToken(_ performerName: String) -> String? {
        let filtered = performerName
            .unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()
            .uppercased()
        return filtered.isEmpty ? nil : filtered
    }

    static func sessionDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func bpmToken(_ bpm: Int) -> String {
        String(format: "%03d", bpm)
    }

    static func takeNumberToken(_ takeNumber: Int) -> String {
        String(format: "%02d", takeNumber)
    }

    static func exportScratchTypeToken(
        scratchTypeID: String?,
        scratchTypeName: String?,
        workflow: String
    ) -> String? {
        switch workflow {
        case "routine_capture", "guided_capture":
            if let scratchTypeID,
               let normalized = normalizedScratchTypeToken(from: scratchTypeID) {
                return normalized
            }
            if let scratchTypeName,
               let normalized = normalizedScratchTypeToken(from: scratchTypeName) {
                return normalized
            }
            return nil
        default:
            return CaptureCanonicalRules.scratchTypeName
        }
    }

    static func standardFileName(
        djToken: String,
        scratchTypeToken: String,
        bpm: Int,
        takeNumber: Int,
        source: String,
        fileExtension: String
    ) -> String {
        "\(djToken)_\(scratchTypeToken)_\(bpmToken(bpm))_take\(takeNumberToken(takeNumber))_\(source).\(fileExtension)"
    }

    private static func normalizedScratchTypeToken(from value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }

        let separatorNormalized = trimmed
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        let suffixTrimmed: String
        if separatorNormalized.hasSuffix("_scratch") {
            suffixTrimmed = String(separatorNormalized.dropLast("_scratch".count))
        } else {
            suffixTrimmed = separatorNormalized
        }
        let filtered = suffixTrimmed.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) || $0 == "_" }
            .map(String.init)
            .joined()
            .replacingOccurrences(of: "__", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return filtered.isEmpty ? nil : filtered
    }

    static func watchCSV(for session: WatchMotionCaptureSession) -> String {
        let rows = session.samples.map { sample in
            let columns: [String] = [
                String(sample.elapsedTime),
                sample.coreMotionTimestamp.map { String($0) } ?? "",
                String(sample.attitudeRoll),
                String(sample.attitudePitch),
                String(sample.attitudeYaw),
                String(sample.quaternionX),
                String(sample.quaternionY),
                String(sample.quaternionZ),
                String(sample.quaternionW),
                String(sample.gravityX),
                String(sample.gravityY),
                String(sample.gravityZ),
                String(sample.userAccelerationX),
                String(sample.userAccelerationY),
                String(sample.userAccelerationZ),
                String(sample.rotationRateX),
                String(sample.rotationRateY),
                String(sample.rotationRateZ)
            ]
            return columns.joined(separator: ",")
        }

        return ([CaptureCanonicalRules.watchCSVHeader.joined(separator: ",")] + rows).joined(separator: "\n")
    }
}

final class WatchCaptureCommandCoordinator: @unchecked Sendable {
    private struct PendingCommand {
        let command: WatchCaptureCommandPayload
        let continuation: CheckedContinuation<WatchCaptureControlReply, Never>
    }

    private let stateLock = NSLock()
    private var pendingCommands: [String: PendingCommand] = [:]
    private var finalizedReplies: [String: WatchCaptureControlReply] = [:]

    func begin(command: WatchCaptureCommandPayload) async -> WatchCaptureControlReply {
        if let finalized = finalizedReply(for: command.commandID) {
            return finalized
        }

        return await withCheckedContinuation { continuation in
            stateLock.lock()
            if let finalized = finalizedReplies[command.commandID] {
                stateLock.unlock()
                continuation.resume(returning: finalized)
                return
            }

            pendingCommands[command.commandID] = PendingCommand(
                command: command,
                continuation: continuation
            )
            stateLock.unlock()
        }
    }

    func resolve(_ reply: WatchCaptureControlReply) -> WatchCaptureControlReply? {
        stateLock.lock()
        defer { stateLock.unlock() }

        if let finalized = finalizedReplies[reply.commandID] {
            if finalized.syncState == .timedOut && reply.syncState == .acknowledged {
                return WatchCaptureControlReply(
                    commandID: reply.commandID,
                    sessionID: reply.sessionID,
                    takeID: reply.takeID,
                    syncState: .timedOut,
                    detail: "Watch acknowledged too late; take remains degraded.",
                    acknowledgedAt: finalized.acknowledgedAt
                )
            }
            return nil
        }

        guard let pending = pendingCommands.removeValue(forKey: reply.commandID) else {
            finalizedReplies[reply.commandID] = reply
            return reply
        }

        finalizedReplies[reply.commandID] = reply
        pending.continuation.resume(returning: reply)
        return reply
    }

    func timeout(commandID: String) -> WatchCaptureControlReply? {
        stateLock.lock()
        defer { stateLock.unlock() }

        if let finalized = finalizedReplies[commandID] {
            return finalized
        }

        guard let pending = pendingCommands.removeValue(forKey: commandID) else {
            return finalizedReplies[commandID]
        }

        let timeoutReply = WatchCaptureControlReply(
            commandID: pending.command.commandID,
            sessionID: pending.command.sessionID,
            takeID: pending.command.takeID,
            syncState: .timedOut,
            detail: "Watch motion start timed out.",
            acknowledgedAt: nil
        )
        finalizedReplies[commandID] = timeoutReply
        pending.continuation.resume(returning: timeoutReply)
        return timeoutReply
    }

    func finalizedReply(for commandID: String) -> WatchCaptureControlReply? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return finalizedReplies[commandID]
    }
}
