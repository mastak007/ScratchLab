import Foundation

// MARK: - TimecodeValidationStatus

/// High-level prototype validation status derived from pipeline counters
/// and signal health.
///
/// This is a diagnostic label. It does NOT represent Serato, SDJ, or any
/// commercial timecode compatibility.
///
/// **Batch 6:** Validation visibility only.
public enum TimecodeValidationStatus: String, Equatable, Sendable, CaseIterable {

    /// No buffer ever received, or signal is completely silent.
    case noSignal

    /// A buffer was received but the most recent one is too old.
    case stale

    /// Signal is present but the decoder is producing no accepted output
    /// (weak signal, no phase correlation, or before first flush).
    case receivingButNoDecode

    /// Some decoding happened but all results are being dropped
    /// (low confidence, weak signal, or accumulated faults).
    case decodingButDropping

    /// Signal is clipping — decoding may be unreliable.
    case clipped

    /// One channel appears dead or severely imbalanced.
    case channelFault

    /// Signal looks usable and accepted motion samples are accumulating.
    /// Prototype decode chain is active.
    case usablePrototypeControl

    /// Signal is being received in diagnostics-only mode; decode is
    /// intentionally disabled by the current pipeline mode.
    case diagnosticsOnlyReceiving

    public var label: String {
        switch self {
        case .noSignal:               return "No Signal"
        case .stale:                  return "Stale"
        case .receivingButNoDecode:   return "Receiving – No Decode"
        case .decodingButDropping:    return "Decoding – Dropping"
        case .clipped:                return "Clipped"
        case .channelFault:           return "Channel Fault"
        case .usablePrototypeControl: return "Prototype Control Active"
        case .diagnosticsOnlyReceiving: return "Receiving – Decode Disabled (Diagnostics Only)"
        }
    }
}

// MARK: - TimecodeValidationSnapshot

/// A pure point-in-time snapshot of timecode prototype validation health.
///
/// Built from `TimecodeControlPipeline` state on demand. All fields are
/// value types; the snapshot does not update after creation.
///
/// The `validationStatus` field is derived from the other fields via
/// `classify(...)`. The snapshot can be used without a live pipeline
/// instance, which makes it straightforward to unit-test status logic.
///
/// This is prototype-only diagnostic data. It does NOT represent Serato,
/// SDJ, or any commercial timecode compatibility.
///
/// **Batch 6:** Validation visibility only. Does not modify decoder or
/// thresholds, does not inject into notation / Review / classification.
public struct TimecodeValidationSnapshot: Equatable, Sendable {

    // MARK: - Pipeline mode / tap state

    /// Raw value of `TimecodeControlMode` at snapshot time.
    public var mode: String

    /// Whether the live audio tap was enabled at snapshot time.
    public var liveTapEnabled: Bool

    // MARK: - Buffer freshness

    /// True if a buffer was received within `staleThreshold` seconds.
    public var hasRecentBuffer: Bool

    /// Seconds since the most recently received buffer. Nil when no buffer
    /// has ever been received in this pipeline session.
    public var lastBufferAge: TimeInterval?

    // MARK: - Signal health

    /// Aggregate signal health from the most recent diagnostics pass.
    public var signalHealth: SignalHealth

    /// Left channel aggregate RMS.
    public var leftRMS: Float

    /// Right channel aggregate RMS. Zero when no stereo diagnosis is available.
    public var rightRMS: Float

    /// Left channel aggregate peak.
    public var leftPeak: Float

    /// Right channel aggregate peak. Zero when no stereo diagnosis is available.
    public var rightPeak: Float

    // MARK: - Decoded output

    /// Raw value of the current decoded direction (from `TimecodeDirection`).
    public var decodedDirection: String

    /// Current decoded rate in position-units per second.
    public var decodedRate: Double

    /// Average confidence across the most recent decode window, in [0, 1].
    public var decoderConfidence: Double

    // MARK: - Counters

    /// Motion samples that passed confidence filtering and were accepted into
    /// the platter output timeline.
    public var acceptedMotionSamples: Int

    /// Prototype recorder sample count (DEBUG builds only; always 0 in
    /// production builds where the recorder does not exist).
    public var recordedSamples: Int

    /// Buffers / decode windows dropped because input was silent.
    public var droppedSilence: Int

    /// Buffers / decode windows dropped because input was clipping.
    public var droppedClipped: Int

