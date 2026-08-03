import Foundation

// MARK: - TimecodeSignedRateDenseEstimatorConfiguration

/// Injectable tuning for the dense signed-rate estimator.
///
/// All fields describe generic quadrature-carrier signal properties (nominal
/// tone frequency, plausible frequency floor, silence floor, envelope
/// smoothing, direction-ambiguity margin) — nothing here encodes any specific
/// timecode format's bitstream, lookup table, or hysteresis constants.
public struct TimecodeSignedRateDenseEstimatorConfiguration: Equatable, Sendable {
    /// Carrier frequency (Hz) that corresponds to normalized signed rate
    /// ±1.0. Matches the nominal 1x reference used elsewhere in the shared
    /// timecode model layer.
    public var nominalCarrierFrequency: Double

    /// Below this measured frequency (Hz) a zero-crossing interval is too
    /// long to represent a plausible moving carrier; the estimator reports
    /// `.unknown` rather than guessing a near-zero rate.
    public var minimumCarrierFrequency: Double

    /// Plausibility bound on normalized speed magnitude. A crossing interval
    /// whose implied speed would exceed this bound is classified `.unknown`
    /// (ambiguous), not reported as an `.available` spike pinned to the bound —
    /// a single spurious short interval amid weak carrier must not look like
    /// real motion. Genuine speed at or below the bound is reported unchanged.
    public var maximumNormalizedSpeed: Double

    /// RMS floor below which both channels are considered to carry no
    /// usable carrier (`.noSignal`).
    public var silenceEnvelopeFloor: Double

    /// Time constant (seconds) of the exponential envelope tracker carried
    /// across blocks. Expressed in real elapsed time (not "per block") so
    /// the envelope — and therefore silence/no-signal detection and the
    /// direction-ambiguity floor — converges to the same values regardless
    /// of how the caller happens to chunk a continuous stream into blocks.
    public var envelopeTimeConstant: TimeInterval

    /// Fraction of the opposite channel's tracked envelope that its
    /// instantaneous value must exceed, in magnitude, at a zero crossing for
    /// direction to be reported rather than `.unknown`.
    public var directionAmbiguityFraction: Double

    /// Fixed calibration sign applied when direction is derived from a
    /// left-channel crossing. For a two-channel quadrature pair (left ≈ A
    /// cos θ, right ≈ A sin θ), the instantaneous rotation sign at a
    /// left-channel zero crossing equals `sign(leftEdgeSlope) *
    /// sign(rightValue) * leftCrossingDirectionSign` — the standard
    /// quadrature-encoder relationship (d(cos θ)/dt = -sin θ · dθ/dt).
    /// Must be `-1` or `1`.
    public var leftCrossingDirectionSign: Double

    /// Fixed calibration sign applied when direction is derived from a
    /// right-channel crossing (`d(sin θ)/dt = cos θ · dθ/dt`). Must be `-1`
    /// or `1`, and must be independently derivable from the same physical
    /// convention as `leftCrossingDirectionSign` — see type documentation.
    public var rightCrossingDirectionSign: Double

    public init(
        nominalCarrierFrequency: Double = 1_000,
        minimumCarrierFrequency: Double = 50,
        maximumNormalizedSpeed: Double = 20,
        silenceEnvelopeFloor: Double = 0.001,
        envelopeTimeConstant: TimeInterval = 0.005,
        directionAmbiguityFraction: Double = 0.15,
        leftCrossingDirectionSign: Double = -1,
        rightCrossingDirectionSign: Double = 1
    ) {
        self.nominalCarrierFrequency = nominalCarrierFrequency
        self.minimumCarrierFrequency = minimumCarrierFrequency
        self.maximumNormalizedSpeed = maximumNormalizedSpeed
        self.silenceEnvelopeFloor = silenceEnvelopeFloor
        self.envelopeTimeConstant = envelopeTimeConstant
        self.directionAmbiguityFraction = directionAmbiguityFraction
        self.leftCrossingDirectionSign = leftCrossingDirectionSign
        self.rightCrossingDirectionSign = rightCrossingDirectionSign
    }

