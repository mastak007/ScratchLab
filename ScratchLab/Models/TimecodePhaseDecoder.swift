import Foundation

// MARK: - TimecodePhaseDecoder

/// **Prototype** phase-based timecode decoder.
///
/// Extracts platter motion (direction and speed) from stereo audio buffers.
///
/// **Direction** is derived from the direct cross-channel phase offset
/// (rightPhase - leftPhase) at the nominal carrier frequency:
///   - Negative offset (~-80°) → forward.
///   - Positive offset (~+80°) → backward.
///   - A ±30° dead-band prevents ambiguous flips.
///
/// **Speed** is derived from the ZCR frequency ratio (measured / carrier).
///
/// **Confidence** combines correlation quality, channel balance, and signal level.
/// Confidence gating is handled downstream by the adapter and stability filter.
public struct TimecodePhaseDecoder: Sendable {
    /// Phase-offset dead-band half-width (30°).
    private static let phaseDeadBand: Double = .pi / 6

    /// Minimum ZCR frequency (Hz) for a plausible control tone.
    private static let minimumCarrierHz: Double = 50.0

    // MARK: - Configuration

    public let carrierFrequency: Float
    public let silenceThresholdRMS: Float
    public let clippingThreshold: Float
    public let minCorrelationMagnitude: Double

    // MARK: - Init

    public init(
        carrierFrequency: Float = 1000,
        silenceThresholdRMS: Float = 0.001,
        clippingThreshold: Float = 0.999,
        minCorrelationMagnitude: Double = 0.1
    ) {
        self.carrierFrequency = carrierFrequency
        self.silenceThresholdRMS = silenceThresholdRMS
        self.clippingThreshold = clippingThreshold
        self.minCorrelationMagnitude = minCorrelationMagnitude
    }

    // MARK: - StereoInput

    public struct StereoInput: Equatable, Sendable {
        public let left: [Float]
        public let right: [Float]
        public let sampleRate: Double
        public let hostTime: UInt64?
        public let relativeTime: TimeInterval

        public init(left: [Float], right: [Float], sampleRate: Double,
                    hostTime: UInt64? = nil, relativeTime: TimeInterval = 0) {
            self.left = left; self.right = right
            self.sampleRate = sampleRate; self.hostTime = hostTime; self.relativeTime = relativeTime
        }
    }

    // MARK: - Decode

    public func decode(_ inputs: [StereoInput]) -> TimecodeDecodeResult {
        guard !inputs.isEmpty else { return .empty(reason: .silence) }

        var counters = TimecodeDecoderCounters()
        var frames: [TimecodeDecodedFrame] = []
        var previousDirection: TimecodeDirection = .unknown
        var anyClipping = false
        var anySilence = true

        for input in inputs {
            // --- Silence check ---
            let leftRMS = rms(input.left)
            let rightRMS = rms(input.right)
            let effectiveRMS = max(leftRMS, rightRMS)
            if effectiveRMS < silenceThresholdRMS {
                counters.droppedSilence += 1; continue
            }
            anySilence = false

            // --- Clipping check ---
            if peak(input.left) >= clippingThreshold || peak(input.right) >= clippingThreshold {
                counters.droppedClipped += 1; anyClipping = true; continue
            }

            // --- ZCR frequency estimate ---
            let lFreq = zcrFrequency(input.left, sampleRate: input.sampleRate)
            let rFreq = zcrFrequency(input.right, sampleRate: input.sampleRate)
            let validFreqs = [lFreq, rFreq].filter { $0 >= Self.minimumCarrierHz }
            guard !validFreqs.isEmpty else {
                counters.droppedLowConfidence += 1; continue
            }
            let sorted = validFreqs.sorted()
            let measuredFreq = sorted[sorted.count / 2]

            // --- Phase extraction at the measured carrier ---
            // The control-vinyl carrier scales with platter speed: measured
            // hardware spans roughly 93 Hz during very slow motion through
            // 3.1 kHz during fast motion. Fitting every buffer against the
            // nominal 1 kHz carrier therefore loses phase lock away from 1x,
            // even though diagnostics correctly identify quadrature. Use the
            // per-buffer ZCR estimate for the sine/cosine reference; retain
            // nominal carrierFrequency only as the 1x speed denominator.
            let (phaseOffset, corrMag) = extractPhaseDelta(
                left: input.left, right: input.right,
                frequency: Float(measuredFreq), sampleRate: input.sampleRate,
                relativeTime: input.relativeTime
            )
            guard corrMag >= minCorrelationMagnitude else {
                counters.droppedLowConfidence += 1; continue
            }

            // --- Confidence ---
            let balance = channelBalance(l: leftRMS, r: rightRMS)
            let levelScore = signalLevelScore(rms: effectiveRMS)
            let confidence = min(max(corrMag * balance * levelScore, 0), 1)

            counters.decodedSamples += 1

            // --- Direction from phase offset sign ---
            let direction: TimecodeDirection
            if phaseOffset < -Self.phaseDeadBand { direction = .forward }
            else if phaseOffset > Self.phaseDeadBand { direction = .backward }
            else { direction = .unknown }

            // Track direction changes
            if direction != .unknown && direction != previousDirection && previousDirection != .unknown {
                counters.directionChanges += 1
            }
            if direction != .unknown { previousDirection = direction }

            // --- Speed from ZCR frequency ratio ---
            let speedRatio = measuredFreq / Double(carrierFrequency)
            let clampedSpeed = min(max(speedRatio, 0.05), 20.0)
            let velocitySign: Double = direction == .forward ? 1.0 : (direction == .backward ? -1.0 : 0.0)
            let velocity = velocitySign * clampedSpeed

            // Track max rate
            if abs(velocity) > counters.maxAbsRate { counters.maxAbsRate = abs(velocity) }

            // Integrate over the audio represented by this input. The live
            // Rane currently supplies 4,800 frames at 48 kHz (100 ms), but
            // fixtures and future devices are not required to use that exact
            // callback duration.
            let frameCount = min(input.left.count, input.right.count)
            let inputDuration = input.sampleRate > 0
                ? Double(frameCount) / input.sampleRate
                : 0

            let frame = TimecodeDecodedFrame(
                hostTime: input.hostTime, relativeTime: input.relativeTime,
                position: 0, deltaPosition: velocity * inputDuration,
                velocity: velocity, direction: direction,
                confidence: confidence
            )
            frames.append(frame)
        }

        let avgConfidence = frames.isEmpty ? 0 : frames.map(\.confidence).reduce(0, +) / Double(frames.count)
        counters.averageConfidence = avgConfidence
        counters.frameConfidenceMin = frames.map(\.confidence).min() ?? 0
        counters.frameConfidenceMax = frames.map(\.confidence).max() ?? 0
        let health = classifyHealth(anySilence: anySilence, anyClipping: anyClipping, hasSignal: !frames.isEmpty)
        counters.signalHealth = health.rawValue

        return TimecodeDecodeResult(
            frames: frames, averageConfidence: avgConfidence,
            signalHealth: health,
            dropoutReason: frames.isEmpty ? (anySilence ? .silence : .noPhaseLock) : nil,
            counters: counters
        )
    }

