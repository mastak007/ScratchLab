import Foundation
import MultipeerConnectivity
import AppKit
import Network

struct RelayedWatchMotionCapture: Identifiable {
    let fileURL: URL
    let session: WatchMotionCaptureSession
    let sourcePeerName: String?

    var id: UUID { session.id }
}

final class RelayedWatchCaptureStore: ObservableObject {
    enum RemoteControlState: Equatable {
        case idle
        case starting
        case acknowledged
        case stopping
        case timedOut(String)
        case unavailable(String)
        case failed(String)

        var statusText: String {
            switch self {
            case .idle:
                return "Watch motion relay is idle."
            case .starting:
                return "Starting watch motion capture through companion device."
            case .acknowledged:
                return "Watch motion capture acknowledged."
            case .stopping:
                return "Stopping watch motion capture through companion device."
            case .timedOut(let message), .unavailable(let message), .failed(let message):
                return message
            }
        }
    }

    @Published private(set) var importedSessions: [RelayedWatchMotionCapture] = []
    @Published private(set) var lastImportStatus = "Waiting for a watch capture relay from companion device."
    @Published private(set) var remoteControlState: RemoteControlState = .idle

    /// Live watch state as reported by the paired iPhone over the companion bridge. macOS has no
    /// direct WCSession — this is the only source of truth for Watch pairing/reachability, and
    /// `nil` means the iPhone hasn't reported anything yet (never assume reachable by default).
    @Published private(set) var watchIsPaired = false
    @Published private(set) var watchIsInstalled = false
    @Published private(set) var watchIsReachable = false
    @Published private(set) var watchAvailabilityUpdatedAt: Date?
    @Published private(set) var relayState: WatchRelayFlowState = .waiting
    @Published private(set) var activeTakeContext: WatchRelayTakeContext?
    @Published private(set) var lastHeartbeatAt: Date?
    @Published private(set) var lastInterruption: WatchRelayInterruption?

    private var isCompanionConnected = false
    private var pendingTakeContext: WatchRelayTakeContext?
    private var endingTakeContext: WatchRelayTakeContext?
    private var liveAssembler = WatchMotionRelayAssembler()

    var watchAvailabilitySummary: String {
        guard watchAvailabilityUpdatedAt != nil else {
            return "Watch status: waiting for the paired iPhone to report Apple Watch status."
        }
        if !watchIsPaired {
            return "Watch status: no Apple Watch paired with the iPhone."
        }
        if !watchIsInstalled {
            return "Watch status: paired, but ScratchLab is not installed on the watch."
        }
        if watchIsReachable {
            return "Watch status: paired, installed, and reachable through the iPhone."
        }
        return "Watch status: paired and installed, but not currently reachable through the iPhone."
    }

    var relayStatusText: String {
        switch relayState {
        case .waiting:
            return "Watch relay is waiting for the required connections."
        case .ready:
            return "Watch relay is ready for a Mac-authorized take."
        case .active:
            return "Watch relay is active for \(activeTakeContext?.takeID ?? "the current take")."
        case .interrupted:
            return lastInterruption?.detail ?? "Watch relay was interrupted."
        }
    }

    /// Semantic readiness of the Apple Watch input, as macOS can actually know it.
    ///
    /// macOS has no direct `WCSession`: pairing / installed / reachable are all
    /// relayed by the paired iPhone over the companion bridge. "Nothing reported
    /// yet" is therefore a distinct state from "no watch paired", and neither may
    /// be rendered as "not connected" — that phrasing previously came from
    /// `importedSessions.isEmpty`, i.e. capture *history*, which said nothing
    /// about whether a watch was paired, installed, or reachable. A healthy,
    /// reachable watch that simply had not relayed a capture yet read as
    /// "Not connected".
    ///
    /// The watch is an **optional** input, so every case here maps to a
    /// non-blocking `InputReadinessState` (never `.setupRequired`,
    /// `.needsAttention` or `.lost`, all of which are `isBlocking`).
    enum WatchInputReadiness: Equatable, Sendable {
        /// The paired iPhone has not reported watch status yet — usually the
        /// companion bridge itself is not connected.
        case awaitingPhoneReport
        case notPaired
        case notInstalled
        /// Paired and installed, but not currently reachable through the iPhone.
        case unreachable
        /// Reachable, but no motion capture has been relayed in this session yet.
        case reachableAwaitingCapture
        case motionAvailable
        /// Motion was relayed earlier, but the watch is not reachable right now.
        case motionAvailableUnreachable

        static func resolve(
            hasPhoneReport: Bool,
            isPaired: Bool,
            isInstalled: Bool,
            isReachable: Bool,
            hasImportedCaptures: Bool
        ) -> WatchInputReadiness {
            guard hasPhoneReport else { return .awaitingPhoneReport }
            guard isPaired else { return .notPaired }
            guard isInstalled else { return .notInstalled }
            if isReachable {
                return hasImportedCaptures ? .motionAvailable : .reachableAwaitingCapture
            }
            return hasImportedCaptures ? .motionAvailableUnreachable : .unreachable
        }

