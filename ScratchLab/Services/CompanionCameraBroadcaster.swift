import Foundation
import AVFoundation
import UIKit
import MultipeerConnectivity
import CoreImage

final class CompanionCameraBroadcaster: NSObject, ObservableObject {
    enum CameraPosition: String, CaseIterable, Identifiable {
        case front
        case rear

        var id: String { rawValue }

        var title: String {
            switch self {
            case .front: return "Self"
            case .rear: return "Deck"
            }
        }

        var avPosition: AVCaptureDevice.Position {
            switch self {
            case .front: return .front
            case .rear: return .back
            }
        }
    }

    struct AudioInputOption: Identifiable, Equatable {
        let id: String
        let name: String
        let portType: AVAudioSession.Port

        var displayName: String {
            let friendlyName: String
            switch portType {
            case .builtInMic:
                friendlyName = "Microphone"
            default:
                friendlyName = name
            }

            switch portType {
            case .usbAudio:
                return "\(friendlyName) (USB)"
            case .lineIn:
                return "\(friendlyName) (Line In)"
            default:
                return friendlyName
            }
        }
    }

    private struct FramePacket: Codable {
        let position: String
        let timestamp: TimeInterval
        let jpegData: Data
    }

    private struct WatchCaptureRelayPacket: Codable {
        let kind: String
        let fileName: String
        let captureSession: WatchMotionCaptureSession

        init(fileName: String, captureSession: WatchMotionCaptureSession) {
            self.kind = Self.packetKind
            self.fileName = fileName
            self.captureSession = captureSession
        }

        static let packetKind = "watch_motion_capture_relay_v1"
    }

    struct WatchControlCommandEvent: Equatable {
        let payload: WatchCaptureCommandPayload
        let requestedAt: Date
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

        init(isPaired: Bool, isInstalled: Bool, isReachable: Bool) {
            self.kind = Self.packetKind
            self.isPaired = isPaired
            self.isInstalled = isInstalled
            self.isReachable = isReachable
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

    private struct PreparedRecording {
        let mediaURL: URL
        let sidecarURL: URL
        let sidecar: CaptureCore.LocalRecordingSidecar
    }

    struct RecordingSummary: Identifiable, Equatable {
        let mediaURL: URL
        let sidecarURL: URL
        let sidecar: CaptureCore.LocalRecordingSidecar
        let statusMessage: String

        var id: String { sidecar.recordingIdentity }
    }

    @Published var selectedCameraPosition: CameraPosition = .rear {
        didSet {
            guard oldValue != selectedCameraPosition, isRunning else { return }
            reconfigureSession()
        }
    }
    @Published var selectedAudioInputID = "" {
        didSet {
            guard oldValue != selectedAudioInputID else { return }
            applyPreferredAudioInput()
        }
    }
    @Published var connectionStatus = "Searching for nearby ScratchLab"
    @Published var connectedPeerNames: [String] = []
    @Published var isBroadcasting = false
    @Published private(set) var videoRotationAngle: CGFloat = 0
    @Published private(set) var availableAudioInputs: [AudioInputOption] = []
    @Published private(set) var activeAudioInputName = "Microphone"
    @Published private(set) var isRecording = false
    @Published private(set) var recordingStatus = "Ready to record locally"
    @Published private(set) var lastRecordingName: String?
    @Published private(set) var lastRecordingSummary: RecordingSummary?
    @Published private(set) var isCameraReady = false
    @Published private(set) var isStorageReady = true
    @Published private(set) var nextTakeNumberPreview = 1
    @Published private(set) var pendingWatchControlCommand: WatchControlCommandEvent?
    /// Delivers a Mac control command straight to the relay, without waiting
    /// for a SwiftUI view to notice `pendingWatchControlCommand` changed.
    ///
    /// Every other relay concern here is already a direct closure. This one was
    /// the exception, routed through an `.onChange` in the app's view body, so
    /// capture control depended on the view-update cycle: a take whose command
    /// arrived while that view was not updating forwarded nothing, and the Mac
    /// saw an unexplained timeout in both directions with no watch motion at
    /// all. Delivery must not depend on rendering.
    var onWatchControlCommand: ((WatchCaptureCommandPayload) -> Void)?
    var onWatchCaptureAcknowledged: ((UUID) -> Void)?
    var recordingSessionID = CaptureCore.LocalRecordingNaming.sessionID() {
        didSet {
            guard oldValue != recordingSessionID else { return }
            refreshNextTakeNumberPreview()
        }
    }
    var recordingSessionConfig: CaptureSessionConfig?
    /// Optional Watch request that belongs to the next local recording. The
    /// request is folded into the initial sidecar on the capture queue so a
    /// linked Watch start can never be reported later as `notRequested`.
    var recordingWatchRequest: WatchCaptureCommandPayload?
    private var recordingWatchReply: WatchCaptureControlReply?

    let captureSession = AVCaptureSession()

    private let serviceType = "scrcamfeed"
    private let peerID = MCPeerID(displayName: UIDevice.current.name)
    private lazy var session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
    private lazy var advertiser = MCNearbyServiceAdvertiser(
        peer: peerID,
        discoveryInfo: ["role": "companion"],
        serviceType: serviceType
    )

    private let captureQueue = DispatchQueue(label: "scratchlab.companion.capture")
    /// Control-plane sends to the Mac: watch status, availability, relay
    /// lifecycle.
    ///
    /// Deliberately NOT `captureQueue`. That queue is also the video output's
    /// sample-buffer delegate queue, so anything dispatched to it waits behind
    /// every camera frame. Relaying the watch's stop acknowledgement on it put
    /// that acknowledgement behind the video pipeline and is why the Mac's stop
    /// handshake timed out while the watch had in fact already stopped.
    private let controlQueue = DispatchQueue(label: "scratchlab.companion.control")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let ciContext = CIContext()
    private let previewFrameInterval: CFTimeInterval = 0.10
    private let previewJPEGQuality: Double = 0.30
    private let landscapePreviewSize = CGSize(width: 480, height: 270)
    private let portraitPreviewSize = CGSize(width: 270, height: 480)

    private var isRunning = false
    private var isAdvertising = false
    private var audioPermissionGranted = false
    private var didConfigureAudioSession = false
    private var lastSentFrameTime: CFTimeInterval = 0
    private var activeRecordingURL: URL?
    private var activeRecordingSidecar: CaptureCore.LocalRecordingSidecar?
    private var activeRecordingSidecarURL: URL?
    private var pendingRecordingFinalizations: [(RecordingSummary?) -> Void] = []
    private var stopRequestedWhileRecordingStarts = false
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationAngleObservation: NSKeyValueObservation?

    override init() {
        super.init()
        session.delegate = self
        advertiser.delegate = self
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: captureQueue)
        recoverInterruptedLocalCaptures()
    }

