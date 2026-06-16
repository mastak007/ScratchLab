import Foundation

// MARK: - TimecodeFixtureValidationVerdict

/// Evidence-driven validation verdict for a timecode audio fixture or
/// hardware recording.
///
/// Every verdict must be supported by measured data — this is a diagnostic
/// label, not a compatibility claim.
///
/// **Batch 9:** Fixture/hardware validation proof only.
/// Does NOT claim Serato, SDJ, or any commercial timecode compatibility.
public enum TimecodeFixtureValidationVerdict: String, Equatable, Sendable, CaseIterable {

    /// Signal is silent or near-silent — decoder had nothing to work with.
    case notEnoughSignal

    /// Signal is present and some frames decode, but the output is too
    /// unstable (spike rate, confidence swings, or dropout percentage)
    /// for prototype use.
    case decodesButUnstable

    /// Signal is clean, decoder produces stable trusted motion, and the
    /// output is eligible for the prototype playback bridge and recorder.
    case usablePrototype

    /// Signal clips (samples at or near digital full scale). Decoded output
    /// is unreliable.
    case clipped

    /// One channel is dead or severely imbalanced — no usable stereo phase
    /// information.
    case channelFault

    /// The file format is unsupported (wrong sample rate, bit depth, or
    /// channel layout that the prototype loader cannot handle).
    case unsupportedFormat

    // MARK: - Labels

    public var label: String {
        switch self {
        case .notEnoughSignal:    return "Not Enough Signal"
        case .decodesButUnstable: return "Decodes – Unstable"
        case .usablePrototype:    return "Usable (Prototype)"
        case .clipped:            return "Clipped"
        case .channelFault:       return "Channel Fault"
        case .unsupportedFormat:  return "Unsupported Format"
        }
    }
}

// MARK: - TimecodeFixtureValidationReport

/// A pure, evidence-only fixture or hardware validation report.
///
/// Built by `TimecodeFixtureLoader` after decoding a complete audio fixture
/// through the prototype `TimecodePhaseDecoder`. The report is a value type
/// — it does not update after creation.
///
/// All fields are measured or counted. No field represents a claim about
/// commercial timecode format compatibility.
///
/// **Batch 9:** Fixture/hardware validation proof only.
public struct TimecodeFixtureValidationReport: Equatable, Sendable {

    // MARK: - Source

    /// Display name for the fixture (file name or hardware label).
    public let sourceName: String

    /// Full path to the fixture file, if loaded from disk.
    /// Nil for synthetic or hardware-live sources.
    public let sourcePath: String?

    // MARK: - Audio properties

    /// Sample rate in Hz (e.g. 44100, 48000).
    public let sampleRate: Double

    /// Number of channels in the source file (1 = mono, 2 = stereo).
    public let channelCount: Int

    /// Duration of the audio in seconds.
    public let duration: TimeInterval

    // MARK: - Signal health

    /// Aggregate RMS across the fixture.
    public let overallRMS: Float

    /// Aggregate peak across the fixture.
    public let overallPeak: Float

    /// True when any sample in the fixture reaches or exceeds the
    /// clipping threshold.
    public let hasClipping: Bool

    /// True when one channel is dead or severely imbalanced relative
    /// to the other (ratio < 0.1).
    public let hasChannelFault: Bool

    /// Human-readable signal health summary.
    public let signalHealthSummary: String

    // MARK: - Decode output

    /// Total number of decoded frames produced by the decoder.
    public let decodedFrameCount: Int

    /// Number of frames accepted after confidence filtering.
    public let acceptedFrameCount: Int

    /// Average confidence across all decoded frames, in [0, 1].
    public let averageConfidence: Double

    /// Minimum confidence observed across decoded frames.
    public let minConfidence: Double

    /// Maximum confidence observed across decoded frames.
    public let maxConfidence: Double

    // MARK: - Drop counts

    /// Frames dropped because the input was silent.
    public let droppedSilence: Int

    /// Frames dropped because the input was clipping.
    public let droppedClipped: Int

    /// Frames dropped because of channel imbalance or fault.
    public let droppedChannelFault: Int

    /// Frames dropped because the decoder could not establish phase lock.
    public let droppedNoPhaseLock: Int

    /// Frames dropped because confidence was below the minimum threshold.
    public let droppedLowConfidence: Int

    /// Total number of dropped frames (sum of all drop categories).
    public var totalDropped: Int {
        droppedSilence + droppedClipped + droppedChannelFault
            + droppedNoPhaseLock + droppedLowConfidence
    }

    // MARK: - Direction distribution

    /// Number of frames decoded as forward motion.
    public let forwardFrameCount: Int

    /// Number of frames decoded as backward motion.
    public let backwardFrameCount: Int

    /// Number of frames with unknown direction.
    public let unknownDirectionFrameCount: Int

    /// Number of direction changes detected.
    public let directionChangeCount: Int

    // MARK: - Rate distribution

    /// Minimum velocity observed (position-units per second).
    /// Negative for backward motion.
    public let minRate: Double

    /// Maximum velocity observed (position-units per second).
    /// Positive for forward motion.
    public let maxRate: Double

    /// Average velocity across all accepted frames.
    public let averageRate: Double

    // MARK: - Stability metrics

    /// Number of frames rejected as rate spikes by the stability filter.
    public let spikeRejectedCount: Int

    /// Number of short-dropout hold events.
    public let shortDropoutCount: Int

    /// Number of long-dropout fail-closed events.
    public let longDropoutCount: Int

    // MARK: - Playback bridge eligibility

    /// True when the fixture output meets the playback bridge's minimum
    /// gating criteria (usable signal, sufficient confidence, known
    /// direction, non-empty timeline).
    public let playbackBridgeEligible: Bool

