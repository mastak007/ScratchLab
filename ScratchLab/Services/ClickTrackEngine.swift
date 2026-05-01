import AVFoundation
import Darwin
import Foundation

struct ClickTrackStartMetadata: Equatable, Sendable {
    let bpm: Int
    let countInBeats: Int
    let beatsPerBar: Int
    let clickStartHostTime: UInt64
    let recordingStartHostTime: UInt64
    let clickAccentPattern: String
    let clickVersion: String
}

enum ClickTrackEngineError: LocalizedError {
    case unableToStartAudio

    var errorDescription: String? {
        switch self {
        case .unableToStartAudio:
            return "ScratchLab could not start the click track audio engine."
        }
    }
}

final class ClickTrackEngine: ObservableObject {
    private static let preRollLeadInSeconds = 0.12
    private static let scheduledBeatHorizon = 16
    private static let clickDurationSeconds = 0.018
    private static let internalSampleRate = 48_000.0

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let schedulingQueue = DispatchQueue(label: "scratchlab.clicktrack.engine")

    private var accentBeatBuffer: AVAudioPCMBuffer?
    private var normalBeatBuffer: AVAudioPCMBuffer?
    private var playerFormat = AVAudioFormat(
        standardFormatWithSampleRate: internalSampleRate,
        channels: 1
    )
    private var beatFrameLength: AVAudioFramePosition = 0
    private var scheduledBeatCount = 0
    private var consumedBeatCount = 0
    private var activeGeneration = UUID()
    private var isRunning = false
    private var beatDurationSeconds = 0.5
    private var pendingUIWorkItems: [DispatchWorkItem] = []