    public var isValid: Bool {
        nominalCarrierFrequency.isFinite && nominalCarrierFrequency > 0
            && minimumCarrierFrequency.isFinite && minimumCarrierFrequency > 0
            && minimumCarrierFrequency < nominalCarrierFrequency
            && maximumNormalizedSpeed.isFinite && maximumNormalizedSpeed > 0
            && silenceEnvelopeFloor.isFinite && silenceEnvelopeFloor >= 0
            && envelopeTimeConstant.isFinite && envelopeTimeConstant > 0
            && directionAmbiguityFraction.isFinite
            && directionAmbiguityFraction >= 0 && directionAmbiguityFraction < 1
            && abs(leftCrossingDirectionSign) == 1
            && abs(rightCrossingDirectionSign) == 1
    }
}

// MARK: - TimecodeSignedRateDenseEstimatorInputBlock

/// One ordered, contiguous block of raw stereo samples from a quadrature-like
/// two-channel carrier. `startFrameIndex` is the absolute sample-frame offset
/// of `left[0]`/`right[0]` since an arbitrary but fixed stream origin, so the
/// caller (not wall-clock) supplies real sample timing and the estimator can
/// detect overlap/gaps deterministically.
public struct TimecodeSignedRateDenseEstimatorInputBlock: Equatable, Sendable {
    public let left: [Float]
    public let right: [Float]
    public let sampleRate: Double
    public let startFrameIndex: Int

    public init(left: [Float], right: [Float], sampleRate: Double, startFrameIndex: Int) {
        self.left = left
        self.right = right
        self.sampleRate = sampleRate
        self.startFrameIndex = startFrameIndex
    }

    var frameCount: Int { min(left.count, right.count) }
}

// MARK: - TimecodeSignedRateDenseEstimatorBlockStatus

/// Deterministic outcome of consuming one input block.
public enum TimecodeSignedRateDenseEstimatorBlockStatus: Equatable, Sendable {
    /// The block was contiguous with prior state and fully processed.
    case processed

    /// The block itself was rejected: mismatched channel lengths, empty,
    /// non-finite samples, non-finite/non-positive sample rate, or a sample
    /// rate that differs from the rate already established for this stream.
    /// Continuity state is reset; no samples are emitted.
    case invalidBlock

    /// `configuration.isValid` was false. Continuity state is reset; no
    /// samples are emitted.
    case invalidConfiguration

    /// `startFrameIndex` did not advance past previously consumed frames
    /// (overlap or rewind). Continuity and envelope state are both reset,
    /// since the next accepted recovery stream may begin at an unrelated
    /// frame origin; no samples are emitted for this block.
    case nonMonotonicFrameIndex

    /// `startFrameIndex` skipped ahead of the expected next frame. The block
    /// itself is still processed (its own samples are real), but continuity
    /// evidence spanning the gap is discarded first so no crossing or
    /// envelope state from before the gap is reused across it.
    case gapDetected(duration: TimeInterval)
}

// MARK: - TimecodeSignedRateDenseEstimatorBlockResult

public struct TimecodeSignedRateDenseEstimatorBlockResult: Equatable, Sendable {
    public let status: TimecodeSignedRateDenseEstimatorBlockStatus
    public let samples: [TimecodeSignedRateSample]

    public init(
        status: TimecodeSignedRateDenseEstimatorBlockStatus,
        samples: [TimecodeSignedRateSample]
    ) {
        self.status = status
        self.samples = samples
    }
}

// MARK: - TimecodeSignedRateDenseEstimator

