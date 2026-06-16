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
                health: .noSignal
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
            health: health
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

    // MARK: - Helpers

    /// Compute the root-mean of RMS values: sqrt(mean of squares).
    private func aggregateRMS(_ rmsValues: [Float]) -> Float {
        guard !rmsValues.isEmpty else { return 0 }
        let meanSquare = rmsValues.reduce(0) { $0 + $1 * $1 } / Float(rmsValues.count)
        return sqrt(meanSquare)
    }
}
