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

    var onImportedCapture: ((ImportedWatchMotionCapture) -> Void)?

    private let fileManager = FileManager.default
    private let processingQueue = DispatchQueue(label: "com.scratchlab.watch-motion-import")
    private var hasActivatedWatchSession = false

    private var watchSession: WCSession? {
        guard WCSession.isSupported() else { return nil }
        return WCSession.default
    }

    override init() {
        super.init()
        createCaptureDirectoryIfNeeded()
        reconcileStoredCaptures()
        loadStoredSessions()
        activateIfNeeded()
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
            connectionSummary = "Watch transfer is unavailable on this device."
            return
        }

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
                    importedCapture = importedCapture.map {
                        $0.session.deviceRecordedAtStart >= latestImportedCapture.session.deviceRecordedAtStart ? $0 : latestImportedCapture
                    } ?? latestImportedCapture
                } catch {
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
        commandID: String = UUID().uuidString.lowercased(),
        completion: @escaping (WatchCaptureControlReply) -> Void
    ) {
        requestRemoteCaptureCommand(
            WatchCaptureCommandPayload(
                commandID: commandID,
                command: .start,
                sessionID: sessionID,
                takeID: takeID
            ),
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
                    detail: detail
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
                        detail: detail
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
                    detail: detail
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
                    detail: detail
                )
            )
            return
        }

        remoteCaptureState = .requested
        let formatter = ISO8601DateFormatter()
        let message: [String: Any] = [
            "kind": WatchCaptureCommandPayload.packetKind,
            "commandID": payload.commandID,
            "command": payload.command.rawValue,
            "sessionID": payload.sessionID,
            "takeID": payload.takeID ?? "",
            "requestedAt": formatter.string(from: payload.requestedAt)
        ]
        watchSession.sendMessage(message, replyHandler: { reply in
            let syncState = CaptureWatchSyncState(rawValue: reply["syncState"] as? String ?? "")
                ?? Self.legacySyncState(for: reply["status"] as? String)
                ?? .failed
            let detail = reply["detail"] as? String
            let acknowledgedAt = formatter.date(from: reply["acknowledgedAt"] as? String ?? "")
            let takeID = (reply["takeID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let controlReply = WatchCaptureControlReply(
                commandID: reply["commandID"] as? String ?? payload.commandID,
                sessionID: reply["sessionID"] as? String ?? payload.sessionID,
                takeID: (takeID?.isEmpty == true) ? nil : takeID,
                syncState: syncState,
                detail: detail,
                acknowledgedAt: acknowledgedAt
            )

            DispatchQueue.main.async {
                self.remoteCaptureState = Self.remoteState(for: controlReply)
                completion(controlReply)
            }
        }, errorHandler: { error in
            let detail = error.localizedDescription
            DispatchQueue.main.async {
                self.remoteCaptureState = .failed(detail)
                completion(
                    WatchCaptureControlReply(
                        commandID: payload.commandID,
                        sessionID: payload.sessionID,
                        takeID: payload.takeID,
                        syncState: .failed,
                        detail: detail
                    )
                )
            }
        })
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

    private func importTransferredFile(_ sessionFile: WCSessionFile) {
        processingQueue.async {
            do {
                let importedCapture = try self.importCaptureFile(
                    from: sessionFile.fileURL,
                    metadataName: sessionFile.metadata?["fileName"] as? String,
                    removeSourceAfterImport: false
                )

                DispatchQueue.main.async {
                    self.reconcileStoredCaptures()
                    self.importedSessions.removeAll { $0.id == importedCapture.id }
                    self.loadStoredSessions()
                    self.lastImportStatus = "Imported \(self.formatDate(importedCapture.session.deviceRecordedAtStart)) from your watch."
                    self.onImportedCapture?(importedCapture)
                }
            } catch {
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

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        importTransferredFile(file)
    }
}
