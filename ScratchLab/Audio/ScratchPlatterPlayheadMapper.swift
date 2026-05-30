import Foundation

// Scratch Playback Lab (first slice): pure platter → sample-position mapping.
//
// Scope guardrails (deliberate):
// - Pure value type + pure functions only. No AVFoundation, no Core MIDI, no device
//   I/O, no Serato, no DVS. This is the unit the Scratch Playback Lab tests exercise.
// - Maps a controller's 14-bit platter pitch-bend stream to a sample-playback
//   position. It is the single source of truth for the playhead; the audio engine
//   *follows* the position this produces.
//
// Model:
//   delta        = rawPitchBend - baseline
//   delta        = 0 when |delta| <= velocityDeadband     // idle-jitter guard
//   playbackRate = (inverted ? -delta : delta) * rateScale // 1.0 == realtime
//   samplePosition += playbackRate * dt                    // seconds
//   samplePosition = clamp(samplePosition, 0 ... sampleDuration)
//
// Clamp behaviour is deliberately *clamp*, not *wrap*: the playhead stops at the
// start and end of the sample. Relative / looping platter position is a later slice.

/// The two platters, identified by raw MIDI pitch-bend channel (RANE ONE MKII:
/// left = raw channel 0x0, right = raw channel 0x1).
enum ScratchPlatterDeck: Int, CaseIterable, Equatable {
    case left = 0
    case right = 1

    /// The raw MIDI channel this deck's platter pitch-bend arrives on.
    var rawChannel: Int { rawValue }

    /// The deck a raw pitch-bend channel belongs to, or nil if it is neither platter.
    static func forRawChannel(_ channel: Int) -> ScratchPlatterDeck? {
        ScratchPlatterDeck(rawValue: channel)
    }
}

/// Pure, testable mapping from a 14-bit platter pitch-bend value to a sample
/// position in seconds. Forward platter motion advances the position (playhead
/// moves right); reverse motion retreats it (playhead moves left).
struct ScratchPlatterPlayheadMapper: Equatable {
    /// Provisional RANE ONE MKII motor baseline: the pitch-bend value reported with
    /// the platter spinning untouched at motor speed. Measured ≈ 11314 but
    /// UNCONFIRMED — the lab exposes a "Calibrate" action to capture it live.
    static let defaultMotorBaseline = 11314

    /// 14-bit pitch-bend centre, a neutral fallback baseline.
    static let pitchBendCenter = 8192

    /// Pitch-bend value treated as zero platter velocity.
    var baseline: Int
    /// Converts `(rawPitchBend - baseline)` into a playback-rate multiplier
    /// (rate per pitch-bend unit). Tunable from the lab UI; not assumed correct.
    var rateScale: Double
    /// Sample length in seconds — the upper clamp bound.
    var sampleDuration: TimeInterval
    /// Largest `dt` honoured in one integration step, so a long gap between events
    /// (e.g. the platter paused) cannot fling the playhead.
    var maxIntegrationStep: TimeInterval
    /// Half-width (in pitch-bend units) of a dead zone around `baseline` in which the
    /// platter is treated as idle and the rate is forced to zero. Absorbs motor
    /// jitter so an untouched, calibrated platter does not creep.
    var velocityDeadband: Int
    /// When true, the platter direction is flipped (forward motion retreats the
    /// playhead). A lab-only escape hatch if the hardware reports the opposite sign.
    var inverted: Bool

    /// Current sample-playback position in seconds, clamped to `0...sampleDuration`.
    private(set) var samplePosition: TimeInterval

    init(
        baseline: Int = ScratchPlatterPlayheadMapper.defaultMotorBaseline,
        rateScale: Double = 1.0 / 4096.0,
        sampleDuration: TimeInterval,
        maxIntegrationStep: TimeInterval = 0.05,
        velocityDeadband: Int = 0,
        inverted: Bool = false,
        samplePosition: TimeInterval = 0
    ) {
        self.baseline = baseline
        self.rateScale = rateScale
        self.sampleDuration = max(0, sampleDuration)
        self.maxIntegrationStep = max(0, maxIntegrationStep)
        self.velocityDeadband = max(0, velocityDeadband)
        self.inverted = inverted
        self.samplePosition = Self.clampPosition(samplePosition, duration: self.sampleDuration)
    }

    /// Playback-rate multiplier for a raw 14-bit pitch-bend value. Positive = forward
    /// (playhead moves right), negative = reverse (playhead moves left), 0 at baseline
    /// or anywhere inside the deadband. Honours `inverted`.
    func playbackRate(forPitchBend raw: Int) -> Double {
        let delta = raw - baseline
        if abs(delta) <= velocityDeadband { return 0 }
        let signed = inverted ? -delta : delta
        return Double(signed) * rateScale
    }

    /// Integrates one pitch-bend sample over `dt` seconds into `samplePosition`,
    /// clamping to `0...sampleDuration`. Negative `dt` is ignored; large `dt` is
    /// capped at `maxIntegrationStep`. Returns the playback rate that was applied.
    @discardableResult
    mutating func ingestPitchBend(_ raw: Int, dt: TimeInterval) -> Double {
        let rate = playbackRate(forPitchBend: raw)
        let step = max(0, min(dt, maxIntegrationStep))
        samplePosition = Self.clampPosition(samplePosition + rate * step, duration: sampleDuration)
        return rate
    }

    /// Sets the baseline to a raw value (calibration from the live idle stream).
    mutating func calibrate(toBaseline raw: Int) {
        baseline = raw
    }

    /// Resets the playhead to the start of the sample.
    mutating func resetPosition() {
        samplePosition = 0
    }

    /// Position as a fraction `0...1` of the sample (0 if duration is non-positive).
    var positionFraction: Double {
        guard sampleDuration > 0 else { return 0 }
        return samplePosition / sampleDuration
    }

    /// True when the playhead is clamped at the very start of the sample.
    var isAtStart: Bool { samplePosition <= 0 }

    /// True when the playhead is clamped at the very end of the sample.
    var isAtEnd: Bool { sampleDuration > 0 && samplePosition >= sampleDuration }

    private static func clampPosition(_ value: TimeInterval, duration: TimeInterval) -> TimeInterval {
        guard duration > 0 else { return 0 }
        return Swift.min(Swift.max(value, 0), duration)
    }

    /// Normalises a 7-bit CC value (0...127) to a `0...1` crossfader position.
    static func normalizedCrossfader(cc value: Int) -> Double {
        Swift.min(Swift.max(Double(value) / 127.0, 0), 1)
    }

    /// Whether a raw pitch-bend channel belongs to the selected deck. Only raw
    /// channels 0x0 (left) and 0x1 (right) are platters; everything else is rejected
    /// so a non-platter channel never drives the playhead.
    static func isPitchBendChannel(_ channel: Int?, forDeck deck: Int) -> Bool {
        guard let channel, ScratchPlatterDeck(rawValue: deck) != nil else { return false }
        return channel == deck
    }
}