    /// Buffers / decode windows dropped because of channel imbalance or fault.
    public var droppedChannelFault: Int

    /// Buffers / decode windows dropped because signal was too weak.
    public var droppedWeakSignal: Int

    /// Decoded frames dropped because confidence was below the minimum threshold.
    public var droppedLowConfidence: Int

    /// Number of direction changes detected across all decode windows.
    public var directionChanges: Int

    /// Maximum absolute rate observed across all decode windows in this session.
    public var maxAbsRate: Double

    /// Average confidence across all decode windows in this session.
    public var averageConfidence: Double

    // MARK: - Diagnostics

    /// Human-readable reason for the most recent dropout. Empty when the
    /// last decode was clean or no flush has occurred.
    public var lastDropReason: String

    /// Source label for this pipeline's output (e.g. `"timecode_live"`).
    public var sourceLabel: String

    // MARK: - Stability metrics (Batch 7)

    /// EMA-smoothed rate after the most recent stability filter pass.
    public var smoothedRate: Double

    /// True when the stability filter updated the EMA in the last flush.
    public var smoothingActive: Bool

    /// Total frames rejected by the stability filter as spikes or
    /// low-confidence this session.
    public var rejectedSpikeCount: Int

    /// Number of flush windows in the short-dropout-hold window this session.
    public var heldDropoutCount: Int

    /// Number of flush windows where the long dropout threshold was exceeded.
    public var longDropoutCount: Int

    /// Most recent spike or confidence rejection reason.
    public var lastSpikeReason: String

    /// Duration of the current or most recently cleared dropout window in ms.
    public var lastDropoutDuration: Double

    /// Maximum absolute smoothed rate observed this session.
    public var maxAbsSmoothedRate: Double

    // MARK: - Adapter diagnostic (Batch 12)

    /// Raw adapter diagnostic from the most recent CMSampleBuffer extraction.
    /// Captures ASBD format flags, per-buffer mDataByteSize, first 8 raw
    /// sample values, and maxAbs.  Empty string when no buffer has been
    /// processed.
    ///
    /// **DEBUG/prototype only.** Never populated in Release.
    public var adapterDiagnostic: String

    /// Capture device name + uniqueID from the active AVCaptureSession
    /// (Batch 12).  Empty when not yet configured.
    public var captureDeviceDebugInfo: String

    // MARK: - Signal classification (Batch 13)

    /// Prototype signal modulation classification.
    public var signalClass: String

    /// Pearson correlation coefficient between L and R channels.
    public var channelCorrelation: Float?

    /// ZCR-derived frequency estimate, left channel (Hz).
    /// Computed as zeroCrossingRateLeft / 2 — valid only for near-pure tones.
    public var zcrFrequencyEstimateLeft: Float?

    /// ZCR-derived frequency estimate, right channel (Hz).
    /// Computed as zeroCrossingRateRight / 2 — valid only for near-pure tones.
    public var zcrFrequencyEstimateRight: Float?

    /// Zero-crossing rate, left channel (crossings/sec).
    public var zeroCrossingRateLeft: Float

    /// Zero-crossing rate, right channel (crossings/sec).
    public var zeroCrossingRateRight: Float

    /// Rough phase offset between L/R at the ZCR frequency estimate (degrees).
    public var estimatedPhaseOffset: Float?

    /// True when stereo resembles a 90° quadrature pair.
    public var isQuadratureLike: Bool

    /// True when L/R ZCR frequency estimates differ enough to be considered
    /// frequency-disparate.  Does NOT imply FSK detection.
    public var isFrequencyDisparate: Bool

    /// Human-readable note explaining why the prototype decoder rejected
    /// this signal (if applicable).  Empty when not applicable.
    public var decoderRejectionNote: String

    /// Sample rate used for classification (Hz).
    public var classificationSampleRate: Double

    // MARK: - Classification

    /// High-level validation status derived from the other fields.
    public var validationStatus: TimecodeValidationStatus

    // MARK: - Init

