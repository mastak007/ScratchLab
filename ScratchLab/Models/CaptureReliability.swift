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
    let takeNumber: Int?
    let watchWrist: String?
    let requestedAt: Date

    init(
        commandID: String = UUID().uuidString.lowercased(),
        command: Command,
        sessionID: String,
        takeID: String?,
        takeNumber: Int? = nil,
        watchWrist: String? = nil,
        requestedAt: Date = Date()
    ) {
        self.kind = Self.packetKind
        self.commandID = commandID
        self.command = command
        self.sessionID = sessionID
        self.takeID = takeID
        self.takeNumber = takeNumber
        self.watchWrist = watchWrist
        self.requestedAt = requestedAt
    }
}

enum WatchRelayFlowState: String, Codable, Equatable, Sendable {
    case waiting
    case ready
    case active
    case interrupted
}

struct WatchRelayTakeContext: Codable, Equatable, Sendable {
    let sessionID: String
    let takeID: String
    let takeNumber: Int?
    let watchWrist: String?

    init(sessionID: String, takeID: String, takeNumber: Int? = nil, watchWrist: String? = nil) {
        self.sessionID = sessionID
        self.takeID = takeID
        self.takeNumber = takeNumber
        self.watchWrist = watchWrist
    }

    init?(payload: WatchCaptureCommandPayload) {
        guard let takeID = payload.takeID, !payload.sessionID.isEmpty, !takeID.isEmpty else { return nil }
        self.init(
            sessionID: payload.sessionID,
            takeID: takeID,
            takeNumber: payload.takeNumber,
            watchWrist: payload.watchWrist
        )
    }
}

enum WatchRelayLifecycleEvent: String, Codable, Equatable, Sendable {
    case hello
    case relayReady = "relay_ready"
    case takeBegin = "take_begin"
    case takeEnd = "take_end"
    case heartbeat
    case error
    case reconnect
}

struct WatchRelayLifecyclePacket: Codable, Equatable, Sendable {
    static let packetKind = "watch_relay_lifecycle_v1"
    static let capabilities = ["live_motion_batch_v1", "durable_watch_file_v1", "mac_authoritative_take_v1"]

    let kind: String
    let event: WatchRelayLifecycleEvent
    let context: WatchRelayTakeContext?
    let detail: String?
    let capabilities: [String]
    let sentAt: Date

    init(
        event: WatchRelayLifecycleEvent,
        context: WatchRelayTakeContext? = nil,
        detail: String? = nil,
        capabilities: [String] = WatchRelayLifecyclePacket.capabilities,
        sentAt: Date = Date()
    ) {
        self.kind = Self.packetKind
        self.event = event
        self.context = context
        self.detail = detail
        self.capabilities = capabilities
        self.sentAt = sentAt
    }
}

struct WatchRelayInterruption: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let context: WatchRelayTakeContext?
    let detail: String
    let occurredAt: Date

    init(
        id: UUID = UUID(),
        context: WatchRelayTakeContext?,
        detail: String,
        occurredAt: Date = Date()
    ) {
        self.id = id
        self.context = context
        self.detail = detail
        self.occurredAt = occurredAt
    }
}

enum WatchRelayStateResolver {
    static func resolve(
        isWatchReachable: Bool,
        isMacConnected: Bool,
        activeContext: WatchRelayTakeContext?,
        hadRequiredConnections: Bool,
        interruptionReason: String?
    ) -> WatchRelayFlowState {
        if interruptionReason != nil {
            return .interrupted
        }
        if activeContext != nil {
            return isWatchReachable && isMacConnected ? .active : .interrupted
        }
        if isWatchReachable && isMacConnected {
            return .ready
        }
        return hadRequiredConnections ? .interrupted : .waiting
    }
}

/// A control request initiated on Apple Watch for the paired iPhone's guided
/// capture state machine. This is intentionally distinct from
/// `WatchCaptureCommandPayload`, which travels in the opposite direction to
/// start/stop the watch motion recorder after iPhone capture is ready.
struct PhoneCaptureCommandPayload: Codable, Equatable, Sendable {
    static let packetKind = "phone_capture_control_command_v1"

    enum Command: String, Codable, Equatable, Sendable {
        case start
        case stop
    }

    let kind: String
    let commandID: String
    let command: Command
    let requestedAt: Date

    init(
        commandID: String = UUID().uuidString.lowercased(),
        command: Command,
        requestedAt: Date = Date()
    ) {
        self.kind = Self.packetKind
        self.commandID = commandID
        self.command = command
        self.requestedAt = requestedAt
    }
}

