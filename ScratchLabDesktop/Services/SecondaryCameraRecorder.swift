import AVFoundation
import AppKit
import SwiftUI

/// Optional local/Continuity camera. Its serial queue owns the session, writer
/// and take token. Network preview packets are never promoted to recordings.
final class SecondaryCameraRecorder: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    @Published private(set) var status = "Second camera is off"
    @Published private(set) var selectedID = ""
    @Published private(set) var ready = false
    @Published private(set) var rotation: CGFloat = 0
    private let queue = DispatchQueue(label: "scratchlab.secondary-camera")
    private let output = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private var coordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var captureRotation: CGFloat = 0
    private var active: Active?
    private var frozen: [URL: SecondaryCameraEvidence] = [:]
    private var latestFrameHostTime: Double = 0
    private var previewReadyPublished = false
    private var finishing: URL?
    private var healthTimer: DispatchSourceTimer?

    private struct Active {
        let primaryURL: URL
        let url: URL
        let epoch: Double
        var evidence: SecondaryCameraEvidence
        var writer: AVAssetWriter?
        var input: AVAssetWriterInput?
        var endHostTime: Double?
    }

    override init() {
        super.init()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self, let device = self.device, self.previewReadyPublished,
                  !self.session.isRunning || CACurrentMediaTime() - self.latestFrameHostTime > 1 else { return }
            self.previewReadyPublished = false
            self.publish("Second camera is not sending frames; main camera can continue.", id: device.uniqueID, ready: false)
        }
        timer.resume()
        healthTimer = timer
    }

    deinit { healthTimer?.cancel() }

    func configure(device: AVCaptureDevice?, primaryID: String) {
        queue.async { [self] in
            guard active == nil, finishing == nil else { return }
            session.stopRunning()
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            session.outputs.forEach { session.removeOutput($0) }
            self.device = nil
            coordinator = nil
            rotationObservation = nil
            latestFrameHostTime = 0
            previewReadyPublished = false
            defer { session.commitConfiguration() }
            guard let device else {
                publish("Second camera is off", id: "", ready: false)
                return
            }
            guard device.uniqueID != primaryID else {
                publish("Choose a different camera from the main camera.", id: device.uniqueID, ready: false)
                return
            }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input), session.canAddOutput(output) else {
                    throw SecondaryCameraError("This camera cannot provide a second video stream.")
                }
                session.addInput(input)
                if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
                output.alwaysDiscardsLateVideoFrames = true
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                output.setSampleBufferDelegate(self, queue: queue)
                session.addOutput(output)
                self.device = device
                let rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
                coordinator = rotationCoordinator
                applyRotation(rotationCoordinator.videoRotationAngleForHorizonLevelCapture)
                rotationObservation = rotationCoordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] value, _ in
                    self?.queue.async { [weak self] in
                        guard let self, self.active == nil, self.finishing == nil else { return }
                        self.applyRotation(value.videoRotationAngleForHorizonLevelCapture)
                    }
                }
                publish("Connecting \(device.localizedName)…", id: device.uniqueID, ready: false)
                queue.async { [self] in session.startRunning() }
            } catch {
                publish(error.localizedDescription, id: device.uniqueID, ready: false)
            }
        }
    }

    private func applyRotation(_ angle: CGFloat) {
        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
            captureRotation = angle
            DispatchQueue.main.async { self.rotation = angle }
        }
    }

    func begin(primaryURL: URL, epoch: Double) {
        queue.async { [self] in
            guard active == nil, finishing == nil, let device else { return }
            let url = SecondaryCameraEvidence.url(beside: primaryURL)
            var evidence = SecondaryCameraEvidence(deviceID: device.uniqueID, deviceName: device.localizedName,
                rotationDegrees: Double(captureRotation), status: .unavailable)
            guard session.isRunning, epoch - latestFrameHostTime < 1, epoch >= latestFrameHostTime - 0.1 else {
                evidence.detail = "No recent second-camera frames at take start; main camera continued."
                frozen[primaryURL] = evidence
                publish(evidence.detail!, id: device.uniqueID, ready: false)
                return
            }
            evidence.status = .recording
            active = Active(primaryURL: primaryURL, url: url, epoch: epoch, evidence: evidence)
            publish("Recording \(device.localizedName)", id: device.uniqueID, ready: true)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let clock = session.masterClock else { return }
        let host = CMSyncConvertTime(CMSampleBufferGetPresentationTimeStamp(sampleBuffer), from: clock, to: CMClockGetHostTimeClock())
        let now = host.seconds
        guard now.isFinite else { return }
        latestFrameHostTime = now
        if !previewReadyPublished, let device, finishing == nil {
            previewReadyPublished = true
            publish(active == nil ? "Ready — \(device.localizedName)" : "Recording \(device.localizedName)",
                id: device.uniqueID, ready: true)
        }
        guard var take = active else { return }
        if let end = take.endHostTime, now > end { return }
        let relative = now - take.epoch
        guard relative >= 0, relative.isFinite else { return }
        if let last = take.evidence.lastFrameSeconds, relative <= last {
            take.evidence.droppedFrameCount += 1
            active = take
            return
        }
        do {
            if take.writer == nil {
                guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
                let size = CMVideoFormatDescriptionGetDimensions(format)
                let writer = try AVAssetWriter(outputURL: take.url, fileType: .mov)
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)
                ])
                input.expectsMediaDataInRealTime = true
                guard writer.canAdd(input) else { throw SecondaryCameraError("Second-camera video format is unsupported.") }
                writer.add(input)
                guard writer.startWriting() else { throw writer.error ?? SecondaryCameraError("Could not start second-camera file.") }
                writer.startSession(atSourceTime: .zero)
                take.writer = writer; take.input = input
            }
            guard let writer = take.writer, let input = take.input else { return }
            guard writer.status == .writing else { throw writer.error ?? SecondaryCameraError("Second-camera recording stopped unexpectedly.") }
            if input.isReadyForMoreMediaData {
                var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sampleBuffer),
                    presentationTimeStamp: CMTime(seconds: relative, preferredTimescale: 1_000_000), decodeTimeStamp: .invalid)
                var copy: CMSampleBuffer?
                guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer,
                    sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy) == noErr,
                    let copy, input.append(copy) else {
                    throw writer.error ?? SecondaryCameraError("Could not write second-camera frame.")
                }
                if let previous = take.evidence.lastFrameSeconds {
                    take.evidence.maximumFrameGapSeconds = max(take.evidence.maximumFrameGapSeconds, relative - previous)
                }
                if take.evidence.firstFrameSeconds == nil { take.evidence.firstFrameSeconds = relative }
                take.evidence.lastFrameSeconds = relative
                take.evidence.frameCount += 1
            } else { take.evidence.droppedFrameCount += 1 }
            active = take
        } catch {
            take.evidence.detail = error.localizedDescription
            take.evidence.status = .failed
            take.writer?.cancelWriting()
            frozen[take.primaryURL] = take.evidence
            active = nil
            publish("Second camera failed; main camera continues: \(error.localizedDescription)", id: take.evidence.deviceID, ready: false)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        active?.evidence.droppedFrameCount += 1
    }

    func end(primaryURL: URL, hostTime: Double) {
        queue.async { [self] in
            guard active?.primaryURL == primaryURL else { return }
            active?.endHostTime = hostTime
        }
    }

    /// Completes before the primary sidecar is sealed. No late attachment can
    /// mutate an already saved draft or bind this angle to the following take.
    func finish(primaryURL: URL, audioURL: URL?) async -> SecondaryCameraEvidence? {
        let fallback: SecondaryCameraEvidence? = await MainActor.run {
            guard !selectedID.isEmpty else { return nil }
            var evidence = SecondaryCameraEvidence(deviceID: selectedID, deviceName: selectedID,
                rotationDegrees: Double(rotation), status: .failed)
            evidence.detail = "Second-camera finalization timed out; the main recording was retained."
            return evidence
        }
        return await withCheckedContinuation { continuation in
            let gate = SecondaryCameraFinishGate { continuation.resume(returning: $0) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) { [weak self] in
                guard gate.complete(fallback) else { return }
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    var affected = false
                    if self.active?.primaryURL == primaryURL {
                        self.active?.writer?.cancelWriting()
                        self.active = nil
                        affected = true
                    }
                    if self.finishing == primaryURL { self.finishing = nil; affected = true }
                    self.frozen.removeValue(forKey: primaryURL)
                    if affected, let fallback { self.publish(fallback.detail!, id: fallback.deviceID, ready: false) }
                }
            }
            queue.async { [self] in
                guard !gate.isFinished else { return }
                if let result = frozen.removeValue(forKey: primaryURL) { gate.complete(result); return }
                guard let take = active, take.primaryURL == primaryURL else { gate.complete(nil); return }
                active = nil
                guard let writer = take.writer, let input = take.input else {
                    var evidence = take.evidence
                    evidence.status = .unavailable
                    evidence.detail = "No second-camera frames were recorded."
                    publish(evidence.detail!, id: evidence.deviceID, ready: false)
                    gate.complete(evidence)
                    return
                }
                finishing = primaryURL
                publish("Saving second camera…", id: take.evidence.deviceID, ready: false)
                input.markAsFinished()
                writer.finishWriting {
                    guard !gate.isFinished else { return }
                    Task {
                        var evidence = take.evidence
                        do {
                            guard writer.status == .completed else { throw writer.error ?? SecondaryCameraError("Second-camera file did not finish.") }
                            if let audioURL { try await Self.attachAudio(videoURL: take.url, audioURL: audioURL, gate: gate) }
                            guard !gate.isFinished else { return }
                            evidence.fileName = take.url.lastPathComponent
                            evidence.sha256 = ReferencePackageIO.sha256Hex(try Data(contentsOf: take.url))
                            evidence.status = .captured
                            let duration = (take.endHostTime ?? take.epoch) - take.epoch
                            if Self.hasIncompleteCoverage(evidence, duration: duration) {
                                evidence.status = .partial
                                evidence.detail = "Second camera contains missing frames or incomplete coverage; original timing is retained."
                            }
                        } catch {
                            evidence.status = .failed
                            evidence.fileName = nil
                            evidence.sha256 = nil
                            evidence.detail = error.localizedDescription
                        }
                        let result = evidence
                        self.queue.async {
                            guard self.finishing == primaryURL else { return }
                            self.finishing = nil
                            if gate.complete(result) {
                                self.publish(result.detail ?? "Second camera saved", id: result.deviceID,
                                    ready: self.session.isRunning && CACurrentMediaTime() - self.latestFrameHostTime < 1)
                                if let coordinator = self.coordinator {
                                    self.applyRotation(coordinator.videoRotationAngleForHorizonLevelCapture)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    static func hasIncompleteCoverage(_ evidence: SecondaryCameraEvidence, duration: Double) -> Bool {
        evidence.droppedFrameCount > 0 || evidence.maximumFrameGapSeconds > 0.2
            || (evidence.firstFrameSeconds ?? .infinity) > 0.2
            || duration - (evidence.lastFrameSeconds ?? 0) > 0.2
    }

    static func attachAudio(videoURL: URL, audioURL: URL, gate: SecondaryCameraFinishGate? = nil) async throws {
        let video = AVURLAsset(url: videoURL), audio = AVURLAsset(url: audioURL)
        guard let v = try await video.loadTracks(withMediaType: .video).first,
              let a = try await audio.loadTracks(withMediaType: .audio).first else { throw SecondaryCameraError("Missing second-camera video or take audio.") }
        let composition = AVMutableComposition()
        guard let vt = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let at = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw SecondaryCameraError("Could not combine second-camera media.") }
        let vr = try await v.load(.timeRange), ar = try await a.load(.timeRange)
        let end = CMTimeMinimum(CMTimeRangeGetEnd(vr), CMTimeRangeGetEnd(ar))
        guard end > vr.start else { throw SecondaryCameraError("Second camera has no overlap with recorded audio.") }
        try vt.insertTimeRange(CMTimeRange(start: vr.start, end: end), of: v, at: vr.start)
        vt.preferredTransform = try await v.load(.preferredTransform)
        try at.insertTimeRange(CMTimeRange(start: .zero, end: end), of: a, at: .zero)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { throw SecondaryCameraError("Could not finish second-camera audio.") }
        let temp = videoURL.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: temp) }
        try await exporter.export(to: temp, as: .mov)
        try Task.checkCancellation()
        let commit = { _ = try FileManager.default.replaceItemAt(videoURL, withItemAt: temp) }
        if let gate { try gate.commitIfPending(commit) } else { try commit() }
    }

    private func publish(_ text: String, id: String, ready: Bool) {
        DispatchQueue.main.async {
            if self.status != text { self.status = text }
            if self.selectedID != id { self.selectedID = id }
            if self.ready != ready { self.ready = ready }
        }
    }
}

struct SecondaryCameraError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct SecondaryCameraSetupView: View {
    @ObservedObject var recorder: SecondaryCameraRecorder
    let devices: [AVCaptureDevice]
    let primaryID: String
    let locked: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Second camera (optional)", selection: Binding(get: { recorder.selectedID }, set: { id in
                recorder.configure(device: devices.first { $0.uniqueID == id }, primaryID: primaryID)
            })) {
                Text("Off — main camera only").tag("")
                ForEach(devices.filter { $0.uniqueID != primaryID }, id: \.uniqueID) { device in
                    Text(device.deviceType == .deskViewCamera ? "\(device.localizedName) (processed overhead)" : device.localizedName).tag(device.uniqueID)
                }
            }.disabled(locked)
            Text("For an iPhone body view, mount it upright in portrait with your upper body and decks visible. Use Continuity Camera on the same Apple Account; a USB cable can help with connection. Keep the main landscape camera aimed at your hands and fader.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Continuity Camera keeps the iPhone locked. Watch relay from that same phone is not verified for this setup; use another camera if you also need the paired iPhone to relay Watch motion. Watch motion is optional.")
                .font(.caption).foregroundStyle(.secondary)
            Text(recorder.status).font(.caption).foregroundStyle(recorder.ready ? Color.secondary : Color.orange)
            if !recorder.selectedID.isEmpty {
                SecondaryCameraPreview(recorder: recorder).frame(width: 180, height: 320)
                Text("Both cameras start and stop with the Mac. A missing second camera does not stop the main take.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.onChange(of: primaryID) { _, value in
            if value == recorder.selectedID { recorder.configure(device: nil, primaryID: value) }
        }
    }
}

