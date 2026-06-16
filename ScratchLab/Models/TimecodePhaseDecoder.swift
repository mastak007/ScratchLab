import Foundation

// MARK: - TimecodePhaseDecoder

/// **Prototype** phase-based timecode decoder.
///
/// Extracts platter motion (direction, velocity, position delta) from
/// synthetic stereo audio buffers carrying a known carrier frequency with
/// a phase relationship between the left and right channels.
///
/// ## Algorithm (quadrature correlation)
///
/// 1. For each stereo input buffer, compute RMS and peak to reject
///    silence and clipping.
/// 2. Cross-correlate each channel against reference sine and cosine at
///    the configured carrier frequency.
/// 3. Extract per-channel instantaneous phase via `atan2`.
/// 4. Compute the phase delta between right and left channels.
/// 5. Track the unwrapped phase delta across consecutive buffers to
///    determine direction and velocity.
/// 6. Smooth single-sample spikes with a median-3 filter on the phase
///    delta sequence.
/// 7. Compute per-frame confidence from correlation magnitude, channel
///    balance, and signal level.
///
/// ## What this is NOT
///
/// - Does NOT decode Serato, SDJ, Traktor, or any commercial timecode format.
/// - Does NOT perform FSK demodulation.
/// - Does NOT lock to live audio hardware.
/// - Does NOT stream — it decodes batches of pre-buffered stereo inputs.
///
/// **Batch 2:** Prototype / fixture-driven only. Live audio tap integration
/// is reserved for Batch 3.
public struct TimecodePhaseDecoder: Sendable {

    // MARK: - StereoInput

    /// A single chunk of raw stereo audio to decode.
    public struct StereoInput: Equatable, Sendable {
        /// Left channel samples, normalised to [-1, 1].
        public let left: [Float]
        /// Right channel samples, normalised to [-1, 1].
        public let right: [Float]
        /// Sample rate in Hz (e.g. 44100, 48000).
        public let sampleRate: Double
        /// Host-clock timestamp, if available.
        public let hostTime: UInt64?
        /// Seconds since the start of the decode session.
        public let relativeTime: TimeInterval

        public init(
            left: [Float],
            right: [Float],
            sampleRate: Double,
            hostTime: UInt64? = nil,
            relativeTime: TimeInterval = 0
        ) {
            self.left = left
            self.right = right
            self.sampleRate = sampleRate
            self.hostTime = hostTime
            self.relativeTime = relativeTime
        }
    }

    // MARK: - Configuration

    /// Expected carrier frequency in Hz (default 1000 Hz for synthetic fixtures).
    public let carrierFrequency: Float

    /// RMS below this value is treated as silence and dropped.
    public let silenceThresholdRMS: Float

    /// Any sample with absolute value ≥ this is treated as clipping.
    public let clippingThreshold: Float

    /// Minimum correlation magnitude for a valid phase lock, in [0, 1].
    /// Below this, the frame is dropped with `.noPhaseLock`.
    public let minCorrelationMagnitude: Double

    /// Minimum confidence for a frame to be considered trusted.
    public let minConfidence: Double

    // MARK: - Init

    public init(
        carrierFrequency: Float = 1000,
        silenceThresholdRMS: Float = 0.001,
        clippingThreshold: Float = 0.999,
        minCorrelationMagnitude: Double = 0.1,
        minConfidence: Double = 0.3
    ) {
        self.carrierFrequency = carrierFrequency
        self.silenceThresholdRMS = silenceThresholdRMS
        self.clippingThreshold = clippingThreshold
        self.minCorrelationMagnitude = minCorrelationMagnitude
        self.minConfidence = minConfidence
    }

    // MARK: - Decode