/// Why a Mac-initiated Watch **stop** ended the way it did.
///
/// Deliberately separate from `CaptureWatchSyncState`, which describes the
/// *start* handshake and is what `watch_source` and the sidecar's
/// `watchSyncState` already carry. Overloading either of those would collapse
/// "the Watch was never asked to stop" into "the Watch stopped", which is the
/// exact ambiguity that let a Watch run 18.5 s past the end of a take while the
/// export still read as clean.
enum CaptureWatchStopOutcome: String, Codable, Equatable, Sendable {
    /// No stop was requested, because this take never owned an active Watch
    /// capture.
    case notRequested
    /// The command left the Mac but no reply has been resolved yet.
    case sent
    /// The relay or the Watch could not be reached at all.
    case unreachable
    /// The command was sent and nothing came back inside the bounded window.
    case timedOut
    /// The Watch received the command but refused it: the session/take it names
    /// is not the capture the Watch is actually running.
    case identityRejected
    /// The Watch confirmed it stopped Core Motion and finalized its file.
    case stopped
    /// The Watch (or the relay) reported an explicit failure.
    case failed

    /// The only outcome that proves the Watch is no longer recording this take.
    var isStopConfirmed: Bool { self == .stopped }

    /// Outcomes that mean the Watch may still be recording. These must never be
    /// reported to the operator as success.
    var isDegraded: Bool {
        switch self {
        case .stopped: return false
        case .notRequested: return false
        case .sent, .unreachable, .timedOut, .identityRejected, .failed: return true
        }
    }
}

/// Where the Watch's motion artifact for a take has got to. Kept apart from the
/// stop outcome because a confirmed stop does not by itself mean the file has
/// arrived, and a file that has arrived does not prove the stop was timely.
enum CaptureWatchMotionTransferState: String, Codable, Equatable, Sendable {
    /// No Watch capture was linked to this take.
    case notApplicable
    /// The Watch stopped and handed a file to WatchConnectivity; it has not
    /// been linked to this take yet.
    case pending
    /// A motion artifact is linked to this take.
    case completed
}

/// The exported record of one take's Watch-stop handshake.
///
/// Written into the take sidecar and surfaced in `session_metadata.json` so a
/// reader can tell "no Watch" from "the Watch was asked and never answered"
/// without inspecting logs.
struct CaptureWatchStopDiagnostics: Codable, Equatable, Sendable {
    let outcome: CaptureWatchStopOutcome
    let sessionID: String?
    let takeID: String?
    let commandID: String?
    let detail: String?
    let requestedAt: Date?
    let resolvedAt: Date?
    /// When the Watch itself handled the stop, by its own clock.
    ///
    /// With `requestedAt` and `resolvedAt` this splits the round trip into its
    /// two legs: `watchHandledAt - requestedAt` is how long the command took to
    /// reach the Watch, `resolvedAt - watchHandledAt` is how long the
    /// acknowledgement took to come back. Without it a slow handshake cannot be
    /// attributed to either direction. `nil` when no reply arrived.
    let watchHandledAt: Date?
    /// When the iPhone relay confirmed it had the command.
    ///
    /// A timeout with no receipt means the relay never heard the command at
    /// all; a timeout with a receipt means the relay heard it and the watch did
    /// not answer. `timedOut` alone cannot tell those apart, and telling them
    /// apart is the difference between looking at the phone and the watch.
    let relayReceivedAt: Date?
    /// How many times the Mac sent the stop command for this take. `1` is the
    /// normal case; `2` means the bounded retry fired.
    let attemptCount: Int
    let motionTransferState: CaptureWatchMotionTransferState

    init(
        outcome: CaptureWatchStopOutcome,
        sessionID: String? = nil,
        takeID: String? = nil,
        commandID: String? = nil,
        detail: String? = nil,
        requestedAt: Date? = nil,
        resolvedAt: Date? = nil,
        watchHandledAt: Date? = nil,
        relayReceivedAt: Date? = nil,
        attemptCount: Int = 0,
        motionTransferState: CaptureWatchMotionTransferState = .notApplicable
    ) {
        self.outcome = outcome
        self.sessionID = sessionID
        self.takeID = takeID
        self.commandID = commandID
        self.detail = detail
        self.requestedAt = requestedAt
        self.resolvedAt = resolvedAt
        self.watchHandledAt = watchHandledAt
        self.relayReceivedAt = relayReceivedAt
        self.attemptCount = attemptCount
        self.motionTransferState = motionTransferState
    }

    static let notRequested = CaptureWatchStopDiagnostics(outcome: .notRequested)
}

/// The one place the Mac's Watch-stop timing policy is stated.
///
/// Bounded on purpose: media finalization must never wait indefinitely on a
/// device that may be off the wrist, so the Mac sends, waits, retries once, and
/// then records the degraded outcome instead of reporting success.
enum CaptureWatchStopPolicy {
    /// How long one stop attempt may wait for the Watch to answer.
    static let acknowledgementTimeoutSeconds: TimeInterval = 2.0
    /// Total attempts, including the first. One retry covers a single dropped
    /// relay message without unbounded stalling.
    static let maximumAttempts = 2

    /// The worst-case wall time the stop handshake can consume.
    static var maximumHandshakeSeconds: TimeInterval {
        acknowledgementTimeoutSeconds * Double(maximumAttempts)
    }

