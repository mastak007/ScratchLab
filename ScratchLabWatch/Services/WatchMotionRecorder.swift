import Combine
import CoreMotion
import Foundation
import WatchConnectivity
import WatchKit

final class WatchMotionRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var sampleCount = 0
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var transferStatus = "Ready"
    @Published private(set) var isPhonePaired = false
    @Published private(set) var isCompanionInstalled = false
    @Published private(set) var isPhoneReachable = false

    let sampleRateHz = 100.0

    private let motionManager = CMMotionManager()
    private let motionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.scratchlab.watch-motion-recorder"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private let fileManager = FileManager.default
    private let sampleLock = NSLock()

    private var captureStartDate: Date?
    private var activeCommandPayload: WatchCaptureCommandPayload?
    private var activeAcknowledgedAt: Date?
    private var firstSampleCoreMotionTimestamp: TimeInterval?
    private var collectedSamples: [WatchMotionSample] = []
    private var elapsedTimer: Timer?

    // File names (not full paths — persisted files can move directories
    // across app versions, but the name is stable) this instance has queued
    // via `transferFile` and not yet seen a `didFinish` callback for. Checked
    // alongside `WCSession.outstandingFileTransfers` (the OS's own bookkeeping)
    // before queueing so a retry sweep never double-queues a transfer that is
    // still genuinely in flight.
    private var outstandingFileTransfers: Set<String> = []

    private var watchSession: WCSession? {
        guard WCSession.isSupported() else { return nil }
        return WCSession.default
    }

    private func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[WatchTransfer] \(message())")
        #endif
    }

    override init() {
        super.init()
        activateWatchSession()
    }

    var elapsedDescription: String {
        let totalSeconds = Int(elapsedTime.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    func startCapture(commandPayload: WatchCaptureCommandPayload? = nil, acknowledgedAt: Date? = nil) {
        guard motionManager.isDeviceMotionAvailable else {
            transferStatus = "Motion capture is unavailable on this watch."
            return
        }

        let startedAt = Date()
        captureStartDate = startedAt
        activeCommandPayload = commandPayload
        activeAcknowledgedAt = acknowledgedAt
        sampleLock.lock()
        firstSampleCoreMotionTimestamp = nil
        collectedSamples = []
        sampleLock.unlock()
        isRecording = true
        sampleCount = 0
        elapsedTime = 0
        transferStatus = "Recording"

        motionManager.deviceMotionUpdateInterval = 1.0 / sampleRateHz
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: motionQueue) { [weak self] motion, error in
            guard let self else { return }

            if let error {
                DispatchQueue.main.async {
                    print("Watch motion capture error: \(error.localizedDescription)")
                    self.transferStatus = "Motion capture stopped. Try again."
                    self.stopCapture()
                }
                return
            }

            guard self.isRecording, let motion else { return }

            let coreMotionTimestamp = motion.timestamp
            self.sampleLock.lock()
            if self.firstSampleCoreMotionTimestamp == nil {
                self.firstSampleCoreMotionTimestamp = coreMotionTimestamp
            }
            let firstSampleTimestamp = self.firstSampleCoreMotionTimestamp ?? coreMotionTimestamp
            let sampleElapsedTime = max(coreMotionTimestamp - firstSampleTimestamp, 0)
            let sample = WatchMotionSample(
                elapsedTime: sampleElapsedTime,
                coreMotionTimestamp: coreMotionTimestamp,
                attitudeRoll: motion.attitude.roll,
                attitudePitch: motion.attitude.pitch,
                attitudeYaw: motion.attitude.yaw,
                quaternionX: motion.attitude.quaternion.x,
                quaternionY: motion.attitude.quaternion.y,
                quaternionZ: motion.attitude.quaternion.z,
                quaternionW: motion.attitude.quaternion.w,
                gravityX: motion.gravity.x,
                gravityY: motion.gravity.y,
                gravityZ: motion.gravity.z,
                userAccelerationX: motion.userAcceleration.x,
                userAccelerationY: motion.userAcceleration.y,
                userAccelerationZ: motion.userAcceleration.z,
                rotationRateX: motion.rotationRate.x,
                rotationRateY: motion.rotationRate.y,
                rotationRateZ: motion.rotationRate.z
            )
            self.collectedSamples.append(sample)
            let count = self.collectedSamples.count
            self.sampleLock.unlock()

            if count.isMultiple(of: 8) {
                DispatchQueue.main.async {
                    self.sampleCount = count
                    self.elapsedTime = sampleElapsedTime
                }
            }
        }

        startElapsedTimer()
    }

    func stopCapture() {
        guard isRecording else { return }

        isRecording = false
        motionManager.stopDeviceMotionUpdates()
        stopElapsedTimer()

        let endedAt = Date()
        let startedAt = captureStartDate ?? endedAt
        let wallClockDuration = max(endedAt.timeIntervalSince(startedAt), 0)

        sampleLock.lock()
        let finishedSamples = collectedSamples
        firstSampleCoreMotionTimestamp = nil
        sampleLock.unlock()

        sampleCount = finishedSamples.count

        guard !finishedSamples.isEmpty else {
            elapsedTime = wallClockDuration
            transferStatus = "No motion captured."
            return
        }

        let timingMetadata = WatchMotionTimingMetadata.make(
            from: finishedSamples,
            requestedSampleInterval: 1.0 / sampleRateHz,
            wallClockDuration: wallClockDuration
        )
        elapsedTime = timingMetadata?.sensorDuration ?? wallClockDuration

        let captureSession = WatchMotionCaptureSession(
            id: UUID(),
            sessionID: activeCommandPayload?.sessionID ?? "",
            takeID: activeCommandPayload?.takeID,
            commandID: activeCommandPayload?.commandID,
            requestedAt: activeCommandPayload?.requestedAt ?? startedAt,
            acknowledgedAt: activeAcknowledgedAt,
            syncState: activeCommandPayload == nil ? .notRequested : .acknowledged,
            sourceDeviceName: WKInterfaceDevice.current().name,
            sampleRateHz: sampleRateHz,
            startedAt: startedAt,
            endedAt: endedAt,
            deviceRecordedAtStart: startedAt,
            deviceRecordedAtEnd: endedAt,
            appVersion: appVersionString,
            timingMetadata: timingMetadata,
            samples: finishedSamples
        )

        #if DEBUG
        print("[WATCH-DEBUG] motion queued sessionID=\(captureSession.sessionID) takeID=\(captureSession.takeID ?? "nil")")
        #endif

        do {
            let fileURL = try persist(captureSession)
            queueTransfer(of: fileURL)
        } catch {
            transferStatus = "Unable to save the motion session."
        }

        activeCommandPayload = nil
        activeAcknowledgedAt = nil
    }

    private func activateWatchSession() {
        guard let watchSession else {
            log("activation skipped — WCSession unsupported on this device")
            transferStatus = "Pair your watch with your device to send sessions."
            return
        }

        log("activating WCSession")
        watchSession.delegate = self
        watchSession.activate()
        refreshConnectivity(using: watchSession)
    }

    private func refreshConnectivity(using session: WCSession) {
        isPhonePaired = session.activationState == .activated || session.isCompanionAppInstalled || session.isReachable
        isCompanionInstalled = session.isCompanionAppInstalled
        isPhoneReachable = session.isReachable

        #if DEBUG
        print("[WATCH-DEBUG] watch session state paired=\(isPhonePaired) installed=\(isCompanionInstalled) reachable=\(isPhoneReachable)")
        #endif

        if !session.isCompanionAppInstalled {
            transferStatus = "Install ScratchLab on your paired device to receive watch captures."
        } else if !isRecording && sampleCount == 0 {
            transferStatus = "Ready"
        }
    }

    private func startElapsedTimer() {
        stopElapsedTimer()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let startedAt = self.captureStartDate else { return }
            self.elapsedTime = Date().timeIntervalSince(startedAt)
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    private func persist(_ captureSession: WatchMotionCaptureSession) throws -> URL {
        try fileManager.createDirectory(at: storageDirectoryURL, withIntermediateDirectories: true)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let timestamp = formatter.string(from: captureSession.startedAt).replacingOccurrences(of: ":", with: "-")
        let fileName = "scratch-motion-\(timestamp)-\(captureSession.id.uuidString.prefix(6)).json"
        let fileURL = storageDirectoryURL.appendingPathComponent(fileName)
        let data = try WatchMotionCaptureCodec.encoder.encode(captureSession)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    /// Queues `fileURL` for transfer, or leaves it on disk untouched if it
    /// can't be queued right now. Never re-encodes or moves the file, so a
    /// retried transfer carries the exact same sessionID/takeID bytes as the
    /// original attempt. Safe to call repeatedly for the same file — an
    /// already-outstanding transfer (ours or one the OS is already tracking)
    /// is skipped rather than duplicated.
    private func queueTransfer(of fileURL: URL, isRetry: Bool = false) {
        let fileName = fileURL.lastPathComponent

        guard let watchSession, watchSession.activationState == .activated else {
            log("queue skipped (session not activated): \(fileName)")
            transferStatus = "Saved on device. Open ScratchLab on your paired device later to import it."
            return
        }

        guard !outstandingFileTransfers.contains(fileName) else {
            log("queue skipped (already tracked as in flight by this instance): \(fileName)")
            return
        }

        guard !watchSession.outstandingFileTransfers.contains(where: { $0.file.fileURL.lastPathComponent == fileName }) else {
            log("queue skipped (WCSession already has an outstanding transfer): \(fileName)")
            outstandingFileTransfers.insert(fileName)
            return
        }

        outstandingFileTransfers.insert(fileName)
        let metadata = ["fileName": fileName]
        watchSession.transferFile(fileURL, metadata: metadata)
        log("\(isRetry ? "retry-queued" : "queued") transfer: \(fileName) (session outstanding=\(watchSession.outstandingFileTransfers.count))")

        if watchSession.isCompanionAppInstalled {
            transferStatus = isRetry ? "Retrying send to your paired device…" : "Queued the motion session for device import."
        } else {
            transferStatus = "Saved on device. Install ScratchLab on your paired device to import it."
        }
    }

    /// Re-queues any persisted capture JSON that isn't already an outstanding
    /// transfer, so a session that was queued but never delivered (no
    /// `didFinish` callback ever observed — the file was simply left on disk)
    /// gets another attempt as soon as the watch is next activated or
    /// reachable, without waiting for the user to record another take.
    private func retryPendingTransfersIfNeeded() {
        guard let watchSession, watchSession.activationState == .activated else { return }

        let pendingFiles = persistedCaptureFileURLs()
        guard !pendingFiles.isEmpty else { return }

        log("retry sweep: \(pendingFiles.count) persisted capture(s) on disk, \(watchSession.outstandingFileTransfers.count) outstanding at session level")
        #if DEBUG
        print("[WATCH-DEBUG] transfer failed/retrying — retry sweep found \(pendingFiles.count) persisted capture(s) on disk")
        #endif

        for fileURL in pendingFiles {
            queueTransfer(of: fileURL, isRetry: true)
        }
    }

    private func persistedCaptureFileURLs() -> [URL] {
        let entries = (try? fileManager.contentsOfDirectory(
            at: storageDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries.filter { $0.pathExtension.lowercased() == "json" }
    }

    private var storageDirectoryURL: URL {
        let baseURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return baseURL.appendingPathComponent("MotionCaptures", isDirectory: true)
    }

    private var appVersionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}

extension WatchMotionRecorder: WCSessionDelegate {
    private func decodeCommandPayload(from message: [String: Any]) -> WatchCaptureCommandPayload? {
        guard let command = WatchCaptureCommandPayload.Command(rawValue: message["command"] as? String ?? "") else {
            return nil
        }
        let requestedAt = ISO8601DateFormatter().date(from: message["requestedAt"] as? String ?? "") ?? Date()
        let takeIDText = (message["takeID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return WatchCaptureCommandPayload(
            commandID: message["commandID"] as? String ?? UUID().uuidString.lowercased(),
            command: command,
            sessionID: message["sessionID"] as? String ?? "",
            takeID: (takeIDText?.isEmpty == true) ? nil : takeIDText,
            requestedAt: requestedAt
        )
    }

    private func makeReply(
        for payload: WatchCaptureCommandPayload,
        syncState: CaptureWatchSyncState,
        detail: String?
    ) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        return [
            "commandID": payload.commandID,
            "sessionID": payload.sessionID,
            "takeID": payload.takeID ?? "",
            "syncState": syncState.rawValue,
            "detail": detail ?? "",
            "acknowledgedAt": formatter.string(from: Date())
        ]
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.log("activation completed: state=\(activationState.rawValue) error=\(error?.localizedDescription ?? "none")")
            self.refreshConnectivity(using: session)
            if let error {
                print("Watch connection error: \(error.localizedDescription)")
                self.transferStatus = "Watch connection needs attention."
            }
            self.retryPendingTransfersIfNeeded()
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.log("reachability changed: isReachable=\(session.isReachable)")
            self.refreshConnectivity(using: session)
            self.retryPendingTransfersIfNeeded()
        }
    }

    func sessionCompanionAppInstalledDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.refreshConnectivity(using: session)
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        guard let payload = decodeCommandPayload(from: message) else { return }

        DispatchQueue.main.async {
            let reply: (CaptureWatchSyncState, String?) -> Void = { syncState, detail in
                if session.isReachable {
                    session.sendMessage(
                        self.makeReply(for: payload, syncState: syncState, detail: detail),
                        replyHandler: nil,
                        errorHandler: nil
                    )
                }
            }

            switch payload.command {
            case .start:
                guard !self.isRecording else {
                    reply(.acknowledged, "Watch motion capture is already recording.")
                    return
                }
                guard self.motionManager.isDeviceMotionAvailable else {
                    reply(.unavailable, "Motion capture is unavailable on this watch.")
                    return
                }
                self.startCapture(commandPayload: payload, acknowledgedAt: Date())
                reply(self.isRecording ? .acknowledged : .failed, self.transferStatus)
            case .stop:
                guard self.isRecording else {
                    reply(.notRequested, "Watch motion capture was already stopped.")
                    return
                }
                self.stopCapture()
                reply(.notRequested, self.transferStatus)
            }
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String : Any], replyHandler: @escaping ([String : Any]) -> Void) {
        guard let payload = decodeCommandPayload(from: message) else {
            replyHandler(["syncState": CaptureWatchSyncState.failed.rawValue, "detail": "Missing watch motion control command."])
            return
        }

        DispatchQueue.main.async {
            switch payload.command {
            case .start:
                guard !self.isRecording else {
                    replyHandler(self.makeReply(for: payload, syncState: .acknowledged, detail: "Watch motion capture is already recording."))
                    return
                }
                guard self.motionManager.isDeviceMotionAvailable else {
                    replyHandler(self.makeReply(for: payload, syncState: .unavailable, detail: "Motion capture is unavailable on this watch."))
                    return
                }
                self.startCapture(commandPayload: payload, acknowledgedAt: Date())
                replyHandler(self.makeReply(for: payload, syncState: self.isRecording ? .acknowledged : .failed, detail: self.transferStatus))
            case .stop:
                guard self.isRecording else {
                    replyHandler(self.makeReply(for: payload, syncState: .notRequested, detail: "Watch motion capture was already stopped."))
                    return
                }
                self.stopCapture()
                replyHandler(self.makeReply(for: payload, syncState: .notRequested, detail: self.transferStatus))
            }
        }
    }

    /// `error == nil` here means WatchConnectivity has taken ownership of the
    /// file and guarantees eventual delivery — it does not by itself prove
    /// the iPhone app has run `didReceive file:` yet, but there is nothing
    /// further this device can or should do, so the local copy is safe to
    /// remove. `error != nil` is the only case treated as a failure — a
    /// callback that never arrives at all is deliberately not surfaced as
    /// failure anywhere in this file (there is no captured error to report),
    /// and is instead picked up again by `retryPendingTransfersIfNeeded()`.
    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let fileURL = fileTransfer.file.fileURL
        let fileName = fileURL.lastPathComponent

        DispatchQueue.main.async {
            self.outstandingFileTransfers.remove(fileName)

            if let error {
                self.log("transfer failed: \(fileName) — \(error.localizedDescription)")
                print("Watch transfer error: \(error.localizedDescription)")
                #if DEBUG
                print("[WATCH-DEBUG] transfer failed/retrying — \(fileName): \(error.localizedDescription)")
                #endif
                self.transferStatus = "Couldn't send to your paired device. Will retry automatically."
                return
            }

            self.log("transfer completed, handed off to WatchConnectivity: \(fileName)")
            self.transferStatus = "Sent to your paired device."
            do {
                try self.fileManager.removeItem(at: fileURL)
                self.log("removed delivered local copy: \(fileName)")
            } catch {
                self.log("delivered but couldn't remove local copy: \(fileName) — \(error.localizedDescription)")
            }
        }
    }
}
