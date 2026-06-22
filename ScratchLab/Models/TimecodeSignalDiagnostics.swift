import Foundation

// MARK: - SignalHealth

/// Confidence-like signal health classification for a timecode audio buffer.
///
/// Does NOT represent decoded position or timecode lock. It only describes
/// whether the raw audio signal looks healthy enough for a hypothetical
/// decoder to work with.
///
/// **Batch 1:** Diagnostics only. No decoder.
public enum SignalHealth: String, Equatable, Sendable, CaseIterable {
    /// No meaningful signal detected — both channels at or below the noise floor.
    case noSignal

    /// Signal is present but low-amplitude — may be too weak for reliable
    /// timecode decoding.
    case weak

    /// Signal looks healthy for timecode use: adequate level, stereo present,
    /// no clipping, no channel fault.
    case usable

    /// Signal is hot enough that clipping is detected on at least one channel.
    /// A clipped timecode signal may still decode but reliability is degraded.
    case clipped

    /// One channel has dramatically lower level than the other, suggesting a
    /// mono signal panned hard, a cable fault, or an interface misconfiguration.
    case channelFault
}

// MARK: - SignalClass

/// Prototype-only signal modulation classification.
///
/// Describes what kind of timecode-like modulation (if any) the stereo audio
/// signal carries.  This is a diagnostic label, not a decoder capability
/// claim.  It does NOT represent Serato, SDJ, or any commercial timecode
/// format.
///
/// **Batch 13:** Signal classification diagnostic.  Does not modify the
/// decoder, change thresholds, or enable new decode paths.
public enum SignalClass: String, Equatable, Sendable, CaseIterable {
    /// Stereo signal with similar-frequency tones on L/R at ~90° phase
    /// offset — matches the prototype quadrature decoder's expected input.
    case quadratureCandidate

    /// Stereo signal where L and R ZCR-estimated frequencies differ
    /// noticeably.  The current prototype quadrature decoder cannot
    /// decode this modulation.  Does NOT indicate FSK detection — the
    /// classifier uses zero-crossing rate, not spectral analysis.
    case frequencyDisparateUnsupported

    /// Stereo audio is present and healthy but does not match the quadrature
    /// profile (e.g. music, correlated stereo, dual-mono, or other
    /// frequency-disparate stereo not classified above).
    case stereoAudioButNotQuadrature

    /// Both channels at or below the noise floor.
    case silent

    /// Signal is clipping on at least one channel.
    case clipped

    /// One channel appears dead or severely imbalanced.
    case channelFault

    /// Signal is present but too weak to classify reliably.
    case weak

    /// Unable to determine modulation type (e.g. unusual spectrum, noise).
    case unknown

    /// Human-readable label for Copy Debug.
    public var label: String {
        switch self {
        case .quadratureCandidate:         return "Quadrature candidate"
        case .frequencyDisparateUnsupported: return "Unsupported non-quadrature (frequency-disparate)"
        case .stereoAudioButNotQuadrature: return "Stereo audio (not quadrature)"
        case .silent:                      return "Silent"
        case .clipped:                     return "Clipped"
        case .channelFault:                return "Channel fault"
        case .weak:                        return "Weak"
        case .unknown:                     return "Unknown"
        }
    }
}

// MARK: - TimecodeSignalDiagnostics

/// Pure diagnostics engine for timecode-like audio buffers.
///
/// Computes aggregate RMS, peak, clipping, silence, channel imbalance, and
/// stereo-present / mono-suspect checks across a `TimecodeAudioBuffer`.
/// Produces a `SignalHealth` classification.
///
/// All computation is deterministic and side-effect-free. No audio hardware
/// or framework dependency. Suitable for both live use and unit testing.
///
/// **Batch 1:** Diagnostics only. No decoding, no position extraction.
public struct TimecodeSignalDiagnostics: Sendable {

    // MARK: - Thresholds

    /// RMS below this value is considered silence.
    public var silenceThresholdRMS: Float = 0.001

    /// RMS below this value is considered "weak" (above silence but below usable).
    public var weakThresholdRMS: Float = 0.02

    /// Any sample with absolute value ≥ this is considered clipping.
    public var clippingThreshold: Float = 0.999

    /// When the ratio of the quieter channel's RMS to the louder channel's RMS
    /// is below this value, the buffer is flagged as single-sided / channel fault.
    public var channelImbalanceThreshold: Float = 0.1

    // MARK: - Output type