    /// Whether a start handshake that ended in `syncState` may have left a
    /// Watch capture running that the Mac is now responsible for stopping.
    ///
    /// Fail-closed on purpose. Only `acknowledged` proves the Watch started,
    /// but a degraded *reply* is not evidence the Watch did **not** start: the
    /// command can reach the wrist and Core Motion can begin while the answer
    /// is lost, arrives late, or comes back as a failure. Treating those as
    /// "nothing to stop" is what left a Watch recording past the end of a take
    /// with `watchStopOutcome: notRequested` — the Mac had simply decided it
    /// owned nothing.
    ///
    /// The two safe negatives are the ones where the command demonstrably never
    /// reached a recorder: `unavailable` (no peer, watch app not installed or
    /// not reachable, motion unavailable) and `notRequested` (no start was made
    /// at all). A stop sent for a capture that never started is harmless — the
    /// Watch's handler answers `alreadyStopped` and does no work.
    static func startMayHaveLeftWatchRecording(_ syncState: CaptureWatchSyncState) -> Bool {
        switch syncState {
        case .acknowledged, .requested, .failed, .timedOut:
            return true
        case .unavailable, .notRequested:
            return false
        }
    }

    /// Maps a resolved control reply onto a stop outcome.
    ///
    /// The Watch reports its own outcome in `stopOutcome` where it can; this is
    /// the fallback for a reply that predates that field or was synthesized by
    /// the relay, and it is what keeps a legacy `notRequested` acknowledgement
    /// (the Watch's historical "I stopped" answer) from reading as "never
    /// asked".
    static func outcome(for reply: WatchCaptureControlReply) -> CaptureWatchStopOutcome {
        if let reported = reply.stopOutcome { return reported }
        switch reply.syncState {
        case .notRequested, .acknowledged:
            return .stopped
        case .timedOut:
            return .timedOut
        case .unavailable:
            return .unreachable
        case .requested, .failed:
            return .failed
        }
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
    /// When the relay confirmed it had the command. Filled in locally on the
    /// Mac from `WatchCaptureCommandCoordinator`, never sent over the wire.
    var relayReceivedAt: Date?
    /// Set only for replies to a `stop` command, and only by peers that know
    /// about stop outcomes. Optional so a reply written by an older Watch or
    /// relay still decodes; `CaptureWatchStopPolicy.outcome(for:)` supplies the
    /// fallback in that case. `syncState` keeps its existing meaning and wire
    /// values untouched.
    let stopOutcome: CaptureWatchStopOutcome?

    init(
        commandID: String,
        sessionID: String,
        takeID: String?,
        syncState: CaptureWatchSyncState,
        detail: String?,
        acknowledgedAt: Date? = nil,
        stopOutcome: CaptureWatchStopOutcome? = nil
    ) {
        self.kind = Self.packetKind
        self.commandID = commandID
        self.sessionID = sessionID
        self.takeID = takeID
        self.syncState = syncState
        self.detail = detail
        self.acknowledgedAt = acknowledgedAt
        self.stopOutcome = stopOutcome
    }

    /// A copy stamped with when the relay confirmed receipt.
    func withRelayReceipt(_ receivedAt: Date?) -> WatchCaptureControlReply {
        var updated = self
        updated.relayReceivedAt = receivedAt
        return updated
    }
}

/// The Watch's decision table for an incoming `stop` command.
///
/// Pure so the Watch's behaviour is testable off-device: `WatchMotionRecorder`
/// owns Core Motion and file handling, this owns *whether* to touch them.
///
/// Three properties it must guarantee:
///   * **Idempotent** — a repeated stop for a command already resolved, or for
///     a device that is not recording, does no work and is not an error.
///   * **Identity-scoped** — a stop naming a different session/take than the
///     capture actually running is refused, never allowed to end someone else's
///     take.
///   * **Honest** — every branch names its outcome, and only `.stop` claims the
///     capture was stopped by this command.
enum WatchMotionStopCommandResolver {
    enum Decision: Equatable {
        /// Stop Core Motion, finalize the file, start the transfer.
        case stop
        /// Nothing to do; the capture is already stopped (or this exact command
        /// was already handled).
        case alreadyStopped(detail: String)
        /// Refuse: the command names a capture this device is not running.
        case rejectIdentity(detail: String)

        var outcome: CaptureWatchStopOutcome {
            switch self {
            case .stop, .alreadyStopped: return .stopped
            case .rejectIdentity: return .identityRejected
            }
        }

        /// The legacy `syncState` to put on the wire. Unchanged from the
        /// shipped contract: a handled stop has always answered `notRequested`
        /// (meaning "this take no longer has a Watch capture running"), and the
        /// Mac's `withWatchSync` relies on that to avoid downgrading an
        /// acknowledged start.
        var syncState: CaptureWatchSyncState {
            switch self {
            case .stop, .alreadyStopped: return .notRequested
            case .rejectIdentity: return .failed
            }
        }
    }