    deinit {
        rotationAngleObservation?.invalidate()
        if didConfigureAudioSession {
            NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)
        }
    }

    var selectedAudioInputName: String {
        availableAudioInputs.first(where: { $0.id == selectedAudioInputID })?.displayName ?? activeAudioInputName
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        startRelayAdvertisingIfNeeded()
        requestPermissionsAndStart()
    }

    func startRelayAdvertisingIfNeeded() {
        guard !isAdvertising else { return }
        isAdvertising = true
        advertiser.startAdvertisingPeer()
    }

    func stopCaptureServices() {
        isRunning = false
        rotationAngleObservation?.invalidate()
        rotationAngleObservation = nil
        rotationCoordinator = nil
        DispatchQueue.main.async {
            self.isCameraReady = false
        }
        captureQueue.async {
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            }
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
        }
    }

    func stop() {
        stopCaptureServices()
        advertiser.stopAdvertisingPeer()
        isAdvertising = false
    }

    func toggleRecording() {
        isRecording ? stopRecording(onFinalized: nil) : startRecording()
    }

    func beginRecording(captureTiming: CaptureTimingMetadata? = nil) {
        startRecording(captureTiming: captureTiming)
    }

    func endRecording() {
        stopRecording(onFinalized: nil)
    }

    /// Stops the exact local recording currently owned by the movie output
    /// and completes only after its media + sidecar finalization callback has
    /// run. The completion is delivered on the main queue so capture UI state
    /// does not depend solely on a separately published observation.
    func endRecording(onFinalized: @escaping (RecordingSummary?) -> Void) {
        stopRecording(onFinalized: onFinalized)
    }

    func validateStorageLocation() -> Bool {
        do {
            _ = try recordingsDirectoryURL()
            DispatchQueue.main.async {
                self.isStorageReady = true
            }
            refreshNextTakeNumberPreview()
            return true
        } catch {
            DispatchQueue.main.async {
                self.isStorageReady = false
                self.recordingStatus = "Unable to prepare local storage."
            }
            return false
        }
    }

    var stagedCaptureDirectoryURL: URL? {
        try? recordingsDirectoryURL()
    }

    func rescanStagedCaptures() {
        recoverInterruptedLocalCaptures()
        refreshNextTakeNumberPreview()
    }

    func discardRecording(_ summary: RecordingSummary) {
        do {
            if FileManager.default.fileExists(atPath: summary.mediaURL.path) {
                try FileManager.default.removeItem(at: summary.mediaURL)
            }
            if FileManager.default.fileExists(atPath: summary.sidecarURL.path) {
                try FileManager.default.removeItem(at: summary.sidecarURL)
            }
            let scratchAudioURL = summary.sidecarURL
                .deletingPathExtension()
                .appendingPathExtension("wav")
            if FileManager.default.fileExists(atPath: scratchAudioURL.path) {
                try FileManager.default.removeItem(at: scratchAudioURL)
            }

            DispatchQueue.main.async {
                if self.lastRecordingSummary == summary {
                    self.lastRecordingSummary = nil
                    self.lastRecordingName = nil
                    self.recordingStatus = "Last take discarded."
                }
            }
        } catch {
            DispatchQueue.main.async {
                self.recordingStatus = "Unable to discard that take."
            }
        }

        refreshNextTakeNumberPreview()
    }

    func sendWatchCaptureSession(_ captureSession: WatchMotionCaptureSession, fileName: String) {
        captureQueue.async {
            guard !self.session.connectedPeers.isEmpty else {
                #if DEBUG
                print("[WATCH-DEBUG] transfer failed/retrying — no Mac peer connected, sessionID=\(captureSession.sessionID) takeID=\(captureSession.takeID ?? "nil") id=\(captureSession.id)")
                #endif
                return
            }
            let packet = WatchCaptureRelayPacket(fileName: fileName, captureSession: captureSession)
            guard let encoded = try? PropertyListEncoder().encode(packet) else { return }

            #if DEBUG
            print("[WATCH-DEBUG] forwarding watch file to Mac sessionID=\(captureSession.sessionID) takeID=\(captureSession.takeID ?? "nil") id=\(captureSession.id)")
            #endif

            do {
                try self.session.send(encoded, toPeers: self.session.connectedPeers, with: .reliable)
            } catch {
                #if DEBUG
                print("[WATCH-DEBUG] transfer failed/retrying — forward to Mac failed: \(error.localizedDescription) id=\(captureSession.id)")
                #endif
                DispatchQueue.main.async {
                    self.connectionStatus = "Unable to relay watch motion to Mac. Check connection."
                }
            }
        }
    }

    func sendWatchMotionBatch(_ batch: WatchMotionRelayBatch) {
        captureQueue.async {
            guard !self.session.connectedPeers.isEmpty,
                  let encoded = try? PropertyListEncoder().encode(batch) else { return }
            do {
                // Five small batches per second is low enough for reliable delivery, and a
                // missing sequence prevents the Mac assembler from producing an exportable
                // Watch artifact. Capture integrity is more important than shaving latency.
                try self.session.send(encoded, toPeers: self.session.connectedPeers, with: .reliable)
            } catch {
                DispatchQueue.main.async {
                    self.connectionStatus = "Live watch motion relay was interrupted."
                }
            }
        }
    }

    func sendWatchRelayLifecycle(
        _ event: WatchRelayLifecycleEvent,
        context: WatchRelayTakeContext?,
        detail: String?
    ) {
        controlQueue.async {
            guard !self.session.connectedPeers.isEmpty else { return }
            let packet = WatchRelayLifecyclePacket(event: event, context: context, detail: detail)
            guard let encoded = try? PropertyListEncoder().encode(packet) else { return }
            try? self.session.send(encoded, toPeers: self.session.connectedPeers, with: .reliable)
        }
    }

    /// Persists finalized controller/notation evidence into the exact sidecar
    /// represented by `summary`, returning the matching in-memory summary for
    /// Guided Capture review/export. The write is atomic and intentionally
    /// fails to the caller instead of silently exporting a stale sidecar.
    func persistingDetectedNotation(
        _ detectedNotation: CaptureCore.DetectedNotationSnapshot?,
        in summary: RecordingSummary
    ) throws -> RecordingSummary {
        let updatedSidecar = summary.sidecar.withDetectedNotation(detectedNotation)
        try writeRecordingSidecar(updatedSidecar, to: summary.sidecarURL)
        return RecordingSummary(
            mediaURL: summary.mediaURL,
            sidecarURL: summary.sidecarURL,
            sidecar: updatedSidecar,
            statusMessage: summary.statusMessage
        )
    }

    /// Records the Watch's acknowledgement/failure against the active take.
    /// The reply is retained on the capture queue so it is also applied when it
    /// arrives just before `prepareRecording` has created the initial sidecar.
    func recordWatchControlReply(_ reply: WatchCaptureControlReply) {
        captureQueue.async {
            self.recordingWatchReply = reply
            guard var sidecar = self.activeRecordingSidecar,
                  sidecar.sessionID == reply.sessionID,
                  sidecar.takeID == reply.takeID else { return }
            sidecar = sidecar.withWatchSync(reply)
            guard let sidecarURL = self.activeRecordingSidecarURL else { return }
            do {
                try self.writeRecordingSidecar(sidecar, to: sidecarURL)
                self.activeRecordingSidecar = sidecar
            } catch {
                DispatchQueue.main.async {
                    self.recordingStatus = "Watch sync status could not be saved with this take."
                }
            }
        }
    }

    /// Relays the local WCSession's live view of the watch (paired / installed / reachable) to
    /// the Mac, so macOS never has to (and never does) infer reachability merely from pairing.
    func sendWatchAvailability(isPaired: Bool, isInstalled: Bool, isReachable: Bool) {
        controlQueue.async {
            guard !self.session.connectedPeers.isEmpty else { return }
            let packet = WatchAvailabilityPacket(isPaired: isPaired, isInstalled: isInstalled, isReachable: isReachable)
            guard let encoded = try? PropertyListEncoder().encode(packet) else { return }

            #if DEBUG
            print("[WATCH-DEBUG] forwarding watch availability to Mac paired=\(isPaired) installed=\(isInstalled) reachable=\(isReachable)")
            #endif

            do {
                try self.session.send(encoded, toPeers: self.session.connectedPeers, with: .reliable)
            } catch {
                #if DEBUG
                print("[WATCH-DEBUG] transfer failed/retrying — forward watch availability to Mac failed: \(error.localizedDescription)")
                #endif
            }
        }
    }

    func sendWatchControlStatus(_ reply: WatchCaptureControlReply) {
        controlQueue.async {
            guard !self.session.connectedPeers.isEmpty else { return }
            let packet = WatchControlStatusPacket(reply: reply)
            guard let encoded = try? PropertyListEncoder().encode(packet) else { return }

            do {
                try self.session.send(encoded, toPeers: self.session.connectedPeers, with: .reliable)
            } catch {
                DispatchQueue.main.async {
                    self.connectionStatus = "Unable to relay watch status to Mac. Check connection."
                }
            }
        }
    }

    func clearPendingWatchControlCommand() {
        pendingWatchControlCommand = nil
    }

    private func startRecording(captureTiming: CaptureTimingMetadata? = nil) {
        captureQueue.async {
            guard self.captureSession.isRunning else {
                DispatchQueue.main.async {
                    self.recordingStatus = "Camera is not ready yet"
                }
                return
            }

            guard !self.movieOutput.isRecording else { return }

            do {
                let preparedRecording = try self.prepareRecording(captureTiming: captureTiming)
                try? CaptureJournalStore.appendTransactionBegan(
                    storageKind: .companion,
                    sessionID: preparedRecording.sidecar.sessionID,
                    takeID: preparedRecording.sidecar.takeID,
                    sidecarFileName: preparedRecording.sidecar.sidecarFileName,
                    mediaFileName: preparedRecording.sidecar.mediaFileName
                )
                try self.writeRecordingSidecar(preparedRecording.sidecar, to: preparedRecording.sidecarURL)
                self.activeRecordingURL = preparedRecording.mediaURL
                self.activeRecordingSidecar = preparedRecording.sidecar
                self.activeRecordingSidecarURL = preparedRecording.sidecarURL
                self.applyVideoRotationToCaptureOutputs()
                DispatchQueue.main.async {
                    self.lastRecordingSummary = nil
                    self.recordingStatus = "Starting local recording"
                }
                self.movieOutput.startRecording(to: preparedRecording.mediaURL, recordingDelegate: self)
            } catch {
                DispatchQueue.main.async {
                    self.recordingStatus = "Unable to start local recording."
                }
            }
        }
    }

    private func stopRecording(onFinalized: ((RecordingSummary?) -> Void)?) {
        captureQueue.async {
            if let onFinalized {
                self.pendingRecordingFinalizations.append(onFinalized)
            }

            if self.movieOutput.isRecording {
                DispatchQueue.main.async {
                    self.recordingStatus = "Stopping recording"
                }
                self.movieOutput.stopRecording()
                return
            }

            // `startRecording(to:)` returns before AVCaptureFileOutput reports
            // didStart. A fast Save Take can therefore arrive while the staged
            // sidecar exists but `isRecording` is still false. Remember that
            // stop and execute it from didStart rather than losing the request.
            if self.activeRecordingSidecar != nil {
                self.stopRequestedWhileRecordingStarts = true
                DispatchQueue.main.async {
                    self.recordingStatus = "Waiting for recorder to finish starting"
                }
                return
            }

            let completions = self.pendingRecordingFinalizations
            self.pendingRecordingFinalizations.removeAll()
            DispatchQueue.main.async {
                self.recordingStatus = "The camera recorder was not active when Save Take was requested."
                completions.forEach { $0(nil) }
            }
        }
    }

    private func requestPermissionsAndStart() {
        requestVideoAccess { [weak self] videoGranted in
            guard let self else { return }
            guard videoGranted else {
                DispatchQueue.main.async {
                    self.connectionStatus = "Camera permission is required for companion mode"
                }
                return
            }

            self.requestAudioAccess { [weak self] audioGranted in
                guard let self else { return }
                self.captureQueue.async {
                    self.audioPermissionGranted = audioGranted
                    self.configureAudioSessionIfNeeded()
                    self.refreshAvailableAudioInputs()
                    _ = self.validateStorageLocation()

                    DispatchQueue.main.async {
                        if !audioGranted {
                            self.recordingStatus = "Microphone access is off. Local recordings will be silent."
                        }
                    }

                    self.configureAndStart()
                }
            }
        }
    }

    private func requestVideoAccess(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video, completionHandler: completion)
        default:
            completion(false)
        }
    }

    private func requestAudioAccess(completion: @escaping (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                completion(true)
            case .denied:
                completion(false)
            case .undetermined:
                AVAudioApplication.requestRecordPermission(completionHandler: completion)
            @unknown default:
                completion(false)
            }
        } else {
            let audioSession = AVAudioSession.sharedInstance()
            switch audioSession.recordPermission {
            case .granted:
                completion(true)
            case .denied:
                completion(false)
            case .undetermined:
                audioSession.requestRecordPermission(completion)
            @unknown default:
                completion(false)
            }
        }
    }

    private func configureAudioSessionIfNeeded() {
        guard audioPermissionGranted else {
            DispatchQueue.main.async {
                self.availableAudioInputs = []
                self.activeAudioInputName = "Microphone access off"
            }
            return
        }

        let audioSession = AVAudioSession.sharedInstance()

        do {
            try audioSession.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try audioSession.setPreferredSampleRate(48_000)
            try audioSession.setActive(true)
        } catch {
            DispatchQueue.main.async {
                self.recordingStatus = "Audio setup needs attention. Check your input and try again."
            }
            return
        }

        if !didConfigureAudioSession {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleAudioRouteChange),
                name: AVAudioSession.routeChangeNotification,
                object: nil
            )
            didConfigureAudioSession = true
        }
    }

    @objc
    private func handleAudioRouteChange() {
        refreshAvailableAudioInputs()
    }

    private func refreshAvailableAudioInputs() {
        let audioSession = AVAudioSession.sharedInstance()
        let ports = audioSession.availableInputs ?? []
        let options = ports
            .map { AudioInputOption(id: $0.uid, name: $0.portName, portType: $0.portType) }
            .sorted { lhs, rhs in
                if lhs.portType == rhs.portType {
                    return lhs.displayName < rhs.displayName
                }
                return audioPriority(for: lhs.portType) < audioPriority(for: rhs.portType)
            }

        let fallbackID = preferredAudioInputID(from: options)
        let nextSelection: String
        if options.contains(where: { $0.id == selectedAudioInputID }) {
            nextSelection = selectedAudioInputID
        } else {
            nextSelection = fallbackID
        }

        let activeName = audioSession.currentRoute.inputs.first.map(displayName(for:))
            ?? options.first(where: { $0.id == nextSelection })?.displayName
            ?? "Microphone"

        DispatchQueue.main.async {
            self.availableAudioInputs = options
            self.activeAudioInputName = activeName

            if self.selectedAudioInputID != nextSelection {
                self.selectedAudioInputID = nextSelection
            }
        }
    }

    private func audioPriority(for portType: AVAudioSession.Port) -> Int {
        switch portType {
        case .usbAudio:
            return 0
        case .lineIn:
            return 1
        case .builtInMic:
            return 3
        default:
            return 2
        }
    }

    private func preferredAudioInputID(from options: [AudioInputOption]) -> String {
        options.first(where: { $0.portType == .usbAudio })?.id
            ?? options.first(where: { $0.portType == .lineIn })?.id
            ?? options.first(where: { $0.portType == .builtInMic })?.id
            ?? options.first?.id
            ?? ""
    }

    private func displayName(for port: AVAudioSessionPortDescription) -> String {
        switch port.portType {
        case .builtInMic:
            return "Microphone"
        default:
            return port.portName
        }
    }

    private func applyPreferredAudioInput() {
        guard audioPermissionGranted else { return }

        let audioSession = AVAudioSession.sharedInstance()
        let preferredPort = audioSession.availableInputs?.first(where: { $0.uid == selectedAudioInputID })

        do {
            try audioSession.setPreferredInput(preferredPort)
            DispatchQueue.main.async {
                self.activeAudioInputName = audioSession.currentRoute.inputs.first.map(self.displayName(for:))
                    ?? preferredPort.map(self.displayName(for:))
                    ?? "Microphone"
            }
        } catch {
            DispatchQueue.main.async {
                self.recordingStatus = "Unable to switch audio source."
            }
        }
    }

    private func configureAndStart() {
        startRelayAdvertisingIfNeeded()
        reconfigureSession()
    }

    private func configureRotationCoordinator(for camera: AVCaptureDevice) {
        rotationAngleObservation?.invalidate()

        let coordinator = AVCaptureDevice.RotationCoordinator(device: camera, previewLayer: nil)
        rotationCoordinator = coordinator
        rotationAngleObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelCapture,
            options: [.initial, .new]
        ) { [weak self] coordinator, _ in
            self?.updateVideoRotationAngle(coordinator.videoRotationAngleForHorizonLevelCapture)
        }
    }

    private func updateVideoRotationAngle(_ angle: CGFloat) {
        guard videoRotationAngle.rounded() != angle.rounded() else { return }

        DispatchQueue.main.async {
            self.videoRotationAngle = angle
        }

        captureQueue.async {
            self.applyVideoRotationToCaptureOutputs(angle)
        }
    }

    private func applyVideoRotationToCaptureOutputs(_ angle: CGFloat? = nil) {
        let resolvedAngle = angle ?? videoRotationAngle
        let isMirrored = selectedCameraPosition == .front

        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(resolvedAngle) {
                connection.videoRotationAngle = resolvedAngle
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = isMirrored
            }
        }

        if let connection = movieOutput.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(resolvedAngle) {
                connection.videoRotationAngle = resolvedAngle
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = isMirrored
            }
        }
    }

    private func reconfigureSession() {
        captureQueue.async {
            self.captureSession.beginConfiguration()
            self.captureSession.sessionPreset = .high

            for input in self.captureSession.inputs {
                self.captureSession.removeInput(input)
            }

            for output in self.captureSession.outputs {
                self.captureSession.removeOutput(output)
            }

            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera],
                mediaType: .video,
                position: self.selectedCameraPosition.avPosition
            )

            guard let camera = discovery.devices.first,
                  let videoInput = try? AVCaptureDeviceInput(device: camera),
                  self.captureSession.canAddInput(videoInput) else {
                DispatchQueue.main.async {
                    self.connectionStatus = "Unable to access the \(self.selectedCameraPosition.title.lowercased()) camera"
                    self.isCameraReady = false
                }
                self.captureSession.commitConfiguration()
                return
            }

            self.captureSession.addInput(videoInput)

            if self.audioPermissionGranted,
               let microphone = AVCaptureDevice.default(for: .audio),
               let audioInput = try? AVCaptureDeviceInput(device: microphone),
               self.captureSession.canAddInput(audioInput) {
                self.captureSession.addInput(audioInput)
            }

            if self.captureSession.canAddOutput(self.videoOutput) {
                self.captureSession.addOutput(self.videoOutput)
            }

            if self.captureSession.canAddOutput(self.movieOutput) {
                self.captureSession.addOutput(self.movieOutput)
            }

            self.configureRotationCoordinator(for: camera)
            self.applyVideoRotationToCaptureOutputs()

            self.captureSession.commitConfiguration()

            if !self.captureSession.isRunning {
                self.captureSession.startRunning()
            }

            DispatchQueue.main.async {
                self.isCameraReady = true
                self.connectionStatus = self.connectedPeerNames.isEmpty
                    ? "Broadcasting \(self.selectedCameraPosition.title.lowercased()) camera. Open ScratchLab on your main device to connect."
                    : "Streaming \(self.selectedCameraPosition.title.lowercased()) camera to \(self.connectedPeerNames.joined(separator: ", "))"
            }

            self.refreshNextTakeNumberPreview()
        }
    }

    private func sendFrame(_ sampleBuffer: CMSampleBuffer) {
        guard !session.connectedPeers.isEmpty else { return }

        let now = CACurrentMediaTime()
        guard now - lastSentFrameTime >= previewFrameInterval else { return }
        lastSentFrameTime = now

        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        autoreleasepool {
            let ciImage = CIImage(cvPixelBuffer: imageBuffer)
            let targetSize = videoRotationAngle.isLandscapeVideoAngle
                ? landscapePreviewSize
                : portraitPreviewSize
            let scaledImage = ciImage.transformed(
                by: CGAffineTransform(
                    scaleX: targetSize.width / ciImage.extent.width,
                    y: targetSize.height / ciImage.extent.height
                )
            )

            guard let jpegData = ciContext.jpegRepresentation(
                of: scaledImage,
                colorSpace: CGColorSpaceCreateDeviceRGB(),
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: previewJPEGQuality]
            ) else {
                return
            }

            let packet = FramePacket(
                position: selectedCameraPosition.rawValue,
                timestamp: Date().timeIntervalSince1970,
                jpegData: jpegData
            )

            guard let encoded = try? PropertyListEncoder().encode(packet) else { return }

            do {
                try session.send(encoded, toPeers: session.connectedPeers, with: .unreliable)
                DispatchQueue.main.async {
                    self.isBroadcasting = true
                }
            } catch {
                DispatchQueue.main.async {
                    self.connectionStatus = "Unable to send video. Check connection."
                }
            }
        }
    }

    private func prepareRecording(captureTiming: CaptureTimingMetadata?) throws -> PreparedRecording {
        let directory = try recordingsDirectoryURL()
        let startedAt = Date()
        let sessionID = recordingSessionID
        let takeNumber = try CaptureCore.LocalRecordingNaming.nextTakeNumber(in: directory, sessionID: sessionID)
        let takeIdentity = CaptureCore.LocalRecordingNaming.takeIdentity(sessionID: sessionID, takeNumber: takeNumber)
        let roleLabel = selectedCameraPosition == .rear ? "camA" : "self"
        let files = try CaptureCore.LocalRecordingFiles.make(
            in: directory,
            sessionID: sessionID,
            takeNumber: takeNumber,
            roleLabel: roleLabel
        )

        var sidecar = CaptureCore.LocalRecordingSidecar.recording(
            sessionID: sessionID,
            sessionConfig: recordingSessionConfig,
            takeIdentity: takeIdentity,
            files: files,
            recordingRole: selectedCameraPosition == .rear ? "camA_candidate" : "self_reference",
            platform: "iOS",
            appSurface: "ScratchLab Companion Camera",
            sourceDeviceName: UIDevice.current.name,
            cameraPosition: selectedCameraPosition.rawValue,
            audioInputName: selectedAudioInputName,
            captureTiming: captureTiming,
            startedAt: startedAt
        )
        if let request = recordingWatchRequest,
           request.sessionID == sessionID,
           request.takeID == takeIdentity.takeID {
            sidecar = sidecar.withPendingWatchRequest(request)
        }
        if let reply = recordingWatchReply,
           reply.sessionID == sessionID,
           reply.takeID == takeIdentity.takeID {
            sidecar = sidecar.withWatchSync(reply)
        }

        return PreparedRecording(mediaURL: files.mediaURL, sidecarURL: files.sidecarURL, sidecar: sidecar)
    }

    private func recordingsDirectoryURL() throws -> URL {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CompanionCaptures", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func refreshNextTakeNumberPreview() {
        captureQueue.async {
            do {
                let directory = try self.recordingsDirectoryURL()
                let sessionID = self.recordingSessionID
                let takeNumber = try CaptureCore.LocalRecordingNaming.nextTakeNumber(in: directory, sessionID: sessionID)
                DispatchQueue.main.async {
                    self.nextTakeNumberPreview = takeNumber
                    self.isStorageReady = true
                }
            } catch {
                DispatchQueue.main.async {
                    self.isStorageReady = false
                }
            }
        }
    }

    private func finalizeRecording(outputFileURL: URL, error: Error?) -> (String, RecordingSummary?) {
        defer {
            activeRecordingURL = nil
            activeRecordingSidecar = nil
            activeRecordingSidecarURL = nil
            recordingWatchRequest = nil
            recordingWatchReply = nil
        }

        let captureErrorDescription = error?.localizedDescription
        guard var sidecar = activeRecordingSidecar else {
            if captureErrorDescription != nil {
                return ("Recording ended before it could be saved.", nil)
            }
            return ("Saved \(outputFileURL.lastPathComponent).", nil)
        }

        sidecar = sidecar.finalized(
            mediaFileName: outputFileURL.lastPathComponent,
            captureErrorDescription: captureErrorDescription
        )
        let sidecarURL = activeRecordingSidecarURL
            ?? CaptureCore.LocalRecordingFiles.sidecarURL(forMediaURL: outputFileURL)

        do {
            try? CaptureJournalStore.appendMediaCommitted(
                storageKind: .companion,
                sidecar: sidecar
            )
            try writeRecordingSidecar(sidecar, to: sidecarURL)
            try? CaptureJournalStore.appendTransactionFinalized(
                storageKind: .companion,
                sidecar: sidecar
            )
            let statusMessage: String
            if captureErrorDescription != nil {
                statusMessage = "Recording ended before it could be saved completely."
            } else {
                statusMessage = "Saved \(outputFileURL.lastPathComponent)."
            }
            let summary = RecordingSummary(
                mediaURL: outputFileURL,
                sidecarURL: sidecarURL,
                sidecar: sidecar,
                statusMessage: statusMessage
            )
            return (statusMessage, summary)
        } catch {
            if captureErrorDescription != nil {
                return ("Recording ended before it could be saved completely.", nil)
            }
            return ("Saved \(outputFileURL.lastPathComponent), but session details could not be updated.", nil)
        }
    }

    private func writeRecordingSidecar(_ sidecar: CaptureCore.LocalRecordingSidecar, to url: URL) throws {
        let data = try sidecar.encodedData()
        try data.write(to: url, options: .atomic)
        try? CaptureAuditStore.persist(sidecar: sidecar, storageKind: .companion)
    }

    private func recoverInterruptedLocalCaptures() {
        do {
            let directory = try recordingsDirectoryURL()
            let report = StagedCaptureRecoveryManager().recoverRecordingDirectory(
                at: directory,
                storageKind: .companion
            )
            if let summaryText = report.summaryText {
                recordingStatus = summaryText
            }
        } catch {
            recordingStatus = "Companion capture recovery needs attention."
        }
    }
}