    // MARK: - Phase extraction

    private func extractPhaseDelta(left: [Float], right: [Float], frequency: Float,
                                   sampleRate: Double, relativeTime: TimeInterval
    ) -> (phaseDelta: Double, correlationMagnitude: Double) {
        let N = min(left.count, right.count)
        guard N > 0 else { return (0, 0) }
        var refSin = [Double](repeating: 0, count: N)
        var refCos = [Double](repeating: 0, count: N)
        let omega = 2 * Double.pi * Double(frequency) / sampleRate
        for i in 0..<N { let a = omega * (relativeTime * sampleRate + Double(i)); refSin[i] = sin(a); refCos[i] = cos(a) }

        var sinSin = 0.0, sinCos = 0.0, cosCos = 0.0
        for i in 0..<N { sinSin += refSin[i] * refSin[i]; sinCos += refSin[i] * refCos[i]; cosCos += refCos[i] * refCos[i] }
        let det = sinSin * cosCos - sinCos * sinCos
        guard abs(det) > 1e-12 else { return (0, 0) }

        var lSinP = 0.0, lCosP = 0.0
        for i in 0..<N { let v = Double(left[i]); lSinP += v * refSin[i]; lCosP += v * refCos[i] }
        let lSC = (lSinP * cosCos - lCosP * sinCos) / det
        let lCC = (lCosP * sinSin - lSinP * sinCos) / det
        let lPhase = atan2(lCC, lSC)
        let lMag = sqrt(lSC * lSC + lCC * lCC)

        var rSinP = 0.0, rCosP = 0.0
        for i in 0..<N { let v = Double(right[i]); rSinP += v * refSin[i]; rCosP += v * refCos[i] }
        let rSC = (rSinP * cosCos - rCosP * sinCos) / det
        let rCC = (rCosP * sinSin - rSinP * sinCos) / det
        let rPhase = atan2(rCC, rSC)
        let rMag = sqrt(rSC * rSC + rCC * rCC)

        var delta = rPhase - lPhase
        if delta > .pi { delta -= 2 * .pi }; if delta < -.pi { delta += 2 * .pi }

        let lRMS = Double(rms(left)); let rRMS = Double(rms(right))
        let lNorm = lRMS > 0 ? min(lMag / (lRMS * 2.0.squareRoot()), 1.0) : 0
        let rNorm = rRMS > 0 ? min(rMag / (rRMS * 2.0.squareRoot()), 1.0) : 0
        return (delta, sqrt(lNorm * rNorm))
    }

    // MARK: - ZCR frequency

    private func zcrFrequency(_ samples: [Float], sampleRate: Double) -> Double {
        guard samples.count > 1 else { return 0 }
        var crossings = 0
        for i in 1..<samples.count where (samples[i - 1] >= 0) != (samples[i] >= 0) { crossings += 1 }
        return Double(crossings) * sampleRate / Double(samples.count - 1) / 2.0
    }

    // MARK: - Helpers

    private func rms(_ s: [Float]) -> Float { sqrt(s.reduce(0) { $0 + $1 * $1 } / Float(max(s.count, 1))) }
    private func peak(_ s: [Float]) -> Float { s.map(abs).max() ?? 0 }
    private func channelBalance(l: Float, r: Float) -> Double {
        let mx = max(l, r); guard mx > 0 else { return 0 }; return Double(min(l, r) / mx)
    }
    private func signalLevelScore(rms: Float) -> Double {
        let fl = Double(silenceThresholdRMS); let ce = fl * 10
        guard ce > fl else { return 1 }; return min(max((Double(rms) - fl) / (ce - fl), 0), 1)
    }
    private func classifyHealth(anySilence: Bool, anyClipping: Bool, hasSignal: Bool) -> SignalHealth {
        if !hasSignal { return anySilence ? .noSignal : .noSignal }
        return anyClipping ? .clipped : .usable
    }
}