    init() {
        audioEngine.attach(playerNode)
        if let playerFormat {
            audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: playerFormat)
        }
        audioEngine.prepare()
    }

    deinit {
        stop()
    }

    static func currentHostTime() -> UInt64 {
        mach_absolute_time()
    }

    func start(
        bpm requestedBPM: Int,
        onCountInBeat: ((Int) -> Void)? = nil,
        onRecordingStart: (() -> Void)? = nil
    ) throws -> ClickTrackStartMetadata {
        stop()

        let bpm = CaptureClickTrackDefaults.clampedBPM(requestedBPM)
        let beatDurationSeconds = 60.0 / Double(bpm)
        let startDelay = Self.preRollLeadInSeconds
        let clickStartHostTime = Self.currentHostTime() + AVAudioTime.hostTime(forSeconds: startDelay)
        let recordingStartHostTime = clickStartHostTime
            + AVAudioTime.hostTime(forSeconds: Double(CaptureClickTrackDefaults.countInBeats) * beatDurationSeconds)
        let sampleRate = resolvedSampleRate()

        do {
            try configurePlayerFormat(sampleRate: sampleRate)
            if !audioEngine.isRunning {
                try audioEngine.start()
            }
        } catch {
            throw ClickTrackEngineError.unableToStartAudio
        }

        accentBeatBuffer = makeBeatBuffer(sampleRate: sampleRate, bpm: bpm, accent: true)
        normalBeatBuffer = makeBeatBuffer(sampleRate: sampleRate, bpm: bpm, accent: false)
        guard accentBeatBuffer != nil, normalBeatBuffer != nil else {
            stop()
            throw ClickTrackEngineError.unableToStartAudio
        }
        beatFrameLength = AVAudioFramePosition(accentBeatBuffer?.frameLength ?? 0)
        guard beatFrameLength > 0 else {
            stop()
            throw ClickTrackEngineError.unableToStartAudio
        }

        let generation = UUID()
        let metadata = ClickTrackStartMetadata(
            bpm: bpm,
            countInBeats: CaptureClickTrackDefaults.countInBeats,
            beatsPerBar: CaptureClickTrackDefaults.beatsPerBar,
            clickStartHostTime: clickStartHostTime,
            recordingStartHostTime: recordingStartHostTime,
            clickAccentPattern: CaptureClickTrackDefaults.clickAccentPattern,
            clickVersion: CaptureClickTrackDefaults.clickVersion
        )

        schedulingQueue.sync {
            self.activeGeneration = generation
            self.isRunning = true
            self.beatDurationSeconds = beatDurationSeconds
            self.scheduledBeatCount = 0
            self.consumedBeatCount = 0
            self.scheduleBeatsIfNeeded()
        }

        playerNode.play(at: AVAudioTime(hostTime: clickStartHostTime))
        scheduleUICallbacks(
            generation: generation,
            metadata: metadata,
            onCountInBeat: onCountInBeat,
            onRecordingStart: onRecordingStart
        )
        return metadata
    }

    func stop() {
        cancelPendingUICallbacks()

        schedulingQueue.sync {
            self.activeGeneration = UUID()
            self.isRunning = false
            self.scheduledBeatCount = 0
            self.consumedBeatCount = 0
            self.beatFrameLength = 0
        }

        playerNode.stop()
        playerNode.reset()
        if audioEngine.isRunning {
            audioEngine.stop()
        }
    }

    private func resolvedSampleRate() -> Double {
        let sampleRate = audioEngine.outputNode.outputFormat(forBus: 0).sampleRate
        return sampleRate > 0 ? sampleRate : 48_000
    }

    private func configurePlayerFormat(sampleRate: Double) throws {
        guard let requestedFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        ) else {
            throw ClickTrackEngineError.unableToStartAudio
        }

        guard playerFormat?.sampleRate != requestedFormat.sampleRate else { return }

        playerNode.stop()
        audioEngine.disconnectNodeOutput(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: requestedFormat)
        playerFormat = requestedFormat
    }

    private func makeBeatBuffer(sampleRate: Double, bpm: Int, accent: Bool) -> AVAudioPCMBuffer? {
        let beatFrameCount = max(1, Int((60.0 / Double(bpm) * sampleRate).rounded()))
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(beatFrameCount)
              ),
              let channelData = buffer.floatChannelData?.pointee else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(beatFrameCount)
        channelData.initialize(repeating: 0, count: beatFrameCount)
        let clickSamples = Self.clickSamples(sampleRate: sampleRate, accent: accent)
        clickSamples.withUnsafeBufferPointer { samples in
            guard let baseAddress = samples.baseAddress else { return }
            memcpy(
                channelData,
                baseAddress,
                min(beatFrameCount, samples.count) * MemoryLayout<Float>.size
            )
        }

        return buffer
    }

    static func renderedClickTrackBuffer(
        bpm requestedBPM: Int,
        durationSeconds: Double,
        sampleRate: Double,
        channelCount: AVAudioChannelCount,
        startBeatIndex: Int
    ) throws -> AVAudioPCMBuffer {
        let bpm = CaptureClickTrackDefaults.clampedBPM(requestedBPM)
        let totalFrameCount = max(1, Int(ceil(max(0, durationSeconds) * sampleRate)))
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: channelCount
        ),
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(totalFrameCount)
        ),
        let channelData = buffer.floatChannelData else {
            throw ClickTrackEngineError.unableToStartAudio
        }

        buffer.frameLength = AVAudioFrameCount(totalFrameCount)
        for channel in 0..<Int(channelCount) {
            channelData[channel].initialize(repeating: 0, count: totalFrameCount)
        }

        let beatFrameCount = max(1, Int((60.0 / Double(bpm) * sampleRate).rounded()))
        let accentSamples = clickSamples(sampleRate: sampleRate, accent: true)
        let normalSamples = clickSamples(sampleRate: sampleRate, accent: false)
        var beatIndex = startBeatIndex
        var startFrame = 0

        while startFrame < totalFrameCount {
            let sourceSamples = (beatIndex % CaptureClickTrackDefaults.beatsPerBar == 0)
                ? accentSamples
                : normalSamples
            for frameOffset in 0..<sourceSamples.count {
                let frameIndex = startFrame + frameOffset
                guard frameIndex < totalFrameCount else { break }
                let sample = sourceSamples[frameOffset]
                for channel in 0..<Int(channelCount) {
                    channelData[channel][frameIndex] += sample
                }
            }
            beatIndex += 1
            startFrame += beatFrameCount
        }

        return buffer
    }

    private static func clickSamples(sampleRate: Double, accent: Bool) -> [Float] {
        let clickFrameCount = max(1, Int((clickDurationSeconds * sampleRate).rounded()))
        let frequency = accent ? 1_960.0 : 1_320.0
        let amplitude: Float = accent ? 0.55 : 0.35

        return (0..<clickFrameCount).map { frame in
            let time = Double(frame) / sampleRate
            let envelope = exp(-time * 85.0)
            let sample = sin(2.0 * .pi * frequency * time) * envelope
            return Float(sample) * amplitude
        }
    }

    private func scheduleBeatsIfNeeded() {
        while isRunning, scheduledBeatCount - consumedBeatCount < Self.scheduledBeatHorizon {
            scheduleBeat(at: scheduledBeatCount, generation: activeGeneration)
            scheduledBeatCount += 1
        }
    }

    private func scheduleBeat(at beatIndex: Int, generation: UUID) {
        guard let accentBeatBuffer, let normalBeatBuffer else { return }
        guard let playerFormat else { return }
        let beatInBar = beatIndex % CaptureClickTrackDefaults.beatsPerBar
        let buffer = beatInBar == 0 ? accentBeatBuffer : normalBeatBuffer
        let sampleTime = AVAudioFramePosition(beatIndex) * beatFrameLength

        playerNode.scheduleBuffer(
            buffer,
            at: AVAudioTime(sampleTime: sampleTime, atRate: playerFormat.sampleRate),
            options: [],
            completionCallbackType: .dataConsumed
        ) { [weak self] _ in
            guard let self else { return }
            self.schedulingQueue.async {
                guard self.isRunning, self.activeGeneration == generation else { return }
                self.consumedBeatCount += 1
                self.scheduleBeatsIfNeeded()
            }
        }
    }

    private func scheduleUICallbacks(
        generation: UUID,
        metadata: ClickTrackStartMetadata,
        onCountInBeat: ((Int) -> Void)?,
        onRecordingStart: (() -> Void)?
    ) {
        cancelPendingUICallbacks()

        for beatIndex in 0..<metadata.countInBeats {
            let beatNumber = (beatIndex % metadata.beatsPerBar) + 1
            let workItem = DispatchWorkItem { [weak self] in
                guard self?.activeGeneration == generation else { return }
                onCountInBeat?(beatNumber)
            }
            pendingUIWorkItems.append(workItem)
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.preRollLeadInSeconds + (Double(beatIndex) * beatDurationSeconds),
                execute: workItem
            )
        }

        let recordingStartItem = DispatchWorkItem { [weak self] in
            guard self?.activeGeneration == generation else { return }
            onRecordingStart?()
        }
        pendingUIWorkItems.append(recordingStartItem)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.preRollLeadInSeconds + (Double(metadata.countInBeats) * beatDurationSeconds),
            execute: recordingStartItem
        )
    }

    private func cancelPendingUICallbacks() {
        pendingUIWorkItems.forEach { $0.cancel() }
        pendingUIWorkItems.removeAll()
    }
}
