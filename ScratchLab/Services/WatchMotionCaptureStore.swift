import Combine
import Foundation
import WatchConnectivity

struct ImportedWatchMotionCapture: Identifiable {
    let fileURL: URL
    let session: WatchMotionCaptureSession

    var id: UUID { session.id }
}

final class WatchMotionCaptureStore: NSObject, ObservableObject {
    enum RemoteCaptureState: Equatable {
        case idle
        case requested
        case acknowledged
        case recording
        case timedOut(String)
        case unavailable(String)
        case failed(String)
    }

    @Published private(set) var importedSessions: [ImportedWatchMotionCapture] = []
    @Published private(set) var connectionSummary = "Open Watch Capture on your watch, record a take, and it will import here."
    @Published private(set) var lastImportStatus = "Waiting for a watch capture."
    @Published private(set) var isWatchPaired = false
    @Published private(set) var isWatchAppInstalled = false
    @Published private(set) var isWatchReachable = false
    @Published private(set) var remoteCaptureState: RemoteCaptureState = .idle
    @Published private(set) var macAcknowledgedCaptureIDs: Set<UUID> = []
    @Published private(set) var isMacConnected = false
    @Published private(set) var activeRelayContext: WatchRelayTakeContext?
    private var pendingRelayContext: WatchRelayTakeContext?
    /// The Watch sends its final motion batch asynchronously, so its stop reply can arrive
    /// first. Keep only that exact take authorized for a short drain window rather than
    /// dropping the final batch after `activeRelayContext` is cleared.
    private var recentlyEndedRelayContext: WatchRelayTakeContext?
    private var finalLiveRelayContext: WatchRelayTakeContext?
    @Published private(set) var relayInterruptionReason: String?
    @Published private(set) var hadRequiredRelayConnections = false
    @Published private(set) var latestLiveMotionBatchAt: Date?

    var onImportedCapture: ((ImportedWatchMotionCapture) -> Void)?
    /// Handles Start/Stop Take requests initiated on Apple Watch. The iPhone
    /// capture view installs this only while its real guided-capture state
    /// machine is on screen.
    var onPhoneCaptureCommand: ((PhoneCaptureCommandPayload, @escaping (WatchCaptureControlReply) -> Void) -> Void)?
    /// (isPaired, isInstalled, isReachable) — fired whenever the local WCSession's view of the
    /// watch changes, so the Mac bridge can relay a fresh snapshot over MultipeerConnectivity.
    var onAvailabilityChange: ((Bool, Bool, Bool) -> Void)?
    var onLiveMotionBatch: ((WatchMotionRelayBatch) -> Void)?
    var onRelayLifecycle: ((WatchRelayLifecycleEvent, WatchRelayTakeContext?, String?) -> Void)?

    var relayState: WatchRelayFlowState {
        WatchRelayStateResolver.resolve(
            isWatchReachable: isWatchReachable,
            isMacConnected: isMacConnected,
            activeContext: activeRelayContext,
            hadRequiredConnections: hadRequiredRelayConnections,
            interruptionReason: relayInterruptionReason
        )
    }

    private let fileManager = FileManager.default
    private let processingQueue = DispatchQueue(label: "com.scratchlab.watch-motion-import")
    private var hasActivatedWatchSession = false
    private let macAcknowledgedCaptureIDsDefaultsKey = "com.scratchlab.watch.macAcknowledgedCaptureIDs"

    private var watchSession: WCSession? {
        guard WCSession.isSupported() else { return nil }
        return WCSession.default
    }