        var detail: String {
            switch self {
            case .awaitingPhoneReport:
                return "Waiting for the paired iPhone to report watch status"
            case .notPaired:
                return "No Apple Watch paired with the iPhone"
            case .notInstalled:
                return "Paired — ScratchLab is not installed on the watch"
            case .unreachable:
                return "Paired and installed — not currently reachable"
            case .reachableAwaitingCapture:
                return "Reachable — no motion relayed yet"
            case .motionAvailable:
                return "Motion data available"
            case .motionAvailableUnreachable:
                return "Motion data available — watch not currently reachable"
            }
        }

        /// Optional input: never blocking. `.detected` means "the watch is
        /// present and usable"; `.ready` is reserved for "motion has actually
        /// arrived", matching the design-system rule that `detected` is not
        /// `ready`.
        var readinessState: InputReadinessState {
            switch self {
            case .awaitingPhoneReport, .notPaired, .notInstalled, .unreachable:
                return .neutral
            case .reachableAwaitingCapture, .motionAvailableUnreachable:
                return .detected
            case .motionAvailable:
                return .ready
            }
        }
    }

    /// Live watch readiness derived from the relayed availability signals —
    /// never from capture history alone.
    var watchInputReadiness: WatchInputReadiness {
        WatchInputReadiness.resolve(
            hasPhoneReport: watchAvailabilityUpdatedAt != nil,
            isPaired: watchIsPaired,
            isInstalled: watchIsInstalled,
            isReachable: watchIsReachable,
            hasImportedCaptures: !importedSessions.isEmpty
        )
    }

    @MainActor
    func updateWatchAvailability(isPaired: Bool, isInstalled: Bool, isReachable: Bool) {
        watchIsPaired = isPaired
        watchIsInstalled = isInstalled
        watchIsReachable = isReachable
        watchAvailabilityUpdatedAt = Date()
        if activeTakeContext != nil, !isReachable {
            markInterrupted("Apple Watch reachability was lost during the active take.")
        } else {
            resolveIdleRelayState()
        }
    }

    @MainActor
    func notePeerConnection(isConnected: Bool) {
        let wasConnected = isCompanionConnected
        isCompanionConnected = isConnected
        if wasConnected, !isConnected, activeTakeContext != nil || endingTakeContext != nil {
            markInterrupted("The iPhone relay connection was lost during the active take.")
        } else {
            resolveIdleRelayState()
        }
    }

    private let fileManager = FileManager.default
    private let captureDirectoryOverride: URL?

    var captureDirectoryURL: URL {
        if let captureDirectoryOverride { return captureDirectoryOverride }
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
        return baseURL
            .appendingPathComponent("ScratchLab", isDirectory: true)
            .appendingPathComponent("RelayedWatchCaptures", isDirectory: true)
    }

    init(captureDirectoryURL: URL? = nil) {
        captureDirectoryOverride = captureDirectoryURL
        createCaptureDirectoryIfNeeded()
        reconcileStoredSessions()
        loadStoredSessions()
    }

    @MainActor
    func noteRequestedStart(context: WatchRelayTakeContext) {
        pendingTakeContext = context
        endingTakeContext = nil
        liveAssembler.reset()
        remoteControlState = .starting
    }

    @MainActor
    func noteRequestedStop(sessionID: String, takeID: String?) {
        guard currentControlContext(sessionID: sessionID, takeID: takeID) != nil else { return }
        remoteControlState = .stopping
    }

    /// A cleanup command for an older take still travels to the Watch, but
    /// its late status cannot change the take currently shown or recorded.
    /// Pending wins because a new start may overlap an older stop reply.
    @MainActor
    private func currentControlContext(sessionID: String, takeID: String?) -> WatchRelayTakeContext? {
        guard let context = pendingTakeContext ?? activeTakeContext ?? endingTakeContext,
              context.sessionID == sessionID, context.takeID == takeID else { return nil }
        return context
    }

    @MainActor
    func noteRemoteControlStatus(_ reply: WatchCaptureControlReply) {
        guard let context = currentControlContext(sessionID: reply.sessionID, takeID: reply.takeID) else {
            return
        }
        switch reply.syncState {
        case .notRequested:
            remoteControlState = .idle
        case .requested:
            remoteControlState = .starting
        case .acknowledged:
            remoteControlState = .acknowledged
            if let pendingTakeContext,
               pendingTakeContext.sessionID == reply.sessionID,
               pendingTakeContext.takeID == reply.takeID {
                activeTakeContext = pendingTakeContext
                self.pendingTakeContext = nil
                relayState = .active
            }
        case .timedOut:
            remoteControlState = .timedOut(reply.detail ?? "Watch motion start timed out.")
            markInterrupted(reply.detail ?? "Watch motion start timed out.", context: context)
        case .unavailable:
            remoteControlState = .unavailable(reply.detail ?? "Watch motion capture is unavailable.")
            markInterrupted(reply.detail ?? "Watch motion capture is unavailable.", context: context)
        case .failed:
            remoteControlState = .failed(reply.detail ?? "Watch motion capture failed to start.")
            markInterrupted(reply.detail ?? "Watch motion capture failed to start.", context: context)
        }
    }

