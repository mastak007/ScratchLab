import Foundation

// MARK: - TimecodeStabilityConfig

/// Conservative configuration for the prototype stability filter.
///
/// All thresholds are deliberately wide so the filter never silently drops
/// legitimate movement. Tune only with measured evidence.
///
/// **Batch 7:** Prototype only. Not exposed as end-user settings yet.
public struct TimecodeStabilityConfig: Equatable, Sendable {

    /// Maximum absolute rate change allowed between the running smoothed rate
    /// and a new raw rate before the frame is rejected as a spike.
    /// Default 100 rad/s (very conservative — only catches wild single-sample
    /// outliers, not fast-but-real movements).
    public var maxRateDeltaPerSecond: Double

    /// EMA smoothing factor alpha ∈ [0, 1].
    /// 0 = frozen (no update), 1 = no memory (passes through raw).
    /// Default 0.3 tracks slow trends without amplifying noise.
    public var smoothingAlpha: Double

    /// Consecutive-empty-flush threshold in milliseconds. If a dropout window
    /// is at least this long, `heldDropoutCount` is incremented each flush.
    /// Smoothed rate state is preserved during this window.
    public var shortDropoutHoldMs: Double

    /// Consecutive-empty-flush fail-closed threshold in milliseconds. Beyond
    /// this, the filter resets smoothed state and increments `longDropoutCount`.
    public var longDropoutFailMs: Double

    /// Minimum decoded confidence to accept a frame for EMA update and output.
    /// Frames below this threshold are rejected as low-confidence.
    public var minConfidenceForUpdate: Double

    // MARK: - Defaults

    public static let conservative = TimecodeStabilityConfig(
        maxRateDeltaPerSecond: 100.0,
        smoothingAlpha: 0.3,
        shortDropoutHoldMs: 200,
        longDropoutFailMs: 1000,
        minConfidenceForUpdate: 0.3
    )

    public init(
        maxRateDeltaPerSecond: Double = 100.0,
        smoothingAlpha: Double = 0.3,
        shortDropoutHoldMs: Double = 200,
        longDropoutFailMs: Double = 1000,
        minConfidenceForUpdate: Double = 0.3
    ) {
        self.maxRateDeltaPerSecond = maxRateDeltaPerSecond
        self.smoothingAlpha = smoothingAlpha
        self.shortDropoutHoldMs = shortDropoutHoldMs
        self.longDropoutFailMs = longDropoutFailMs
        self.minConfidenceForUpdate = minConfidenceForUpdate
    }
}

// MARK: - TimecodeStabilityFilterState

/// Cross-flush state carried by the stability filter.
///
/// Stored on `TimecodeControlPipeline` and passed into each `filter()` call.
/// Pure value type — no side effects.
public struct TimecodeStabilityFilterState: Equatable, Sendable {

    /// EMA-smoothed rate from the most recently accepted frame.
    public var smoothedRate: Double = 0

    /// Relative decode time of the last accepted (non-rejected, non-dropout)
    /// frame.
    public var lastAcceptedRelativeTime: TimeInterval = 0

    /// Relative decode time when the current consecutive-dropout window began.
    /// `nil` when the most recent flush produced at least one accepted frame.
    public var dropoutStartRelativeTime: TimeInterval? = nil

    /// Direction of the last accepted frame (used for reversal detection).
    public var lastAcceptedDirection: TimecodeDirection = .unknown

    public init() {}
}

// MARK: - TimecodeStabilityFilterMetrics

/// Per-flush metrics produced by the stability filter.
///
/// Accumulated into `TimecodeControlCounters` by the pipeline.
public struct TimecodeStabilityFilterMetrics: Equatable, Sendable {

    /// Last raw (pre-smoothing) rate in the batch, in position-units per second.
    public var rawRate: Double = 0

    /// EMA-smoothed rate after this flush, in position-units per second.
    public var smoothedRate: Double = 0

    /// True when at least one frame updated the EMA this flush.
    public var smoothingActive: Bool = false

