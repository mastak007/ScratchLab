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
    var recordingSessionID = CaptureCore.LocalRecordingNaming.sessionID() {
        didSet {
            guard oldValue != recordingSessionID else { return }
            refreshNextTakeNumberPreview()
        }
    }
    var recordingSessionConfig: CaptureSessionConfig?

    let captureSession = AVCaptureSession()

    private let serviceType = "scrcamfeed"
    private let peerID = MCPeerID(displayName: UIDevice.current.name)
    private lazy var session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
    private lazy var advertiser = MCNearbyServiceAdvertiser(
        peer: peerID,
        discoveryInfo: ["role": "camera"],
        serviceType: serviceType
    )

    private let captureQueue = DispatchQueue(label: "scratchlab.companion.capture")
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
        isRecording ? stopRecording() : startRecording()
    }

    func beginRecording(captureTiming: CaptureTimingMetadata? = nil) {
        startRecording(captureTiming: captureTiming)
    }

    func endRecording() {
        stopRecording()
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
            guard !self.session.connectedPeers.isEmpty else { return }
            let packet = WatchCaptureRelayPacket(fileName: fileName, captureSession: captureSession)
            guard let encoded = try? PropertyListEncoder().encode(packet) else { return }

            do {
                try self.session.send(encoded, toPeers: self.session.connectedPeers, with: .reliable)
            } catch {
                DispatchQueue.main.async {
                    self.connectionStatus = "Unable to relay watch motion to Mac. Check connection."
                }
            }
        }
    }

    func sendWatchControlStatus(_ reply: WatchCaptureControlReply) {
        captureQueue.async {
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

    private func stopRecording() {
        captureQueue.async {
            guard self.movieOutput.isRecording else { return }
            DispatchQueue.main.async {
                self.recordingStatus = "Stopping recording"
            }
            self.movieOutput.stopRecording()
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

        let sidecar = CaptureCore.LocalRecordingSidecar.recording(
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
        DispatchQueue.main.async {
            self.isRecording = true
            self.recordingStatus = "Recording to \(fileURL.lastPathComponent)"
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        let (statusMessage, summary) = finalizeRecording(outputFileURL: outputFileURL, error: error)
        DispatchQueue.main.async {
            self.isRecording = false

            if error == nil {
                self.lastRecordingName = outputFileURL.lastPathComponent
            }

            if let summary {
                self.lastRecordingSummary = summary
            }
            self.recordingStatus = statusMessage
        }
        refreshNextTakeNumberPreview()
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
                self.connectionStatus = "Streaming \(self.selectedCameraPosition.title.lowercased()) camera to \(peerID.displayName)"
            case .connecting:
                self.connectionStatus = "Connecting to \(peerID.displayName)"
            case .notConnected:
                self.isBroadcasting = false
                self.connectionStatus = self.connectedPeerNames.isEmpty
                    ? "Searching for nearby ScratchLab"
                    : "Streaming \(self.selectedCameraPosition.title.lowercased()) camera to \(self.connectedPeerNames.joined(separator: ", "))"
            @unknown default:
                self.connectionStatus = "Connection state changed"
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        if let commandPacket = try? PropertyListDecoder().decode(WatchControlCommandPacket.self, from: data),
           commandPacket.payload.kind == WatchCaptureCommandPayload.packetKind {
            DispatchQueue.main.async {
                self.pendingWatchControlCommand = WatchControlCommandEvent(
                    payload: commandPacket.payload,
                    requestedAt: Date()
                )
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