struct SecondaryCameraPreview: NSViewRepresentable {
    @ObservedObject var recorder: SecondaryCameraRecorder
    final class Preview: NSView {
        let preview = AVCaptureVideoPreviewLayer()
        override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer = preview; preview.videoGravity = .resizeAspect }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    }
    func makeNSView(context: Context) -> Preview { let v = Preview(); v.preview.session = recorder.session; return v }
    func updateNSView(_ view: Preview, context: Context) {
        if let connection = view.preview.connection {
            if connection.isVideoRotationAngleSupported(recorder.rotation) { connection.videoRotationAngle = recorder.rotation }
            if connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false }
        }
    }
}

struct SecondaryCameraLiveView: View {
    @ObservedObject var recorder: SecondaryCameraRecorder
    var body: some View {
        if !recorder.selectedID.isEmpty {
            HStack {
                SecondaryCameraPreview(recorder: recorder).frame(width: 180, height: 320)
                Text(recorder.status).font(.caption)
            }
        }
    }
}

/// A timeout and writer callback may race; only one may publish the result.
/// A late mux is never allowed to replace media after the take has finalized.
final class SecondaryCameraFinishGate: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((SecondaryCameraEvidence?) -> Void)?
    init(_ callback: @escaping (SecondaryCameraEvidence?) -> Void) { self.callback = callback }
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return callback == nil }
    @discardableResult
    func complete(_ evidence: SecondaryCameraEvidence?) -> Bool {
        lock.lock()
        let action = callback
        callback = nil
        lock.unlock()
        action?(evidence)
        return action != nil
    }
    func commitIfPending(_ action: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard callback != nil else { throw CancellationError() }
        try action()
    }
}