    /// - Parameters:
    ///   - payload: the incoming stop command.
    ///   - isRecording: whether Core Motion is currently collecting samples.
    ///   - activeCommand: the command that started the running capture, if any.
    ///   - resolvedStopCommandIDs: stop commands this device has already acted on.
    static func decide(
        payload: WatchCaptureCommandPayload,
        isRecording: Bool,
        activeCommand: WatchCaptureCommandPayload?,
        resolvedStopCommandIDs: Set<String>
    ) -> Decision {
        guard payload.command == .stop else {
            return .alreadyStopped(detail: "Not a stop command.")
        }
        if resolvedStopCommandIDs.contains(payload.commandID) {
            return .alreadyStopped(detail: "Duplicate stop command; watch motion capture was already stopped.")
        }
        guard isRecording else {
            return .alreadyStopped(detail: "Watch motion capture was already stopped.")
        }
        if let mismatch = identityMismatchDetail(payload: payload, activeCommand: activeCommand) {
            return .rejectIdentity(detail: mismatch)
        }
        return .stop
    }

    /// Non-nil when both sides name an identity and those identities differ.
    ///
    /// A command with no identity (a local Watch-UI stop, or a legacy peer) is
    /// allowed through: refusing it would strand a running capture. A capture
    /// started locally with no command payload likewise cannot be identity-
    /// checked, and is stoppable.
    private static func identityMismatchDetail(
        payload: WatchCaptureCommandPayload,
        activeCommand: WatchCaptureCommandPayload?
    ) -> String? {
        guard let activeCommand else { return nil }

        let requestedSession = payload.sessionID.trimmed
        let activeSession = activeCommand.sessionID.trimmed
        if let requestedSession, let activeSession, requestedSession != activeSession {
            return "Stop names session \(requestedSession) but this watch is recording \(activeSession)."
        }

        let requestedTake = payload.takeID?.trimmed
        let activeTake = activeCommand.takeID?.trimmed
        if let requestedTake, let activeTake, requestedTake != activeTake {
            return "Stop names take \(requestedTake) but this watch is recording \(activeTake)."
        }
        return nil
    }
}

private extension String {
    /// Whitespace-trimmed, or `nil` when there is nothing left to compare.
    var trimmed: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
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

    /// Session date policy — the single source of truth for every calendar
    /// date ScratchLab writes into an export.
    ///
    /// A session's date is the **capture device's local calendar date** at
    /// session start. It appears, identically, in:
    ///   - the export folder name (`session_YYYY_MM_DD_...`)
    ///   - `session_manifest.json` `date`
    ///   - every manifest take's `date`
    ///
    /// Absolute instants (`createdAt`, `generatedAt`, audit timestamps) stay
    /// UTC ISO-8601 and are deliberately *not* required to fall on the same
    /// calendar day — a 08:04 NZ session is 20:04 UTC the previous day, and
    /// both statements are true. Formatting the folder with the device zone
    /// while formatting the manifest in UTC is what produced the split
    /// `2026_09_04` / `2026-09-03` pair.
    ///
    /// The zone comes from `CaptureSessionConfig.sessionTimeZoneIdentifier`,
    /// persisted when the session identity was created — never from the
    /// exporting machine's current zone, which would re-date a session that is
    /// exported after travel or a DST change.
    /// Fallback for a legacy session that recorded no zone: **UTC**.
    ///
    /// Deliberately not the exporting machine's zone. A legacy session has no
    /// evidence of where it was captured, so the only defensible date is one
    /// that is reproducible: the UTC calendar day of `createdAt`. Re-exporting
    /// the same legacy session on a different machine, after travel, or across
    /// a DST boundary produces the identical folder name and manifest date.
    /// This is also the date pre-policy exports already wrote for the manifest,
    /// so recovering an old session does not silently re-date it.
    ///
    /// A session that *does* carry a zone is always dated in that zone; this
    /// value is never consulted for one.
    static let fallbackSessionCalendarTimeZone = TimeZone(secondsFromGMT: 0) ?? .gmt

    /// Resolves the zone a session's calendar date must be read in.
    static func sessionCalendarTimeZone(identifier: String?) -> TimeZone {
        guard let identifier, let zone = TimeZone(identifier: identifier) else {
            return fallbackSessionCalendarTimeZone
        }
        return zone
    }

    private static func sessionDateFormatter(
        dateFormat: String,
        timeZone: TimeZone
    ) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = dateFormat
        return formatter
    }

    /// `yyyy-MM-dd` for manifests and take records.
    static func sessionDateString(
        _ date: Date,
        timeZoneIdentifier: String?
    ) -> String {
        sessionDateFormatter(
            dateFormat: "yyyy-MM-dd",
            timeZone: sessionCalendarTimeZone(identifier: timeZoneIdentifier)
        ).string(from: date)
    }