    /// Aggregate diagnostics for a complete buffer.
    public struct Diagnosis: Equatable, Sendable {
        /// Aggregate RMS level for the left channel.
        public let leftRMS: Float
        /// Aggregate RMS level for the right channel (nil for mono sources).
        public let rightRMS: Float?
        /// Aggregate peak for the left channel.
        public let leftPeak: Float
        /// Aggregate peak for the right channel (nil for mono sources).
        public let rightPeak: Float?
        /// True when any individual sample in the buffer flags clipping.
        public let isClipping: Bool
        /// True when the aggregate RMS of all channels is below the silence threshold.
        public let isSilent: Bool
        /// True when the stereo image is severely imbalanced (see `channelImbalanceThreshold`).
        public let isChannelImbalanced: Bool
        /// True when the buffer has two channels (i.e. is stereo-capable).
        public let isStereo: Bool
        /// True when one channel appears silent while the other is active
        /// (stronger signal than `isChannelImbalanced` — one channel is essentially dead).
        public let isMonoSuspect: Bool
        /// Aggregate signal health classification.
        public let health: SignalHealth

        // MARK: Batch 13 — Signal modulation classification

        /// Sample rate used for classification (Hz).
        public let classificationSampleRate: Double
        /// Pearson correlation coefficient between L and R channels.
        /// nil for mono sources.
        public let channelCorrelation: Float?
        /// ZCR-derived frequency estimate, left channel (Hz). nil when silent.
        /// Computed as zeroCrossingRateLeft / 2 — valid only for near-pure tones.
        public let zcrFrequencyEstimateLeft: Float?
        /// ZCR-derived frequency estimate, right channel (Hz). nil when silent.
        /// Computed as zeroCrossingRateRight / 2 — valid only for near-pure tones.
        public let zcrFrequencyEstimateRight: Float?
        /// Zero-crossing rate, left channel (crossings/sec).
        public let zeroCrossingRateLeft: Float
        /// Zero-crossing rate, right channel (crossings/sec).
        public let zeroCrossingRateRight: Float
        /// Rough phase offset between L/R at the ZCR frequency estimate (degrees).
        /// Positive = R leads L. nil when classification cannot determine phase.
        public let estimatedPhaseOffset: Float?
        /// True when stereo resembles a 90° quadrature pair.
        public let isQuadratureLike: Bool
        /// True when L/R ZCR frequency estimates differ enough to be considered
        /// frequency-disparate.  Does NOT imply FSK detection.
        public let isFrequencyDisparate: Bool
        /// Prototype signal modulation classification.
        public let signalClass: SignalClass
        /// Human-readable reason the current prototype decoder rejected this
        /// signal, if the classification suggests it should have been decodable.
        /// nil when not applicable.
        public let decoderRejectionNote: String?
    }

    // MARK: - Init

    public init(
        silenceThresholdRMS: Float = 0.001,
        weakThresholdRMS: Float = 0.02,
        clippingThreshold: Float = 0.999,
        channelImbalanceThreshold: Float = 0.1
    ) {
        self.silenceThresholdRMS = silenceThresholdRMS
        self.weakThresholdRMS = weakThresholdRMS
        self.clippingThreshold = clippingThreshold
        self.channelImbalanceThreshold = channelImbalanceThreshold
    }

    // MARK: - Diagnostics