extension CompanionCameraBroadcaster: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        sendFrame(sampleBuffer)
    }
}

extension CompanionCameraBroadcaster: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput,
                    didStartRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
        captureQueue.async {
            let shouldStopImmediately = self.stopRequestedWhileRecordingStarts
            self.stopRequestedWhileRecordingStarts = false
            DispatchQueue.main.async {
                self.isRecording = true
                self.recordingStatus = shouldStopImmediately
                    ? "Stopping recording"
                    : "Recording to \(fileURL.lastPathComponent)"
            }
            if shouldStopImmediately {
                self.movieOutput.stopRecording()
            }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        captureQueue.async {
            let (statusMessage, summary) = self.finalizeRecording(outputFileURL: outputFileURL, error: error)
            let completions = self.pendingRecordingFinalizations
            self.pendingRecordingFinalizations.removeAll()
            self.stopRequestedWhileRecordingStarts = false
            DispatchQueue.main.async {
                self.isRecording = false

                if error == nil {
                    self.lastRecordingName = outputFileURL.lastPathComponent
                }

                if let summary {
                    self.lastRecordingSummary = summary
                }
                self.recordingStatus = statusMessage
                completions.forEach { $0(summary) }
            }
            self.refreshNextTakeNumberPreview()
        }
    }
}

