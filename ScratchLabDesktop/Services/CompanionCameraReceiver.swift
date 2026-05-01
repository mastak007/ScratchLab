import Foundation
import MultipeerConnectivity
import AppKit

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
                return "Starting watch motion capture through iPhone."
            case .acknowledged:
                return "Watch motion capture acknowledged."
            case .stopping:
                return "Stopping watch motion capture through iPhone."
            case .timedOut(let message), .unavailable(let message), .failed(let message):
                return message
            }
        }
    }

    @Published private(set) var importedSessions: [RelayedWatchMotionCapture] = []
    @Published private(set) var lastImportStatus = "Waiting for a watch capture relay from iPhone."
    @Published private(set) var remoteControlState: RemoteControlState = .idle

    private let fileManager = FileManager.default

    var captureDirectoryURL: URL {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
        return baseURL
            .appendingPathComponent("ScratchLab", isDirectory: true)
            .appendingPathComponent("RelayedWatchCaptures", isDirectory: true)
    }

    init() {
        createCaptureDirectoryIfNeeded()
        reconcileStoredSessions()
        loadStoredSessions()
    }

    @MainActor
    func noteRequestedStart() {
        remoteControlState = .starting
    }

    @MainActor
    func noteRequestedStop() {
        remoteControlState = .stopping
    }

    @MainActor
    func noteRemoteControlStatus(_ reply: WatchCaptureControlReply) {
        switch reply.syncState {
        case .notRequested:
            remoteControlState = .idle
        case .requested:
            remoteControlState = .starting
        case .acknowledged:
            remoteControlState = .acknowledged
        case .timedOut:
            remoteControlState = .timedOut(reply.detail ?? "Watch motion start timed out.")
        case .unavailable:
            remoteControlState = .unavailable(reply.detail ?? "Watch motion capture is unavailable.")
        case .failed:
            remoteControlState = .failed(reply.detail ?? "Watch motion capture failed to start.")
        }
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
            lastImportStatus = "Imported watch motion relay from \(sourcePeerName ?? "iPhone") at \(formatDate(storedCapture.session.deviceRecordedAtStart))."
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
        let fileName = sanitizedFileName(suggestedFileName ?? "scratch-motion-\(captureSession.id.uuidString).json")
        let destinationURL = captureDirectoryURL.appendingPathComponent(fileName)
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
    @Published var connectionStatus = "Searching for companion device"

    let frameStore = FrameStore()
    let relayedWatchCaptureStore: RelayedWatchCaptureStore

    private let serviceType = "scrcamfeed"
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

    init(relayedWatchCaptureStore: RelayedWatchCaptureStore, autoStartBrowsing: Bool = true) {
        self.relayedWatchCaptureStore = relayedWatchCaptureStore
        super.init()
        session.delegate = self
        browser.delegate = self
        if autoStartBrowsing {
            browser.startBrowsingForPeers()
        }
    }

    @MainActor
    func requestWatchCaptureStart(
        sessionID: String,
        takeID: String,
        timeoutSeconds: TimeInterval = 3
    ) async -> WatchCaptureControlReply {
        relayedWatchCaptureStore.noteRequestedStart()
        let payload = WatchCaptureCommandPayload(
            command: .start,
            sessionID: sessionID,
            takeID: takeID
        )

        guard !session.connectedPeers.isEmpty else {
            let reply = WatchCaptureControlReply(
                commandID: payload.commandID,
                sessionID: sessionID,
                takeID: takeID,
                syncState: .unavailable,
                detail: "Connect the iPhone companion before trying to control watch capture."
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
                detail: "ScratchLab couldn't send the watch control command to iPhone."
            )
            relayedWatchCaptureStore.noteRemoteControlStatus(reply)
            return reply
        }

        return await withTaskGroup(of: WatchCaptureControlReply.self) { group in
            group.addTask {
                await self.watchCommandCoordinator.begin(command: payload)
            }
            group.addTask {
                let nanoseconds = UInt64(timeoutSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                return self.watchCommandCoordinator.timeout(commandID: payload.commandID)
                    ?? WatchCaptureControlReply(
                        commandID: payload.commandID,
                        sessionID: sessionID,
                        takeID: takeID,
                        syncState: .timedOut,
                        detail: "Watch start did not acknowledge within \(Int(timeoutSeconds)) seconds."
                    )
            }

            guard let reply = await group.next() else {
                return WatchCaptureControlReply(
                    commandID: payload.commandID,
                    sessionID: sessionID,
                    takeID: takeID,
                    syncState: .failed,
                    detail: "Watch start failed before a reply was received."
                )
            }
            group.cancelAll()
            await MainActor.run {
                self.relayedWatchCaptureStore.noteRemoteControlStatus(reply)
            }
            return reply
        }
    }

    @MainActor
    func requestWatchCaptureStop(sessionID: String, takeID: String?) {
        relayedWatchCaptureStore.noteRequestedStop()
        let payload = WatchCaptureCommandPayload(
            command: .stop,
            sessionID: sessionID,
            takeID: takeID
        )
        if !sendWatchControlCommand(payload) {
            relayedWatchCaptureStore.noteRemoteControlStatus(
                WatchCaptureControlReply(
                    commandID: payload.commandID,
                    sessionID: sessionID,
                    takeID: takeID,
                    syncState: .failed,
                    detail: "ScratchLab couldn't send the watch stop command to iPhone."
                )
            )
        }
    }

    func connect(to peer: PeerSummary) {
        guard let mcPeer = peerLookup[peer.id] else { return }
        connectionStatus = "Inviting \(peer.name)"
        browser.invitePeer(mcPeer, to: session, withContext: nil, timeout: 10)
    }

    func disconnect() {
        session.disconnect()
        connectedPeerNames = []
        latestRenderedFrameTimestamp = 0
        lastPublishedWallClockTime = 0
        frameStore.image = nil
        frameStore.cameraPosition = "Unknown"
        connectionStatus = "Searching for companion device"
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
        if let relayPacket = try? decoder.decode(WatchCaptureRelayPacket.self, from: data),
           relayPacket.isWatchCaptureRelay {
            Task { @MainActor in
                self.relayedWatchCaptureStore.importRelayedSession(
                    relayPacket.captureSession,
                    suggestedFileName: relayPacket.fileName,
                    sourcePeerName: peerID.displayName
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

    private func sendWatchControlCommand(_ payload: WatchCaptureCommandPayload) -> Bool {
        guard !session.connectedPeers.isEmpty else {
            return false
        }

        let packet = WatchControlCommandPacket(payload: payload)

        guard let encoded = try? PropertyListEncoder().encode(packet) else {
            return false
        }

        do {
            try session.send(encoded, toPeers: session.connectedPeers, with: .reliable)
            return true
        } catch {
            return false
        }
    }
}
