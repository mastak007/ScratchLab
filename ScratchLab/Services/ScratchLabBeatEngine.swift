import AVFoundation
import Darwin
import Foundation

protocol ClickTrackTimingEngine: AnyObject {
    func start(
        bpm requestedBPM: Int,
        onCountInBeat: ((Int) -> Void)?,
        onRecordingStart: (() -> Void)?
    ) throws -> ClickTrackStartMetadata
    func stop()
}

extension ClickTrackEngine: ClickTrackTimingEngine {}

struct BeatEngineStartMetadata: Equatable, Sendable {
    let bpm: Int
    let countInBeats: Int
    let beatsPerBar: Int
    let clickStartHostTime: UInt64
    let recordingStartHostTime: UInt64
    let clickAccentPattern: String
    let clickVersion: String
    let beatEngineMode: BeatEngineMode
    let beatEnabled: Bool
    let beatPatternName: String?
    let beatPatternVersion: String
    let swingAmount: Double
    let engineVersion: String
}

enum ScratchLabBeatEngineError: LocalizedError {
    case unableToStartAudio

    var errorDescription: String? {
        switch self {
        case .unableToStartAudio:
            return "ScratchLab could not start the beat engine."
        }
    }
}

final class ScratchLabBeatEngine: ObservableObject {
    private struct StepVoicing {
        let kick: Bool
        let snare: Bool
        let hat: Bool

        static let silent = StepVoicing(kick: false, snare: false, hat: false)
    }

    private static let preRollLeadInSeconds = 0.12
    private static let scheduledStepHorizon = 64

    private let clickTrackEngine: ClickTrackTimingEngine
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let schedulingQueue = DispatchQueue(label: "scratchlab.beatengine.scheduler")

    private var playerFormat = AVAudioFormat(
        standardFormatWithSampleRate: 48_000,
        channels: 1
    )
    private var currentMode: BeatEngineMode = .silent
    private var currentBPM = CaptureClickTrackDefaults.defaultTimedBPM
    private var currentSwingAmount = 0.0
    private var stepBuffers: [AVAudioPCMBuffer] = []
    private var beatFrameLength: AVAudioFramePosition = 0
    private var framesPerBar: AVAudioFramePosition = 0
    private var swingFrameOffset: AVAudioFramePosition = 0
    private var scheduledStepCount = 0
    private var consumedStepCount = 0
    private var activeGeneration = UUID()
    private var isRunning = false
    private var pendingUIWorkItems: [DispatchWorkItem] = []

    init(clickTrackEngine: ClickTrackTimingEngine = ClickTrackEngine()) {
        self.clickTrackEngine = clickTrackEngine
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
        ClickTrackEngine.currentHostTime()
    }

    func start(
        mode: BeatEngineMode,
        bpm requestedBPM: Int,
        onCountInBeat: ((Int) -> Void)? = nil,
        onRecordingStart: (() -> Void)? = nil
    ) throws -> BeatEngineStartMetadata {
        stop()

        let bpm = CaptureClickTrackDefaults.clampedBPM(requestedBPM)
        if mode == .clickTrack {
            let clickMetadata = try clickTrackEngine.start(
                bpm: bpm,
                onCountInBeat: onCountInBeat,
                onRecordingStart: onRecordingStart
            )
            return BeatEngineStartMetadata(
                bpm: clickMetadata.bpm,
                countInBeats: clickMetadata.countInBeats,
                beatsPerBar: clickMetadata.beatsPerBar,
                clickStartHostTime: clickMetadata.clickStartHostTime,
                recordingStartHostTime: clickMetadata.recordingStartHostTime,
                clickAccentPattern: clickMetadata.clickAccentPattern,
                clickVersion: clickMetadata.clickVersion,
                beatEngineMode: .clickTrack,
                beatEnabled: false,
                beatPatternName: nil,
                beatPatternVersion: CaptureBeatEngineDefaults.beatPatternVersion,
                swingAmount: 0,
                engineVersion: CaptureBeatEngineDefaults.engineVersion
            )
        }

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
            throw ScratchLabBeatEngineError.unableToStartAudio
        }

        currentMode = mode
        currentBPM = bpm
        currentSwingAmount = mode.defaultSwingAmount
        stepBuffers = makeStepBuffers(mode: mode, sampleRate: sampleRate)
        guard !stepBuffers.isEmpty else {
            stop()
            throw ScratchLabBeatEngineError.unableToStartAudio
        }

        beatFrameLength = max(1, AVAudioFramePosition((60.0 / Double(bpm) * sampleRate).rounded()))
        framesPerBar = beatFrameLength * AVAudioFramePosition(CaptureClickTrackDefaults.beatsPerBar)
        swingFrameOffset = mode == .minimalFunk
            ? AVAudioFramePosition((Double(beatFrameLength) * currentSwingAmount).rounded())
            : 0