    @MainActor
    func noteRelayLifecycle(_ packet: WatchRelayLifecyclePacket) {
        guard packet.kind == WatchRelayLifecyclePacket.packetKind else { return }
        lastHeartbeatAt = packet.sentAt

        switch packet.event {
        case .hello, .reconnect:
            if let context = packet.context,
               context == activeTakeContext || context == pendingTakeContext || context == endingTakeContext {
                activeTakeContext = context
                relayState = .active
            } else {
                resolveIdleRelayState()
            }
        case .relayReady:
            guard activeTakeContext == nil else { return }
            resolveIdleRelayState()
        case .takeBegin:
            guard let context = packet.context, context == pendingTakeContext || context == activeTakeContext else {
                return
            }
            activeTakeContext = context
            pendingTakeContext = nil
            relayState = .active
        case .takeEnd:
            guard let context = packet.context, context == activeTakeContext || context == endingTakeContext else {
                return
            }
            endingTakeContext = context
            activeTakeContext = nil
            resolveIdleRelayState()
        case .heartbeat:
            if let context = packet.context {
                guard context == activeTakeContext || context == endingTakeContext else { return }
                if activeTakeContext != nil {
                    relayState = .active
                }
            } else {
                resolveIdleRelayState()
            }
        case .error:
            let context = packet.context
            guard context == nil || context == activeTakeContext || context == endingTakeContext || context == pendingTakeContext else {
                return
            }
            markInterrupted(packet.detail ?? "The watch relay reported an interruption.", context: context)
        }
    }

    @MainActor
    func receiveLiveMotionBatch(_ batch: WatchMotionRelayBatch, sourcePeerName: String?) {
        guard let authorizedContext = activeTakeContext ?? endingTakeContext ?? pendingTakeContext else {
            lastImportStatus = "Rejected live watch motion without an active Mac take."
            return
        }

        switch liveAssembler.ingest(batch, accepting: authorizedContext) {
        case .accepted:
            lastImportStatus = "Receiving live watch motion for \(authorizedContext.takeID)."
        case .rejected:
            lastImportStatus = "Rejected stale or unknown live watch motion for \(batch.context.takeID)."
        case .completed(let session):
            importRelayedSession(
                session,
                suggestedFileName: "scratch-motion-live-\(session.id.uuidString).json",
                sourcePeerName: sourcePeerName
            )
            liveAssembler.reset()
            endingTakeContext = nil
            resolveIdleRelayState()
        }
    }

    @MainActor
    func evaluateHeartbeatTimeout(now: Date = Date(), maximumAge: TimeInterval = 5) {
        guard activeTakeContext != nil,
              let lastHeartbeatAt,
              now.timeIntervalSince(lastHeartbeatAt) > maximumAge else { return }
        markInterrupted("The iPhone relay heartbeat stopped during the active take.")
    }

    @MainActor
    private func resolveIdleRelayState() {
        if activeTakeContext != nil {
            relayState = isCompanionConnected && watchIsReachable ? .active : .interrupted
        } else if isCompanionConnected && watchIsReachable {
            relayState = .ready
        } else if relayState != .interrupted {
            relayState = .waiting
        }
    }

    @MainActor
    private func markInterrupted(_ detail: String, context: WatchRelayTakeContext? = nil) {
        let resolvedContext = context ?? activeTakeContext ?? endingTakeContext ?? pendingTakeContext
        guard relayState != .interrupted || lastInterruption?.detail != detail else { return }
        relayState = .interrupted
        lastInterruption = WatchRelayInterruption(context: resolvedContext, detail: detail)
    }

    func linkedCapture(sessionID: String, takeID: String) -> RelayedWatchMotionCapture? {
        importedSessions.first(where: {
            WatchAssociationResolver.isLinkedCaptureValid(
                sessionID: sessionID,
                takeID: takeID,
                captureSession: $0.session
            )
        })
    }

    @MainActor
    func importRelayedSession(
        _ captureSession: WatchMotionCaptureSession,
        suggestedFileName: String?,
        sourcePeerName: String?
    ) {
        do {
            let storedCapture = try persist(
                captureSession,
                suggestedFileName: suggestedFileName,
                sourcePeerName: sourcePeerName
            )
            reconcileStoredSessions()
            loadStoredSessions()
            lastImportStatus = "Imported watch motion relay from \(sourcePeerName ?? "companion device") at \(formatDate(storedCapture.session.deviceRecordedAtStart))."
        } catch {
            lastImportStatus = "Watch motion relay failed to import."
        }
    }

    func reconcileStoredSessionsNow() {
        reconcileStoredSessions()
        loadStoredSessions()
    }

