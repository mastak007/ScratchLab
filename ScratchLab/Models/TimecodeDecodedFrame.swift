import Foundation

// MARK: - TimecodeDecodedFrame

/// A single decoded timecode frame produced by the prototype decoder.
///
/// Each frame represents the decoder's best estimate of platter position and
/// velocity at one point in time, derived from the phase relationship between
/// the left and right channels of a timecode-like stereo signal.
///
/// **Batch 2:** Prototype only. Does not claim compatibility with any
/// commercial timecode format (Serato, SDJ, Traktor, etc.).
public struct TimecodeDecodedFrame: Equatable, Sendable {

    /// Host-clock timestamp, if available from the source.
    public let hostTime: UInt64?

    /// Seconds since the start of the decode session.
    public let relativeTime: TimeInterval

    /// Absolute decoded position in unbounded displacement units.
    /// Positive = forward, negative = backward. This is the cumulative
    /// integral of all delta positions seen so far.
    public let position: Double

    /// Position delta for this frame relative to the previous frame.
    /// Positive = forward, negative = backward.
    public let deltaPosition: Double

    /// Estimated velocity in position-units per second. Sign indicates
    /// direction (positive = forward).
    public let velocity: Double

    /// Decoded direction for this frame.
    public let direction: TimecodeDirection

    /// Confidence in this frame's decode, in [0, 1].
    /// 1.0 = ideal conditions (strong, balanced signal with clear phase).
    /// 0.0 = no confidence (should be dropped).
    public let confidence: Double

    // MARK: - Init

    public init(
        hostTime: UInt64?,
        relativeTime: TimeInterval,
        position: Double,
        deltaPosition: Double,
        velocity: Double,
        direction: TimecodeDirection,
        confidence: Double
    ) {
        self.hostTime = hostTime
        self.relativeTime = relativeTime
        self.position = position
        self.deltaPosition = deltaPosition
        self.velocity = velocity
        self.direction = direction
        self.confidence = confidence
    }
}

// MARK: - TimecodeDropoutReason

/// Why a sample or frame was dropped during decoding.
public enum TimecodeDropoutReason: String, Equatable, Sendable, CaseIterable {
    /// The input buffer was silent (RMS below threshold on all channels).
    case silence

    /// The input buffer was clipped (samples at or near digital full scale).
    case clipped

    /// The decoded frame confidence fell below the minimum threshold.
    case lowConfidence

    /// One channel was dramatically lower than the other (cable fault,
    /// mono panned hard, interface misconfiguration).
    case channelFault

    /// The decoder could not establish a phase lock on the carrier frequency.
    case noPhaseLock
}

// MARK: - TimecodeDecoderCounters

/// Pure debug counters accumulated during a decode pass.
///
/// These counters are reset per `decode(_:)` call and returned as part of
/// the `TimecodeDecodeResult`. They are not persisted on the decoder instance.
public struct TimecodeDecoderCounters: Equatable, Sendable {

    /// Total number of frames successfully decoded (before filtering).
    public var decodedSamples: Int = 0

    /// Number of samples dropped because the input was silent.
    public var droppedSilence: Int = 0

    /// Number of samples dropped because the input was clipping.
    public var droppedClipped: Int = 0

    /// Number of frames dropped because confidence was below threshold.
    public var droppedLowConfidence: Int = 0

    /// Number of direction changes detected across the decode window.
    public var directionChanges: Int = 0

    /// Maximum absolute velocity encountered, in position-units per second.
    public var maxAbsRate: Double = 0

    /// Average confidence across all decoded frames.
    public var averageConfidence: Double = 0

    /// Minimum per-buffer confidence seen this decode pass, over all valid
    /// (phase-locked) inputs — including buffers that never formed a frame
    /// because there weren't enough consecutive samples to form a delta.
    public var frameConfidenceMin: Double = 0

    /// Maximum per-buffer confidence seen this decode pass (see
    /// `frameConfidenceMin`).
    public var frameConfidenceMax: Double = 0

    /// Aggregate signal health label for the decode window (raw value from
    /// `SignalHealth`).
    public var signalHealth: String = SignalHealth.noSignal.rawValue

    // MARK: - Init

    public init() {}
}

// MARK: - TimecodeDecodeResult

/// The result of one `TimecodePhaseDecoder.decode(_:)` call.
///
/// Contains the decoded frames, aggregate diagnostics, dropout reason (if
/// applicable), and debug counters.
public struct TimecodeDecodeResult: Equatable, Sendable {

    /// The decoded frames, in time order. May be empty if no frames could
    /// be decoded (e.g. silent or clipped input).
    public let frames: [TimecodeDecodedFrame]

    /// Average confidence across all decoded frames, in [0, 1].
    public let averageConfidence: Double

    /// Aggregate signal health classification for the decode window.
    public let signalHealth: SignalHealth

    /// Primary reason frames were dropped, if any. Nil when all input
    /// samples produced valid decoded frames.
    public let dropoutReason: TimecodeDropoutReason?

    /// Debug counters accumulated during this decode pass.
    public let counters: TimecodeDecoderCounters

    // MARK: - Init

    public init(
        frames: [TimecodeDecodedFrame],
        averageConfidence: Double,
        signalHealth: SignalHealth,
        dropoutReason: TimecodeDropoutReason?,
        counters: TimecodeDecoderCounters
    ) {
        self.frames = frames
        self.averageConfidence = averageConfidence
        self.signalHealth = signalHealth
        self.dropoutReason = dropoutReason
        self.counters = counters
    }

    /// Convenience initialiser for an empty (no-signal) result.
    public static func empty(reason: TimecodeDropoutReason, signalHealth: SignalHealth = .noSignal) -> TimecodeDecodeResult {
        var counters = TimecodeDecoderCounters()
        counters.signalHealth = signalHealth.rawValue
        switch reason {
        case .silence: counters.droppedSilence = 1
        case .clipped: counters.droppedClipped = 1
        case .lowConfidence: counters.droppedLowConfidence = 1
        default: break
        }
        return TimecodeDecodeResult(
            frames: [],
            averageConfidence: 0,
            signalHealth: signalHealth,
            dropoutReason: reason,
            counters: counters
        )
    }
}
