import AVFoundation
import CryptoKit
import Darwin
import Foundation

/// A verified playback destination, independent of the recorded scratch stem.
struct BeatPlaybackOutputRoute: Codable, Equatable, Sendable {
    var deviceID: UInt32
    var deviceUID: String
    var deviceName: String
    var channelPair: String
    var channelMap: [Int]
}

/// Hardware routing is supplied by the host; scheduling and PCM stay shared.
protocol BeatPlaybackOutputRouting: AnyObject {
    var route: BeatPlaybackOutputRoute? { get }
    func prepare(_ engine: AVAudioEngine) throws
    func verify(_ engine: AVAudioEngine) throws
}

protocol ClickTrackTimingEngine: AnyObject {
    func start(
        bpm requestedBPM: Int,
        onCountInBeat: ((Int) -> Void)?,
        onRecordingStart: (() -> Void)?
    ) throws -> ClickTrackStartMetadata
    func stop()
    func setOutputGain(_ normalizedGain: Double)
}

extension ClickTrackTimingEngine {
    func setOutputGain(_ normalizedGain: Double) {}
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
    var outputRoute: BeatPlaybackOutputRoute? = nil
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

    /// One player timeline: an optional click-only bar followed by the
    /// existing repeating drum pattern. The frame boundary also owns the
    /// recording-start host time; no completion callback starts another engine.
    struct PlaybackSchedule {
        let countInBuffer: AVAudioPCMBuffer?
        let stepBuffers: [AVAudioPCMBuffer]
        let beatFrameLength: Int
        let framesPerBar: Int
        let swingFrameOffset: Int
        let sampleRate: Double

        var patternStartFrame: Int { Int(countInBuffer?.frameLength ?? 0) }
        var countInDurationSeconds: Double { Double(patternStartFrame) / sampleRate }

        func sampleTime(forStepIndex stepIndex: Int) -> AVAudioFramePosition {
            AVAudioFramePosition(patternStartFrame + ScratchLabBeatEngine.sampleTimeForStepIndex(
                stepIndex,
                beatFrames: beatFrameLength,
                framesPerBar: framesPerBar,
                swingFrames: swingFrameOffset
            ))
        }
    }

    struct PreparedPlayback {
        let countInBuffer: AVAudioPCMBuffer
        let loopBuffer: AVAudioPCMBuffer
    }

    private let clickTrackEngine: ClickTrackTimingEngine
    private let outputRouting: (any BeatPlaybackOutputRouting)?
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
    private var playbackSchedule: PlaybackSchedule?
    private var preparedPlayback: PreparedPlayback?
    private var scheduledStepCount = 0
    private var consumedStepCount = 0
    private var activeGeneration = UUID()
    private var isRunning = false
    private var pendingUIWorkItems: [DispatchWorkItem] = []

    init(clickTrackEngine: ClickTrackTimingEngine? = nil,
         outputRouting: (any BeatPlaybackOutputRouting)? = nil) {
        self.outputRouting = outputRouting
        self.clickTrackEngine = clickTrackEngine ?? ClickTrackEngine(outputRouting: outputRouting)
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

    func hardResetBeatPlayback() {
        cancelPendingUICallbacks()
        clickTrackEngine.stop()

        schedulingQueue.sync {
            self.activeGeneration = UUID()
            self.isRunning = false
            self.scheduledStepCount = 0
            self.consumedStepCount = 0
            self.playbackSchedule = nil
            self.preparedPlayback = nil
        }

        playerNode.stop()
        playerNode.reset()

        if audioEngine.isRunning {
            audioEngine.stop()
        }

        audioEngine.disconnectNodeOutput(playerNode)
        audioEngine.detach(playerNode)
        audioEngine.reset()
        audioEngine.attach(playerNode)
        if let fmt = playerFormat {
            audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: fmt)
        }
        audioEngine.prepare()
    }