    private func loadStoredSessions() {
        let captures = (try? fileManager.contentsOfDirectory(
            at: captureDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        importedSessions = captures
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap(decodeCapture(at:))
            .sorted(by: { lhs, rhs in
                lhs.session.deviceRecordedAtStart > rhs.session.deviceRecordedAtStart
            })
    }

    private func reconcileStoredSessions() {
        let routineDirectory = captureDirectoryURL
            .deletingLastPathComponent()
            .appendingPathComponent("RoutineCaptures", isDirectory: true)
        let report = StagedCaptureRecoveryManager().reconcileWatchDirectory(
            at: captureDirectoryURL,
            storageKind: .relayedWatch,
            sidecarDirectories: [routineDirectory],
            sidecarStorageKind: .routine
        )
        if let summaryText = report.summaryText {
            lastImportStatus = summaryText
        }
    }

    private func createCaptureDirectoryIfNeeded() {
        do {
            try fileManager.createDirectory(at: captureDirectoryURL, withIntermediateDirectories: true)
        } catch {
            lastImportStatus = "Couldn't prepare macOS storage for relayed watch captures."
        }
    }

    private func persist(
        _ captureSession: WatchMotionCaptureSession,
        suggestedFileName: String?,
        sourcePeerName: String?
    ) throws -> RelayedWatchMotionCapture {
        try fileManager.createDirectory(at: captureDirectoryURL, withIntermediateDirectories: true)
        let destinationURL: URL
        if let existingCapture = importedSessions.first(where: { $0.id == captureSession.id }) {
            destinationURL = existingCapture.fileURL
        } else {
            let fileName = sanitizedFileName(suggestedFileName ?? "scratch-motion-\(captureSession.id.uuidString).json")
            destinationURL = captureDirectoryURL.appendingPathComponent(fileName)
        }
        let data = try WatchMotionCaptureCodec.encoder.encode(captureSession)
        try data.write(to: destinationURL, options: Data.WritingOptions.atomic)
        return RelayedWatchMotionCapture(fileURL: destinationURL, session: captureSession, sourcePeerName: sourcePeerName)
    }

    private func decodeCapture(at url: URL) -> RelayedWatchMotionCapture? {
        guard let data = try? Data(contentsOf: url),
              let session = try? WatchMotionCaptureCodec.decoder.decode(WatchMotionCaptureSession.self, from: data) else {
            return nil
        }

        return RelayedWatchMotionCapture(fileURL: url, session: session, sourcePeerName: nil)
    }

    private func sanitizedFileName(_ value: String) -> String {
        let cleaned = value
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return cleaned.lowercased().hasSuffix(".json") ? cleaned : cleaned + ".json"
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

final class CompanionCameraReceiver: NSObject, ObservableObject {
    private struct FramePacket: Codable {
        let position: String
        let timestamp: TimeInterval
        let jpegData: Data
    }

    private struct WatchCaptureRelayPacket: Codable {
        let kind: String
        let fileName: String
        let captureSession: WatchMotionCaptureSession

        var isWatchCaptureRelay: Bool {
            kind == Self.packetKind
        }

        static let packetKind = "watch_motion_capture_relay_v1"
    }

    private struct WatchControlCommandPacket: Codable {
        let payload: WatchCaptureCommandPayload
    }

    private struct WatchControlStatusPacket: Codable {
        let reply: WatchCaptureControlReply
    }

    private struct WatchAvailabilityPacket: Codable {
        let kind: String
        let isPaired: Bool
        let isInstalled: Bool
        let isReachable: Bool

        var isWatchAvailability: Bool {
            kind == Self.packetKind
        }

        static let packetKind = "watch_availability_v1"
    }

    private struct WatchCaptureRelayAckPacket: Codable {
        let kind: String
        let captureID: UUID

        init(captureID: UUID) {
            self.kind = Self.packetKind
            self.captureID = captureID
        }

        static let packetKind = "watch_motion_capture_relay_ack_v1"
    }

    final class FrameStore: ObservableObject {
        @Published var image: NSImage?
        @Published var cameraPosition = "Unknown"
    }

    struct PeerSummary: Identifiable, Equatable {
        let id: String
        let name: String
    }

    @Published var discoveredPeers: [PeerSummary] = []
    @Published var connectedPeerNames: [String] = []
    @Published var connectionStatus = "Companion relay is off"
    @Published private(set) var isBrowsingForPeers = false

    let frameStore = FrameStore()
    let relayedWatchCaptureStore: RelayedWatchCaptureStore

    private let serviceType = "scrcamfeed"
    private let directServiceType = "_scrcamfeed._tcp"
    private let peerID = MCPeerID(displayName: Host.current().localizedName ?? "ScratchLab")
    private lazy var session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
    private lazy var browser = MCNearbyServiceBrowser(peer: peerID, serviceType: serviceType)
    private let decoder = PropertyListDecoder()
    private let maximumAcceptedFrameAge: TimeInterval = 0.45
    private let minimumFramePublishInterval: TimeInterval = 1.0 / 12.0
    private var peerLookup: [String: MCPeerID] = [:]
    private var attemptedAutoConnectPeerIDs: Set<String> = []
    private var latestRenderedFrameTimestamp: TimeInterval = 0
    private var lastPublishedWallClockTime: TimeInterval = 0
    private let watchCommandCoordinator = WatchCaptureCommandCoordinator()
    private var watchHealthTimer: DispatchSourceTimer?
    private let relayQueue = DispatchQueue(label: "scratchlab.cxl.companion.relay")
    private let directConnectionLock = NSLock()
    private var directBrowser: NWBrowser?
    private var directConnection: NWConnection?
    private var directEndpointLookup: [String: NWEndpoint] = [:]

    init(relayedWatchCaptureStore: RelayedWatchCaptureStore, autoStartBrowsing: Bool = true) {
        self.relayedWatchCaptureStore = relayedWatchCaptureStore
        super.init()
        session.delegate = self
        browser.delegate = self
        if autoStartBrowsing {
            Task { @MainActor [weak self] in
                self?.startBrowsingForCompanionIfNeeded()
            }
        }
    }

    deinit {
        if isBrowsingForPeers {
            browser.stopBrowsingForPeers()
        }
        watchHealthTimer?.cancel()
        directBrowser?.cancel()
        replaceDirectConnection(nil)
    }

    /// Starts nearby companion discovery only after the operator enables the relay.
    /// Repeated calls are safe and do not create another browser or health timer.
    @MainActor
    func startBrowsingForCompanionIfNeeded() {
        guard !isBrowsingForPeers else { return }

        isBrowsingForPeers = true
        connectionStatus = "Searching for companion device"
        startDirectBrowsing()
        startWatchHealthTimer()
    }

    @MainActor
    func requestWatchCaptureStart(
        sessionID: String,
        takeID: String,
        takeNumber: Int? = nil,
        watchWrist: String? = nil,
        timeoutSeconds: TimeInterval = 3
    ) async -> WatchCaptureControlReply {
        let payload = WatchCaptureCommandPayload(
            command: .start,
            sessionID: sessionID,
            takeID: takeID,
            takeNumber: takeNumber,
            watchWrist: watchWrist
        )
        let context = WatchRelayTakeContext(
            sessionID: sessionID,
            takeID: takeID,
            takeNumber: takeNumber,
            watchWrist: watchWrist
        )
        relayedWatchCaptureStore.noteRequestedStart(context: context)

        guard hasConnectedRelay else {
            let reply = WatchCaptureControlReply(
                commandID: payload.commandID,
                sessionID: sessionID,
                takeID: takeID,
                syncState: .unavailable,
                detail: "Connect the companion device before trying to control watch capture."
            )
            relayedWatchCaptureStore.noteRemoteControlStatus(reply)
            return reply
        }

        let sendSucceeded = sendWatchControlCommand(payload)
        guard sendSucceeded else {
            let reply = WatchCaptureControlReply(
                commandID: payload.commandID,
                sessionID: sessionID,
                takeID: takeID,
                syncState: .failed,
                detail: "ScratchLab couldn't send the watch control command to the companion device."
            )
            relayedWatchCaptureStore.noteRemoteControlStatus(reply)
            return reply
        }

        let reply = await awaitWatchControlReply(
            for: payload,
            timeoutSeconds: timeoutSeconds,
            timeoutDetail: "Watch start did not acknowledge within \(Int(timeoutSeconds)) seconds.",
            timeoutStopOutcome: nil
        )
        relayedWatchCaptureStore.noteRemoteControlStatus(reply)
        return reply
    }

    /// Asks the Watch to stop the capture named by `sessionID`/`takeID` and
    /// waits, within a bound, for it to say what happened.
    ///
    /// Previously this was fire-and-forget: the Mac sent a stop and reported
    /// success regardless of whether the command reached the relay, reached the
    /// Watch, or was acted on. A Watch that never got the command kept
    /// recording — for 18.5 s past the end of a take, in the BVB capture — and
    /// nothing in the export said so.
    ///
    /// Bounded on purpose. `CaptureWatchStopPolicy` caps one attempt and the
    /// total number of attempts, so media finalization can never be blocked
    /// indefinitely by a Watch that is off the wrist. When the bound is reached
    /// the degraded outcome is returned and recorded — never smoothed into
    /// success.
    ///
    /// - Returns: the resolved reply. `stopOutcome` is always populated.
    @MainActor
    @discardableResult
    func requestWatchCaptureStop(
        sessionID: String,
        takeID: String?,
        timeoutSeconds: TimeInterval = CaptureWatchStopPolicy.acknowledgementTimeoutSeconds,
        maximumAttempts: Int = CaptureWatchStopPolicy.maximumAttempts
    ) async -> WatchCaptureControlReply {
        let context = relayedWatchCaptureStore.activeTakeContext
        let resolvedTakeID = takeID ?? context?.takeID
        relayedWatchCaptureStore.noteRequestedStop(sessionID: sessionID, takeID: resolvedTakeID)
        var lastReply: WatchCaptureControlReply?

        for attempt in 1...max(1, maximumAttempts) {
            let payload = WatchCaptureCommandPayload(
                command: .stop,
                sessionID: sessionID,
                takeID: resolvedTakeID,
                takeNumber: context?.takeNumber,
                watchWrist: context?.watchWrist
            )

            guard hasConnectedRelay else {
                let reply = WatchCaptureControlReply(
                    commandID: payload.commandID,
                    sessionID: sessionID,
                    takeID: resolvedTakeID,
                    syncState: .unavailable,
                    detail: "No companion device is connected, so the watch could not be told to stop.",
                    stopOutcome: .unreachable
                )
                relayedWatchCaptureStore.noteRemoteControlStatus(reply)
                return reply
            }

            guard sendWatchControlCommand(payload) else {
                let reply = WatchCaptureControlReply(
                    commandID: payload.commandID,
                    sessionID: sessionID,
                    takeID: resolvedTakeID,
                    syncState: .failed,
                    detail: "ScratchLab couldn't send the watch stop command to the companion device.",
                    stopOutcome: .failed
                )
                relayedWatchCaptureStore.noteRemoteControlStatus(reply)
                return reply
            }

            let reply = await awaitWatchControlReply(
                for: payload,
                timeoutSeconds: timeoutSeconds,
                timeoutDetail: "Watch stop was not acknowledged within \(Int(timeoutSeconds)) seconds.",
                timeoutStopOutcome: .timedOut
            )
            lastReply = reply

            let outcome = CaptureWatchStopPolicy.outcome(for: reply)
            // Only a timeout is worth resending: unreachable, rejected and
            // failed are answers, not silence, and repeating the command cannot
            // change them.
            if outcome != .timedOut || attempt == max(1, maximumAttempts) {
                relayedWatchCaptureStore.noteRemoteControlStatus(reply)
                return reply
            }
        }

        let fallback = lastReply ?? WatchCaptureControlReply(
            commandID: UUID().uuidString.lowercased(),
            sessionID: sessionID,
            takeID: resolvedTakeID,
            syncState: .timedOut,
            detail: "Watch stop was not acknowledged.",
            stopOutcome: .timedOut
        )
        relayedWatchCaptureStore.noteRemoteControlStatus(fallback)
        return fallback
    }

    /// Races the command coordinator against a bounded timeout. Shared by the
    /// start and stop paths so both resolve exactly once.
    private func awaitWatchControlReply(
        for payload: WatchCaptureCommandPayload,
        timeoutSeconds: TimeInterval,
        timeoutDetail: String,
        timeoutStopOutcome: CaptureWatchStopOutcome?
    ) async -> WatchCaptureControlReply {
        await withTaskGroup(of: WatchCaptureControlReply.self) { group in
            group.addTask {
                await self.watchCommandCoordinator.begin(command: payload)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                return self.watchCommandCoordinator.timeout(commandID: payload.commandID)
                    ?? WatchCaptureControlReply(
                        commandID: payload.commandID,
                        sessionID: payload.sessionID,
                        takeID: payload.takeID,
                        syncState: .timedOut,
                        detail: timeoutDetail,
                        stopOutcome: timeoutStopOutcome
                    )
            }

            guard let reply = await group.next() else {
                return WatchCaptureControlReply(
                    commandID: payload.commandID,
                    sessionID: payload.sessionID,
                    takeID: payload.takeID,
                    syncState: .failed,
                    detail: "The watch command failed before a reply was received.",
                    stopOutcome: timeoutStopOutcome == nil ? nil : .failed
                )
            }
            group.cancelAll()
            // A timeout with no receipt means the relay never heard the
            // command; a timeout with one means the watch did not answer.
            return reply.withRelayReceipt(
                self.watchCommandCoordinator.receipt(for: payload.commandID)
            )
        }
    }

    func connect(to peer: PeerSummary) {
        if let endpoint = directEndpointLookup[peer.id] {
            connectDirectly(to: endpoint, peerName: peer.name)
            return
        }
        guard let mcPeer = peerLookup[peer.id] else { return }
        connectionStatus = "Inviting \(peer.name)"
        browser.invitePeer(mcPeer, to: session, withContext: nil, timeout: 10)
    }

    func disconnect() {
        session.disconnect()
        replaceDirectConnection(nil)
        connectedPeerNames = []
        latestRenderedFrameTimestamp = 0
        lastPublishedWallClockTime = 0
        frameStore.image = nil
        frameStore.cameraPosition = "Unknown"
        connectionStatus = "Searching for companion device"
        Task { @MainActor in
            self.relayedWatchCaptureStore.notePeerConnection(isConnected: false)
        }
    }

    private var hasConnectedRelay: Bool {
        directConnectionLock.lock()
        let hasDirectConnection = directConnection != nil
        directConnectionLock.unlock()
        return hasDirectConnection || !session.connectedPeers.isEmpty
    }

    private func replaceDirectConnection(_ connection: NWConnection?) {
        directConnectionLock.lock()
        let previous = directConnection
        directConnection = connection
        directConnectionLock.unlock()
        if previous !== connection {
            previous?.cancel()
        }
    }

    private func directConnectionSnapshot() -> NWConnection? {
        directConnectionLock.lock()
        defer { directConnectionLock.unlock() }
        return directConnection
    }

    private func startDirectBrowsing() {
        directBrowser?.cancel()
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: directServiceType, domain: nil),
            using: parameters
        )
        directBrowser = browser
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed(let error) = state {
                DispatchQueue.main.async {
                    self.connectionStatus = "Unable to search for companion device: \(error.localizedDescription)"
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            let endpoints = Dictionary(uniqueKeysWithValues: results.map { result in
                (result.endpoint.debugDescription, result.endpoint)
            })
            let summaries = results.map { result -> PeerSummary in
                let name: String
                if case .service(let serviceName, _, _, _) = result.endpoint {
                    name = serviceName.isEmpty ? "iPhone" : serviceName
                } else {
                    name = "iPhone"
                }
                return PeerSummary(id: result.endpoint.debugDescription, name: name)
            }
            .sorted { $0.name < $1.name }

            DispatchQueue.main.async {
                self.directEndpointLookup = endpoints
                self.discoveredPeers = summaries
                if self.connectedPeerNames.isEmpty {
                    self.connectionStatus = summaries.isEmpty
                        ? "Searching for companion device"
                        : "Found \(summaries[0].name). Connecting..."
                }
                self.autoConnectIfNeeded()
            }
        }
        browser.start(queue: relayQueue)
    }

    private func connectDirectly(to endpoint: NWEndpoint, peerName: String) {
        if directConnectionSnapshot() != nil { return }
        connectionStatus = "Connecting to \(peerName)"
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let connection = NWConnection(to: endpoint, using: parameters)
        replaceDirectConnection(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                DispatchQueue.main.async {
                    self.connectedPeerNames = [peerName]
                    self.connectionStatus = "Receiving companion feed from \(peerName)"
                    self.relayedWatchCaptureStore.notePeerConnection(isConnected: true)
                }
                self.receiveDirectPacketLength(on: connection, peerName: peerName)
            case .waiting(let error):
                DispatchQueue.main.async {
                    self.connectionStatus = "Companion connection paused: \(error.localizedDescription)"
                }
            case .failed, .cancelled:
                if self.directConnectionSnapshot() === connection {
                    self.replaceDirectConnection(nil)
                    DispatchQueue.main.async {
                        self.connectedPeerNames = []
                        self.relayedWatchCaptureStore.notePeerConnection(isConnected: false)
                        self.connectionStatus = "Searching for companion device"
                        self.attemptedAutoConnectPeerIDs.removeAll()
                        self.autoConnectIfNeeded()
                    }
                }
            default:
                break
            }
        }
        connection.start(queue: relayQueue)
    }

    private func receiveDirectPacketLength(on connection: NWConnection, peerName: String) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            guard error == nil, !isComplete, let data, data.count == 4 else {
                connection.cancel()
                return
            }
            let length = data.withUnsafeBytes { rawBuffer in
                Int(UInt32(bigEndian: rawBuffer.loadUnaligned(as: UInt32.self)))
            }
            guard length > 0, length <= 16_000_000 else {
                connection.cancel()
                return
            }
            self.receiveDirectPacketBody(length: length, on: connection, peerName: peerName)
        }
    }