    public init(
        mode: String,
        liveTapEnabled: Bool,
        hasRecentBuffer: Bool,
        lastBufferAge: TimeInterval?,
        signalHealth: SignalHealth,
        leftRMS: Float,
        rightRMS: Float,
        leftPeak: Float,
        rightPeak: Float,
        decodedDirection: String,
        decodedRate: Double,
        decoderConfidence: Double,
        acceptedMotionSamples: Int,
        recordedSamples: Int,
        droppedSilence: Int,
        droppedClipped: Int,
        droppedChannelFault: Int,
        droppedWeakSignal: Int,
        droppedLowConfidence: Int,
        directionChanges: Int,
        maxAbsRate: Double,
        averageConfidence: Double,
        lastDropReason: String,
        sourceLabel: String,
        smoothedRate: Double = 0,
        smoothingActive: Bool = false,
        rejectedSpikeCount: Int = 0,
        heldDropoutCount: Int = 0,
        longDropoutCount: Int = 0,
        lastSpikeReason: String = "",
        lastDropoutDuration: Double = 0,
        maxAbsSmoothedRate: Double = 0,
        adapterDiagnostic: String = "",
        captureDeviceDebugInfo: String = "",
        signalClass: String = SignalClass.unknown.rawValue,
        channelCorrelation: Float? = nil,
        zcrFrequencyEstimateLeft: Float? = nil,
        zcrFrequencyEstimateRight: Float? = nil,
        zeroCrossingRateLeft: Float = 0,
        zeroCrossingRateRight: Float = 0,
        estimatedPhaseOffset: Float? = nil,
        isQuadratureLike: Bool = false,
        isFrequencyDisparate: Bool = false,
        decoderRejectionNote: String = "",
        classificationSampleRate: Double = 0,
        validationStatus: TimecodeValidationStatus
    ) {
        self.mode = mode
        self.liveTapEnabled = liveTapEnabled
        self.hasRecentBuffer = hasRecentBuffer
        self.lastBufferAge = lastBufferAge
        self.signalHealth = signalHealth
        self.leftRMS = leftRMS
        self.rightRMS = rightRMS
        self.leftPeak = leftPeak
        self.rightPeak = rightPeak
        self.decodedDirection = decodedDirection
        self.decodedRate = decodedRate
        self.decoderConfidence = decoderConfidence
        self.acceptedMotionSamples = acceptedMotionSamples
        self.recordedSamples = recordedSamples
        self.droppedSilence = droppedSilence
        self.droppedClipped = droppedClipped
        self.droppedChannelFault = droppedChannelFault
        self.droppedWeakSignal = droppedWeakSignal
        self.droppedLowConfidence = droppedLowConfidence
        self.directionChanges = directionChanges
        self.maxAbsRate = maxAbsRate
        self.averageConfidence = averageConfidence
        self.lastDropReason = lastDropReason
        self.sourceLabel = sourceLabel
        self.smoothedRate = smoothedRate
        self.smoothingActive = smoothingActive
        self.rejectedSpikeCount = rejectedSpikeCount
        self.heldDropoutCount = heldDropoutCount
        self.longDropoutCount = longDropoutCount
        self.lastSpikeReason = lastSpikeReason
        self.lastDropoutDuration = lastDropoutDuration
        self.maxAbsSmoothedRate = maxAbsSmoothedRate
        self.adapterDiagnostic = adapterDiagnostic
        self.captureDeviceDebugInfo = captureDeviceDebugInfo
        self.signalClass = signalClass
        self.channelCorrelation = channelCorrelation
        self.zcrFrequencyEstimateLeft = zcrFrequencyEstimateLeft
        self.zcrFrequencyEstimateRight = zcrFrequencyEstimateRight
        self.zeroCrossingRateLeft = zeroCrossingRateLeft
        self.zeroCrossingRateRight = zeroCrossingRateRight
        self.estimatedPhaseOffset = estimatedPhaseOffset
        self.isQuadratureLike = isQuadratureLike
        self.isFrequencyDisparate = isFrequencyDisparate
        self.decoderRejectionNote = decoderRejectionNote
        self.classificationSampleRate = classificationSampleRate
        self.validationStatus = validationStatus
    }

    // MARK: - Classification

    /// Seconds before a buffer timestamp is considered stale.
    public static let staleThreshold: TimeInterval = 5.0

