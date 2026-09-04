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
    @Published private(set) var isPhoneCaptureCommandPending = false

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
    private var activeCaptureID: UUID?
    private var relayedSampleCount = 0
    private var liveBatchSequence = 0
    private var elapsedTimer: Timer?

    // File names (not full paths — persisted files can move directories
    // across app versions, but the name is stable) this instance has queued
    // via `transferFile` and not yet seen a `didFinish` callback for. Checked
    // alongside `WCSession.outstandingFileTransfers` (the OS's own bookkeeping)
    // before queueing so a retry sweep never double-queues a transfer that is
    // still genuinely in flight.
    private var outstandingFileTransfers: Set<String> = []

    // Stop commands this device has already acted on. Makes a repeated stop —
    // from a Mac retry, or a relay that delivered twice — a no-op instead of a
    // second finalize/transfer of the same capture. Bounded so a long session
    // cannot grow it without limit.
    private var resolvedStopCommandIDs: Set<String> = []
    private var resolvedStopCommandOrder: [String] = []
    private static let maximumRememberedStopCommands = 32

    private func rememberResolvedStopCommand(_ commandID: String) {
        guard resolvedStopCommandIDs.insert(commandID).inserted else { return }
        resolvedStopCommandOrder.append(commandID)
        while resolvedStopCommandOrder.count > Self.maximumRememberedStopCommands {
            resolvedStopCommandIDs.remove(resolvedStopCommandOrder.removeFirst())
        }
    }

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

    var isMotionCaptureAvailable: Bool {
        motionManager.isDeviceMotionAvailable
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
        activeCaptureID = UUID()
        sampleLock.lock()
        firstSampleCoreMotionTimestamp = nil
        collectedSamples = []
        relayedSampleCount = 0
        liveBatchSequence = 0
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

            self.relayPendingLiveBatchesIfPossible()

            if count.isMultiple(of: 8) {
                DispatchQueue.main.async {
                    self.sampleCount = count
                    self.elapsedTime = sampleElapsedTime
                }
            }
        }

        startElapsedTimer()
    }

    /// Everything `finalizeStoppedCapture` needs, captured while stopping.
    ///
    /// Exists so the fast half of a stop can be separated from the slow half.
    private struct StoppedCapture {
        let captureID: UUID
        let command: WatchCaptureCommandPayload?
        let acknowledgedAt: Date?
        let samples: [WatchMotionSample]
        let startedAt: Date
        let endedAt: Date
        let wallClockDuration: TimeInterval
    }

    /// Stops the capture and finalizes it, synchronously.
    ///
    /// This is the watch-UI entry point. The relay's stop path deliberately
    /// does not use it — see `resolveControlCommand`.
    func stopCapture() {
        guard let stopped = beginStop() else { return }
        finalizeStoppedCapture(stopped)
    }

    /// The fast half of a stop: Core Motion is stopped and the samples are
    /// taken, and nothing else.
    ///
    /// This is all a stop acknowledgement should ever wait for. Finalization —
    /// building the session, encoding a multi-megabyte JSON and writing it —
    /// used to run before the reply was sent, which put file I/O on the
    /// acknowledgement path and is why the Mac's stop handshake timed out even
    /// though the watch had already stopped recording.
    ///
    /// Returns `nil` when nothing was recording, which is what keeps a repeated
    /// stop harmless.
    private func beginStop() -> StoppedCapture? {
        guard isRecording else { return nil }

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

        let stopped = StoppedCapture(
            captureID: activeCaptureID ?? UUID(),
            command: activeCommandPayload,
            acknowledgedAt: activeAcknowledgedAt,
            samples: finishedSamples,
            startedAt: startedAt,
            endedAt: endedAt,
            wallClockDuration: wallClockDuration
        )

        activeCommandPayload = nil
        activeAcknowledgedAt = nil
        activeCaptureID = nil
        return stopped
    }

    /// The slow half: relay any pending live batches, build the session,
    /// persist it, and queue the existing transfer. Safe to run after the stop
    /// has already been acknowledged — none of it changes whether the watch is
    /// recording.
    private func finalizeStoppedCapture(_ stopped: StoppedCapture) {
        guard !stopped.samples.isEmpty else {
            elapsedTime = stopped.wallClockDuration
            transferStatus = "No motion captured."
            return
        }

        relayPendingLiveBatchesIfPossible(isFinal: true, endedAt: stopped.endedAt)

        let timingMetadata = WatchMotionTimingMetadata.make(
            from: stopped.samples,
            requestedSampleInterval: 1.0 / sampleRateHz,
            wallClockDuration: stopped.wallClockDuration
        )
        elapsedTime = timingMetadata?.sensorDuration ?? stopped.wallClockDuration

        let captureSession = WatchMotionCaptureSession(
            id: stopped.captureID,
            sessionID: stopped.command?.sessionID ?? "",
            takeID: stopped.command?.takeID,
            commandID: stopped.command?.commandID,
            requestedAt: stopped.command?.requestedAt ?? stopped.startedAt,
            acknowledgedAt: stopped.acknowledgedAt,
            syncState: stopped.command == nil ? .notRequested : .acknowledged,
            sourceDeviceName: WKInterfaceDevice.current().name,
            sampleRateHz: sampleRateHz,
            startedAt: stopped.startedAt,
            endedAt: stopped.endedAt,
            deviceRecordedAtStart: stopped.startedAt,
            deviceRecordedAtEnd: stopped.endedAt,
            appVersion: appVersionString,
            timingMetadata: timingMetadata,
            samples: stopped.samples
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
    }

    /// Asks the paired iPhone to run its real guided-capture Start/Stop action.
    /// The watch motion recorder then starts/stops only when the iPhone sends
    /// its existing linked-capture command with the authoritative take ID.
    func requestPairedPhoneCapture(_ command: PhoneCaptureCommandPayload.Command) {
        guard command != .start || isMotionCaptureAvailable else {
            isPhoneCaptureCommandPending = false
            transferStatus = "Motion capture is unavailable on this watch."
            return
        }

        guard let watchSession,
              watchSession.activationState == .activated,
              watchSession.isCompanionAppInstalled,
              watchSession.isReachable else {
            isPhoneCaptureCommandPending = false
            if command == .stop, isRecording {
                stopCapture()
                transferStatus = "Stopped locally. Open Capture on iPhone to finish the phone take."
            } else {
                transferStatus = "Open ScratchLab Capture on iPhone, then try Start Take again."
            }
            return
        }

        let payload = PhoneCaptureCommandPayload(command: command)
        let formatter = ISO8601DateFormatter()
        let message: [String: Any] = [
            "kind": PhoneCaptureCommandPayload.packetKind,
            "commandID": payload.commandID,
            "command": payload.command.rawValue,
            "requestedAt": formatter.string(from: payload.requestedAt)
        ]

        isPhoneCaptureCommandPending = true
        transferStatus = command == .start
            ? "Starting take on iPhone…"
            : "Stopping take on iPhone…"

        watchSession.sendMessage(message, replyHandler: { reply in
            let syncState = CaptureWatchSyncState(rawValue: reply["syncState"] as? String ?? "") ?? .failed
            let detail = reply["detail"] as? String
            DispatchQueue.main.async {
                let replyDetail = detail.flatMap { $0.isEmpty ? nil : $0 }
                let commandHasCompleted = command == .start ? self.isRecording : !self.isRecording
                self.isPhoneCaptureCommandPending = syncState == .requested && !commandHasCompleted
                if commandHasCompleted {
                    return
                }
                switch syncState {
                case .requested, .acknowledged:
                    self.transferStatus = replyDetail
                        ?? (command == .start ? "Starting take on iPhone…" : "Stopping take on iPhone…")
                default:
                    self.isPhoneCaptureCommandPending = false
                    self.transferStatus = replyDetail
                        ?? "The iPhone could not complete that capture command."
                }
            }
        }, errorHandler: { error in
            DispatchQueue.main.async {
                self.isPhoneCaptureCommandPending = false
                self.transferStatus = "iPhone control failed: \(error.localizedDescription)"
            }
        })
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

    private func relayPendingLiveBatchesIfPossible(isFinal: Bool = false, endedAt: Date? = nil) {
        guard let watchSession,
              watchSession.activationState == .activated,
              watchSession.isReachable,
              let payload = activeCommandPayload,
              let context = WatchRelayTakeContext(payload: payload),
              let captureID = activeCaptureID,
              let startedAt = captureStartDate else { return }

        let maximumBatchSize = 20
        var sentFinalPacket = false

        while true {
            sampleLock.lock()
            let pendingCount = collectedSamples.count - relayedSampleCount
            let shouldSendSamples = pendingCount >= maximumBatchSize || (isFinal && pendingCount > 0)
            guard shouldSendSamples else {
                sampleLock.unlock()
                break
            }
            let count = min(maximumBatchSize, pendingCount)
            let range = relayedSampleCount..<(relayedSampleCount + count)
            let samples = Array(collectedSamples[range])
            relayedSampleCount += count
            let isLastPacket = isFinal && relayedSampleCount == collectedSamples.count
            let sequence = liveBatchSequence
            liveBatchSequence += 1
            sampleLock.unlock()

            sendLiveBatch(
                samples: samples,
                sequence: sequence,
                isFinal: isLastPacket,
                endedAt: isLastPacket ? endedAt : nil,
                captureID: captureID,
                context: context,
                payload: payload,
                startedAt: startedAt,
                session: watchSession
            )
            sentFinalPacket = sentFinalPacket || isLastPacket
        }

        if isFinal && !sentFinalPacket {
            sampleLock.lock()
            let sequence = liveBatchSequence
            liveBatchSequence += 1
            sampleLock.unlock()
            sendLiveBatch(
                samples: [],
                sequence: sequence,
                isFinal: true,
                endedAt: endedAt,
                captureID: captureID,
                context: context,
                payload: payload,
                startedAt: startedAt,
                session: watchSession
            )
        }
    }

    private func sendLiveBatch(
        samples: [WatchMotionSample],
        sequence: Int,
        isFinal: Bool,
        endedAt: Date?,
        captureID: UUID,
        context: WatchRelayTakeContext,
        payload: WatchCaptureCommandPayload,
        startedAt: Date,
        session: WCSession
    ) {
        let batch = WatchMotionRelayBatch(
            captureID: captureID,
            context: context,
            commandID: payload.commandID,
            requestedAt: payload.requestedAt,
            acknowledgedAt: activeAcknowledgedAt,
            sourceDeviceName: WKInterfaceDevice.current().name,
            appVersion: appVersionString,
            sampleRateHz: sampleRateHz,
            startedAt: startedAt,
            endedAt: endedAt,
            sequence: sequence,
            isFinal: isFinal,
            samples: samples
        )
        guard let data = try? WatchMotionCaptureCodec.encoder.encode(batch) else { return }
        sendEncodedLiveBatch(data, batch: batch, session: session, attempt: 0)
    }

    private func sendEncodedLiveBatch(
        _ data: Data,
        batch: WatchMotionRelayBatch,
        session: WCSession,
        attempt: Int
    ) {
        session.sendMessageData(data, replyHandler: { [weak self] replyData in
            DispatchQueue.main.async {
                guard let self else { return }
                let acknowledgement = try? WatchMotionCaptureCodec.decoder.decode(
                    WatchMotionRelayAcknowledgement.self,
                    from: replyData
                )
                guard acknowledgement?.accepts(batch) == true else {
                    self.retryLiveBatch(data, batch: batch, session: session, attempt: attempt)
                    return
                }
                self.log("live batch \(batch.sequence) acknowledged")
            }
        }, errorHandler: { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.log("live batch \(batch.sequence) relay failed: \(error.localizedDescription)")
                self.retryLiveBatch(data, batch: batch, session: session, attempt: attempt)
            }
        })
    }

    private func retryLiveBatch(
        _ data: Data,
        batch: WatchMotionRelayBatch,
        session: WCSession,
        attempt: Int
    ) {
        let nextAttempt = attempt + 1
        guard nextAttempt <= 8 else {
            log("live batch \(batch.sequence) exhausted immediate retries; durable file transfer remains queued")
            return
        }

        let delay = min(0.15 * Double(nextAttempt), 0.75)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard session.activationState == .activated, session.isReachable else {
                self.retryLiveBatch(data, batch: batch, session: session, attempt: nextAttempt)
                return
            }
            self.sendEncodedLiveBatch(data, batch: batch, session: session, attempt: nextAttempt)
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
            takeNumber: message["takeNumber"] as? Int,
            watchWrist: message["watchWrist"] as? String,
            requestedAt: requestedAt
        )
    }

    private func makeReply(
        for payload: WatchCaptureCommandPayload,
        syncState: CaptureWatchSyncState,
        detail: String?,
        stopOutcome: CaptureWatchStopOutcome? = nil
    ) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        var reply: [String: Any] = [
            "commandID": payload.commandID,
            "sessionID": payload.sessionID,
            "takeID": payload.takeID ?? "",
            "syncState": syncState.rawValue,
            "detail": detail ?? "",
            "acknowledgedAt": formatter.string(from: Date())
        ]
        // Additive key. Peers that predate stop outcomes ignore it and fall
        // back to `syncState`.
        if let stopOutcome {
            reply["stopOutcome"] = stopOutcome.rawValue
        }
        return reply
    }

    /// The single implementation behind both `didReceiveMessage` overloads.
    ///
    /// Applies `WatchMotionStopCommandResolver`'s decision, performs at most
    /// one Core Motion stop and one finalize per command, and returns the reply
    /// dictionary to send back. Must be called on the main queue.
    private func resolveControlCommand(_ payload: WatchCaptureCommandPayload) -> [String: Any] {
        isPhoneCaptureCommandPending = false

        switch payload.command {
        case .start:
            guard !isRecording else {
                return makeReply(
                    for: payload,
                    syncState: .acknowledged,
                    detail: "Watch motion capture is already recording."
                )
            }
            guard motionManager.isDeviceMotionAvailable else {
                return makeReply(
                    for: payload,
                    syncState: .unavailable,
                    detail: "Motion capture is unavailable on this watch."
                )
            }
            startCapture(commandPayload: payload, acknowledgedAt: Date())
            return makeReply(
                for: payload,
                syncState: isRecording ? .acknowledged : .failed,
                detail: transferStatus
            )

        case .stop:
            let decision = WatchMotionStopCommandResolver.decide(
                payload: payload,
                isRecording: isRecording,
                activeCommand: activeCommandPayload,
                resolvedStopCommandIDs: resolvedStopCommandIDs
            )
            switch decision {
            case .stop:
                // Recorded first so a command delivered twice cannot stop twice.
                rememberResolvedStopCommand(payload.commandID)
                // Core Motion stops here, and the reply goes out immediately
                // after. Finalization — encoding and writing a multi-megabyte
                // motion file — runs on the next main-queue turn, because the
                // Mac needs to know the watch stopped, not that the file was
                // written. Doing it the other way round put file I/O on the
                // acknowledgement path and timed out the handshake.
                let stopped = beginStop()
                if let stopped {
                    DispatchQueue.main.async { self.finalizeStoppedCapture(stopped) }
                }
                return makeReply(
                    for: payload,
                    syncState: decision.syncState,
                    detail: "Watch motion capture stopped.",
                    stopOutcome: decision.outcome
                )
            case let .alreadyStopped(detail):
                rememberResolvedStopCommand(payload.commandID)
                return makeReply(
                    for: payload,
                    syncState: decision.syncState,
                    detail: detail,
                    stopOutcome: decision.outcome
                )
            case let .rejectIdentity(detail):
                // Deliberately does NOT remember the command: it was refused,
                // not handled, and the sender is told exactly why.
                log("stop rejected: \(detail)")
                return makeReply(
                    for: payload,
                    syncState: decision.syncState,
                    detail: detail,
                    stopOutcome: decision.outcome
                )
            }
        }
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
            let reply = self.resolveControlCommand(payload)
            guard session.isReachable else { return }
            session.sendMessage(reply, replyHandler: nil, errorHandler: nil)
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String : Any], replyHandler: @escaping ([String : Any]) -> Void) {
        guard let payload = decodeCommandPayload(from: message) else {
            replyHandler(["syncState": CaptureWatchSyncState.failed.rawValue, "detail": "Missing watch motion control command."])
            return
        }

        DispatchQueue.main.async {
            replyHandler(self.resolveControlCommand(payload))
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