        let generation = UUID()
        schedulingQueue.sync {
            self.activeGeneration = generation
            self.isRunning = true
            self.scheduledStepCount = 0
            self.consumedStepCount = 0
            self.scheduleStepsIfNeeded()
        }

        playerNode.play(at: AVAudioTime(hostTime: clickStartHostTime))
        let metadata = BeatEngineStartMetadata(
            bpm: bpm,
            countInBeats: CaptureClickTrackDefaults.countInBeats,
            beatsPerBar: CaptureClickTrackDefaults.beatsPerBar,
            clickStartHostTime: clickStartHostTime,
            recordingStartHostTime: recordingStartHostTime,
            clickAccentPattern: CaptureClickTrackDefaults.clickAccentPattern,
            clickVersion: CaptureClickTrackDefaults.clickVersion,
            beatEngineMode: mode,
            beatEnabled: mode.beatEnabled,
            beatPatternName: mode.beatPatternName,
            beatPatternVersion: CaptureBeatEngineDefaults.beatPatternVersion,
            swingAmount: mode.defaultSwingAmount,
            engineVersion: CaptureBeatEngineDefaults.engineVersion
        )
        scheduleUICallbacks(
            generation: generation,
            bpm: bpm,
            onCountInBeat: onCountInBeat,
            onRecordingStart: onRecordingStart
        )
        return metadata
    }

    func stop() {
        clickTrackEngine.stop()
        cancelPendingUICallbacks()

        schedulingQueue.sync {
            self.activeGeneration = UUID()
            self.isRunning = false
            self.scheduledStepCount = 0
            self.consumedStepCount = 0
            self.stepBuffers = []
            self.beatFrameLength = 0
            self.framesPerBar = 0
            self.swingFrameOffset = 0
        }

        playerNode.stop()
        playerNode.reset()
        if audioEngine.isRunning {
            audioEngine.stop()
        }
    }

    static func renderedTimingBuffer(
        mode: BeatEngineMode,
        bpm requestedBPM: Int,
        durationSeconds: Double,
        countInBeats: Int,
        beatsPerBar: Int,
        clickStartHostTime: UInt64?,
        recordingStartHostTime: UInt64?,
        sampleRate: Double,
        channelCount: AVAudioChannelCount
    ) throws -> AVAudioPCMBuffer {
        let bpm = CaptureClickTrackDefaults.clampedBPM(requestedBPM)
        let startBeatIndex = resolvedStartBeatIndex(
            bpm: bpm,
            countInBeats: countInBeats,
            clickStartHostTime: clickStartHostTime,
            recordingStartHostTime: recordingStartHostTime
        )

        if mode == .clickTrack {
            return try ClickTrackEngine.renderedClickTrackBuffer(
                bpm: bpm,
                durationSeconds: durationSeconds,
                sampleRate: sampleRate,
                channelCount: channelCount,
                startBeatIndex: startBeatIndex
            )
        }

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
            throw ScratchLabBeatEngineError.unableToStartAudio
        }

        buffer.frameLength = AVAudioFrameCount(totalFrameCount)
        for channel in 0..<Int(channelCount) {
            channelData[channel].initialize(repeating: 0, count: totalFrameCount)
        }

        guard mode != .silent else { return buffer }

        let renderedSteps = makeRenderedStepSamples(mode: mode, sampleRate: sampleRate)
        let beatFrames = max(1, Int((60.0 / Double(bpm) * sampleRate).rounded()))
        let framesPerBar = beatFrames * beatsPerBar
        let swingFrames = mode == .minimalFunk
            ? Int((Double(beatFrames) * mode.defaultSwingAmount).rounded())
            : 0
        let startStepIndex = max(0, startBeatIndex * 2)
        let totalStepCount = Int(ceil(max(0, durationSeconds) / max(0.0001, 60.0 / Double(bpm) / 2.0))) + 8

        for stepIndex in startStepIndex..<(startStepIndex + totalStepCount) {
            let stepInBar = stepIndex % renderedSteps.count
            let stepSamples = renderedSteps[stepInBar]
            guard !stepSamples.isEmpty else { continue }
            let relativeStepIndex = stepIndex - startStepIndex
            let sampleTime = sampleTimeForStepIndex(
                relativeStepIndex,
                beatFrames: beatFrames,
                framesPerBar: framesPerBar,
                swingFrames: swingFrames
            )
            guard sampleTime < totalFrameCount else { break }
            for frameOffset in 0..<stepSamples.count {
                let frameIndex = sampleTime + frameOffset
                guard frameIndex < totalFrameCount else { break }
                let sample = stepSamples[frameOffset]
                for channel in 0..<Int(channelCount) {
                    channelData[channel][frameIndex] += sample
                }
            }
        }

        return buffer
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
            throw ScratchLabBeatEngineError.unableToStartAudio
        }

        guard playerFormat?.sampleRate != requestedFormat.sampleRate else { return }

        playerNode.stop()
        audioEngine.disconnectNodeOutput(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: requestedFormat)
        playerFormat = requestedFormat
    }

    private func makeStepBuffers(mode: BeatEngineMode, sampleRate: Double) -> [AVAudioPCMBuffer] {
        let renderedSteps = Self.makeRenderedStepSamples(mode: mode, sampleRate: sampleRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            return []
        }

        return renderedSteps.compactMap { stepSamples in
            let frameCount = max(1, stepSamples.count)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
            ),
            let channelData = buffer.floatChannelData?.pointee else {
                return nil
            }
            buffer.frameLength = AVAudioFrameCount(frameCount)
            channelData.initialize(repeating: 0, count: frameCount)
            if !stepSamples.isEmpty {
                stepSamples.withUnsafeBufferPointer { samples in
                    guard let baseAddress = samples.baseAddress else { return }
                    memcpy(
                        channelData,
                        baseAddress,
                        min(frameCount, samples.count) * MemoryLayout<Float>.size
                    )
                }
            }
            return buffer
        }
    }

    private static func makeRenderedStepSamples(mode: BeatEngineMode, sampleRate: Double) -> [[Float]] {
        let kick = kickSamples(sampleRate: sampleRate)
        let snare = snareSamples(sampleRate: sampleRate, aggressive: mode == .battleLoop)
        let hat = hatSamples(sampleRate: sampleRate)
        return stepPattern(for: mode).map { step in
            mixStepSamples(
                kick: step.kick ? kick : [],
                snare: step.snare ? snare : [],
                hat: step.hat ? hat : []
            )
        }
    }

    private func scheduleStepsIfNeeded() {
        while isRunning, scheduledStepCount - consumedStepCount < Self.scheduledStepHorizon {
            scheduleStep(at: scheduledStepCount, generation: activeGeneration)
            scheduledStepCount += 1
        }
    }

    private func scheduleStep(at stepIndex: Int, generation: UUID) {
        guard !stepBuffers.isEmpty else { return }
        guard let playerFormat else { return }
        let stepBuffer = stepBuffers[stepIndex % stepBuffers.count]
        let sampleTime = Self.sampleTimeForStepIndex(
            stepIndex,
            beatFrames: Int(beatFrameLength),
            framesPerBar: Int(framesPerBar),
            swingFrames: Int(swingFrameOffset)
        )

        playerNode.scheduleBuffer(
            stepBuffer,
            at: AVAudioTime(sampleTime: AVAudioFramePosition(sampleTime), atRate: playerFormat.sampleRate),
            options: [],
            completionCallbackType: .dataConsumed
        ) { [weak self] _ in
            guard let self else { return }
            self.schedulingQueue.async {
                guard self.isRunning, self.activeGeneration == generation else { return }
                self.consumedStepCount += 1
                self.scheduleStepsIfNeeded()
            }
        }
    }

    private static func sampleTimeForStepIndex(
        _ stepIndex: Int,
        beatFrames: Int,
        framesPerBar: Int,
        swingFrames: Int
    ) -> Int {
        let stepInBar = stepIndex % 8
        let barIndex = stepIndex / 8
        let beatIndex = stepInBar / 2
        let isOffbeat = stepInBar % 2 == 1

        var frame = (barIndex * framesPerBar) + (beatIndex * beatFrames)
        if isOffbeat {
            frame += max(1, beatFrames / 2) + swingFrames
        }
        return frame
    }

    private func scheduleUICallbacks(
        generation: UUID,
        bpm: Int,
        onCountInBeat: ((Int) -> Void)?,
        onRecordingStart: (() -> Void)?
    ) {
        cancelPendingUICallbacks()

        let beatDurationSeconds = 60.0 / Double(bpm)
        for beatIndex in 0..<CaptureClickTrackDefaults.countInBeats {
            let beatNumber = (beatIndex % CaptureClickTrackDefaults.beatsPerBar) + 1
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
            deadline: .now() + Self.preRollLeadInSeconds + (Double(CaptureClickTrackDefaults.countInBeats) * beatDurationSeconds),
            execute: recordingStartItem
        )
    }

    private func cancelPendingUICallbacks() {
        pendingUIWorkItems.forEach { $0.cancel() }
        pendingUIWorkItems.removeAll()
    }

    private static func resolvedStartBeatIndex(
        bpm: Int,
        countInBeats: Int,
        clickStartHostTime: UInt64?,
        recordingStartHostTime: UInt64?
    ) -> Int {
        guard let clickStartHostTime,
              let recordingStartHostTime,
              recordingStartHostTime > clickStartHostTime else {
            return countInBeats
        }

        let beatDurationHostTime = AVAudioTime.hostTime(forSeconds: 60.0 / Double(bpm))
        guard beatDurationHostTime > 0 else { return countInBeats }
        let delta = recordingStartHostTime - clickStartHostTime
        let beatOffset = Int((Double(delta) / Double(beatDurationHostTime)).rounded())
        return max(0, beatOffset)
    }

    private static func stepPattern(for mode: BeatEngineMode) -> [StepVoicing] {
        switch mode {
        case .silent:
            return Array(repeating: .silent, count: 8)
        case .clickTrack:
            return Array(repeating: .silent, count: 8)
        case .boomBapTrainer:
            return [
                StepVoicing(kick: true, snare: false, hat: true),
                StepVoicing(kick: false, snare: false, hat: true),
                StepVoicing(kick: false, snare: true, hat: true),
                StepVoicing(kick: false, snare: false, hat: true),
                StepVoicing(kick: false, snare: false, hat: true),
                StepVoicing(kick: false, snare: false, hat: true),
                StepVoicing(kick: false, snare: true, hat: true),
                StepVoicing(kick: false, snare: false, hat: true)
            ]
        case .minimalFunk:
            return [
                StepVoicing(kick: true, snare: false, hat: true),
                StepVoicing(kick: false, snare: false, hat: true),
                StepVoicing(kick: false, snare: true, hat: true),
                StepVoicing(kick: false, snare: false, hat: true),
                StepVoicing(kick: true, snare: false, hat: true),
                StepVoicing(kick: false, snare: false, hat: true),
                StepVoicing(kick: false, snare: true, hat: true),
                StepVoicing(kick: false, snare: false, hat: true)
            ]
        case .battleLoop:
            return [
                StepVoicing(kick: true, snare: false, hat: false),
                StepVoicing(kick: false, snare: false, hat: true),
                StepVoicing(kick: false, snare: true, hat: false),
                .silent,
                .silent,
                StepVoicing(kick: false, snare: false, hat: true),
                StepVoicing(kick: false, snare: true, hat: false),
                .silent
            ]
        }
    }

    private static func mixStepSamples(kick: [Float], snare: [Float], hat: [Float]) -> [Float] {
        let frameCount = max(1, max(kick.count, max(snare.count, hat.count)))
        var samples = Array(repeating: Float(0), count: frameCount)

        for (source, gain) in [(kick, Float(1.0)), (snare, Float(0.9)), (hat, Float(0.45))] {
            for index in 0..<source.count {
                samples[index] += source[index] * gain
            }
        }

        return samples
    }

    private static func kickSamples(sampleRate: Double) -> [Float] {
        let frameCount = max(1, Int((sampleRate * 0.18).rounded()))
        return (0..<frameCount).map { frame in
            let time = Double(frame) / sampleRate
            let frequency = 120.0 * exp(-time * 10.0) + 42.0
            let envelope = exp(-time * 18.0)
            let body = sin(2.0 * .pi * frequency * time)
            let transient = sin(2.0 * .pi * 240.0 * time) * exp(-time * 42.0)
            return Float((body + (transient * 0.3)) * envelope) * 0.9
        }
    }

    private static func snareSamples(sampleRate: Double, aggressive: Bool) -> [Float] {
        let frameCount = max(1, Int((sampleRate * 0.12).rounded()))
        return (0..<frameCount).map { frame in
            let time = Double(frame) / sampleRate
            let envelope = exp(-time * (aggressive ? 36.0 : 28.0))
            let noise = sin(2.0 * .pi * 1_900.0 * time)
                + sin(2.0 * .pi * 2_700.0 * time)
                + sin(2.0 * .pi * 3_400.0 * time)
            let tone = sin(2.0 * .pi * (aggressive ? 220.0 : 180.0) * time) * exp(-time * 20.0)
            return Float(((noise * 0.16) + (tone * 0.4)) * envelope) * (aggressive ? 1.0 : 0.85)
        }
    }

    private static func hatSamples(sampleRate: Double) -> [Float] {
        let frameCount = max(1, Int((sampleRate * 0.045).rounded()))
        return (0..<frameCount).map { frame in
            let time = Double(frame) / sampleRate
            let envelope = exp(-time * 85.0)
            let noise = sin(2.0 * .pi * 6_500.0 * time)
                + sin(2.0 * .pi * 8_100.0 * time)
                + sin(2.0 * .pi * 9_700.0 * time)
            return Float(noise * 0.12 * envelope)
        }
    }
}