    private func receiveDirectPacketBody(length: Int, on connection: NWConnection, peerName: String) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            guard error == nil, !isComplete, let data, data.count == length else {
                connection.cancel()
                return
            }
            self.session(
                self.session,
                didReceive: data,
                fromPeer: MCPeerID(displayName: peerName)
            )
            self.receiveDirectPacketLength(on: connection, peerName: peerName)
        }
    }

    private func sendDirectPacket(_ data: Data) -> Bool {
        guard let connection = directConnectionSnapshot(), data.count <= Int(UInt32.max) else {
            return false
        }
        var length = UInt32(data.count).bigEndian
        var framed = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        framed.append(data)
        connection.send(content: framed, completion: .contentProcessed { [weak self] error in
            guard error != nil else { return }
            DispatchQueue.main.async {
                self?.connectionStatus = "Companion relay connection was interrupted."
            }
        })
        return true
    }

    private func startWatchHealthTimer() {
        guard watchHealthTimer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.relayedWatchCaptureStore.evaluateHeartbeatTimeout()
            }
        }
        timer.resume()
        watchHealthTimer = timer
    }
}

extension CompanionCameraReceiver: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        DispatchQueue.main.async {
            let summary = PeerSummary(id: peerID.displayName, name: peerID.displayName)
            self.peerLookup[summary.id] = peerID
            if !self.discoveredPeers.contains(summary) {
                self.discoveredPeers.append(summary)
                self.discoveredPeers.sort { $0.name < $1.name }
            }
            self.connectionStatus = self.connectedPeerNames.isEmpty
                ? "Found \(peerID.displayName). Connect when ready."
                : "Receiving companion feed from \(self.connectedPeerNames.joined(separator: ", "))"
            self.autoConnectIfNeeded()
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async {
            self.discoveredPeers.removeAll { $0.id == peerID.displayName }
            self.peerLookup[peerID.displayName] = nil
            self.attemptedAutoConnectPeerIDs.remove(peerID.displayName)
            if self.connectedPeerNames.isEmpty {
                self.connectionStatus = self.discoveredPeers.isEmpty
                    ? "Searching for companion device"
                    : "Choose a device to connect"
            }
        }
    }
}