    private func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[WatchImport] \(message())")
        #endif
    }

    override init() {
        super.init()
        createCaptureDirectoryIfNeeded()
        reconcileStoredCaptures()
        loadStoredSessions()
        if let stored = UserDefaults.standard.stringArray(forKey: macAcknowledgedCaptureIDsDefaultsKey) {
            macAcknowledgedCaptureIDs = Set(stored.compactMap(UUID.init(uuidString:)))
        }
        activateIfNeeded()
    }

    /// Imported captures the Mac has not yet acknowledged importing. Used to retry the
    /// iPhone -> Mac relay for every queued take on reconnect, not just the latest one.
    func unsentCaptures() -> [ImportedWatchMotionCapture] {
        importedSessions.filter { !macAcknowledgedCaptureIDs.contains($0.id) }
    }

    func markAcknowledgedByMac(_ id: UUID) {
        guard !macAcknowledgedCaptureIDs.contains(id) else { return }
        macAcknowledgedCaptureIDs.insert(id)
        UserDefaults.standard.set(macAcknowledgedCaptureIDs.map(\.uuidString), forKey: macAcknowledgedCaptureIDsDefaultsKey)
        #if DEBUG
        print("[WATCH-DEBUG] Mac acknowledged import id=\(id)")
        #endif
    }

    func jsonExportURL(for capture: ImportedWatchMotionCapture) -> URL {
        capture.fileURL
    }

    func csvExportURL(for capture: ImportedWatchMotionCapture) -> URL? {
        let fileName = capture.fileURL.deletingPathExtension().lastPathComponent + ".csv"
        let exportURL = exportDirectoryURL.appendingPathComponent(fileName)

        if !fileManager.fileExists(atPath: exportURL.path) {
            let csv = makeCSV(for: capture.session)
            do {
                try csv.write(to: exportURL, atomically: true, encoding: .utf8)
            } catch {
                return nil
            }
        }

        return exportURL
    }

    func activateIfNeeded() {
        guard !hasActivatedWatchSession else { return }
        guard let watchSession else {
            log("activation skipped — WCSession unsupported on this device")
            connectionSummary = "Watch transfer is unavailable on this device."
            return
        }

        log("activating WCSession")
        hasActivatedWatchSession = true
        watchSession.delegate = self
        watchSession.activate()
        refreshConnectionStatus(using: watchSession)
    }

    func checkForPendingImports() {
        processingQueue.async {
            let pendingFiles = self.pendingTransferFileURLs()
            guard !pendingFiles.isEmpty else { return }

            var importedCapture: ImportedWatchMotionCapture?

            for fileURL in pendingFiles {
                do {
                    let latestImportedCapture = try self.importCaptureFile(
                        from: fileURL,
                        metadataName: nil,
                        removeSourceAfterImport: true
                    )
                    self.log("decode/import succeeded (pending): id=\(latestImportedCapture.id) sessionID=\(latestImportedCapture.session.sessionID) takeID=\(latestImportedCapture.session.takeID ?? "nil")")
                    importedCapture = importedCapture.map {
                        $0.session.deviceRecordedAtStart >= latestImportedCapture.session.deviceRecordedAtStart ? $0 : latestImportedCapture
                    } ?? latestImportedCapture
                } catch {
                    self.log("decode/import FAILED (pending) for \(fileURL.lastPathComponent): \(error.localizedDescription)")
                    continue
                }
            }

            guard let importedCapture else { return }

            DispatchQueue.main.async {
                self.reconcileStoredCaptures()
                self.loadStoredSessions()
                self.lastImportStatus = "Imported pending watch capture from \(self.formatDate(importedCapture.session.deviceRecordedAtStart))."
                self.onImportedCapture?(importedCapture)
            }
        }
    }

    func linkedCapture(sessionID: String, takeID: String) -> ImportedWatchMotionCapture? {
        importedSessions.first(where: {
            WatchAssociationResolver.isLinkedCaptureValid(
                sessionID: sessionID,
                takeID: takeID,
                captureSession: $0.session
            )
        })
    }

    func hasLinkedCapture(sessionID: String, takeID: String) -> Bool {
        linkedCapture(sessionID: sessionID, takeID: takeID) != nil
    }

    func reconcileStoredCapturesNow() {
        reconcileStoredCaptures()
        loadStoredSessions()
    }

    func requestRemoteCaptureStart(
        sessionID: String,
        takeID: String,
        takeNumber: Int? = nil,
        watchWrist: String? = nil,
        commandID: String = UUID().uuidString.lowercased(),
        completion: @escaping (WatchCaptureControlReply) -> Void
    ) {
        let payload = WatchCaptureCommandPayload(
            commandID: commandID,
            command: .start,
            sessionID: sessionID,
            takeID: takeID,
            takeNumber: takeNumber,
            watchWrist: watchWrist
        )
        pendingRelayContext = WatchRelayTakeContext(payload: payload)
        requestRemoteCaptureCommand(
            payload,
            completion: completion
        )
    }

    func requestRemoteCaptureStop(
        sessionID: String,
        takeID: String?,
        commandID: String = UUID().uuidString.lowercased(),
        completion: @escaping (WatchCaptureControlReply) -> Void
    ) {
        requestRemoteCaptureCommand(
            WatchCaptureCommandPayload(
                commandID: commandID,
                command: .stop,
                sessionID: sessionID,
                takeID: takeID
            ),
            completion: completion
        )
    }

    func updateMacConnection(isConnected: Bool) {
        let wasConnected = isMacConnected
        isMacConnected = isConnected
        reconcileRelayHealth(
            lostConnectionDetail: wasConnected && !isConnected ? "Mac connection was lost." : nil
        )
        guard isConnected else { return }
        onRelayLifecycle?(wasConnected ? .reconnect : .hello, activeRelayContext, nil)
        publishReadyLifecycleIfNeeded()
    }

    func retryRelayConnection() {
        activateIfNeeded()
        relayInterruptionReason = nil
        reconcileRelayHealth(lostConnectionDetail: nil)
        onAvailabilityChange?(isWatchPaired, isWatchAppInstalled, isWatchReachable)
        if isMacConnected {
            onRelayLifecycle?(.reconnect, activeRelayContext, nil)
            publishReadyLifecycleIfNeeded()
        }
    }

    func sendRelayHeartbeat() {
        guard isMacConnected else { return }
        onRelayLifecycle?(.heartbeat, activeRelayContext, nil)
    }

    private func loadStoredSessions() {
        let captures = (try? fileManager.contentsOfDirectory(
            at: captureDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let decodedCaptures = captures
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap(decodeCapture(at:))
            .sorted { $0.session.deviceRecordedAtStart > $1.session.deviceRecordedAtStart }

        importedSessions = decodedCaptures
    }

    private func reconcileStoredCaptures() {
        let companionDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CompanionCaptures", isDirectory: true)
        let report = StagedCaptureRecoveryManager().reconcileWatchDirectory(
            at: captureDirectoryURL,
            storageKind: .importedWatch,
            sidecarDirectories: companionDirectory.map { [$0] } ?? [],
            sidecarStorageKind: .companion
        )
        if let summaryText = report.summaryText {
            lastImportStatus = summaryText
        }
    }

    private func decodeCapture(at url: URL) -> ImportedWatchMotionCapture? {
        guard let data = try? Data(contentsOf: url),
              let session = try? WatchMotionCaptureCodec.decoder.decode(WatchMotionCaptureSession.self, from: data) else {
            return nil
        }

        return ImportedWatchMotionCapture(fileURL: url, session: session)
    }

    private func createCaptureDirectoryIfNeeded() {
        do {
            try fileManager.createDirectory(at: captureDirectoryURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: exportDirectoryURL, withIntermediateDirectories: true)
        } catch {
            lastImportStatus = "Couldn't prepare local storage for watch capture sessions."
        }
    }

    private func refreshConnectionStatus(using session: WCSession) {
        isWatchPaired = session.isPaired
        isWatchAppInstalled = session.isWatchAppInstalled
        isWatchReachable = session.isReachable

        #if DEBUG
        print("[WATCH-DEBUG] watch session state paired=\(isWatchPaired) installed=\(isWatchAppInstalled) reachable=\(isWatchReachable)")
        #endif
        onAvailabilityChange?(isWatchPaired, isWatchAppInstalled, isWatchReachable)
        reconcileRelayHealth(
            lostConnectionDetail: !isWatchReachable && activeRelayContext != nil
                ? "Apple Watch connection was lost during the active take."
                : nil
        )
        publishReadyLifecycleIfNeeded()

        if !session.isPaired {
            connectionSummary = "Pair your watch with this device to capture wrist motion."
        } else if !session.isWatchAppInstalled {
            connectionSummary = "Your watch is paired. Install ScratchLab on the watch, then record a take and stop to send it here."
        } else if session.isReachable {
            connectionSummary = "Watch is connected. Stop a take on the watch to send the motion session here."
        } else {
            connectionSummary = "ScratchLab is installed on your watch. You can still send a session after recording, even when the watch is not currently reachable."
        }
    }

    private func requestRemoteCaptureCommand(
        _ payload: WatchCaptureCommandPayload,
        completion: @escaping (WatchCaptureControlReply) -> Void
    ) {
        requestRemoteCaptureCommand(payload, activationRetriesRemaining: 3, completion: completion)
    }

    private func requestRemoteCaptureCommand(
        _ payload: WatchCaptureCommandPayload,
        activationRetriesRemaining: Int,
        completion: @escaping (WatchCaptureControlReply) -> Void
    ) {
        activateIfNeeded()

        guard let watchSession else {
            let detail = "Watch control is unavailable on this device."
            remoteCaptureState = .unavailable(detail)
            completion(
                WatchCaptureControlReply(
                    commandID: payload.commandID,
                    sessionID: payload.sessionID,
                    takeID: payload.takeID,
                    syncState: .unavailable,
                    detail: detail,
                    stopOutcome: payload.command == .stop ? .unreachable : nil
                )
            )
            return
        }

        guard watchSession.activationState == .activated else {
            watchSession.activate()

            guard activationRetriesRemaining > 0 else {
                let detail = "Watch connectivity is still activating."
                remoteCaptureState = .unavailable(detail)
                completion(
                    WatchCaptureControlReply(
                        commandID: payload.commandID,
                        sessionID: payload.sessionID,
                        takeID: payload.takeID,
                        syncState: .unavailable,
                        detail: detail,
                        stopOutcome: payload.command == .stop ? .unreachable : nil
                    )
                )
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.requestRemoteCaptureCommand(
                    payload,
                    activationRetriesRemaining: activationRetriesRemaining - 1,
                    completion: completion
                )
            }
            return
        }

        guard watchSession.isWatchAppInstalled else {
            let detail = "Install ScratchLab on the watch before remote capture."
            remoteCaptureState = .unavailable(detail)
            completion(
                WatchCaptureControlReply(
                    commandID: payload.commandID,
                    sessionID: payload.sessionID,
                    takeID: payload.takeID,
                    syncState: .unavailable,
                    detail: detail,
                    stopOutcome: payload.command == .stop ? .unreachable : nil
                )
            )
            return
        }

        guard watchSession.isReachable else {
            let detail = "Open ScratchLab on the watch so this device can control motion capture."
            remoteCaptureState = .unavailable(detail)
            completion(
                WatchCaptureControlReply(
                    commandID: payload.commandID,
                    sessionID: payload.sessionID,
                    takeID: payload.takeID,
                    syncState: .unavailable,
                    detail: detail,
                    stopOutcome: payload.command == .stop ? .unreachable : nil
                )
            )
            return
        }

        remoteCaptureState = .requested
        let formatter = ISO8601DateFormatter()
        var message: [String: Any] = [
            "kind": WatchCaptureCommandPayload.packetKind,
            "commandID": payload.commandID,
            "command": payload.command.rawValue,
            "sessionID": payload.sessionID,
            "takeID": payload.takeID ?? "",
            "watchWrist": payload.watchWrist ?? "",
            "requestedAt": formatter.string(from: payload.requestedAt)
        ]
        if let takeNumber = payload.takeNumber {
            message["takeNumber"] = takeNumber
        }
        watchSession.sendMessage(message, replyHandler: { reply in
            let syncState = CaptureWatchSyncState(rawValue: reply["syncState"] as? String ?? "")
                ?? Self.legacySyncState(for: reply["status"] as? String)
                ?? .failed
            let detail = reply["detail"] as? String
            let acknowledgedAt = formatter.date(from: reply["acknowledgedAt"] as? String ?? "")
            let takeID = (reply["takeID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            // Additive key from a Watch that knows about stop outcomes. A
            // Watch that does not send it leaves this `nil`, and the Mac
            // derives the outcome from `syncState` instead.
            let reportedStopOutcome = (reply["stopOutcome"] as? String)
                .flatMap(CaptureWatchStopOutcome.init(rawValue:))
            let controlReply = WatchCaptureControlReply(
                commandID: reply["commandID"] as? String ?? payload.commandID,
                sessionID: reply["sessionID"] as? String ?? payload.sessionID,
                takeID: (takeID?.isEmpty == true) ? nil : takeID,
                syncState: syncState,
                detail: detail,
                acknowledgedAt: acknowledgedAt,
                stopOutcome: payload.command == .stop ? reportedStopOutcome : nil
            )

            DispatchQueue.main.async {
                self.remoteCaptureState = Self.remoteState(for: controlReply)
                self.applyRelayControlResult(payload: payload, reply: controlReply)
                completion(controlReply)
            }
        }, errorHandler: { error in
            let detail = error.localizedDescription
            DispatchQueue.main.async {
                self.remoteCaptureState = .failed(detail)
                let reply = WatchCaptureControlReply(
                        commandID: payload.commandID,
                        sessionID: payload.sessionID,
                        takeID: payload.takeID,
                        syncState: .failed,
                        detail: detail,
                        stopOutcome: payload.command == .stop ? .failed : nil
                    )
                self.applyRelayControlResult(payload: payload, reply: reply)
                completion(reply)
            }
        })
    }

    private func applyRelayControlResult(
        payload: WatchCaptureCommandPayload,
        reply: WatchCaptureControlReply
    ) {
        switch payload.command {
        case .start:
            if reply.syncState == .acknowledged, let context = WatchRelayTakeContext(payload: payload) {
                pendingRelayContext = nil
                recentlyEndedRelayContext = nil
                finalLiveRelayContext = nil
                activeRelayContext = context
                relayInterruptionReason = nil
                hadRequiredRelayConnections = true
                onRelayLifecycle?(.takeBegin, context, nil)
            } else if reply.syncState != .requested {
                pendingRelayContext = nil
                let detail = reply.detail ?? "Watch motion capture did not acknowledge."
                relayInterruptionReason = detail
                onRelayLifecycle?(.error, WatchRelayTakeContext(payload: payload), detail)
            }
        case .stop:
            if reply.syncState == .notRequested {
                pendingRelayContext = nil
                let completedContext = activeRelayContext
                if let completedContext, finalLiveRelayContext != completedContext {
                    recentlyEndedRelayContext = completedContext
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                        guard self?.recentlyEndedRelayContext == completedContext else { return }
                        self?.recentlyEndedRelayContext = nil
                    }
                } else {
                    recentlyEndedRelayContext = nil
                }
                onRelayLifecycle?(.takeEnd, completedContext, nil)
                activeRelayContext = nil
                relayInterruptionReason = nil
                publishReadyLifecycleIfNeeded()
            } else if reply.syncState != .requested {
                let detail = reply.detail ?? "Watch motion capture did not stop cleanly."
                relayInterruptionReason = detail
                onRelayLifecycle?(.error, activeRelayContext, detail)
            }
        }
    }

    private func reconcileRelayHealth(lostConnectionDetail: String?) {
        let hasRequiredConnections = isMacConnected && isWatchReachable
        if hasRequiredConnections {
            hadRequiredRelayConnections = true
            relayInterruptionReason = nil
        } else if let lostConnectionDetail, hadRequiredRelayConnections || activeRelayContext != nil {
            relayInterruptionReason = lostConnectionDetail
            onRelayLifecycle?(.error, activeRelayContext, lostConnectionDetail)
        }
    }

    private func publishReadyLifecycleIfNeeded() {
        guard isMacConnected, isWatchReachable, activeRelayContext == nil else { return }
        onRelayLifecycle?(.relayReady, nil, nil)
    }

    private static func remoteState(for reply: WatchCaptureControlReply) -> RemoteCaptureState {
        switch reply.syncState {
        case .acknowledged:
            return .acknowledged
        case .requested:
            return .requested
        case .notRequested:
            return .idle
        case .timedOut:
            return .timedOut(reply.detail ?? "Watch motion capture timed out.")
        case .unavailable:
            return .unavailable(reply.detail ?? "Watch motion capture is unavailable.")
        case .failed:
            return .failed(reply.detail ?? "Watch motion capture failed.")
        }
    }

    private static func legacySyncState(for status: String?) -> CaptureWatchSyncState? {
        switch status {
        case "recording":
            return .acknowledged
        case "idle", "stopped":
            return .notRequested
        case "unavailable":
            return .unavailable
        case "failed":
            return .failed
        default:
            return nil
        }
    }

    private func decodePhoneCaptureCommand(from message: [String: Any]) -> PhoneCaptureCommandPayload? {
        guard message["kind"] as? String == PhoneCaptureCommandPayload.packetKind,
              let command = PhoneCaptureCommandPayload.Command(
                rawValue: message["command"] as? String ?? ""
              ) else {
            return nil
        }
        let requestedAt = ISO8601DateFormatter().date(
            from: message["requestedAt"] as? String ?? ""
        ) ?? Date()
        return PhoneCaptureCommandPayload(
            commandID: message["commandID"] as? String ?? UUID().uuidString.lowercased(),
            command: command,
            requestedAt: requestedAt
        )
    }

    private func phoneCaptureReplyDictionary(_ reply: WatchCaptureControlReply) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        return [
            "kind": WatchCaptureControlReply.packetKind,
            "commandID": reply.commandID,
            "sessionID": reply.sessionID,
            "takeID": reply.takeID ?? "",
            "syncState": reply.syncState.rawValue,
            "detail": reply.detail ?? "",
            "acknowledgedAt": formatter.string(from: reply.acknowledgedAt ?? Date())
        ]
    }

    private func importTransferredFile(_ sessionFile: WCSessionFile) {
        processingQueue.async {
            do {
                let importedCapture = try self.importCaptureFile(
                    from: sessionFile.fileURL,
                    metadataName: sessionFile.metadata?["fileName"] as? String,
                    removeSourceAfterImport: false
                )

                self.log("decode/import succeeded: id=\(importedCapture.id) sessionID=\(importedCapture.session.sessionID) takeID=\(importedCapture.session.takeID ?? "nil")")

                DispatchQueue.main.async {
                    self.reconcileStoredCaptures()
                    self.importedSessions.removeAll { $0.id == importedCapture.id }
                    self.loadStoredSessions()
                    self.lastImportStatus = "Imported \(self.formatDate(importedCapture.session.deviceRecordedAtStart)) from your watch."
                    self.onImportedCapture?(importedCapture)
                }
            } catch {
                self.log("decode/import FAILED for \(sessionFile.fileURL.lastPathComponent): \(error.localizedDescription)")

                DispatchQueue.main.async {
                    self.lastImportStatus = "Watch transfer failed to import. Open the watch app and try stopping another capture."
                }
            }
        }
    }

    private func importCaptureFile(from sourceURL: URL, metadataName: String?, removeSourceAfterImport: Bool) throws -> ImportedWatchMotionCapture {
        let destinationURL = uniqueCaptureURL(for: sourceURL, metadataName: metadataName)

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.copyItem(at: sourceURL, to: destinationURL)

        guard let importedCapture = decodeCapture(at: destinationURL) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        if removeSourceAfterImport {
            removeImportedSourceIfPossible(sourceURL)
        }

        return importedCapture
    }

    private func uniqueCaptureURL(for sourceURL: URL, metadataName: String?) -> URL {
        let baseName = metadataName ?? sourceURL.lastPathComponent
        let sanitizedName = baseName.replacingOccurrences(of: "/", with: "-")
        return captureDirectoryURL.appendingPathComponent(sanitizedName)
    }

    private func pendingTransferFileURLs() -> [URL] {
        guard fileManager.fileExists(atPath: watchConnectivityInboxURL.path) else { return [] }

        let enumerator = fileManager.enumerator(
            at: watchConnectivityInboxURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        let files = (enumerator?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension.lowercased() == "json" }

        return files.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate > rhsDate
        }
    }

    private func removeImportedSourceIfPossible(_ sourceURL: URL) {
        try? fileManager.removeItem(at: sourceURL)

        var currentDirectory = sourceURL.deletingLastPathComponent()
        while currentDirectory.path.hasPrefix(watchConnectivityInboxURL.path),
              currentDirectory != watchConnectivityInboxURL {
            let contents = (try? fileManager.contentsOfDirectory(
                at: currentDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []

            guard contents.isEmpty else { break }
            try? fileManager.removeItem(at: currentDirectory)
            currentDirectory = currentDirectory.deletingLastPathComponent()
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func makeCSV(for session: WatchMotionCaptureSession) -> String {
        var rows = [
            "elapsed_time,core_motion_timestamp,attitude_roll,attitude_pitch,attitude_yaw,quaternion_x,quaternion_y,quaternion_z,quaternion_w,gravity_x,gravity_y,gravity_z,user_accel_x,user_accel_y,user_accel_z,rotation_rate_x,rotation_rate_y,rotation_rate_z"
        ]

        rows.append(contentsOf: session.samples.map { sample in
            [
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
            .joined(separator: ",")
        })

        return rows.joined(separator: "\n")
    }

    var captureDirectoryURL: URL {
        let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return appSupportURL.appendingPathComponent("WatchMotionCaptures", isDirectory: true)
    }

    private var watchConnectivityInboxURL: URL {
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return documentsURL.appendingPathComponent("Inbox/com.apple.watchconnectivity", isDirectory: true)
    }

    private var exportDirectoryURL: URL {
        let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return cachesURL.appendingPathComponent("WatchMotionCaptureExports", isDirectory: true)
    }
}

extension WatchMotionCaptureStore: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.log("activation completed: state=\(activationState.rawValue) error=\(error?.localizedDescription ?? "none")")
            self.refreshConnectionStatus(using: session)
            if error != nil {
                self.lastImportStatus = "Watch connection needs attention."
            }
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        DispatchQueue.main.async {
            self.refreshConnectionStatus(using: session)
        }
    }

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
        DispatchQueue.main.async {
            self.refreshConnectionStatus(using: session)
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.refreshConnectionStatus(using: session)
        }
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.refreshConnectionStatus(using: session)
        }
    }

    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard let payload = decodePhoneCaptureCommand(from: message) else {
            replyHandler([
                "kind": WatchCaptureControlReply.packetKind,
                "syncState": CaptureWatchSyncState.failed.rawValue,
                "detail": "Unsupported watch control request."
            ])
            return
        }

        DispatchQueue.main.async {
            guard let onPhoneCaptureCommand = self.onPhoneCaptureCommand else {
                let reply = WatchCaptureControlReply(
                    commandID: payload.commandID,
                    sessionID: "",
                    takeID: nil,
                    syncState: .unavailable,
                    detail: "Open Capture on iPhone and finish System Check before starting from Watch.",
                    acknowledgedAt: Date()
                )
                replyHandler(self.phoneCaptureReplyDictionary(reply))
                return
            }

            onPhoneCaptureCommand(payload) { reply in
                replyHandler(self.phoneCaptureReplyDictionary(reply))
            }
        }
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        log("received file from watch: \(file.fileURL.lastPathComponent) metadata=\(file.metadata ?? [:])")
        #if DEBUG
        print("[WATCH-DEBUG] iPhone received watch file name=\(file.fileURL.lastPathComponent)")
        #endif
        importTransferredFile(file)
    }

    private func handleLiveMotionMessageData(
        _ messageData: Data,
        replyHandler: ((Data) -> Void)?
    ) {
        guard let batch = try? WatchMotionCaptureCodec.decoder.decode(
            WatchMotionRelayBatch.self,
            from: messageData
        ) else {
            replyHandler?(Data())
            return
        }

        DispatchQueue.main.async {
            let isAuthorized = batch.kind == WatchMotionRelayBatch.packetKind
                && (batch.context == self.activeRelayContext
                    || batch.context == self.pendingRelayContext
                    || batch.context == self.recentlyEndedRelayContext)

            if isAuthorized {
                self.latestLiveMotionBatchAt = Date()
                self.onLiveMotionBatch?(batch)
                if batch.isFinal {
                    self.finalLiveRelayContext = batch.context
                    if self.recentlyEndedRelayContext == batch.context {
                        self.recentlyEndedRelayContext = nil
                    }
                }
            } else {
                self.lastImportStatus = "Rejected stale or unknown Watch motion for \(batch.context.takeID)."
            }

            let acknowledgement = WatchMotionRelayAcknowledgement(
                batch: batch,
                accepted: isAuthorized
            )
            let acknowledgementData = (try? WatchMotionCaptureCodec.encoder.encode(acknowledgement)) ?? Data()
            replyHandler?(acknowledgementData)
        }
    }

    func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        handleLiveMotionMessageData(messageData, replyHandler: nil)
    }

    func session(
        _ session: WCSession,
        didReceiveMessageData messageData: Data,
        replyHandler: @escaping (Data) -> Void
    ) {
        handleLiveMotionMessageData(messageData, replyHandler: replyHandler)
    }
}