    /// Compute aggregate diagnostics for the given buffer.
    ///
    /// - Parameter buffer: The timecode audio buffer to diagnose.
    /// - Returns: A `Diagnosis` struct with aggregate metrics and health classification.
    public func diagnose(_ buffer: TimecodeAudioBuffer) -> Diagnosis {
        let samples = buffer.samples

        guard !samples.isEmpty else {
            return Diagnosis(
                leftRMS: 0, rightRMS: nil, leftPeak: 0, rightPeak: nil,
                isClipping: false, isSilent: true, isChannelImbalanced: false,
                isStereo: buffer.channelCount >= 2, isMonoSuspect: false,
                health: .noSignal,
                classificationSampleRate: buffer.sampleRate,
                channelCorrelation: nil,
                zcrFrequencyEstimateLeft: nil,
                zcrFrequencyEstimateRight: nil,
                zeroCrossingRateLeft: 0,
                zeroCrossingRateRight: 0,
                estimatedPhaseOffset: nil,
                isQuadratureLike: false,
                isFrequencyDisparate: false,
                signalClass: .silent,
                decoderRejectionNote: nil
            )
        }

        let isStereo = buffer.channelCount >= 2

        // Aggregate RMS (root mean of per-sample RMS values)
        let leftRMS = aggregateRMS(samples.map(\.leftRMS))
        let rightRMS: Float? = isStereo ? aggregateRMS(samples.compactMap(\.rightRMS)) : nil

        // Aggregate peak (max of per-sample peaks)
        let leftPeak = samples.map(\.leftPeak).max() ?? 0
        let rightPeak: Float? = isStereo ? samples.compactMap(\.rightPeak).max() : nil

        // Aggregate flags
        let isClipping = samples.contains(where: \.isClipping)
        // Use aggregate RMS for silence check
        let primaryRMS = leftRMS
        let secondaryRMS = rightRMS ?? leftRMS
        let effectiveRMS = max(primaryRMS, secondaryRMS)
        let isSilent = effectiveRMS < silenceThresholdRMS

        // Channel imbalance check (only for stereo)
        let isChannelImbalanced: Bool
        let isMonoSuspect: Bool
        if isStereo, let rRMS = rightRMS {
            let maxRMS = max(leftRMS, rRMS)
            let minRMS = min(leftRMS, rRMS)
            let ratio = maxRMS > 0 ? minRMS / maxRMS : 1.0
            isChannelImbalanced = ratio < channelImbalanceThreshold
            // Mono suspect: one channel is effectively silent while the other is not
            isMonoSuspect = (minRMS < silenceThresholdRMS) && (maxRMS >= weakThresholdRMS)
        } else {
            isChannelImbalanced = false
            isMonoSuspect = false
        }

        // Health classification
        let health = classifyHealth(
            isSilent: isSilent,
            effectiveRMS: effectiveRMS,
            isClipping: isClipping,
            isChannelImbalanced: isChannelImbalanced,
            isMonoSuspect: isMonoSuspect
        )

        return Diagnosis(
            leftRMS: leftRMS,
            rightRMS: rightRMS,
            leftPeak: leftPeak,
            rightPeak: rightPeak,
            isClipping: isClipping,
            isSilent: isSilent,
            isChannelImbalanced: isChannelImbalanced,
            isStereo: isStereo,
            isMonoSuspect: isMonoSuspect,
            health: health,
            classificationSampleRate: buffer.sampleRate,
            channelCorrelation: nil,
            zcrFrequencyEstimateLeft: nil,
            zcrFrequencyEstimateRight: nil,
            zeroCrossingRateLeft: 0,
            zeroCrossingRateRight: 0,
            estimatedPhaseOffset: nil,
            isQuadratureLike: false,
            isFrequencyDisparate: false,
            signalClass: .unknown,
            decoderRejectionNote: nil
        )
    }

    // MARK: - Health classification

    private func classifyHealth(
        isSilent: Bool,
        effectiveRMS: Float,
        isClipping: Bool,
        isChannelImbalanced: Bool,
        isMonoSuspect: Bool
    ) -> SignalHealth {
        if isSilent {
            return .noSignal
        }
        if isMonoSuspect || isChannelImbalanced {
            return .channelFault
        }
        if isClipping {
            return .clipped
        }
        if effectiveRMS < weakThresholdRMS {
            return .weak
        }
        return .usable
    }

    // MARK: - Signal classification (Batch 13)