    /// `yyyy_MM_dd` for the session folder name. Same instant, same zone, same
    /// calendar day as `sessionDateString`.
    static func sessionFolderDateString(
        _ date: Date,
        timeZoneIdentifier: String?
    ) -> String {
        sessionDateFormatter(
            dateFormat: "yyyy_MM_dd",
            timeZone: sessionCalendarTimeZone(identifier: timeZoneIdentifier)
        ).string(from: date)
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
    /// When the relay confirmed it had each command, keyed by command ID.
    private var receipts: [String: Date] = [:]
    /// Commands a reply arrived for that nobody was waiting on.
    ///
    /// This is the shape of a real defect, not a curiosity: the relay used to
    /// mint a fresh command ID instead of carrying the Mac's through, so every
    /// reply landed here, no await was ever resumed, and both handshakes timed
    /// out no matter how quickly the watch answered. Recorded so that failure
    /// mode is visible instead of silent.
    private var orphanedReplyCommandIDs: Set<String> = []

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

    /// Applies a reply to its command.
    ///
    /// `requested` is a **receipt**, not an answer: it says the relay has the
    /// command and is forwarding it. It is recorded and deliberately does not
    /// finalize the await, so the command keeps waiting for the watch's real
    /// response.
    func resolve(_ reply: WatchCaptureControlReply) -> WatchCaptureControlReply? {
        stateLock.lock()
        defer { stateLock.unlock() }

        if reply.syncState == .requested {
            receipts[reply.commandID] = reply.acknowledgedAt ?? Date()
            return nil
        }

        if let finalized = finalizedReplies[reply.commandID] {
            if finalized.syncState == .timedOut && reply.syncState == .acknowledged {
                return WatchCaptureControlReply(
                    commandID: reply.commandID,
                    sessionID: reply.sessionID,
                    takeID: reply.takeID,
                    syncState: .timedOut,
                    detail: "Watch acknowledged too late; take remains degraded.",
                    acknowledgedAt: finalized.acknowledgedAt,
                    stopOutcome: finalized.stopOutcome
                )
            }
            return nil
        }

        guard let pending = pendingCommands.removeValue(forKey: reply.commandID) else {
            // Nobody is waiting on this ID. Either the command already timed
            // out, or something upstream changed the ID in flight.
            orphanedReplyCommandIDs.insert(reply.commandID)
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

        let isStop = pending.command.command == .stop
        let timeoutReply = WatchCaptureControlReply(
            commandID: pending.command.commandID,
            sessionID: pending.command.sessionID,
            takeID: pending.command.takeID,
            syncState: .timedOut,
            detail: isStop
                ? "Watch motion stop timed out."
                : "Watch motion start timed out.",
            acknowledgedAt: nil,
            stopOutcome: isStop ? .timedOut : nil
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

    /// When the relay confirmed it had this command, if it ever did.
    ///
    /// A timeout with no receipt means the relay never heard the command; a
    /// timeout with one means the relay heard it and the watch did not answer.
    /// An unqualified `timedOut` cannot tell those apart.
    func receipt(for commandID: String) -> Date? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return receipts[commandID]
    }

    /// True when a reply arrived for a command nobody was awaiting.
    func hasOrphanedReply(for commandID: String) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return orphanedReplyCommandIDs.contains(commandID)
    }
}

// MARK: - Multichannel capture: program-pair selection & signal probe
//
// A Rane ONE MKII exposes ~14 CoreAudio channels, but ScratchLab must record
// exactly ONE explicitly-selected stereo program (master) pair — never the
// whole device. These pure, hardware-free types back:
//   * the Rane channel-map diagnostic (identify which pair carries program audio),
//   * per-device persistence of the resolved pair, and
//   * (Stage B) the canonical-stereo capture-health gate.
// Thresholds intentionally mirror `TimecodeSignalDiagnostics` so the capture
// path and the timecode path agree on what "silent" / "clipping" mean.

/// An explicitly-selected stereo program channel pair, as zero-based indices
/// into a capture device's interleaved channel order.
struct CaptureAudioProgramPair: Equatable, Codable, Sendable {
    let leftChannel: Int
    let rightChannel: Int

    init?(leftChannel: Int, rightChannel: Int) {
        guard leftChannel >= 0, rightChannel >= 0, leftChannel != rightChannel else { return nil }
        self.leftChannel = leftChannel
        self.rightChannel = rightChannel
    }

    /// The common adjacent ascending pair (`startChannel`, `startChannel + 1`).
    init?(startChannel: Int) {
        self.init(leftChannel: startChannel, rightChannel: startChannel + 1)
    }

    /// Human, 1-based label, e.g. `"1/2"`.
    var label: String { "\(leftChannel + 1)/\(rightChannel + 1)" }

    var maxChannelIndex: Int { max(leftChannel, rightChannel) }

    /// True when both channels exist in a stream carrying `channelCount` channels.
    func isResolvable(inChannelCount channelCount: Int) -> Bool {
        leftChannel >= 0 && rightChannel >= 0 && maxChannelIndex < channelCount
    }
}

/// Per-audio-device persistence of the resolved program pair, keyed by the
/// AVFoundation/CoreAudio device unique ID so each interface keeps its own
/// mapping. Ordinary 2-channel interfaces need no entry — absence resolves to
/// channels 0/1 at the call site.
enum CaptureAudioProgramPairStore {
    static let defaultsKeyPrefix = "scratchlab.capture.programPair."

    static func key(forDeviceUniqueID uid: String) -> String { defaultsKeyPrefix + uid }

    static func pair(
        forDeviceUniqueID uid: String,
        defaults: UserDefaults = .standard
    ) -> CaptureAudioProgramPair? {
        guard !uid.isEmpty, let data = defaults.data(forKey: key(forDeviceUniqueID: uid)) else { return nil }
        return try? JSONDecoder().decode(CaptureAudioProgramPair.self, from: data)
    }

    static func setPair(
        _ pair: CaptureAudioProgramPair?,
        forDeviceUniqueID uid: String,
        defaults: UserDefaults = .standard
    ) {
        guard !uid.isEmpty else { return }
        let k = key(forDeviceUniqueID: uid)
        guard let pair, let data = try? JSONEncoder().encode(pair) else {
            defaults.removeObject(forKey: k)
            return
        }
        defaults.set(data, forKey: k)
    }
}

/// Deterministic per-channel / per-pair signal statistics for a multichannel
/// capture buffer. No AVFoundation or hardware dependency; suitable for the
/// live diagnostic and for unit tests.
enum MultichannelSignalProbe {

    /// RMS (linear, full-scale) below this counts as silence.
    static let silenceRMS: Float = 0.001
    /// RMS below this is "weak" — present but under a usable program level.
    static let weakRMS: Float = 0.02
    /// |sample| at or above this counts as clipping.
    static let clippingPeak: Float = 0.999
    /// |DC mean| at or above this fraction of full-scale is an implausible
    /// pedestal for program audio (the failed Rane take's ch13 sat near −0.868).
    static let excessiveDCOffset: Float = 0.02
    /// |sample − mean| above this counts toward a channel's AC "activity"
    /// fraction. Measured against the mean so a pure-DC channel reads as
    /// inactive however large its offset.
    static let activityThreshold: Float = 0.003

    enum ChannelKind: String, Equatable, Sendable {
        case program          // plausible real audio
        case weakSignal       // audio, but low level
        case silent
        case dcHeavy          // large DC pedestal, little AC content
        case dataOrControl    // non-finite, or near-constant full-scale
        case noiseOnly        // above silence, essentially no structured activity
    }

    struct ChannelStats: Equatable, Sendable {
        let channelIndex: Int
        let frameCount: Int
        let rms: Float
        let peak: Float
        let dcOffset: Float
        let sampleActivity: Float
        let hasNonFiniteSamples: Bool

        var rmsDBFS: Float { MultichannelSignalProbe.dbfs(rms) }
        var peakDBFS: Float { MultichannelSignalProbe.dbfs(peak) }
        var isSilent: Bool { !hasNonFiniteSamples && rms < MultichannelSignalProbe.silenceRMS }
        var isClipping: Bool { peak >= MultichannelSignalProbe.clippingPeak }
        var hasExcessiveDC: Bool { dcOffset.isFinite && abs(dcOffset) >= MultichannelSignalProbe.excessiveDCOffset }

        var kind: ChannelKind {
            if hasNonFiniteSamples { return .dataOrControl }
            if peak >= 0.999 && rms >= 0.98 { return .dataOrControl }
            if isSilent { return .silent }
            if hasExcessiveDC && sampleActivity < 0.05 { return .dcHeavy }
            if rms < MultichannelSignalProbe.silenceRMS { return .silent }
            if sampleActivity < 0.02 { return .noiseOnly }
            if rms < MultichannelSignalProbe.weakRMS { return .weakSignal }
            return .program
        }
    }

    struct PairStats: Equatable, Sendable {
        let pair: CaptureAudioProgramPair
        let left: ChannelStats
        let right: ChannelStats
        let correlation: Float
        /// 0…1; higher means the pair looks more like real stereo program audio.
        let programLikelihood: Float

        var label: String { pair.label }

        /// The one channel carrying program audio when its partner does not.
        /// Non-nil means "usable, but not real stereo".
        var soleProgramChannel: ChannelStats? {
            MultichannelSignalProbe.soleProgramChannel(left: left, right: right)
        }
    }

    struct Snapshot: Equatable, Sendable {
        let channelCount: Int
        let sampleRate: Double
        let frameCount: Int
        let channels: [ChannelStats]
        let pairs: [PairStats]
        let recommendedPair: CaptureAudioProgramPair?

        /// The "CH 1/2 …" block described in the diagnostic spec.
        var reportText: String {
            var lines: [String] = []
            lines.append(String(
                format: "device: %d ch @ %.0f Hz, %d frames",
                channelCount, sampleRate, frameCount
            ))
            if let recommendedPair {
                if let live = pairs.first(where: { $0.pair == recommendedPair })?.soleProgramChannel {
                    let side = live.channelIndex == recommendedPair.leftChannel ? "left" : "right"
                    lines.append(
                        "recommended program pair: CH \(recommendedPair.label)"
                            + " (\(side) channel only — the other carries no program audio)"
                    )
                } else {
                    lines.append("recommended program pair: CH \(recommendedPair.label)")
                }
            } else {
                lines.append("recommended program pair: (none — no pair looks like program audio)")
            }
            for pairStats in pairs {
                lines.append("")
                lines.append("CH \(pairStats.label)")
                lines.append(String(
                    format: "L RMS: %@   R RMS: %@",
                    Self.db(pairStats.left.rmsDBFS), Self.db(pairStats.right.rmsDBFS)
                ))
                lines.append(String(
                    format: "L peak: %@   R peak: %@",
                    Self.db(pairStats.left.peakDBFS), Self.db(pairStats.right.peakDBFS)
                ))
                lines.append(String(
                    format: "L DC: %+.5f   R DC: %+.5f",
                    pairStats.left.dcOffset, pairStats.right.dcOffset
                ))
                lines.append(String(
                    format: "corr: %+.3f   likelihood: %.2f",
                    pairStats.correlation, pairStats.programLikelihood
                ))
                lines.append("status: L \(pairStats.left.kind.rawValue) / R \(pairStats.right.kind.rawValue)")
            }
            return lines.joined(separator: "\n")
        }

        private static func db(_ value: Float) -> String {
            value <= -160 ? "  -inf dBFS" : String(format: "%7.1f dBFS", value)
        }
    }

    static func dbfs(_ linear: Float) -> Float {
        guard linear.isFinite, linear > 0 else { return -160 }
        return 20 * log10(linear)
    }

    /// Analyse planar per-channel Float samples (one array per channel).
    static func analyze(planarChannels: [[Float]], sampleRate: Double) -> Snapshot? {
        guard !planarChannels.isEmpty else { return nil }
        let frameCount = planarChannels.map(\.count).min() ?? 0
        guard frameCount > 0 else { return nil }

        let channels = planarChannels.enumerated().map { index, samples in
            channelStats(channelIndex: index, samples: samples, limit: frameCount)
        }

        var pairs: [PairStats] = []
        var start = 0
        while start + 1 < channels.count {
            if let pair = CaptureAudioProgramPair(startChannel: start) {
                pairs.append(pairStats(
                    pair: pair,
                    left: channels[start],
                    right: channels[start + 1],
                    leftSamples: planarChannels[start],
                    rightSamples: planarChannels[start + 1],
                    limit: frameCount
                ))
            }
            start += 2
        }

        let recommendedPair = pairs
            .max(by: { $0.programLikelihood < $1.programLikelihood })
            .flatMap { $0.programLikelihood >= 0.5 ? $0.pair : nil }

        return Snapshot(
            channelCount: channels.count,
            sampleRate: sampleRate,
            frameCount: frameCount,
            channels: channels,
            pairs: pairs,
            recommendedPair: recommendedPair
        )
    }

    /// Analyse an interleaved buffer of `frameCount * channelCount` samples.
    static func analyzeInterleaved(
        _ interleaved: [Float],
        channelCount: Int,
        sampleRate: Double
    ) -> Snapshot? {
        guard channelCount > 0, interleaved.count >= channelCount else { return nil }
        let frameCount = interleaved.count / channelCount
        guard frameCount > 0 else { return nil }
        var planar = Array(
            repeating: [Float](repeating: 0, count: frameCount),
            count: channelCount
        )
        for frame in 0..<frameCount {
            let base = frame * channelCount
            for channel in 0..<channelCount {
                planar[channel][frame] = interleaved[base + channel]
            }
        }
        return analyze(planarChannels: planar, sampleRate: sampleRate)
    }

    // MARK: - Internals

    static func channelStats(channelIndex: Int, samples: [Float], limit: Int) -> ChannelStats {
        let count = min(limit, samples.count)
        guard count > 0 else {
            return ChannelStats(
                channelIndex: channelIndex, frameCount: 0, rms: 0, peak: 0,
                dcOffset: 0, sampleActivity: 0, hasNonFiniteSamples: false
            )
        }
        var sum: Double = 0
        var sumSquares: Double = 0
        var peak: Float = 0
        var nonFinite = false
        for index in 0..<count {
            let value = samples[index]
            if !value.isFinite {
                nonFinite = true
                continue
            }
            let magnitude = abs(value)
            sum += Double(value)
            sumSquares += Double(value) * Double(value)
            if magnitude > peak { peak = magnitude }
        }
        let n = Double(count)
        let mean = sum / n
        let rms = Float((sumSquares / n).squareRoot())

        // AC activity: fraction of finite samples that swing away from the mean.
        var activeCount = 0
        for index in 0..<count {
            let value = samples[index]
            guard value.isFinite else { continue }
            if abs(value - Float(mean)) > activityThreshold { activeCount += 1 }
        }
        return ChannelStats(
            channelIndex: channelIndex,
            frameCount: count,
            rms: rms.isFinite ? rms : 0,
            peak: peak,
            dcOffset: Float(mean),
            sampleActivity: Float(activeCount) / Float(count),
            hasNonFiniteSamples: nonFinite
        )
    }

    static func pairStats(
        pair: CaptureAudioProgramPair,
        left: ChannelStats,
        right: ChannelStats,
        leftSamples: [Float],
        rightSamples: [Float],
        limit: Int
    ) -> PairStats {
        let correlation = pearsonCorrelation(leftSamples, rightSamples, limit: limit)
        let likelihood = programLikelihood(left: left, right: right, correlation: correlation)
        return PairStats(
            pair: pair,
            left: left,
            right: right,
            correlation: correlation,
            programLikelihood: likelihood
        )
    }

    static func pearsonCorrelation(_ a: [Float], _ b: [Float], limit: Int) -> Float {
        let count = min(limit, min(a.count, b.count))
        guard count > 1 else { return 0 }
        var sumA: Double = 0, sumB: Double = 0
        for index in 0..<count {
            let x = a[index], y = b[index]
            guard x.isFinite, y.isFinite else { return 0 }
            sumA += Double(x); sumB += Double(y)
        }
        let meanA = sumA / Double(count)
        let meanB = sumB / Double(count)
        var covariance: Double = 0, varA: Double = 0, varB: Double = 0
        for index in 0..<count {
            let dx = Double(a[index]) - meanA
            let dy = Double(b[index]) - meanB
            covariance += dx * dy
            varA += dx * dx
            varB += dy * dy
        }
        guard varA > 0, varB > 0 else { return 0 }
        let result = covariance / (varA.squareRoot() * varB.squareRoot())
        return Float(max(-1, min(1, result)))
    }

    /// A half-live pair is usable but never as good as real stereo, so it is
    /// capped below what a genuine stereo pair can score.
    static let monoRecoveredLikelihoodCeiling: Float = 0.75

    /// The one channel carrying program audio when its partner does not.
    ///
    /// A pair like this is still usable — `SessionExportAudioProjection` writes
    /// the live channel to both sides rather than shipping the dead one — so it
    /// must be recommendable. It is not real stereo, so it must only ever beat
    /// "nothing at all", never a genuine pair.
    static func soleProgramChannel(left: ChannelStats, right: ChannelStats) -> ChannelStats? {
        // A non-finite sample anywhere makes the pair untrustworthy: NaN would
        // propagate straight into the exported stem.
        guard !left.hasNonFiniteSamples, !right.hasNonFiniteSamples else { return nil }
        let leftIsProgram = left.kind == .program
        let rightIsProgram = right.kind == .program
        guard leftIsProgram != rightIsProgram else { return nil }
        let live = leftIsProgram ? left : right
        let partner = leftIsProgram ? right : left
        switch partner.kind {
        case .silent, .dcHeavy, .dataOrControl, .noiseOnly:
            return live
        case .program, .weakSignal:
            // A merely quiet partner is still a stereo pair, not a dead one.
            return nil
        }
    }

    /// Scores a pair carrying program audio on exactly one channel.
    ///
    /// Pair-level scoring alone subtracts for the dead partner and then
    /// multiplies the whole pair down, so a live channel beside a DC-frozen one
    /// scored ~0.04 and the probe reported "no pair looks like program audio"
    /// while that channel *was* the performance. Measured on a RANE ONE MKII
    /// (2026-08-31), CH 13/14: L frozen at +0.66995, R program at -4.8 dBFS.
    static func monoRecoveredProgramLikelihood(
        left: ChannelStats,
        right: ChannelStats
    ) -> Float {
        guard let live = soleProgramChannel(left: left, right: right) else { return 0 }
        var score: Float = 0.60
        if live.rmsDBFS <= -3 && live.rmsDBFS >= -55 { score += 0.10 }
        // Clipping is a level warning, not evidence against program audio — a
        // scratch performance touching full scale is ordinary.
        if live.isClipping { score *= 0.85 }
        return max(0, min(monoRecoveredLikelihoodCeiling, score))
    }

    static func programLikelihood(
        left: ChannelStats,
        right: ChannelStats,
        correlation: Float
    ) -> Float {
        max(
            stereoProgramLikelihood(left: left, right: right, correlation: correlation),
            monoRecoveredProgramLikelihood(left: left, right: right)
        )
    }

    /// Scores a pair as real stereo program audio: both channels must earn it.
    static func stereoProgramLikelihood(
        left: ChannelStats,
        right: ChannelStats,
        correlation: Float
    ) -> Float {
        var score: Float = 0

        for channel in [left, right] {
            switch channel.kind {
            case .program: score += 0.35
            case .weakSignal: score += 0.12
            case .noiseOnly: score += 0.02
            case .silent, .dcHeavy, .dataOrControl: score -= 0.30
            }
        }

        // Both channels sitting in a plausible program band.
        let bandOK = [left, right].allSatisfy { $0.rmsDBFS <= -3 && $0.rmsDBFS >= -55 }
        if bandOK { score += 0.20 }

        // Real stereo: correlated enough to be one performance, decorrelated
        // enough not to be dual-mono / a duplicated data line.
        let magnitude = abs(correlation)
        if magnitude > 0.05 && magnitude < 0.985 { score += 0.15 }
        if magnitude >= 0.999 { score -= 0.10 }

        // Hard disqualifiers.
        if left.isClipping || right.isClipping { score *= 0.5 }
        if left.hasExcessiveDC || right.hasExcessiveDC { score *= 0.3 }
        if left.hasNonFiniteSamples || right.hasNonFiniteSamples { score = 0 }
        if left.isSilent || right.isSilent { score *= 0.15 }

        return max(0, min(1, score))
    }
}