/// Pure, platform-agnostic dense signed-rate estimator.
///
/// Produces a stream of timestamped `TimecodeSignedRateSample` values —
/// exactly the type `TimecodeSignedRateExcursionStabilizer` consumes — dense
/// enough to observe fast reversals that a per-callback-window decoder can
/// miss entirely within one window.
///
/// **Derivation.** Two nominally-quadrature channels (left/right ~90° apart,
/// the same channel relationship the existing prototype decoder already
/// assumes) are decoded with textbook quadrature-encoder logic. Writing the
/// pair as left ≈ A cos θ(t), right ≈ A sin θ(t), the standard
/// quadrature-decoder identity gives the instantaneous rotation sign
/// directly at any zero crossing:
///   - at a left crossing: `sign(θ') = sign(leftSlope) · sign(right) · leftCrossingDirectionSign`
///   - at a right crossing: `sign(θ') = sign(rightSlope) · sign(left) · rightCrossingDirectionSign`
/// (from d(cos θ)/dt = -sin θ·θ' and d(sin θ)/dt = cos θ·θ'). This is the
/// same relationship used to decode any two-phase rotary encoder — not
/// "other channel's raw sign" alone, which only recovers phase quadrant, not
/// direction. The elapsed time since the previous same-channel crossing
/// gives a local half-period, hence a local carrier frequency, hence a
/// normalized speed relative to `nominalCarrierFrequency`. This produces one
/// candidate sample per detected crossing — roughly twice the carrier
/// frequency, i.e. hundreds to thousands of samples/sec at typical DVS
/// carrier speeds — instead of one sample per multi-hundred- or
/// multi-thousand-frame decode window.
///
/// This is a generic, decades-old signal-processing technique (quadrature
/// zero-crossing decoding) independently derived from ScratchLab's own
/// two-channel signal assumptions. It shares no code, constants, tables, or
/// architecture with any third-party timecode decoder.
///
/// **What it does not do.** It never consults absolute-position lock (there
/// is none here), never interpolates or fabricates a sample across a
/// dropout/gap, and never re-derives a crossing from data before a detected
/// gap. Cross-block continuity (the last raw sample and last crossing time
/// per channel, plus the persistent envelope estimate) is preserved only
/// while blocks remain exactly contiguous.
///
/// **Chunking invariance.** Crossing timestamps, signed rates, signal states
/// (`.available`/`.unknown`), and the persisted envelope/continuity state are
/// identical for the same continuous input regardless of how the caller
/// slices it into blocks — including a variable-amplitude carrier, not just
/// a constant-amplitude one, because the envelope is a per-real-sample
/// exponential power tracker (`power += alpha · (sample² − power)`, `alpha`
/// derived from the real elapsed time between consecutive samples and
/// `envelopeTimeConstant`) rather than a once-per-call blend over a
/// block-aggregate RMS. The one deliberate exception: `.noSignal` marker
/// *count* and *timestamp* are a property of how the caller chunks calls to
/// `consume`, not of the underlying audio — one marker is emitted per call
/// whose block is, in aggregate, below `silenceEnvelopeFloor`, stamped at
/// that call's own `startFrameIndex`. Splitting an identical silent span
/// into more calls produces more markers. This is intentional and tested
/// explicitly; it is not a broken invariant.
///
/// No production call site exists for this type. It exists to be measured
/// offline and, if ever approved, to feed
/// `TimecodeSignedRateExcursionStabilizer` — never `TimecodePhaseDecoder`,
/// `TimecodeControlPipeline`, capture, playback, notation, export, or UI.
public struct TimecodeSignedRateDenseEstimator: Sendable, Equatable {
    public let configuration: TimecodeSignedRateDenseEstimatorConfiguration

    private var establishedSampleRate: Double?
    private var expectedNextFrameIndex: Int?

    /// Mean-square power per channel, updated one real sample at a time.
    /// The RMS envelope used for silence/ambiguity gating is `sqrt` of this.
    private var envelopePowerLeft: Double = 0
    private var envelopePowerRight: Double = 0
    private var hasEnvelope: Bool = false

    private var previousLeftSample: Double?
    private var previousRightSample: Double?
    private var previousSampleTime: TimeInterval?

    private var lastLeftCrossingTime: TimeInterval?
    private var lastRightCrossingTime: TimeInterval?

    public init(configuration: TimecodeSignedRateDenseEstimatorConfiguration) {
        self.configuration = configuration
    }