    /// Decode a sequence of stereo audio buffers into timecode motion frames.
    ///
    /// - Parameter inputs: Stereo audio buffers in time order.
    /// - Returns: A `TimecodeDecodeResult` with decoded frames, diagnostics,
    ///   and debug counters.
    public func decode(_ inputs: [StereoInput]) -> TimecodeDecodeResult {
        guard !inputs.isEmpty else {
            return .empty(reason: .silence)
        }

        var counters = TimecodeDecoderCounters()
        var frames: [TimecodeDecodedFrame] = []
        var rawPhases: [Double] = []        // right-left phase per valid input
        var rawTimes: [TimeInterval] = []    // relativeTime per valid input
        var rawConfidences: [Double] = []    // per-input confidence
        var cumulativePosition: Double = 0
        var previousDirection: TimecodeDirection = .unknown
        var anyClipping = false
        var anySilence = true
        var sumConfidence: Double = 0

        for input in inputs {
            // --- Silence check ---
            let leftRMS = rms(input.left)
            let rightRMS = rms(input.right)
            let effectiveRMS = max(leftRMS, rightRMS)

            if effectiveRMS < silenceThresholdRMS {
                counters.droppedSilence += 1
                continue
            }
            anySilence = false

            // --- Clipping check ---
            let leftPeak = peak(input.left)
            let rightPeak = peak(input.right)
            let isClipping = leftPeak >= clippingThreshold || rightPeak >= clippingThreshold
            if isClipping {
                counters.droppedClipped += 1
                anyClipping = true
                continue
            }

            // --- Phase extraction via quadrature correlation ---
            let (phase, corrMag) = extractPhaseDelta(
                left: input.left,
                right: input.right,
                frequency: carrierFrequency,
                sampleRate: input.sampleRate
            )

            // --- Phase-lock check ---
            if corrMag < minCorrelationMagnitude {
                // Weak correlation — can't trust the phase
                continue
            }

            // --- Channel balance ---
            let balance = channelBalance(leftRMS: leftRMS, rightRMS: rightRMS)

            // --- Signal level score ---
            let levelScore = signalLevelScore(rms: effectiveRMS)

            // --- Confidence ---
            let confidence = corrMag * balance * levelScore
            let clampedConfidence = min(max(confidence, 0), 1)

            counters.decodedSamples += 1
            rawPhases.append(phase)
            rawTimes.append(input.relativeTime)
            rawConfidences.append(clampedConfidence)
            sumConfidence += clampedConfidence

            // Store host time for frame construction
            // We'll build frames after spike smoothing
        }

        // --- All inputs dropped? ---
        if rawPhases.isEmpty {
            let health = classifyHealth(anySilence: anySilence, anyClipping: anyClipping, hasSignal: !anySilence)
            let reason: TimecodeDropoutReason
            if anySilence && !anyClipping {
                reason = .silence
            } else if anyClipping && anySilence {
                reason = .clipped
            } else if counters.decodedSamples == 0 {
                reason = .noPhaseLock
            } else {
                reason = .lowConfidence
            }
            var result = TimecodeDecodeResult.empty(reason: reason, signalHealth: health)
            result = TimecodeDecodeResult(
                frames: [],
                averageConfidence: 0,
                signalHealth: health,
                dropoutReason: reason,
                counters: counters
            )
            return result
        }

        // --- Compute phase deltas between consecutive valid inputs ---
        var deltas: [Double] = []
        for i in 1..<rawPhases.count {
            let dt = rawTimes[i] - rawTimes[i - 1]
            let dp = unwrapPhaseDelta(rawPhases[i] - rawPhases[i - 1])
            deltas.append(dp / max(dt, 1e-9))  // phase velocity (rad/s)
        }

        // --- Spike smoothing (median-3) ---
        let smoothedDeltas = median3Filter(deltas)

        // --- Build frames ---
        for i in 0..<smoothedDeltas.count {
            let inputIndex = i + 1  // first delta is between input[0] and input[1]
            let velocity = smoothedDeltas[i]
            let absVelocity = abs(velocity)

            // Direction
            let direction: TimecodeDirection
            if velocity > 1e-6 {
                direction = .forward
            } else if velocity < -1e-6 {
                direction = .backward
            } else {
                direction = .unknown
            }

            // Track direction changes
            if direction != .unknown && direction != previousDirection && previousDirection != .unknown {
                counters.directionChanges += 1
            }
            if direction != .unknown {
                previousDirection = direction
            }

            // Track max rate
            if absVelocity > counters.maxAbsRate {
                counters.maxAbsRate = absVelocity
            }

            // Cumulative position
            let deltaPosition = velocity * (rawTimes[inputIndex] - rawTimes[inputIndex - 1])
            cumulativePosition += deltaPosition

            let confidence = rawConfidences[inputIndex]

            let frame = TimecodeDecodedFrame(
                hostTime: inputs.first(where: { $0.relativeTime == rawTimes[inputIndex] })?.hostTime,
                relativeTime: rawTimes[inputIndex],
                position: cumulativePosition,
                deltaPosition: deltaPosition,
                velocity: velocity,
                direction: direction,
                confidence: confidence
            )
            frames.append(frame)
        }

        // --- Aggregate counters ---
        let avgConfidence = rawConfidences.isEmpty ? 0 : sumConfidence / Double(rawConfidences.count)
        counters.averageConfidence = avgConfidence

        let health = classifyHealth(anySilence: anySilence, anyClipping: anyClipping, hasSignal: !rawPhases.isEmpty)
        counters.signalHealth = health.rawValue

        // --- Dropout reason ---
        var dropoutReason: TimecodeDropoutReason? = nil
        if counters.droppedSilence > 0 && frames.isEmpty {
            dropoutReason = .silence
        } else if counters.droppedClipped > 0 && frames.isEmpty {
            dropoutReason = .clipped
        }

        return TimecodeDecodeResult(
            frames: frames,
            averageConfidence: avgConfidence,
            signalHealth: health,
            dropoutReason: dropoutReason,
            counters: counters
        )
    }

    // MARK: - Phase extraction

