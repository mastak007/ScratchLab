import Foundation
import AVFAudio

// MARK: - TimecodeFixtureLoader

/// Loads a timecode audio fixture from disk, decodes it through the
/// prototype decoder chain, and produces an evidence-only validation report.
///
/// ## Usage
///
/// ```swift
/// let loader = TimecodeFixtureLoader()
/// if let report = loader.loadAndValidate(url: fileURL) {
///     print(report.debugText)
/// }
/// ```
///
/// ## Synthetic fixtures (no audio file)
///
/// Use `loadSynthetic(...)` to generate synthetic stereo buffers inline and
/// validate them through the same pipeline. Synthetic fixtures never touch
/// the filesystem or env vars.
///
/// ## Environment variable
///
/// Callers (typically tests) should check `SCRATCHLAB_TIMECODE_FIXTURE_PATH`
/// before invoking `loadAndValidate(url:)`. If the env var is unset, fixture
/// tests skip gracefully. The loader itself is env-var-agnostic — it just
/// takes a URL.
///
/// **Batch 9:** Fixture/hardware validation proof only.
/// Does NOT claim Serato, SDJ, or any commercial timecode compatibility.
public struct TimecodeFixtureLoader: Sendable {

    // MARK: - Configuration

    /// Samples per stereo input chunk. Default 441 = ~10 ms at 44100 Hz
    /// (exactly 10 periods of 1000 Hz carrier).
    public let chunkSize: Int

    /// Decoder configuration.
    public let decoder: TimecodePhaseDecoder

    /// Stability filter configuration.
    public let stabilityConfig: TimecodeStabilityConfig

    /// Minimum confidence for a frame to be considered "accepted" in the
    /// report. This mirrors the adapter's threshold.
    public let minConfidenceForAccept: Double

    // MARK: - Init

    public init(
        chunkSize: Int = 441,
        decoder: TimecodePhaseDecoder = TimecodePhaseDecoder(),
        stabilityConfig: TimecodeStabilityConfig = .conservative,
        minConfidenceForAccept: Double = 0.3
    ) {
        self.chunkSize = chunkSize
        self.decoder = decoder
        self.stabilityConfig = stabilityConfig
        self.minConfidenceForAccept = minConfidenceForAccept
    }

    // MARK: - Load and validate (file)

    /// Load a WAV fixture from `url`, decode it, and produce a validation report.
    ///
    /// - Parameter url: File URL for a WAV audio file.
    /// - Returns: A `TimecodeFixtureValidationReport`, or `nil` if the file
    ///   cannot be read or the format is unsupported.
    public func loadAndValidate(url: URL) -> TimecodeFixtureValidationReport? {
        let sourceName = url.lastPathComponent

        // --- Open file ---
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            return makeUnsupportedReport(
                sourceName: sourceName,
                sourcePath: url.path,
                reason: "Cannot open file: \(error.localizedDescription)"
            )
        }

        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let channelCount = Int(format.channelCount)
        let totalFrames = AVAudioFrameCount(file.length)
        let duration = Double(totalFrames) / sampleRate

        // --- Validate format ---
        // Accept mono (1) or stereo (2). Other channel counts are unsupported.
        guard channelCount == 1 || channelCount == 2 else {
            return makeUnsupportedReport(
                sourceName: sourceName,
                sourcePath: url.path,
                sampleRate: sampleRate,
                channelCount: channelCount,
                duration: duration,
                reason: "Unsupported channel count \(channelCount) (expected 1 or 2)"
            )
        }

        // Accept common sample rates
        let supportedRates: Set<Double> = [44100, 48000, 22050, 96000]
        if !supportedRates.contains(sampleRate) {
            // Not a hard block — just note it
        }

