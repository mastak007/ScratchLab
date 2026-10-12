import AVFoundation
import CoreAudio
import CryptoKit
import Foundation

/// Shared, input-only HAL client. Never changes the S9 sample rate, routing,
/// default device or output. All file I/O and decoding happen off the IOProc.
final class PhaseS9InputCapture: @unchecked Sendable {
    struct Snapshot: Sendable {
        var acceptedBuffers = 0
        var lastAcceptedHostSeconds: Double?
        var lastBufferHostSeconds: Double?
        var programmePeak: Float?
        var polarity: PhaseDVSRecordingEvidence.Polarity?
        var error: String?
    }
    enum Failure: LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            if case .unavailable(let message) = self { return message }
            return nil
        }
    }
    struct Result {
        let audioURL: URL
        let frames: Int
        let samples: [Float]
        let evidence: PhaseDVSRecordingEvidence
    }
    private final class InputContext {
        let ring = TimecodeRealtimeIngressRing(configuration: .production)
    }
    private struct Take {
        let destination: URL
        let stagingURL: URL
        let controlURL: URL
        let sessionID: String
        let takeID: String
        let polarity: PhaseDVSRecordingEvidence.Polarity
        let maximumFrames: Int
        var control: AVAudioFile?
        var programme: AVAudioFile?
        var blocks: [PhaseDVSRecordingEvidence.Block] = []
        var frames = 0
        var failure: String?
    }

    let deviceUID: String
    let connectionID = UUID()
    private let device: AudioDeviceID
    private let context = InputContext()
    private var proc: AudioDeviceIOProcID?
    private var worker: TimecodeRealtimeIngressWorker?
    private let lock = NSLock()
    private var state = Snapshot()
    private var take: Take?
    private var checkSigns: [Int]?
    private var previewBlocks: [PhaseDVSRecordingEvidence.Block] = []
    private let decoder = TimecodePhaseDecoder()
    private var stabilityState = TimecodeStabilityFilterState()
    private let stability = TimecodeMotionStabilityFilter(config: .init(minConfidenceForUpdate: PhaseDVSRecordingEvidence.minimumConfidence))
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!

    init(deviceUID: String) throws {
        self.deviceUID = deviceUID
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            throw Failure.unavailable("Cannot enumerate audio inputs.")
        }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = devices.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr, let device = devices.first(where: { Self.uid($0) == deviceUID }) else {
            throw Failure.unavailable("The selected DJM-S9 input disconnected.")
        }
        self.device = device
        var asbd = AudioStreamBasicDescription()
        address = .init(mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        size = UInt32(MemoryLayout.size(ofValue: asbd))
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &asbd) == noErr,
              asbd.mFormatID == kAudioFormatLinearPCM, asbd.mSampleRate == 48_000,
              asbd.mChannelsPerFrame == 8, asbd.mBitsPerChannel == 32,
              asbd.mBytesPerFrame == 32, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mFormatFlags & (kAudioFormatFlagIsBigEndian | kAudioFormatFlagIsNonInterleaved) == 0 else {
            throw Failure.unavailable("Phase B capture requires the verified S9 48 kHz, eight-channel Float32 input format. No device settings were changed.")
        }
    }

    func start() throws {
        guard proc == nil else { return }
        worker = TimecodeRealtimeIngressWorker(ring: context.ring,
            queueLabel: "com.scratchlab.phase-s9-input") { [weak self] slot in self?.consume(slot) }
        let status = AudioDeviceCreateIOProcID(device, { _, _, input, stamp, _, _, context in
            guard let context else { return noErr }
            let owner = Unmanaged<InputContext>.fromOpaque(context).takeUnretainedValue()
            owner.ring.publishInterleaved(bufferList: input, channelCount: 8,
                sampleRate: 48_000, timestamp: stamp.pointee)
            return noErr
        }, Unmanaged.passRetained(context).toOpaque(), &proc)
        guard status == noErr, let proc else {
            Unmanaged.passUnretained(context).release()
            worker?.stop(); worker = nil
            throw Failure.unavailable("DJM-S9 input could not open (\(status)).")
        }
        let started = AudioDeviceStart(device, proc)
        guard started == noErr else {
            if AudioDeviceDestroyIOProcID(device, proc) == noErr {
                Unmanaged.passUnretained(context).release(); self.proc = nil
            }
            worker?.stop(); worker = nil
            throw Failure.unavailable("DJM-S9 input could not start (\(started)).")
        }
    }

    func stop() throws {
        if let proc {
            let status = AudioDeviceStop(device, proc)
            guard status == noErr else { throw Failure.unavailable("DJM-S9 input stop failed (\(status)).") }
            let destroyed = AudioDeviceDestroyIOProcID(device, proc)
            guard destroyed == noErr else { throw Failure.unavailable("DJM-S9 callback removal failed (\(destroyed)).") }
            Unmanaged.passUnretained(context).release()
            self.proc = nil
        }
        worker?.stop(); worker = nil
        lock.lock(); defer { lock.unlock() }
        state.polarity = nil
        checkSigns = nil
        take?.failure = "Input stopped before finalization."
    }

    deinit {
        // An unsuccessful HAL detach intentionally retains the callback context.
        // It must never become a dangling realtime pointer.
        try? stop()
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    func beginForwardCheck() {
        lock.lock(); defer { lock.unlock() }
        guard take == nil else { return }
        checkSigns = []
        state.polarity = nil
        previewBlocks = []
    }

    func confirmForwardCheck() throws {
        lock.lock(); defer { lock.unlock() }
        guard let signs = checkSigns, signs.count >= 20, let sign = signs.first,
              signs.allSatisfy({ $0 == sign }), state.error == nil else {
            throw Failure.unavailable("Keep the right platter moving forward steadily, then confirm again. No full revolution is needed.")
        }
        state.polarity = .init(deviceUID: deviceUID, connectionID: connectionID,
            decoderForwardSign: sign, confirmedAt: Date(), acceptedBufferCount: signs.count)
        checkSigns = nil
    }

    func begin(destination: URL, sessionID: String, takeID: String, maximumDuration: Double) throws {
        lock.lock(); defer { lock.unlock() }
        guard take == nil, proc != nil, let polarity = state.polarity, state.error == nil,
              maximumDuration.isFinite, maximumDuration > 0, maximumDuration <= 195 else {
            throw Failure.unavailable("Phase input is not ready: check the S9 route and confirm forward direction before recording.")
        }
        let root = destination.deletingPathExtension()
        let staging = root.appendingPathExtension("phase-programme.wav")
        let control = root.appendingPathExtension("phase-control.wav")
        guard !FileManager.default.fileExists(atPath: staging.path),
              !FileManager.default.fileExists(atPath: control.path) else {
            throw Failure.unavailable("This take already has Phase audio; refusing to overwrite it.")
        }
        take = Take(destination: destination, stagingURL: staging, controlURL: control,
            sessionID: sessionID, takeID: takeID, polarity: polarity,
            maximumFrames: Int(maximumDuration * 48_000),
            control: try AVAudioFile(forWriting: control, settings: format.settings),
            programme: try AVAudioFile(forWriting: staging, settings: format.settings))
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        // Retain interrupted source files for diagnosis; no incomplete take is
        // promoted into the saved/reference pipeline.
        take = nil
    }

    private func consume(_ slot: TimecodeRealtimeIngressSlotView) {
        let channels = (2...5).map { Array(slot.samples(forChannel: $0)) }
        let finite = channels.allSatisfy { $0.allSatisfy(\.isFinite) }
        let result = finite ? decoder.decode([.init(left: channels[0], right: channels[1],
            sampleRate: slot.sampleRate, hostTime: slot.hostTime,
            relativeTime: AVAudioTime.seconds(forHostTime: slot.hostTime))]) : nil
        let filtered = stability.filter(frames: result?.frames ?? [], state: stabilityState,
            flushRelativeTime: AVAudioTime.seconds(forHostTime: slot.hostTime))
        stabilityState = filtered.state
        let frame = result?.frames.first
        // Preserve raw displacement only when the existing stability filter
        // admits the frame. Smoothing never invents a trajectory or a hold.
        let accepted = !filtered.accepted.isEmpty && result?.signalHealth == .usable && frame?.direction != .unknown
            && (frame?.confidence ?? 0) >= PhaseDVSRecordingEvidence.minimumConfidence
        let delta = accepted ? frame?.deltaPosition : nil
        let host = AVAudioTime.seconds(forHostTime: slot.hostTime)
        lock.lock(); defer { lock.unlock() }
        if context.ring.droppedCount > 0 || context.ring.rejectedCount > 0 || !finite {
            state.error = "S9 input lost or rejected samples; reconnect before recording."
            take?.failure = state.error
        }
        state.lastBufferHostSeconds = host
        state.programmePeak = finite ? channels[2...3].flatMap { $0 }.map { abs($0) }.max() : nil
        if let delta, delta.isFinite, delta != 0 {
            state.acceptedBuffers += 1
            state.lastAcceptedHostSeconds = host
            if checkSigns != nil {
                let sign = delta > 0 ? 1 : -1
                if checkSigns?.last != sign { checkSigns = [] }
                checkSigns?.append(sign)
                if checkSigns!.count > 400 { checkSigns?.removeFirst() }
            }
        } else if checkSigns != nil { checkSigns = [] }
        let block = PhaseDVSRecordingEvidence.Block(start: host, duration: Double(slot.frameCount) / 48_000,
            rawFrameOffset: 0, frameCount: slot.frameCount, sampleTime: Double(slot.sampleTime),
            hostTime: slot.hostTime, confidence: frame?.confidence ?? 0, delta: delta,
            rejection: delta == nil ? (result?.dropoutReason?.rawValue ?? "untrusted_direction_or_confidence") : nil)
        if let previous = previewBlocks.last,
           (block.sampleTime != previous.sampleTime + Double(previous.frameCount) || block.hostTime <= previous.hostTime) {
            state.error = "S9 input clock continuity failed; reconnect before recording."
            take?.failure = state.error
        }
        previewBlocks.append(block)
        if previewBlocks.count > 1200 { previewBlocks.removeFirst(previewBlocks.count - 1200) }
        guard var recording = take, recording.failure == nil else { return }
        defer { take = recording }
        guard finite, recording.blocks.count < 40_000, recording.frames + slot.frameCount <= recording.maximumFrames else {
            recording.failure = "Phase recording exceeded its bound or received nonfinite audio."; return
        }
        do {
            for (pair, file) in [(0, recording.control), (2, recording.programme)] {
                guard let file, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(slot.frameCount)),
                      let target = pcm.floatChannelData else { throw Failure.unavailable("Cannot allocate S9 audio buffer.") }
                pcm.frameLength = pcm.frameCapacity
                for channel in 0..<2 {
                    channels[pair + channel].withUnsafeBufferPointer { target[channel].update(from: $0.baseAddress!, count: slot.frameCount) }
                }
                try file.write(from: pcm)
            }
            recording.blocks.append(.init(start: host, duration: Double(slot.frameCount) / 48_000,
                rawFrameOffset: recording.frames, frameCount: slot.frameCount,
                sampleTime: Double(slot.sampleTime), hostTime: slot.hostTime,
                confidence: frame?.confidence ?? 0, delta: delta,
                rejection: delta == nil ? (result?.dropoutReason?.rawValue ?? "untrusted_direction_or_confidence") : nil))
            recording.frames += slot.frameCount
        } catch { recording.failure = error.localizedDescription }
    }

    func liveMotion(mediaStart: Double?) -> CaptureCore.PlatterMotionEvidence {
        lock.lock(); defer { lock.unlock() }
        let empty = CaptureCore.PlatterMotionEvidence(events: [], intervals: [], trajectorySegments: [])
        guard let polarity = state.polarity, state.error == nil else { return empty }
        let original = mediaStart != nil ? (take?.blocks ?? []) : previewBlocks
        guard let first = original.first, let last = original.last else { return empty }
        let origin = mediaStart ?? first.start
        let blocks = original.map { block in
            PhaseDVSRecordingEvidence.Block(start: first.start - origin + (block.sampleTime - first.sampleTime) / 48_000,
                duration: block.duration, rawFrameOffset: block.rawFrameOffset, frameCount: block.frameCount,
                sampleTime: block.sampleTime, hostTime: block.hostTime, confidence: block.confidence,
                delta: block.delta, rejection: block.rejection)
        }
        let duration = first.start - origin + (last.sampleTime - first.sampleTime + Double(last.frameCount)) / 48_000
        return PhaseDVSRecordingEvidence.project(blocks: blocks, duration: duration, forwardSign: polarity.decoderForwardSign)
    }

    func finish(mediaStart: Double, duration: Double) throws -> Result {
        lock.lock()
        guard var recording = take else { lock.unlock(); throw Failure.unavailable("Phase recorder was not armed.") }
        take = nil
        lock.unlock()
        recording.control = nil; recording.programme = nil
        return try Self.finalize(recording, deviceUID: deviceUID, connectionID: connectionID,
            mediaStart: mediaStart, duration: duration)
    }

    private static func finalize(_ recording: Take, deviceUID: String, connectionID: UUID,
                                 mediaStart: Double, duration: Double) throws -> Result {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        if let failure = recording.failure { throw Failure.unavailable(failure) }
        let firstHost = recording.blocks.first?.start ?? .nan
        let blocks = recording.blocks.map {
            PhaseDVSRecordingEvidence.Block(start: firstHost - mediaStart + Double($0.rawFrameOffset) / 48_000, duration: $0.duration,
                rawFrameOffset: $0.rawFrameOffset, frameCount: $0.frameCount,
                sampleTime: $0.sampleTime, hostTime: $0.hostTime, confidence: $0.confidence,
                delta: $0.delta, rejection: $0.rejection)
        }
        let rawData = try Data(contentsOf: recording.controlURL, options: .mappedIfSafe)
        let evidence = PhaseDVSRecordingEvidence(version: 1, sessionID: recording.sessionID,
            takeID: recording.takeID, deviceUID: deviceUID, connectionID: connectionID,
            sampleRate: 48_000, controlChannels: [3,4], programmeChannels: [5,6],
            rawControlFileName: recording.controlURL.lastPathComponent,
            rawControlSHA256: SHA256.hash(data: rawData).map { String(format: "%02x", $0) }.joined(),
            rawFrameCount: recording.frames, mediaDuration: duration,
            mediaStartHostSeconds: mediaStart, firstAudioHostSeconds: firstHost,
            polarity: recording.polarity, blocks: blocks)
        try evidence.validate()
        guard mediaStart.isFinite, let first = blocks.first else { throw Failure.unavailable("No S9 audio covered the movie.") }
        let offset = Int((-first.start * 48_000).rounded())
        let count = Int((duration * 48_000).rounded())
        guard offset >= 0, count > 0, offset + count <= recording.frames else {
            throw Failure.unavailable("S9 audio did not cover the complete camera recording.")
        }
        let source = try AVAudioFile(forReading: recording.stagingURL)
        guard source.length == recording.frames, source.fileFormat.sampleRate == 48_000,
              source.fileFormat.channelCount == 2, source.fileFormat.commonFormat == .pcmFormatFloat32 else {
            throw Failure.unavailable("Captured programme audio is truncated or its format changed.")
        }
        _ = try evidence.verifiedControlURL(beside: recording.destination)
        source.framePosition = AVAudioFramePosition(offset)
        let target = try AVAudioFile(forWriting: recording.destination, settings: format.settings)
        var mono: [Float] = []; mono.reserveCapacity(count)
        var remaining = count
        while remaining > 0 {
            let n = min(8192, remaining)
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else {
                throw Failure.unavailable("Cannot prepare captured programme audio.")
            }
            try source.read(into: pcm, frameCount: AVAudioFrameCount(n))
            guard pcm.frameLength == n, let channels = pcm.floatChannelData else {
                throw Failure.unavailable("Captured programme audio is truncated.")
            }
            try target.write(from: pcm)
            for i in 0..<n { mono.append((channels[0][i] + channels[1][i]) * 0.5) }
            remaining -= n
        }
        return Result(audioURL: recording.destination, frames: count, samples: mono, evidence: evidence)
    }

    #if DEBUG
    /// File-only seam runs the actual camera/audio finalizer without HAL or
    /// microphone access. Callback starts supplied here are absolute host seconds.
    static func testOnly_finalizeRecordedInput(
        programmeURL: URL, controlURL: URL, destination: URL,
        evidence: PhaseDVSRecordingEvidence, mediaStart: Double
    ) throws -> Result {
        let recording = Take(destination: destination, stagingURL: programmeURL, controlURL: controlURL,
            sessionID: evidence.sessionID, takeID: evidence.takeID, polarity: evidence.polarity,
            maximumFrames: evidence.rawFrameCount, control: nil, programme: nil,
            blocks: evidence.blocks, frames: evidence.rawFrameCount, failure: nil)
        return try finalize(recording, deviceUID: evidence.deviceUID, connectionID: evidence.connectionID,
            mediaStart: mediaStart, duration: evidence.mediaDuration)
    }
    #endif

    private static func uid(_ device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: value))
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        return status == noErr ? value?.takeUnretainedValue() as String? : nil
    }
}