    /// Number of frames rejected as spikes or low-confidence this flush.
    public var rejectedSpikeCount: Int = 0

    /// Of `rejectedSpikeCount`, how many were rejected specifically for
    /// confidence below `config.minConfidenceForUpdate` (not a rate spike).
    public var lowConfidenceRejectCount: Int = 0

    /// Of `rejectedSpikeCount`, how many were rejected specifically for an
    /// excessive rate delta (not low confidence).
    public var rateSpikeRejectCount: Int = 0

    /// The rejection reason for the *first* frame rejected this flush (as
    /// opposed to `lastSpikeReason`, which reflects the most recent one).
    public var firstRejectReason: String = ""

    /// Non-zero when the current dropout duration is within the short-hold
    /// window (≥ shortDropoutHoldMs and < longDropoutFailMs).
    public var heldDropoutCount: Int = 0

    /// Non-zero when the current dropout duration exceeded longDropoutFailMs.
    public var longDropoutCount: Int = 0

    /// Human-readable label for the most recent rejection reason this flush.
    public var lastSpikeReason: String = ""

    /// Duration of the current (or most recently cleared) dropout window in
    /// milliseconds.
    public var lastDropoutDuration: Double = 0

    /// Maximum absolute smoothed rate seen this flush.
    public var maxAbsSmoothedRate: Double = 0
}

// MARK: - TimecodeMotionStabilityFilter

/// Pure post-decoder stability filter for the prototype timecode pipeline.
///
/// Applied to calibrated `[TimecodeDecodedFrame]` output inside
/// `TimecodeControlPipeline.flushDecode()`, after rate scaling and invert,
/// and **before** `TimecodePlatterAdapter.adapt()` and
/// `TimecodePrototypeRecorder.accept()`.
///
/// ## Responsibilities
///
/// 1. Smooth small rate jitter via an exponential moving average (EMA).
/// 2. Reject impossible single-sample rate spikes.
/// 3. Preserve genuine direction reversals (not counted as spikes).
/// 4. Preserve slow forward / back movement (never dropped for low rate).
/// 5. Handle short consecutive dropouts conservatively (hold EMA state).
/// 6. Fail closed on long / bad dropouts (reset EMA state).
/// 7. Keep confidence / drop reason visible in per-flush metrics.
///
/// ## What this does NOT do
///
/// - Does NOT modify the decoder (`TimecodePhaseDecoder`).
/// - Does NOT modify frame fields — only selects which frames to include.
/// - Does NOT inject into notation, classification, production playback, or
///   export paths.
/// - Does NOT alter RANE / replay source labels or trust gates.
/// - Does NOT claim Serato, SDJ, or any commercial timecode compatibility.
///
/// **Batch 7:** Prototype stability / latency diagnostics only.
public struct TimecodeMotionStabilityFilter: Sendable {

    public let config: TimecodeStabilityConfig

    public init(config: TimecodeStabilityConfig = .conservative) {
        self.config = config
    }

    // MARK: - Filter