extension CompanionCameraReceiver: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            self.connectedPeerNames = session.connectedPeers.map(\.displayName).sorted()
            self.relayedWatchCaptureStore.notePeerConnection(isConnected: !self.connectedPeerNames.isEmpty)
            switch state {
            case .connected:
                self.connectionStatus = "Receiving companion feed from \(peerID.displayName)"
            case .connecting:
                self.connectionStatus = "Connecting to \(peerID.displayName)"
            case .notConnected:
                self.latestRenderedFrameTimestamp = 0
                self.lastPublishedWallClockTime = 0
                self.frameStore.image = nil
                self.frameStore.cameraPosition = "Unknown"
                self.attemptedAutoConnectPeerIDs.remove(peerID.displayName)
                self.connectionStatus = self.connectedPeerNames.isEmpty
                    ? "Searching for companion device"
                    : "Receiving companion feed from \(self.connectedPeerNames.joined(separator: ", "))"
                self.autoConnectIfNeeded()
            @unknown default:
                self.connectionStatus = "Connection state changed"
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        if let lifecyclePacket = try? decoder.decode(WatchRelayLifecyclePacket.self, from: data),
           lifecyclePacket.kind == WatchRelayLifecyclePacket.packetKind {
            Task { @MainActor in
                self.relayedWatchCaptureStore.noteRelayLifecycle(lifecyclePacket)
            }
            return
        }

        if let motionBatch = try? decoder.decode(WatchMotionRelayBatch.self, from: data),
           motionBatch.kind == WatchMotionRelayBatch.packetKind {
            Task { @MainActor in
                self.relayedWatchCaptureStore.receiveLiveMotionBatch(
                    motionBatch,
                    sourcePeerName: peerID.displayName
                )
            }
            return
        }

        if let relayPacket = try? decoder.decode(WatchCaptureRelayPacket.self, from: data),
           relayPacket.isWatchCaptureRelay {
            Task { @MainActor in
                self.relayedWatchCaptureStore.importRelayedSession(
                    relayPacket.captureSession,
                    suggestedFileName: relayPacket.fileName,
                    sourcePeerName: peerID.displayName
                )
                #if DEBUG
                print("[WATCH-DEBUG] Mac received/imported watch file sessionID=\(relayPacket.captureSession.sessionID) takeID=\(relayPacket.captureSession.takeID ?? "nil") id=\(relayPacket.captureSession.id)")
                #endif
                self.sendCaptureAck(for: relayPacket.captureSession.id, to: peerID)
            }
            return
        }

        if let availabilityPacket = try? decoder.decode(WatchAvailabilityPacket.self, from: data),
           availabilityPacket.isWatchAvailability {
            #if DEBUG
            print("[WATCH-DEBUG] Mac received watch availability paired=\(availabilityPacket.isPaired) installed=\(availabilityPacket.isInstalled) reachable=\(availabilityPacket.isReachable)")
            #endif
            Task { @MainActor in
                self.relayedWatchCaptureStore.updateWatchAvailability(
                    isPaired: availabilityPacket.isPaired,
                    isInstalled: availabilityPacket.isInstalled,
                    isReachable: availabilityPacket.isReachable
                )
            }
            return
        }

        if let statusPacket = try? decoder.decode(WatchControlStatusPacket.self, from: data) {
            Task { @MainActor in
                if let resolvedReply = self.watchCommandCoordinator.resolve(statusPacket.reply) {
                    self.relayedWatchCaptureStore.noteRemoteControlStatus(resolvedReply)
                }
            }
            return
        }

        let now = Date().timeIntervalSince1970
        guard let packet = try? decoder.decode(FramePacket.self, from: data),
              packet.timestamp > latestRenderedFrameTimestamp,
              now - packet.timestamp <= maximumAcceptedFrameAge,
              now - lastPublishedWallClockTime >= minimumFramePublishInterval,
              let image = NSImage(data: packet.jpegData) else {
            return
        }

        latestRenderedFrameTimestamp = packet.timestamp
        lastPublishedWallClockTime = now

        DispatchQueue.main.async {
            self.frameStore.image = image
            self.frameStore.cameraPosition = packet.position.capitalized
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}

    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}

    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}

    private func autoConnectIfNeeded() {
        guard connectedPeerNames.isEmpty else { return }
        guard discoveredPeers.count == 1, let onlyPeer = discoveredPeers.first else { return }
        guard !attemptedAutoConnectPeerIDs.contains(onlyPeer.id) else { return }

        attemptedAutoConnectPeerIDs.insert(onlyPeer.id)
        connectionStatus = "Auto-connecting to \(onlyPeer.name)"
        connect(to: onlyPeer)
    }

    private func sendCaptureAck(for captureID: UUID, to peerID: MCPeerID) {
        let packet = WatchCaptureRelayAckPacket(captureID: captureID)
        guard let encoded = try? PropertyListEncoder().encode(packet) else { return }

        if sendDirectPacket(encoded) {
            return
        }

        guard session.connectedPeers.contains(peerID) else { return }

        do {
            try session.send(encoded, toPeers: [peerID], with: .reliable)
        } catch {
            #if DEBUG
            print("[WATCH-DEBUG] transfer failed/retrying — Mac ack send failed: \(error.localizedDescription) id=\(captureID)")
            #endif
        }
    }

    private func sendWatchControlCommand(_ payload: WatchCaptureCommandPayload) -> Bool {
        let packet = WatchControlCommandPacket(payload: payload)

        guard let encoded = try? PropertyListEncoder().encode(packet) else {
            return false
        }

        if sendDirectPacket(encoded) {
            return true
        }

        guard !session.connectedPeers.isEmpty else { return false }
        do {
            try session.send(encoded, toPeers: session.connectedPeers, with: .reliable)
            return true
        } catch {
            return false
        }
    }
}