    /// Classify the modulation type of a raw stereo audio buffer.
    ///
    /// Analyses zero-crossing rate, channel correlation, phase offset, and
    /// ZCR-derived frequency similarity to distinguish quadrature-like,
    /// frequency-disparate, correlated stereo, and fault conditions.
    ///
    /// This is a prototype diagnostic. It does NOT claim compatibility with
    /// any commercial timecode format.
    ///
    /// - Parameters:
    ///   - left: Left-channel samples, normalised to [-1, +1].
    ///   - right: Right-channel samples, normalised to [-1, +1].
    ///   - sampleRate: Sample rate in Hz.
    ///   - health: Pre-computed signal health (from `classifyHealth`).
    ///   - isStereo: Whether the source has two channels.
    /// - Returns: A `Diagnosis` with classification fields populated.
    public func classifySignal(
        left: [Float],
        right: [Float],
        sampleRate: Double,
        health: SignalHealth,
        isStereo: Bool
    ) -> Diagnosis {
        let frameCount = min(left.count, right.count)
        let sr = Float(sampleRate)

        guard frameCount > 0, sr > 0 else {
            return Diagnosis(
                leftRMS: 0, rightRMS: nil, leftPeak: 0, rightPeak: nil,
                isClipping: false, isSilent: true, isChannelImbalanced: false,
                isStereo: isStereo, isMonoSuspect: false,
                health: .noSignal,
                classificationSampleRate: sampleRate,
                channelCorrelation: nil,
                zcrFrequencyEstimateLeft: nil,
                zcrFrequencyEstimateRight: nil,
                zeroCrossingRateLeft: 0,
                zeroCrossingRateRight: 0,
                estimatedPhaseOffset: nil,
                isQuadratureLike: false,
                isFrequencyDisparate: false,
                signalClass: .silent,
                decoderRejectionNote: nil
            )
        }

        // --- Zero-crossing rate ---
        let zcrLeft = zeroCrossingRate(left, sampleRate: sr)
        let zcrRight = zeroCrossingRate(right, sampleRate: sr)

        // --- ZCR frequency estimate (domFreqLeft/Right are internal locals only) ---
        // For a pure tone, ZCR = 2 × frequency, so frequency ≈ ZCR / 2.
        let domFreqLeft: Float? = zcrLeft > 0 ? zcrLeft / 2.0 : nil
        let domFreqRight: Float? = zcrRight > 0 ? zcrRight / 2.0 : nil

        // --- Channel correlation (Pearson r) ---
        let correlation: Float? = isStereo ? pearsonCorrelation(left, right) : nil

        // --- Phase offset estimation via cross-correlation ---
        let phaseOffset: Float? = estimatePhaseOffset(
            left: left, right: right,
            sampleRate: sr,
            dominantFreq: domFreqLeft ?? domFreqRight
        )

        // --- Modulation classification ---
        // Uses ZCR-derived frequency estimates only — not FFT or spectral analysis.
        let isQuadrature: Bool
        let isFrequencyDisparate: Bool

        if let dfL = domFreqLeft, let dfR = domFreqRight, isStereo {
            let freqRatio = max(dfL, dfR) / max(min(dfL, dfR), 1.0)
            let freqDiff = abs(dfL - dfR)

            // Frequency-disparate: ZCR estimates on L/R differ by >20% AND both
            // fall in a plausible timecode range (800–8000 Hz).
            let inTimecodeRange: (Float) -> Bool = { f in f >= 800 && f <= 8000 }
            let freqDisparateCondition = freqRatio > 1.20 && freqDiff > 200
            let rangeCondition = inTimecodeRange(dfL) && inTimecodeRange(dfR)

            isFrequencyDisparate = freqDisparateCondition && rangeCondition

            // Quadrature-like: similar ZCR frequencies (±10%), phase offset near
            // ±90° (±35° tolerance), and low channel correlation (<0.4).
            let similarFreq = freqRatio < 1.10
            let phaseNearQuadrature: Bool
            if let po = phaseOffset {
                let absPO = abs(po)
                phaseNearQuadrature = absPO > 55 && absPO < 125
            } else {
                phaseNearQuadrature = false
            }
            let lowCorrelation = (correlation.map { abs($0) } ?? 1.0) < 0.4

            isQuadrature = similarFreq && phaseNearQuadrature && lowCorrelation && !isFrequencyDisparate
        } else {
            isFrequencyDisparate = false
            isQuadrature = false
        }

        // --- SignalClass assignment ---
        let signalClass: SignalClass
        let rejectionNote: String?

        switch health {
        case .noSignal:
            signalClass = .silent
            rejectionNote = nil
        case .clipped:
            signalClass = .clipped
            rejectionNote = nil
        case .channelFault:
            signalClass = .channelFault
            rejectionNote = nil
        case .weak:
            signalClass = .weak
            rejectionNote = nil
        case .usable:
            if isQuadrature {
                signalClass = .quadratureCandidate
                // If it looks quadrature but the decoder still rejects it,
                // the decoder's minCorrelationMagnitude or minConfidence
                // thresholds may be too strict for this signal level.
                rejectionNote = nil
            } else if isFrequencyDisparate {
                signalClass = .frequencyDisparateUnsupported
                rejectionNote = "Unsupported non-quadrature stereo: channel ZCR frequency estimates differ by "
                    + "\(String(format: "%.0f", abs((domFreqLeft ?? 0) - (domFreqRight ?? 0)))) Hz; "
                    + "prototype only decodes quadrature (same-frequency, ~90° phase-shifted pair)."
            } else if isStereo {
                signalClass = .stereoAudioButNotQuadrature
                rejectionNote = "Stereo audio present but does not match quadrature profile. "
                    + "Decoder expects ~1 kHz quadrature pair (90° phase, similar freq, low correlation)."
            } else {
                signalClass = .unknown
                rejectionNote = "Mono signal with usable level; decoder expects stereo quadrature input."
            }
        }

        return Diagnosis(
            leftRMS: 0, rightRMS: nil, leftPeak: 0, rightPeak: nil,
            isClipping: false, isSilent: health == .noSignal, isChannelImbalanced: false,
            isStereo: isStereo, isMonoSuspect: false,
            health: health,
            classificationSampleRate: sampleRate,
            channelCorrelation: correlation,
            zcrFrequencyEstimateLeft: domFreqLeft,
            zcrFrequencyEstimateRight: domFreqRight,
            zeroCrossingRateLeft: zcrLeft,
            zeroCrossingRateRight: zcrRight,
            estimatedPhaseOffset: phaseOffset,
            isQuadratureLike: isQuadrature,
            isFrequencyDisparate: isFrequencyDisparate,
            signalClass: signalClass,
            decoderRejectionNote: rejectionNote
        )
    }