    /// Consume one ordered block and return every dense sample it produced.
    public mutating func consume(
        _ block: TimecodeSignedRateDenseEstimatorInputBlock
    ) -> TimecodeSignedRateDenseEstimatorBlockResult {
        guard configuration.isValid else {
            resetAll()
            return .init(status: .invalidConfiguration, samples: [])
        }

        guard block.sampleRate.isFinite, block.sampleRate > 0,
              block.startFrameIndex >= 0,
              block.left.count == block.right.count,
              !block.left.isEmpty else {
            resetAll()
            return .init(status: .invalidBlock, samples: [])
        }

        for value in block.left where !value.isFinite {
            resetAll()
            return .init(status: .invalidBlock, samples: [])
        }
        for value in block.right where !value.isFinite {
            resetAll()
            return .init(status: .invalidBlock, samples: [])
        }

        if let establishedSampleRate, establishedSampleRate != block.sampleRate {
            resetAll()
            return .init(status: .invalidBlock, samples: [])
        }
        establishedSampleRate = block.sampleRate

        if let expectedNextFrameIndex {
            if block.startFrameIndex < expectedNextFrameIndex {
                // A rewound/overlapping block breaks stream continuity just
                // as a forward gap does, and the next accepted recovery
                // stream may begin at an unrelated frame origin — so the
                // persisted envelope must not outlive this rejection either.
                resetContinuityAndEnvelope()
                self.expectedNextFrameIndex = nil
                return .init(status: .nonMonotonicFrameIndex, samples: [])
            }
            if block.startFrameIndex > expectedNextFrameIndex {
                let gapFrames = block.startFrameIndex - expectedNextFrameIndex
                let gapDuration = Double(gapFrames) / block.sampleRate
                // A frame gap is a genuine discontinuity: post-gap
                // classification must never depend on pre-gap amplitude,
                // crossing, or timing evidence, so both crossing continuity
                // and the persisted envelope reset together.
                resetContinuityAndEnvelope()
                let samples = process(block: block)
                self.expectedNextFrameIndex = block.startFrameIndex + block.frameCount
                return .init(status: .gapDetected(duration: gapDuration), samples: samples)
            }
        }

        let samples = process(block: block)
        expectedNextFrameIndex = block.startFrameIndex + block.frameCount
        return .init(status: .processed, samples: samples)
    }

    public mutating func reset() {
        resetAll()
    }

    // MARK: - State reset

    private mutating func resetAll() {
        establishedSampleRate = nil
        expectedNextFrameIndex = nil
        resetContinuityAndEnvelope()
    }

    private mutating func resetContinuity() {
        previousLeftSample = nil
        previousRightSample = nil
        previousSampleTime = nil
        lastLeftCrossingTime = nil
        lastRightCrossingTime = nil
    }

    private mutating func resetEnvelope() {
        envelopePowerLeft = 0
        envelopePowerRight = 0
        hasEnvelope = false
    }

    private mutating func resetContinuityAndEnvelope() {
        resetContinuity()
        resetEnvelope()
    }

    // MARK: - Block processing