    /// Extract the phase difference between the right and left channels at the
    /// carrier frequency using quadrature correlation.
    ///
    /// - Returns: A tuple of `(phaseDelta, correlationMagnitude)` where:
    ///   - `phaseDelta` is the right-channel phase minus the left-channel phase
    ///     (wrapped to [-π, π])
    ///   - `correlationMagnitude` is the geometric mean of the left and right
    ///     correlation magnitudes, normalised to [0, 1]
    private func extractPhaseDelta(
        left: [Float],
        right: [Float],
        frequency: Float,
        sampleRate: Double
    ) -> (phaseDelta: Double, correlationMagnitude: Double) {
        let N = min(left.count, right.count)
        guard N > 0 else { return (0, 0) }

        // Build reference quadrature oscillators
        var refSin = [Double](repeating: 0, count: N)
        var refCos = [Double](repeating: 0, count: N)
        let omega = 2 * Double.pi * Double(frequency) / sampleRate
        for i in 0..<N {
            let angle = omega * Double(i)
            refSin[i] = sin(angle)
            refCos[i] = cos(angle)
        }

        // Correlate left channel — use raw sum (do NOT average) so that
        // the magnitude scales with N. A unit-amplitude sine produces a
        // correlation magnitude of N/2, so normalising by N/2 gives the
        // signal amplitude directly.
        var leftSin = 0.0, leftCos = 0.0
        for i in 0..<N {
            let v = Double(left[i])
            leftSin += v * refSin[i]
            leftCos += v * refCos[i]
        }
        let leftPhase = atan2(leftCos, leftSin)
        let leftMag = sqrt(leftSin * leftSin + leftCos * leftCos)

        // Correlate right channel
        var rightSin = 0.0, rightCos = 0.0
        for i in 0..<N {
            let v = Double(right[i])
            rightSin += v * refSin[i]
            rightCos += v * refCos[i]
        }
        let rightPhase = atan2(rightCos, rightSin)
        let rightMag = sqrt(rightSin * rightSin + rightCos * rightCos)

        // Phase delta (right - left), wrapped to [-π, π]
        var delta = rightPhase - leftPhase
        delta = unwrapPhaseDelta(delta)

        // Correlation magnitude: normalise by N/2 (a unit-amplitude sine
        // produces N/2 correlation magnitude). Use geometric mean so one
        // dead channel pulls the confidence down.
        let norm = Double(N) / 2.0
        let leftNorm = norm > 0 ? leftMag / norm : 0
        let rightNorm = norm > 0 ? rightMag / norm : 0
        let corrMag = sqrt(leftNorm * rightNorm)  // geometric mean, clamped to [0,1] below

        return (delta, min(corrMag, 1.0))
    }

    // MARK: - Helpers

    /// Compute RMS of a sample buffer.
    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumSq = samples.reduce(0) { $0 + $1 * $1 }
        return sqrt(sumSq / Float(samples.count))
    }

    /// Compute peak absolute value of a sample buffer.
    private func peak(_ samples: [Float]) -> Float {
        samples.map { abs($0) }.max() ?? 0
    }

    /// Unwrap a phase delta to the range [-π, π].
    private func unwrapPhaseDelta(_ delta: Double) -> Double {
        var d = delta
        if d > .pi { d -= 2 * .pi }
        if d < -.pi { d += 2 * .pi }
        return d
    }

    /// Channel balance score: 1.0 when left and right RMS are equal,
    /// approaching 0 when one channel is silent.
    private func channelBalance(leftRMS: Float, rightRMS: Float) -> Double {
        let maxRMS = max(leftRMS, rightRMS)
        guard maxRMS > 0 else { return 0 }
        let minRMS = min(leftRMS, rightRMS)
        return Double(minRMS / maxRMS)
    }

    /// Signal level score: 0 at the silence threshold, ramping to 1 at
    /// healthy levels.
    private func signalLevelScore(rms: Float) -> Double {
        // Linear ramp from silenceThresholdRMS (score 0) to
        // 10 × silenceThresholdRMS (score 1), clamped.
        let floor = Double(silenceThresholdRMS)
        let ceiling = floor * 10
        guard ceiling > floor else { return 1 }
        let raw = (Double(rms) - floor) / (ceiling - floor)
        return min(max(raw, 0), 1)
    }

    /// Median-3 filter: each output element is the median of itself and its
    /// immediate neighbours. Endpoints pass through unchanged.
    private func median3Filter(_ values: [Double]) -> [Double] {
        guard values.count >= 3 else { return values }
        var result = values
        for i in 1..<(values.count - 1) {
            let window = [values[i - 1], values[i], values[i + 1]].sorted()
            result[i] = window[1]  // median
        }
        return result
    }

    /// Classify aggregate signal health from the decode pass.
    private func classifyHealth(anySilence: Bool, anyClipping: Bool, hasSignal: Bool) -> SignalHealth {
        if !hasSignal {
            if anyClipping && anySilence { return .clipped }
            if anySilence { return .noSignal }
            return .noSignal
        }
        if anyClipping { return .clipped }
        return .usable
    }
}