extension CompanionCameraBroadcaster: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, session)
    }
}

extension CompanionCameraBroadcaster: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            self.connectedPeerNames = session.connectedPeers.map(\.displayName).sorted()
            switch state {
            case .connected:
                self.connectionStatus = self.isRunning
                    ? "Streaming \(self.selectedCameraPosition.title.lowercased()) camera to \(peerID.displayName)"
                    : "Watch relay connected to \(peerID.displayName)"
            case .connecting:
                self.connectionStatus = "Connecting to \(peerID.displayName)"
            case .notConnected:
                self.isBroadcasting = false
                self.connectionStatus = self.connectedPeerNames.isEmpty
                    ? "Searching for nearby ScratchLab"
                    : (self.isRunning
                        ? "Streaming \(self.selectedCameraPosition.title.lowercased()) camera to \(self.connectedPeerNames.joined(separator: ", "))"
                        : "Watch relay connected to \(self.connectedPeerNames.joined(separator: ", "))")
            @unknown default:
                self.connectionStatus = "Connection state changed"
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        if let commandPacket = try? PropertyListDecoder().decode(WatchControlCommandPacket.self, from: data),
           commandPacket.payload.kind == WatchCaptureCommandPayload.packetKind {
            DispatchQueue.main.async {
                // Tell the Mac the relay has the command before doing anything
                // with it. A stop that later times out can then say whether the
                // phone never heard it or the watch never answered — states an
                // unqualified `timedOut` cannot tell apart.
                self.sendWatchControlStatus(
                    WatchCaptureControlReply(
                        commandID: commandPacket.payload.commandID,
                        sessionID: commandPacket.payload.sessionID,
                        takeID: commandPacket.payload.takeID,
                        syncState: .requested,
                        detail: "Relay received the command and is forwarding it to the watch.",
                        acknowledgedAt: Date()
                    )
                )
                // Published for the UI and for debugging only; delivery is the
                // closure's job.
                self.pendingWatchControlCommand = WatchControlCommandEvent(
                    payload: commandPacket.payload,
                    requestedAt: Date()
                )
                self.onWatchControlCommand?(commandPacket.payload)
            }
            return
        }

        if let ackPacket = try? PropertyListDecoder().decode(WatchCaptureRelayAckPacket.self, from: data),
           ackPacket.kind == WatchCaptureRelayAckPacket.packetKind {
            #if DEBUG
            print("[WATCH-DEBUG] Mac acknowledged import id=\(ackPacket.captureID)")
            #endif
            DispatchQueue.main.async {
                self.onWatchCaptureAcknowledged?(ackPacket.captureID)
            }
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}

    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}

    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

private extension CGFloat {
    var normalizedVideoRotationAngle: Int {
        var normalized = Int(self.rounded()) % 360
        if normalized < 0 {
            normalized += 360
        }
        return normalized
    }

    var isLandscapeVideoAngle: Bool {
        let angle = normalizedVideoRotationAngle
        return angle == 90 || angle == 270
    }
}