    private mutating func process(
        block: TimecodeSignedRateDenseEstimatorInputBlock
    ) -> [TimecodeSignedRateSample] {
        let sampleRate = block.sampleRate
        let n = block.frameCount
        let blockStartTime = Double(block.startFrameIndex) / sampleRate

        // Per-real-sample exponential power update: the elapsed time between
        // any two consecutive contiguous audio frames at this sample rate is
        // always exactly `1 / sampleRate`, independent of how the caller
        // happened to group frames into blocks, so `alpha` (and therefore
        // the resulting envelope trajectory) is identical for the same
        // continuous samples regardless of chunking. This replaces the
        // former once-per-call blend over a block-aggregate RMS, which
        // produced different envelope histories for different block
        // boundaries whenever amplitude varied within/across blocks.
        let perSampleAlpha = 1 - exp(-(1.0 / sampleRate) / configuration.envelopeTimeConstant)

        var samples: [TimecodeSignedRateSample] = []
        samples.reserveCapacity(max(n / 8, 1))

        var prevL = previousLeftSample
        var prevR = previousRightSample
        var prevT = previousSampleTime ?? blockStartTime

        for i in 0..<n {
            let l = Double(block.left[i])
            let r = Double(block.right[i])
            let t = Double(block.startFrameIndex + i) / sampleRate

            if hasEnvelope {
                envelopePowerLeft += perSampleAlpha * (l * l - envelopePowerLeft)
                envelopePowerRight += perSampleAlpha * (r * r - envelopePowerRight)
            } else {
                envelopePowerLeft = l * l
                envelopePowerRight = r * r
                hasEnvelope = true
            }

            if let prevLeft = prevL, crossesZero(prevLeft, l) {
                let crossingTime = interpolatedCrossing(v0: prevLeft, t0: prevT, v1: l, t1: t)
                if let sample = evaluateCrossing(
                    crossingTime: crossingTime,
                    lastCrossingTime: &lastLeftCrossingTime,
                    edgeSign: l > prevLeft ? 1 : -1,
                    otherChannelValue: r,
                    otherEnvelope: envelopePowerRight.squareRoot(),
                    directionCalibration: configuration.leftCrossingDirectionSign
                ) {
                    samples.append(sample)
                }
            }

            if let prevRight = prevR, crossesZero(prevRight, r) {
                let crossingTime = interpolatedCrossing(v0: prevRight, t0: prevT, v1: r, t1: t)
                if let sample = evaluateCrossing(
                    crossingTime: crossingTime,
                    lastCrossingTime: &lastRightCrossingTime,
                    edgeSign: r > prevRight ? 1 : -1,
                    otherChannelValue: l,
                    otherEnvelope: envelopePowerLeft.squareRoot(),
                    directionCalibration: configuration.rightCrossingDirectionSign
                ) {
                    samples.append(sample)
                }
            }

            prevL = l
            prevR = r
            prevT = t
        }

        // The silence gate is evaluated once per call, against the envelope
        // as of the end of this block — an intentionally block-shaped
        // decision (see the type's "Chunking invariance" documentation).
        // Crossings found earlier in a block that ends up classified silent
        // are discarded along with it, matching the pre-fix block-level gate
        // shape exactly; only the smoothing formula that feeds it changed.
        let finalEnvelopeMagnitude = max(envelopePowerLeft.squareRoot(), envelopePowerRight.squareRoot())
        guard finalEnvelopeMagnitude >= configuration.silenceEnvelopeFloor else {
            resetContinuity()
            return [TimecodeSignedRateSample(
                timestamp: blockStartTime,
                signedRate: 0,
                signalState: .noSignal
            )]
        }

        previousLeftSample = prevL
        previousRightSample = prevR
        previousSampleTime = prevT

        return samples
    }

    // MARK: - Crossing evaluation

    private func evaluateCrossing(
        crossingTime: TimeInterval,
        lastCrossingTime: inout TimeInterval?,
        edgeSign: Double,
        otherChannelValue: Double,
        otherEnvelope: Double,
        directionCalibration: Double
    ) -> TimecodeSignedRateSample? {
        defer { lastCrossingTime = crossingTime }

        guard let previous = lastCrossingTime, crossingTime > previous else {
            return nil
        }

        let halfPeriod = crossingTime - previous
        guard halfPeriod > 0 else { return nil }
        let frequency = 1.0 / (2.0 * halfPeriod)

        guard frequency.isFinite, frequency >= configuration.minimumCarrierFrequency else {
            return TimecodeSignedRateSample(
                timestamp: crossingTime, signedRate: 0, signalState: .unknown
            )
        }

        let ambiguityFloor = configuration.directionAmbiguityFraction * otherEnvelope
        guard abs(otherChannelValue) >= ambiguityFloor else {
            return TimecodeSignedRateSample(
                timestamp: crossingTime, signedRate: 0, signalState: .unknown
            )
        }

        let rawNormalizedSpeed = frequency / configuration.nominalCarrierFrequency
        guard rawNormalizedSpeed <= configuration.maximumNormalizedSpeed else {
            return TimecodeSignedRateSample(
                timestamp: crossingTime, signedRate: 0, signalState: .unknown
            )
        }
        let normalizedSpeed = rawNormalizedSpeed
        let otherSign: Double = otherChannelValue > 0 ? 1 : -1
        let directionSign = edgeSign * otherSign * directionCalibration
        let signedRate = directionSign * normalizedSpeed

        return TimecodeSignedRateSample(
            timestamp: crossingTime, signedRate: signedRate, signalState: .available
        )
    }

    // MARK: - Helpers

    private func crossesZero(_ previous: Double, _ current: Double) -> Bool {
        (previous >= 0) != (current >= 0) && previous != current
    }

    private func interpolatedCrossing(
        v0: Double, t0: TimeInterval, v1: Double, t1: TimeInterval
    ) -> TimeInterval {
        let denominator = v0 - v1
        guard denominator != 0 else { return t1 }
        let fraction = min(max(v0 / denominator, 0), 1)
        return t0 + (t1 - t0) * fraction
    }
}