    func start(
        mode: BeatEngineMode,
        bpm requestedBPM: Int,
        usesClickCountIn: Bool = false,
        onCountInBeat: ((Int) -> Void)? = nil,
        onRecordingStart: (() -> Void)? = nil
    ) throws -> BeatEngineStartMetadata {
        hardResetBeatPlayback()

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
                engineVersion: CaptureBeatEngineDefaults.engineVersion,
                outputRoute: outputRouting?.route
            )
        }

        let beatDurationSeconds = 60.0 / Double(bpm)
        let startDelay = Self.preRollLeadInSeconds
        let legacyClickStartHostTime = Self.currentHostTime() + AVAudioTime.hostTime(forSeconds: startDelay)
        let sampleRate = resolvedSampleRate()

        do {
            try configurePlayerFormat(sampleRate: sampleRate)
            try outputRouting?.prepare(audioEngine)
            if !audioEngine.isRunning {
                try audioEngine.start()
            }
            try outputRouting?.verify(audioEngine)
        } catch {
            stop()
            throw error
        }

        currentMode = mode
        currentBPM = bpm
        currentSwingAmount = mode.defaultSwingAmount
        let schedule: PlaybackSchedule
        do {
            schedule = try Self.makePlaybackSchedule(
                mode: mode,
                bpm: bpm,
                sampleRate: sampleRate,
                usesClickCountIn: usesClickCountIn
            )
        } catch {
            stop()
            throw error
        }
        let recordingDelay = schedule.countInBuffer != nil
            ? schedule.countInDurationSeconds
            : Double(CaptureClickTrackDefaults.countInBeats) * beatDurationSeconds
        // Prepare the opted-in count-in before choosing its future start:
        // audio-device startup must not consume any of the four audible beats.
        let clickStartHostTime = schedule.countInBuffer != nil
            ? Self.currentHostTime() + AVAudioTime.hostTime(forSeconds: startDelay)
            : legacyClickStartHostTime
        let recordingStartHostTime = clickStartHostTime + AVAudioTime.hostTime(forSeconds: recordingDelay)

        let generation = UUID()
        schedulingQueue.sync {
            self.activeGeneration = generation
            self.isRunning = true
            self.playbackSchedule = schedule
            self.scheduledStepCount = 0
            self.consumedStepCount = 0
            if let countInBuffer = schedule.countInBuffer {
                self.playerNode.scheduleBuffer(
                    countInBuffer,
                    at: AVAudioTime(sampleTime: 0, atRate: sampleRate),
                    options: []
                )
            }
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
            engineVersion: CaptureBeatEngineDefaults.engineVersion,
            outputRoute: outputRouting?.route
        )
        scheduleUICallbacks(
            generation: generation,
            bpm: bpm,
            countInStartHostTime: schedule.countInBuffer != nil ? clickStartHostTime : nil,
            countInBeatDurationSeconds: Double(schedule.beatFrameLength) / sampleRate,
            recordingStartHostTime: schedule.countInBuffer != nil ? recordingStartHostTime : nil,
            onCountInBeat: onCountInBeat,
            onRecordingStart: onRecordingStart
        )
        return metadata
    }

    /// CXL playback consumes the exact verified production WAV that is bound
    /// to the take. The four-click prefix runs once; the remaining frames loop
    /// on this same player node without a timer or renderer transition.
    func start(
        preparedBeat: ReferencePreparedBeat,
        mode: BeatEngineMode,
        bpm: Int,
        onCountInBeat: ((Int) -> Void)? = nil,
        onRecordingStart: (() -> Void)? = nil
    ) throws -> BeatEngineStartMetadata {
        hardResetBeatPlayback()
        do {
            let playback = try Self.loadPreparedPlayback(preparedBeat: preparedBeat, mode: mode, bpm: bpm)
            let sampleRate = playback.loopBuffer.format.sampleRate
            try configurePlayerFormat(sampleRate: sampleRate, channelCount: playback.loopBuffer.format.channelCount)
            try outputRouting?.prepare(audioEngine)
            try audioEngine.start()
            try outputRouting?.verify(audioEngine)
            currentMode = mode
            currentBPM = bpm
            currentSwingAmount = mode.defaultSwingAmount
            let countInFrames = playback.countInBuffer.frameLength
            let clickStart = Self.currentHostTime() + AVAudioTime.hostTime(forSeconds: Self.preRollLeadInSeconds)
            let recordingStart = clickStart + AVAudioTime.hostTime(forSeconds: Double(countInFrames) / sampleRate)
            let generation = UUID()
            schedulingQueue.sync {
                self.activeGeneration = generation
                self.isRunning = true
                self.preparedPlayback = playback
                self.playerNode.scheduleBuffer(
                    playback.countInBuffer,
                    at: AVAudioTime(sampleTime: 0, atRate: sampleRate), options: []
                )
                self.playerNode.scheduleBuffer(
                    playback.loopBuffer,
                    at: AVAudioTime(sampleTime: AVAudioFramePosition(countInFrames), atRate: sampleRate),
                    options: [.loops]
                )
            }
            playerNode.play(at: AVAudioTime(hostTime: clickStart))
            scheduleUICallbacks(
                generation: generation, bpm: bpm, countInStartHostTime: clickStart,
                countInBeatDurationSeconds: Double(countInFrames) / 4.0 / sampleRate,
                recordingStartHostTime: recordingStart,
                onCountInBeat: onCountInBeat, onRecordingStart: onRecordingStart
            )
            return BeatEngineStartMetadata(
                bpm: bpm, countInBeats: 4, beatsPerBar: 4,
                clickStartHostTime: clickStart, recordingStartHostTime: recordingStart,
                clickAccentPattern: CaptureClickTrackDefaults.clickAccentPattern,
                clickVersion: CaptureClickTrackDefaults.clickVersion,
                beatEngineMode: mode, beatEnabled: mode.beatEnabled,
                beatPatternName: mode.beatPatternName,
                beatPatternVersion: CaptureBeatEngineDefaults.beatPatternVersion,
                swingAmount: mode.defaultSwingAmount,
                engineVersion: CaptureBeatEngineDefaults.engineVersion,
                outputRoute: outputRouting?.route
            )
        } catch {
            stop()
            throw error
        }
    }

    /// A hardware-free loading seam shared by playback and its PCM regressions.
    /// Revalidate the bound set each time; a stale prepared URL is not evidence.
    static func loadPreparedPlayback(
        preparedBeat: ReferencePreparedBeat,
        mode: BeatEngineMode,
        bpm: Int
    ) throws -> PreparedPlayback {
        let verified = try ReferenceBeatAssetStore.resolve(
            binding: preparedBeat.binding,
            rootURL: preparedBeat.directoryURL.deletingLastPathComponent()
        )
        guard verified == preparedBeat, verified.mode == mode, verified.binding.bpm == bpm else {
            throw ReferenceBeatAssetError.invalid("playback mode or BPM differs from the prepared binding")
        }
        let file = try AVAudioFile(forReading: verified.productionMasterURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        func readFrames(_ frameCount: Int64) throws -> AVAudioPCMBuffer {
            guard frameCount > 0, frameCount <= Int64(UInt32.max),
                  let result = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frameCount)),
                  let destination = result.floatChannelData,
                  let chunk = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384),
                  let source = chunk.floatChannelData else {
                throw ReferenceBeatAssetError.invalid("the production WAV could not be decoded")
            }
            var copied: Int64 = 0
            while copied < frameCount {
                chunk.frameLength = 0
                try file.read(into: chunk, frameCount: AVAudioFrameCount(min(frameCount - copied, Int64(chunk.frameCapacity))))
                guard chunk.frameLength > 0 else {
                    throw ReferenceBeatAssetError.invalid("the production WAV ended before its bound frame count")
                }
                let length = min(Int(chunk.frameLength), Int(frameCount - copied))
                for channel in 0..<Int(file.processingFormat.channelCount) {
                    destination[channel].advanced(by: Int(copied)).update(from: source[channel], count: length)
                }
                copied += Int64(length)
            }
            result.frameLength = AVAudioFrameCount(frameCount)
            return result
        }
        let countIn = try readFrames(verified.binding.countInFrameCount)
        let loop = try readFrames(verified.binding.loopFrameCount)
        let hashAfterRead = SHA256.hash(data: try Data(contentsOf: verified.productionMasterURL))
            .map { String(format: "%02x", $0) }.joined()
        guard file.framePosition == file.length, hashAfterRead == verified.binding.productionMasterSHA256 else {
            throw ReferenceBeatAssetError.invalid("the production WAV changed while playback was loading")
        }
        return PreparedPlayback(countInBuffer: countIn, loopBuffer: loop)
    }

    /// Recheck after the count-in, immediately before the capture is armed.
    func verifiedPreparedOutputRoute() throws -> BeatPlaybackOutputRoute? {
        try outputRouting?.verify(audioEngine)
        return outputRouting?.route
    }

    func stop() {
        clickTrackEngine.stop()
        cancelPendingUICallbacks()

        schedulingQueue.sync {
            self.activeGeneration = UUID()
            self.isRunning = false
            self.scheduledStepCount = 0
            self.consumedStepCount = 0
            self.playbackSchedule = nil
            self.preparedPlayback = nil
        }

        playerNode.stop()
        playerNode.reset()
        if audioEngine.isRunning {
            audioEngine.stop()
        }
    }

    func setOutputGain(_ normalizedGain: Double) {
        let finiteGain = normalizedGain.isFinite ? normalizedGain : 0
        let clampedGain = min(max(finiteGain, 0), 1)
        playerNode.volume = Float(clampedGain)
        clickTrackEngine.setOutputGain(clampedGain)
    }

    /// Peak-level policy for audio ScratchLab *generates* (timing/beat stems and
    /// the scratch+timing mix).
    ///
    /// Summed percussion voices routinely overshoot full scale, and the old
    /// export clamped the overshoot sample-by-sample, which is hard clipping:
    /// it is audible, it is irreversible, and it makes a stem that no longer
    /// matches what the pattern actually is. Instead every generated buffer is
    /// attenuated by one constant linear gain until its peak sits at the
    /// ceiling. Attenuation only — a quiet pattern is never boosted — so the
    /// operation is a pure gain and cannot change frame counts, timing, or the
    /// relative shape of the waveform.
    enum GeneratedAudioHeadroom {
        /// Ceiling for stems ScratchLab renders on its own (beat_only).
        static let generatedStemCeilingDBFS: Double = -1.0
        /// Ceiling for the scratch + timing mix.
        ///
        /// Deliberately close to full scale rather than matching the generated
        /// stem ceiling. The mix contains *captured* audio, and the captured
        /// scratch in the regression fixture already peaks at -0.234 dBFS; a
        /// -1 dBFS mix ceiling would force an attenuation of the recording
        /// itself just to make room for a stem ScratchLab generated. The mix
        /// instead holds the scratch at unity and reduces only the timing
        /// contribution — see `SessionArchiveBuilder.mixScratchWithTiming`.
        static let mixCeilingDBFS: Double = -0.1

        static func amplitude(forDBFS dbfs: Double) -> Float {
            Float(pow(10.0, dbfs / 20.0))
        }

        static func peakAmplitude(of buffer: AVAudioPCMBuffer) -> Float {
            guard let channels = buffer.floatChannelData else { return 0 }
            let frameCount = Int(buffer.frameLength)
            var peak: Float = 0
            for channel in 0..<Int(buffer.format.channelCount) {
                let samples = channels[channel]
                for frame in 0..<frameCount {
                    peak = max(peak, abs(samples[frame]))
                }
            }
            return peak
        }

        /// Attenuates `buffer` in place so its peak is at most `ceilingDBFS`.
        /// Returns the gain that was applied (1.0 when nothing was needed).
        @discardableResult
        static func applyCeiling(_ ceilingDBFS: Double, to buffer: AVAudioPCMBuffer) -> Float {
            let ceiling = amplitude(forDBFS: ceilingDBFS)
            let peak = peakAmplitude(of: buffer)
            guard peak > ceiling, peak.isFinite, peak > 0,
                  let channels = buffer.floatChannelData else { return 1 }

            let gain = ceiling / peak
            let frameCount = Int(buffer.frameLength)
            for channel in 0..<Int(buffer.format.channelCount) {
                let samples = channels[channel]
                for frame in 0..<frameCount {
                    samples[frame] *= gain
                }
            }
            return gain
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
        channelCount: AVAudioChannelCount,
        exactFrameCount: AVAudioFrameCount? = nil
    ) throws -> AVAudioPCMBuffer {
        let bpm = CaptureClickTrackDefaults.clampedBPM(requestedBPM)
        let startBeatIndex = resolvedStartBeatIndex(
            bpm: bpm,
            countInBeats: countInBeats,
            clickStartHostTime: clickStartHostTime,
            recordingStartHostTime: recordingStartHostTime
        )

        if mode == .clickTrack {
            let clickBuffer = try ClickTrackEngine.renderedClickTrackBuffer(
                bpm: bpm,
                durationSeconds: durationSeconds,
                sampleRate: sampleRate,
                channelCount: channelCount,
                startBeatIndex: startBeatIndex,
                exactFrameCount: exactFrameCount
            )
            GeneratedAudioHeadroom.applyCeiling(
                GeneratedAudioHeadroom.generatedStemCeilingDBFS,
                to: clickBuffer
            )
            return clickBuffer
        }

        let totalFrameCount = max(
            1,
            exactFrameCount.map(Int.init)
                ?? Int(ceil(max(0, durationSeconds) * sampleRate))
        )
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
        let renderedDurationSeconds = Double(totalFrameCount) / sampleRate
        let totalStepCount = Int(ceil(renderedDurationSeconds / max(0.0001, 60.0 / Double(bpm) / 2.0))) + 8

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

        // Overlapping kick/snare/hat voices sum past full scale on the
        // downbeat. Pull the whole stem back to the headroom ceiling with one
        // gain instead of clipping individual samples.
        GeneratedAudioHeadroom.applyCeiling(
            GeneratedAudioHeadroom.generatedStemCeilingDBFS,
            to: buffer
        )

        return buffer
    }

    private func resolvedSampleRate() -> Double {
        let sampleRate = audioEngine.outputNode.outputFormat(forBus: 0).sampleRate
        return sampleRate > 0 ? sampleRate : 48_000
    }

    private func configurePlayerFormat(sampleRate: Double, channelCount: AVAudioChannelCount = 1) throws {
        guard let requestedFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: channelCount
        ) else {
            throw ScratchLabBeatEngineError.unableToStartAudio
        }

        guard playerFormat?.sampleRate != requestedFormat.sampleRate
                || playerFormat?.channelCount != requestedFormat.channelCount else { return }

        playerNode.stop()
        audioEngine.disconnectNodeOutput(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: requestedFormat)
        playerFormat = requestedFormat
    }

    static func makePlaybackSchedule(
        mode: BeatEngineMode,
        bpm requestedBPM: Int,
        sampleRate: Double,
        usesClickCountIn: Bool = false
    ) throws -> PlaybackSchedule {
        let bpm = CaptureClickTrackDefaults.clampedBPM(requestedBPM)
        let beatFrames = max(1, Int((60.0 / Double(bpm) * sampleRate).rounded()))
        let countInFrames = beatFrames * CaptureClickTrackDefaults.countInBeats
        let countInBuffer: AVAudioPCMBuffer?
        if usesClickCountIn && mode.beatEnabled {
            countInBuffer = try ClickTrackEngine.renderedClickTrackBuffer(
                bpm: bpm,
                durationSeconds: Double(countInFrames) / sampleRate,
                sampleRate: sampleRate,
                channelCount: 1,
                startBeatIndex: 0,
                exactFrameCount: AVAudioFrameCount(countInFrames)
            )
        } else {
            countInBuffer = nil
        }
        let stepBuffers = makeStepBuffers(mode: mode, sampleRate: sampleRate)
        guard !stepBuffers.isEmpty else { throw ScratchLabBeatEngineError.unableToStartAudio }
        return PlaybackSchedule(
            countInBuffer: countInBuffer,
            stepBuffers: stepBuffers,
            beatFrameLength: beatFrames,
            framesPerBar: beatFrames * CaptureClickTrackDefaults.beatsPerBar,
            swingFrameOffset: mode == .minimalFunk
                ? Int((Double(beatFrames) * mode.defaultSwingAmount).rounded()) : 0,
            sampleRate: sampleRate
        )
    }

    private static func makeStepBuffers(mode: BeatEngineMode, sampleRate: Double) -> [AVAudioPCMBuffer] {
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
        guard let playbackSchedule, !playbackSchedule.stepBuffers.isEmpty else { return }
        guard let playerFormat else { return }
        let stepBuffer = playbackSchedule.stepBuffers[stepIndex % playbackSchedule.stepBuffers.count]
        let sampleTime = playbackSchedule.sampleTime(forStepIndex: stepIndex)

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
        countInStartHostTime: UInt64?,
        countInBeatDurationSeconds: Double,
        recordingStartHostTime: UInt64?,
        onCountInBeat: ((Int) -> Void)?,
        onRecordingStart: (() -> Void)?
    ) {
        cancelPendingUICallbacks()

        let beatDurationSeconds = 60.0 / Double(bpm)
        func delay(until hostTime: UInt64) -> Double {
            let now = Self.currentHostTime()
            return hostTime > now ? AVAudioTime.seconds(forHostTime: hostTime - now) : 0
        }
        for beatIndex in 0..<CaptureClickTrackDefaults.countInBeats {
            let beatNumber = (beatIndex % CaptureClickTrackDefaults.beatsPerBar) + 1
            let workItem = DispatchWorkItem { [weak self] in
                guard self?.activeGeneration == generation else { return }
                onCountInBeat?(beatNumber)
            }
            pendingUIWorkItems.append(workItem)
            let beatDelay = countInStartHostTime.map {
                delay(until: $0 + AVAudioTime.hostTime(forSeconds: Double(beatIndex) * countInBeatDurationSeconds))
            } ?? (Self.preRollLeadInSeconds + Double(beatIndex) * beatDurationSeconds)
            DispatchQueue.main.asyncAfter(
                deadline: .now() + beatDelay,
                execute: workItem
            )
        }

        let recordingStartItem = DispatchWorkItem { [weak self] in
            guard self?.activeGeneration == generation else { return }
            onRecordingStart?()
        }
        pendingUIWorkItems.append(recordingStartItem)
        let recordingDelay = recordingStartHostTime.map { delay(until: $0) }
            ?? (Self.preRollLeadInSeconds + Double(CaptureClickTrackDefaults.countInBeats) * beatDurationSeconds)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + recordingDelay,
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