    /// Apply stability filtering to a batch of calibrated decoded frames.
    ///
    /// - Parameters:
    ///   - frames: Calibrated frames from `TimecodeControlPipeline.flushDecode()`.
    ///   - state: Cross-flush filter state from the previous call.
    ///   - flushRelativeTime: Decode session relative time for this flush.
    ///     Typically taken from `inputs.last?.relativeTime`.
    /// - Returns: Accepted (stabilized) frames, updated state, and per-flush
    ///   metrics. The accepted list may be empty for dropouts or when all
    ///   frames are spike / confidence-rejected.
    public func filter(
        frames: [TimecodeDecodedFrame],
        state: TimecodeStabilityFilterState,
        flushRelativeTime: TimeInterval
    ) -> (accepted: [TimecodeDecodedFrame], state: TimecodeStabilityFilterState, metrics: TimecodeStabilityFilterMetrics) {

        var newState = state
        var metrics = TimecodeStabilityFilterMetrics()
        metrics.smoothedRate = state.smoothedRate

        // --- Empty batch: potential dropout ---
        if frames.isEmpty {
            let dropoutStart = state.dropoutStartRelativeTime ?? flushRelativeTime
            newState.dropoutStartRelativeTime = dropoutStart
            let dropoutMs = max(0, (flushRelativeTime - dropoutStart) * 1000)
            metrics.lastDropoutDuration = dropoutMs
            metrics.smoothedRate = state.smoothedRate

            if dropoutMs >= config.longDropoutFailMs {
                // Long dropout: fail closed and clear EMA state
                metrics.longDropoutCount += 1
                newState.smoothedRate = 0
                newState.lastAcceptedDirection = .unknown
                metrics.smoothedRate = 0
            } else if dropoutMs >= config.shortDropoutHoldMs {
                // Short hold: preserve EMA state, count the event
                metrics.heldDropoutCount += 1
            }
            // brief gap (< shortDropoutHoldMs): silent pass-through, no counter

            metrics.maxAbsSmoothedRate = abs(newState.smoothedRate)
            return ([], newState, metrics)
        }

        // --- Non-empty batch: clear dropout window if one was open ---
        if let dropStart = state.dropoutStartRelativeTime {
            let dropoutMs = max(0, (flushRelativeTime - dropStart) * 1000)
            metrics.lastDropoutDuration = dropoutMs
            newState.dropoutStartRelativeTime = nil
        }

        var accepted: [TimecodeDecodedFrame] = []
        var currentSmoothed = state.smoothedRate
        let hasContext = abs(currentSmoothed) > 1e-9

        for frame in frames {
            let rawRate = frame.velocity
            metrics.rawRate = rawRate

            // --- Confidence gate ---
            if frame.confidence < config.minConfidenceForUpdate {
                metrics.rejectedSpikeCount += 1
                metrics.lowConfidenceRejectCount += 1
                metrics.lastSpikeReason = "low_confidence"
                if metrics.firstRejectReason.isEmpty {
                    metrics.firstRejectReason = metrics.lastSpikeReason
                }
                continue
            }

            // --- Direction-reversal detection ---
            let isReversal = isGenuineReversal(
                rawRate: rawRate,
                lastDirection: newState.lastAcceptedDirection
            )

            // --- Spike rejection ---
            // Only spike-check when we have prior context (non-zero smoothedRate).
            // Genuine reversals are always passed through — they are real events,
            // not noise, and would look like spikes because the sign flips.
            if hasContext && !isReversal {
                let rateDelta = abs(rawRate - currentSmoothed)
                if rateDelta > config.maxRateDeltaPerSecond {
                    metrics.rejectedSpikeCount += 1
                    metrics.rateSpikeRejectCount += 1
                    metrics.lastSpikeReason = String(
                        format: "rate_spike_%.1f_delta_per_s", rateDelta
                    )
                    if metrics.firstRejectReason.isEmpty {
                        metrics.firstRejectReason = metrics.lastSpikeReason
                    }
                    continue
                }
            }

            // --- Accept: update EMA ---
            currentSmoothed = config.smoothingAlpha * rawRate
                + (1.0 - config.smoothingAlpha) * currentSmoothed
            metrics.smoothingActive = true

            accepted.append(frame)
            newState.lastAcceptedRelativeTime = frame.relativeTime
            if frame.direction != .unknown {
                newState.lastAcceptedDirection = frame.direction
            }
        }

        newState.smoothedRate = currentSmoothed
        metrics.smoothedRate = currentSmoothed
        metrics.maxAbsSmoothedRate = abs(currentSmoothed)

        return (accepted, newState, metrics)
    }

    // MARK: - Private helpers

    /// Returns true when `rawRate` represents a genuine direction change from
    /// `lastDirection`. Used to suppress spike rejection on real reversals.
    private func isGenuineReversal(
        rawRate: Double,
        lastDirection: TimecodeDirection
    ) -> Bool {
        guard lastDirection != .unknown else { return false }
        switch lastDirection {
        case .forward:  return rawRate < -1e-6
        case .backward: return rawRate > 1e-6
        case .unknown:  return false
        }
    }
}