        // --- Read all audio into float buffers ---
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: totalFrames
        ) else {
            return makeUnsupportedReport(
                sourceName: sourceName,
                sourcePath: url.path,
                sampleRate: sampleRate,
                channelCount: channelCount,
                duration: duration,
                reason: "Cannot allocate PCM buffer for \(totalFrames) frames"
            )
        }

        do {
            try file.read(into: buffer)
        } catch {
            return makeUnsupportedReport(
                sourceName: sourceName,
                sourcePath: url.path,
                sampleRate: sampleRate,
                channelCount: channelCount,
                duration: duration,
                reason: "Read error: \(error.localizedDescription)"
            )
        }

        guard let floatData = buffer.floatChannelData else {
            return makeUnsupportedReport(
                sourceName: sourceName,
                sourcePath: url.path,
                sampleRate: sampleRate,
                channelCount: channelCount,
                duration: duration,
                reason: "Buffer has no float channel data"
            )
        }

        let frameLength = Int(buffer.frameLength)
        let leftPtr = floatData[0]
        let rightPtr = channelCount >= 2 ? floatData[1] : floatData[0]

        // --- Compute overall signal metrics ---
        var sumSq: Float = 0
        var overallPeak: Float = 0
        let totalSamples = frameLength * channelCount
        for i in 0..<frameLength {
            let l = leftPtr[i]
            sumSq += l * l
            overallPeak = max(overallPeak, abs(l))
            if channelCount >= 2 {
                let r = rightPtr[i]
                sumSq += r * r
                overallPeak = max(overallPeak, abs(r))
            }
        }
        let overallRMS = totalSamples > 0 ? sqrt(sumSq / Float(totalSamples)) : 0

        let hasClipping = overallPeak >= decoder.clippingThreshold

        // Check channel fault for stereo files
        var hasChannelFault = false
        if channelCount >= 2 {
            var leftSumSq: Float = 0
            var rightSumSq: Float = 0
            for i in 0..<frameLength {
                leftSumSq += leftPtr[i] * leftPtr[i]
                rightSumSq += rightPtr[i] * rightPtr[i]
            }
            let leftRMS = frameLength > 0 ? sqrt(leftSumSq / Float(frameLength)) : 0
            let rightRMS = frameLength > 0 ? sqrt(rightSumSq / Float(frameLength)) : 0
            let maxRMS = max(leftRMS, rightRMS)
            let minRMS = min(leftRMS, rightRMS)
            hasChannelFault = maxRMS > 0 && (minRMS / maxRMS) < 0.1
        }

        // --- Chunk into StereoInput and decode ---
        let validationResult = decodeChunks(
            sourceName: sourceName,
            sourcePath: url.path,
            sampleRate: sampleRate,
            channelCount: channelCount,
            duration: duration,
            overallRMS: overallRMS,
            overallPeak: overallPeak,
            hasClipping: hasClipping,
            hasChannelFault: hasChannelFault,
            leftPtr: leftPtr,
            rightPtr: rightPtr,
            frameLength: frameLength
        )

        return validationResult
    }

    // MARK: - Load and validate (synthetic)

    /// Decode and validate synthetic stereo buffers without touching the
    /// filesystem.
    ///
    /// - Parameters:
    ///   - sourceName: Label for the report (e.g. "synthetic_forward").
    ///   - sampleRate: Sample rate in Hz.
    ///   - inputs: Stereo audio buffers in time order.
    /// - Returns: A `TimecodeFixtureValidationReport`.
    public func loadSynthetic(
        sourceName: String,
        sampleRate: Double,
        inputs: [TimecodePhaseDecoder.StereoInput],
        channelCount: Int = 2
    ) -> TimecodeFixtureValidationReport {
        let duration = inputs.last?.relativeTime ?? 0

        // Compute overall signal metrics from all inputs
        var sumSq: Float = 0
        var overallPeak: Float = 0
        var totalSamples = 0
        for input in inputs {
            for v in input.left {
                sumSq += v * v
                overallPeak = max(overallPeak, abs(v))
            }
            for v in input.right {
                sumSq += v * v
                overallPeak = max(overallPeak, abs(v))
            }
            totalSamples += input.left.count + input.right.count
        }
        let overallRMS = totalSamples > 0 ? sqrt(sumSq / Float(totalSamples)) : 0

        let hasClipping = overallPeak >= decoder.clippingThreshold

        // Check channel fault
        var hasChannelFault = false
        if channelCount >= 2 {
            var leftSumSq: Float = 0
            var rightSumSq: Float = 0
            var leftCount = 0, rightCount = 0
            for input in inputs {
                for v in input.left { leftSumSq += v * v; leftCount += 1 }
                for v in input.right { rightSumSq += v * v; rightCount += 1 }
            }
            let leftRMS = leftCount > 0 ? sqrt(leftSumSq / Float(leftCount)) : 0
            let rightRMS = rightCount > 0 ? sqrt(rightSumSq / Float(rightCount)) : 0
            let maxRMS = max(leftRMS, rightRMS)
            let minRMS = min(leftRMS, rightRMS)
            hasChannelFault = maxRMS > 0 && (minRMS / maxRMS) < 0.1
        }

        return decodeInputs(
            sourceName: sourceName,
            sourcePath: nil,
            sampleRate: sampleRate,
            channelCount: channelCount,
            duration: duration + (inputs.last.flatMap { _ in 0.01 } ?? 0),
            overallRMS: overallRMS,
            overallPeak: overallPeak,
            hasClipping: hasClipping,
            hasChannelFault: hasChannelFault,
            inputs: inputs
        )
    }

    // MARK: - Private: decode from float pointers

    private func decodeChunks(
        sourceName: String,
        sourcePath: String,
        sampleRate: Double,
        channelCount: Int,
        duration: TimeInterval,
        overallRMS: Float,
        overallPeak: Float,
        hasClipping: Bool,
        hasChannelFault: Bool,
        leftPtr: UnsafeMutablePointer<Float>,
        rightPtr: UnsafeMutablePointer<Float>,
        frameLength: Int
    ) -> TimecodeFixtureValidationReport {
        var inputs: [TimecodePhaseDecoder.StereoInput] = []
        var offset = 0
        var relativeTime: TimeInterval = 0

        while offset < frameLength {
            let remaining = frameLength - offset
            let chunkFrames = min(chunkSize, remaining)
            let chunkTime = Double(chunkFrames) / sampleRate

            var leftChunk: [Float] = []
            var rightChunk: [Float] = []
            leftChunk.reserveCapacity(chunkFrames)
            rightChunk.reserveCapacity(chunkFrames)

            for i in 0..<chunkFrames {
                leftChunk.append(leftPtr[offset + i])
                rightChunk.append(rightPtr[offset + i])
            }

            inputs.append(TimecodePhaseDecoder.StereoInput(
                left: leftChunk,
                right: rightChunk,
                sampleRate: sampleRate,
                relativeTime: relativeTime
            ))

            offset += chunkFrames
            relativeTime += chunkTime
        }

        return decodeInputs(
            sourceName: sourceName,
            sourcePath: sourcePath,
            sampleRate: sampleRate,
            channelCount: channelCount,
            duration: duration,
            overallRMS: overallRMS,
            overallPeak: overallPeak,
            hasClipping: hasClipping,
            hasChannelFault: hasChannelFault,
            inputs: inputs
        )
    }

    // MARK: - Private: shared decode + report pipeline

    private func decodeInputs(
        sourceName: String,
        sourcePath: String?,
        sampleRate: Double,
        channelCount: Int,
        duration: TimeInterval,
        overallRMS: Float,
        overallPeak: Float,
        hasClipping: Bool,
        hasChannelFault: Bool,
        inputs: [TimecodePhaseDecoder.StereoInput]
    ) -> TimecodeFixtureValidationReport {
        // --- Signal health summary ---
        let signalHealthSummary: String
        if overallRMS < decoder.silenceThresholdRMS {
            signalHealthSummary = "silent"
        } else if hasClipping && hasChannelFault {
            signalHealthSummary = "clipped + channel fault"
        } else if hasClipping {
            signalHealthSummary = "clipped"
        } else if hasChannelFault {
            signalHealthSummary = "channel fault"
        } else if overallRMS < 0.02 {
            signalHealthSummary = "weak"
        } else {
            signalHealthSummary = "usable"
        }

        // --- Decode ---
        let decodeResult = decoder.decode(inputs)

        // Accumulate per-frame stats
        var acceptedConfidences: [Double] = []
        var forwardCount = 0
        var backwardCount = 0
        var unknownCount = 0
        var rates: [Double] = []

        for frame in decodeResult.frames {
            rates.append(frame.velocity)
            switch frame.direction {
            case .forward:  forwardCount += 1
            case .backward: backwardCount += 1
            case .unknown:  unknownCount += 1
            }
            if frame.confidence >= minConfidenceForAccept {
                acceptedConfidences.append(frame.confidence)
            }
        }

        let decodedFrameCount = decodeResult.frames.count
        let acceptedFrameCount = acceptedConfidences.count
        let avgConf = decodeResult.averageConfidence
        let minConf = decodeResult.frames.map(\.confidence).min() ?? 0
        let maxConf = decodeResult.frames.map(\.confidence).max() ?? 0

        let minRate = rates.min() ?? 0
        let maxRateObserved = rates.max() ?? 0
        let avgRate = rates.isEmpty ? 0 : rates.reduce(0, +) / Double(rates.count)

        // --- Drop counts from decoder counters ---
        let c = decodeResult.counters
        let droppedSilence = c.droppedSilence
        let droppedClipped = c.droppedClipped
        let droppedNoPhaseLock = max(0, inputs.count - c.decodedSamples - droppedSilence - droppedClipped)
        let droppedLowConfidence = max(0, decodedFrameCount - acceptedFrameCount)

        // --- Stability filter pass ---
        let filter = TimecodeMotionStabilityFilter(config: stabilityConfig)
        let filterState = TimecodeStabilityFilterState()
        let flushTime = inputs.last?.relativeTime ?? duration
        let filterResult = filter.filter(
            frames: decodeResult.frames,
            state: filterState,
            flushRelativeTime: flushTime
        )
        let spikeRejectedCount = filterResult.metrics.rejectedSpikeCount
        let shortDropoutCount = filterResult.metrics.heldDropoutCount
        let longDropoutCount = filterResult.metrics.longDropoutCount

        // --- Playback bridge eligibility ---
        let (playbackBridgeEligible, bridgeBlockReason) = assessBridgeEligibility(
            decodeResult: decodeResult,
            acceptedFrameCount: acceptedFrameCount,
            avgConfidence: avgConf,
            directionKnown: forwardCount > 0 || backwardCount > 0
        )

        // --- Verdict ---
        let verdict = classifyVerdict(
            overallRMS: overallRMS,
            hasClipping: hasClipping,
            hasChannelFault: hasChannelFault,
            acceptedFrameCount: acceptedFrameCount,
            decodedFrameCount: decodedFrameCount,
            avgConfidence: avgConf,
            spikeRejectedCount: spikeRejectedCount,
            totalDropped: droppedSilence + droppedClipped + droppedNoPhaseLock + droppedLowConfidence,
            totalFrames: decodedFrameCount
        )

        return TimecodeFixtureValidationReport(
            sourceName: sourceName,
            sourcePath: sourcePath,
            sampleRate: sampleRate,
            channelCount: channelCount,
            duration: duration,
            overallRMS: overallRMS,
            overallPeak: overallPeak,
            hasClipping: hasClipping,
            hasChannelFault: hasChannelFault,
            signalHealthSummary: signalHealthSummary,
            decodedFrameCount: decodedFrameCount,
            acceptedFrameCount: acceptedFrameCount,
            averageConfidence: avgConf,
            minConfidence: minConf,
            maxConfidence: maxConf,
            droppedSilence: droppedSilence,
            droppedClipped: droppedClipped,
            droppedChannelFault: hasChannelFault ? 1 : 0,
            droppedNoPhaseLock: droppedNoPhaseLock,
            droppedLowConfidence: droppedLowConfidence,
            forwardFrameCount: forwardCount,
            backwardFrameCount: backwardCount,
            unknownDirectionFrameCount: unknownCount,
            directionChangeCount: c.directionChanges,
            minRate: minRate,
            maxRate: maxRateObserved,
            averageRate: avgRate,
            spikeRejectedCount: spikeRejectedCount,
            shortDropoutCount: shortDropoutCount,
            longDropoutCount: longDropoutCount,
            playbackBridgeEligible: playbackBridgeEligible,
            playbackBridgeBlockReason: bridgeBlockReason,
            verdict: verdict
        )
    }

    // MARK: - Private: bridge eligibility

    private func assessBridgeEligibility(
        decodeResult: TimecodeDecodeResult,
        acceptedFrameCount: Int,
        avgConfidence: Double,
        directionKnown: Bool
    ) -> (eligible: Bool, reason: String) {
        if decodeResult.signalHealth == .clipped {
            return (false, "signal is clipped")
        }
        if decodeResult.signalHealth == .channelFault {
            return (false, "channel fault")
        }
        if decodeResult.signalHealth == .noSignal {
            return (false, "no signal")
        }
        if acceptedFrameCount == 0 {
            return (false, "no accepted frames")
        }
        if avgConfidence < minConfidenceForAccept {
            return (false, "confidence below threshold")
        }
        if !directionKnown {
            return (false, "direction unknown")
        }
        if decodeResult.frames.isEmpty {
            return (false, "no decoded frames")
        }
        return (true, "")
    }

    // MARK: - Private: verdict classification

    private func classifyVerdict(
        overallRMS: Float,
        hasClipping: Bool,
        hasChannelFault: Bool,
        acceptedFrameCount: Int,
        decodedFrameCount: Int,
        avgConfidence: Double,
        spikeRejectedCount: Int,
        totalDropped: Int,
        totalFrames: Int
    ) -> TimecodeFixtureValidationVerdict {
        // Priority order (first match wins):

        // 1. Silent / no signal
        if overallRMS < decoder.silenceThresholdRMS {
            return .notEnoughSignal
        }

        // 2. Channel fault
        if hasChannelFault {
            return .channelFault
        }

        // 3. Clipped
        if hasClipping {
            return .clipped
        }

        // 4. Nothing decoded
        if decodedFrameCount == 0 {
            return .notEnoughSignal
        }

        // 5. Usable prototype: sufficient accepted frames, good confidence,
        //    low spike rate
        let acceptanceRatio = totalFrames > 0
            ? Double(acceptedFrameCount) / Double(totalFrames)
            : 0
        let spikeRatio = totalFrames > 0
            ? Double(spikeRejectedCount) / Double(totalFrames)
            : 0

        if acceptedFrameCount > 0
            && avgConfidence >= minConfidenceForAccept
            && acceptanceRatio >= 0.5
            && spikeRatio <= 0.3
        {
            return .usablePrototype
        }

        // 6. Decodes but unstable
        return .decodesButUnstable
    }

    // MARK: - Private: unsupported format report

    private func makeUnsupportedReport(
        sourceName: String,
        sourcePath: String,
        sampleRate: Double = 0,
        channelCount: Int = 0,
        duration: TimeInterval = 0,
        reason: String
    ) -> TimecodeFixtureValidationReport {
        TimecodeFixtureValidationReport(
            sourceName: sourceName,
            sourcePath: sourcePath,
            sampleRate: sampleRate,
            channelCount: channelCount,
            duration: duration,
            overallRMS: 0,
            overallPeak: 0,
            hasClipping: false,
            hasChannelFault: false,
            signalHealthSummary: "unsupported format: \(reason)",
            decodedFrameCount: 0,
            acceptedFrameCount: 0,
            averageConfidence: 0,
            minConfidence: 0,
            maxConfidence: 0,
            droppedSilence: 0,
            droppedClipped: 0,
            droppedChannelFault: 0,
            droppedNoPhaseLock: 0,
            droppedLowConfidence: 0,
            forwardFrameCount: 0,
            backwardFrameCount: 0,
            unknownDirectionFrameCount: 0,
            directionChangeCount: 0,
            minRate: 0,
            maxRate: 0,
            averageRate: 0,
            spikeRejectedCount: 0,
            shortDropoutCount: 0,
            longDropoutCount: 0,
            playbackBridgeEligible: false,
            playbackBridgeBlockReason: reason,
            verdict: .unsupportedFormat
        )
    }
}