    /// Classify validation status from the set of pipeline inputs.
    ///
    /// Priority order (first match wins):
    /// 1. Stale buffer
    /// 2. No buffer / no signal
    /// 3. Channel fault
    /// 4. Clipped
    /// 5. Usable with accepted samples → prototype active
    /// 6. Drops accumulating → decoding but dropping
    /// 7. Signal present, no output → receivingButNoDecode
    public static func classify(
        hasRecentBuffer: Bool,
        lastBufferAge: TimeInterval?,
        signalHealth: SignalHealth,
        acceptedMotionSamples: Int,
        droppedSilence: Int,
        droppedClipped: Int,
        droppedChannelFault: Int,
        droppedWeakSignal: Int,
        droppedLowConfidence: Int
    ) -> TimecodeValidationStatus {
        if let age = lastBufferAge, age > staleThreshold {
            return .stale
        }
        guard hasRecentBuffer else {
            return .noSignal
        }
        if signalHealth == .channelFault { return .channelFault }
        if signalHealth == .clipped      { return .clipped }
        if signalHealth == .noSignal     { return .noSignal }

        if acceptedMotionSamples > 0 { return .usablePrototypeControl }

        let totalDropped = droppedSilence + droppedClipped + droppedChannelFault
            + droppedWeakSignal + droppedLowConfidence
        if totalDropped > 0 { return .decodingButDropping }

        return .receivingButNoDecode
    }

    // MARK: - Debug text

    /// A copyable single-block debug summary for console/clipboard use.
    ///
    /// Does not spam the console — intended for explicit copy action only.
    public var debugText: String {
        let ageStr = lastBufferAge.map { String(format: "%.2fs", $0) } ?? "never"
        return """
        --- Timecode Validation Snapshot ---
        Mode:            \(mode)
        Live tap:        \(liveTapEnabled)
        Has buffer:      \(hasRecentBuffer)
        Buffer age:      \(ageStr)
        Signal health:   \(signalHealth.rawValue)
        L RMS / Peak:    \(String(format: "%.4f / %.4f", leftRMS, leftPeak))
        R RMS / Peak:    \(String(format: "%.4f / %.4f", rightRMS, rightPeak))
        Direction:       \(decodedDirection)
        Rate (raw):      \(String(format: "%.3f u/s", decodedRate))
        Rate (smoothed): \(String(format: "%.3f u/s", smoothedRate))
        Smoothing:       \(smoothingActive ? "active" : "inactive")
        Max abs rate:    \(String(format: "%.3f u/s", maxAbsRate))
        Max smo rate:    \(String(format: "%.3f u/s", maxAbsSmoothedRate))
        Confidence:      \(String(format: "%.3f", decoderConfidence))
        Accepted:        \(acceptedMotionSamples)
        Recorded:        \(recordedSamples)
        Dropped silence: \(droppedSilence)
        Dropped clipped: \(droppedClipped)
        Dropped ch fault:\(droppedChannelFault)
        Dropped weak:    \(droppedWeakSignal)
        Dropped low conf:\(droppedLowConfidence)
        Rejected spikes: \(rejectedSpikeCount)
        Held dropouts:   \(heldDropoutCount)
        Long dropouts:   \(longDropoutCount)
        Dropout dur ms:  \(String(format: "%.1f", lastDropoutDuration))
        Dir changes:     \(directionChanges)
        Last drop:       \(lastDropReason.isEmpty ? "(none)" : lastDropReason)
        Last spike:      \(lastSpikeReason.isEmpty ? "(none)" : lastSpikeReason)
        Source:          \(sourceLabel)
        Status:          \(validationStatus.rawValue)
        Adapter diag:    \(adapterDiagnostic.isEmpty ? "(none)" : adapterDiagnostic)
        Capture device:  \(captureDeviceDebugInfo.isEmpty ? "(unknown)" : captureDeviceDebugInfo)
        Signal class:    \(signalClass)\(isQuadratureLike ? " (quad-like)" : "")\(isFrequencyDisparate ? " (freq-disparate)" : "")
        ZCR freq est L:  \(zcrFrequencyEstimateLeft.map { String(format: "%.0f Hz", $0) } ?? "n/a")
        ZCR freq est R:  \(zcrFrequencyEstimateRight.map { String(format: "%.0f Hz", $0) } ?? "n/a")
        Correlation:     \(channelCorrelation.map { String(format: "%.4f", $0) } ?? "n/a")
        Phase offset:    \(estimatedPhaseOffset.map { String(format: "%.0f°", $0) } ?? "n/a")
        ZCR L/R:         \(String(format: "%.0f / %.0f", zeroCrossingRateLeft, zeroCrossingRateRight))
        Rejection note:  \(decoderRejectionNote.isEmpty ? "(none)" : decoderRejectionNote)
        NOT sent to notation (prototype only)
        """
    }
}