    /// Human-readable reason when playbackBridgeEligible is false.
    /// Empty when eligible.
    public let playbackBridgeBlockReason: String

    // MARK: - Verdict

    /// Evidence-driven validation verdict.
    public let verdict: TimecodeFixtureValidationVerdict

    // MARK: - Init

    public init(
        sourceName: String,
        sourcePath: String?,
        sampleRate: Double,
        channelCount: Int,
        duration: TimeInterval,
        overallRMS: Float,
        overallPeak: Float,
        hasClipping: Bool,
        hasChannelFault: Bool,
        signalHealthSummary: String,
        decodedFrameCount: Int,
        acceptedFrameCount: Int,
        averageConfidence: Double,
        minConfidence: Double,
        maxConfidence: Double,
        droppedSilence: Int,
        droppedClipped: Int,
        droppedChannelFault: Int,
        droppedNoPhaseLock: Int,
        droppedLowConfidence: Int,
        forwardFrameCount: Int,
        backwardFrameCount: Int,
        unknownDirectionFrameCount: Int,
        directionChangeCount: Int,
        minRate: Double,
        maxRate: Double,
        averageRate: Double,
        spikeRejectedCount: Int,
        shortDropoutCount: Int,
        longDropoutCount: Int,
        playbackBridgeEligible: Bool,
        playbackBridgeBlockReason: String,
        verdict: TimecodeFixtureValidationVerdict
    ) {
        self.sourceName = sourceName
        self.sourcePath = sourcePath
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.duration = duration
        self.overallRMS = overallRMS
        self.overallPeak = overallPeak
        self.hasClipping = hasClipping
        self.hasChannelFault = hasChannelFault
        self.signalHealthSummary = signalHealthSummary
        self.decodedFrameCount = decodedFrameCount
        self.acceptedFrameCount = acceptedFrameCount
        self.averageConfidence = averageConfidence
        self.minConfidence = minConfidence
        self.maxConfidence = maxConfidence
        self.droppedSilence = droppedSilence
        self.droppedClipped = droppedClipped
        self.droppedChannelFault = droppedChannelFault
        self.droppedNoPhaseLock = droppedNoPhaseLock
        self.droppedLowConfidence = droppedLowConfidence
        self.forwardFrameCount = forwardFrameCount
        self.backwardFrameCount = backwardFrameCount
        self.unknownDirectionFrameCount = unknownDirectionFrameCount
        self.directionChangeCount = directionChangeCount
        self.minRate = minRate
        self.maxRate = maxRate
        self.averageRate = averageRate
        self.spikeRejectedCount = spikeRejectedCount
        self.shortDropoutCount = shortDropoutCount
        self.longDropoutCount = longDropoutCount
        self.playbackBridgeEligible = playbackBridgeEligible
        self.playbackBridgeBlockReason = playbackBridgeBlockReason
        self.verdict = verdict
    }

    // MARK: - Debug text

    /// A copyable single-block debug summary for console/clipboard use.
    ///
    /// Explicitly labelled "prototype only." Does not claim Serato, SDJ, or
    /// any commercial timecode compatibility.
    public var debugText: String {
        let pathStr = sourcePath ?? "(synthetic / live)"
        let eligibilityStr = playbackBridgeEligible
            ? "eligible"
            : "blocked (\(playbackBridgeBlockReason))"
        let hasClippingStr = hasClipping ? "YES ⚠️" : "no"
        let hasFaultStr = hasChannelFault ? "YES ⚠️" : "no"

        return """
        --- Timecode Fixture Validation Report ---
        Source:          \(sourceName)
        Path:            \(pathStr)
        Sample rate:     \(String(format: "%.0f Hz", sampleRate))
        Channels:        \(channelCount)
        Duration:        \(String(format: "%.3f s", duration))
        Overall RMS:     \(String(format: "%.4f", overallRMS))
        Overall peak:    \(String(format: "%.4f", overallPeak))
        Clipping:        \(hasClippingStr)
        Channel fault:   \(hasFaultStr)
        Signal summary:  \(signalHealthSummary)
        Decoded frames:  \(decodedFrameCount)
        Accepted frames: \(acceptedFrameCount)
        Avg confidence:  \(String(format: "%.4f", averageConfidence))
        Min confidence:  \(String(format: "%.4f", minConfidence))
        Max confidence:  \(String(format: "%.4f", maxConfidence))
        Dropped silence: \(droppedSilence)
        Dropped clipped: \(droppedClipped)
        Dropped ch fault:\(droppedChannelFault)
        Dropped no lock: \(droppedNoPhaseLock)
        Dropped low conf:\(droppedLowConfidence)
        Total dropped:   \(totalDropped)
        Forward frames:  \(forwardFrameCount)
        Backward frames: \(backwardFrameCount)
        Unknown dir:     \(unknownDirectionFrameCount)
        Direction changes:\(directionChangeCount)
        Min rate:        \(String(format: "%.3f u/s", minRate))
        Max rate:        \(String(format: "%.3f u/s", maxRate))
        Avg rate:        \(String(format: "%.3f u/s", averageRate))
        Spike rejected:  \(spikeRejectedCount)
        Short dropouts:  \(shortDropoutCount)
        Long dropouts:   \(longDropoutCount)
        Playback bridge: \(eligibilityStr)
        Verdict:         \(verdict.rawValue) — \(verdict.label)
        ---
        PROTOTYPE ONLY — NOT a compatibility claim.
        Does NOT represent Serato, SDJ, or any commercial format.
        """
    }

    /// Compact single-line summary for tight UI.
    public var compactSummary: String {
        "[\(verdict.label)] \(sourceName) — \(acceptedFrameCount) accepted, \(totalDropped) dropped, conf \(String(format: "%.3f", averageConfidence))"
    }
}