    // MARK: - DSP helpers (Batch 13)

    /// Zero-crossing rate in crossings per second.
    private func zeroCrossingRate(_ samples: [Float], sampleRate: Float) -> Float {
        guard samples.count > 1 else { return 0 }
        var crossings: Int = 0
        for i in 1..<samples.count {
            if (samples[i - 1] >= 0) != (samples[i] >= 0) {
                crossings += 1
            }
        }
        return Float(crossings) * sampleRate / Float(samples.count - 1)
    }

    /// Pearson correlation coefficient between two sample arrays.
    /// Returns nil when variance is zero (constant signal).
    private func pearsonCorrelation(_ a: [Float], _ b: [Float]) -> Float? {
        let n = min(a.count, b.count)
        guard n > 1 else { return nil }

        var sumA: Float = 0, sumB: Float = 0
        for i in 0..<n {
            sumA += a[i]
            sumB += b[i]
        }
        let meanA = sumA / Float(n)
        let meanB = sumB / Float(n)

        var cov: Float = 0, varA: Float = 0, varB: Float = 0
        for i in 0..<n {
            let da = a[i] - meanA
            let db = b[i] - meanB
            cov += da * db
            varA += da * da
            varB += db * db
        }

        guard varA > 1e-12 && varB > 1e-12 else { return nil }
        return cov / sqrt(varA * varB)
    }

    /// Rough phase offset between L and R in degrees via cross-correlation lag.
    /// Positive = R leads L. Returns nil when no ZCR frequency estimate is available.
    private func estimatePhaseOffset(
        left: [Float],
        right: [Float],
        sampleRate: Float,
        dominantFreq: Float?
    ) -> Float? {
        guard let freq = dominantFreq, freq > 0 else { return nil }
        let n = min(left.count, right.count)
        guard n > 1 else { return nil }

        // Search a limited lag window: at most ± half the period at the ZCR freq estimate.
        let periodSamples = Int(sampleRate / freq)
        let maxLag = min(n / 2, max(1, periodSamples / 2))

        var bestLag = 0
        var bestCorr: Float = -.infinity

        for lag in -maxLag...maxLag {
            var sum: Float = 0
            var count = 0
            for i in 0..<n {
                let j = i + lag
                guard j >= 0, j < n else { continue }
                sum += left[i] * right[j]
                count += 1
            }
            guard count > 0 else { continue }
            let corr = sum / Float(count)
            if corr > bestCorr {
                bestCorr = corr
                bestLag = lag
            }
        }

        // Convert lag (samples) to phase offset in degrees.
        // phase = lag / period * 360 = lag * freq / sampleRate * 360
        let phaseDeg = Float(bestLag) * freq / sampleRate * 360.0
        // Normalise to [-180, 180]
        let normalised = phaseDeg.truncatingRemainder(dividingBy: 360.0)
        return normalised > 180 ? normalised - 360 : (normalised < -180 ? normalised + 360 : normalised)
    }

    /// Compute the root-mean of RMS values: sqrt(mean of squares).
    private func aggregateRMS(_ rmsValues: [Float]) -> Float {
        guard !rmsValues.isEmpty else { return 0 }
        let meanSquare = rmsValues.reduce(0) { $0 + $1 * $1 } / Float(rmsValues.count)
        return sqrt(meanSquare)
    }
}
