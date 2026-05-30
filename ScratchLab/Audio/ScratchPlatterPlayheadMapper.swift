import Foundation

// Scratch Playback Lab: pure platter → sample-position mapping.
//
// Scope guardrails (deliberate):
// - Pure value type + pure functions only. No AVFoundation, no Core MIDI, no device
//   I/O, no Serato, no DVS. This is the unit the Scratch Playback Lab tests exercise.
//
// Decode model (RANE ONE MKII, confirmed from the platter-scrub video):
//   The platter pitch bend is an ABSOLUTE 14-bit angle (0…16383 = one revolution),
//   not a velocity. It holds its value at rest and sweeps the full range as the
//   platter turns. So the playhead tracks the *change* in angle, not an integrated
//   offset-from-baseline:
//
//     delta          = wrappedDelta(lastRaw → raw, modulus: 16384)   // shortest signed path
//     delta          = -delta when inverted
//     samplePosition += delta / 16384 * secondsPerRevolution         // seconds
//     samplePosition  = clamp(samplePosition, 0 ... sampleDuration)
//
// The first event only seeds `lastRawPitchBend` (no movement), so a stale value can
// never produce a giant first jump. Clamp is deliberately *clamp*, not *wrap*:
// looping platter position is a later slice.

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

/// Pure, testable mapping from an absolute 14-bit platter angle to a sample position
/// in seconds. Forward platter rotation advances the position (playhead moves right);
/// reverse rotation retreats it (playhead moves left).
struct ScratchPlatterPlayheadMapper: Equatable {
    /// Resolution of the platter's absolute angle: ticks per full revolution.
    static let ticksPerRevolution = 16384

    /// Seconds of sample advanced by one full platter revolution. The default is the
    /// real-vinyl figure (one revolution at 33⅓ rpm = 1.8 s of audio); tunable in the
    /// lab to taste. Larger = more sample per turn (coarser); smaller = finer.
    var secondsPerRevolution: TimeInterval
    /// Sample length in seconds — the upper clamp bound.
    var sampleDuration: TimeInterval
    /// When true, platter direction is flipped (forward rotation retreats the
    /// playhead). A lab-only escape hatch if the hardware reports the opposite sign.
    var inverted: Bool

    /// Current sample-playback position in seconds, clamped to `0...sampleDuration`.
    private(set) var samplePosition: TimeInterval
    /// The most recent raw pitch-bend value, or nil until the first event seeds it.
    private(set) var lastRawPitchBend: Int?
    /// The wrapped signed delta (in ticks, pre-invert) applied on the most recent
    /// ingest; 0 on a seeding event. Exposed for the lab readout.
    private(set) var lastWrappedDelta: Int

    init(
        secondsPerRevolution: TimeInterval = 1.8,
        sampleDuration: TimeInterval,
        inverted: Bool = false,
        samplePosition: TimeInterval = 0,
        lastRawPitchBend: Int? = nil
    ) {
        self.secondsPerRevolution = max(0, secondsPerRevolution)
        self.sampleDuration = max(0, sampleDuration)
        self.inverted = inverted
        self.samplePosition = Self.clampPosition(samplePosition, duration: self.sampleDuration)
        self.lastRawPitchBend = lastRawPitchBend
        self.lastWrappedDelta = 0
    }

    /// Shortest signed distance from `last` to `current` on a ring of `modulus` ticks.
    /// Result is in `(-modulus/2 ... modulus/2]`; positive = forward across the ring,
    /// so crossing the 16383→0 boundary forward yields a small positive delta (not a
    /// near-full-range negative one).
    static func wrappedDelta(from last: Int, to current: Int, modulus: Int = ticksPerRevolution) -> Int {
        guard modulus > 0 else { return 0 }
        var delta = (current - last) % modulus
        if delta < 0 { delta += modulus }          // 0 ..< modulus
        if delta > modulus / 2 { delta -= modulus } // fold to (-modulus/2 ... modulus/2]
        return delta
    }

    /// Tracks one absolute 14-bit platter angle into `samplePosition`. The first event
    /// only seeds `lastRawPitchBend` (no movement). Subsequent events move the playhead
    /// by the wrapped delta scaled by `secondsPerRevolution`, clamped to the sample.
    /// Returns the wrapped (pre-invert) delta applied, in ticks (0 on the seeding event).
    @discardableResult
    mutating func ingestPitchBend(_ raw: Int) -> Int {
        defer { lastRawPitchBend = raw }
        guard let last = lastRawPitchBend else {
            lastWrappedDelta = 0
            return 0 // seed only — never jump on the first value
        }
        let delta = Self.wrappedDelta(from: last, to: raw)
        lastWrappedDelta = delta
        let signed = inverted ? -delta : delta
        let movement = Double(signed) / Double(Self.ticksPerRevolution) * secondsPerRevolution
        samplePosition = Self.clampPosition(samplePosition + movement, duration: sampleDuration)
        return delta
    }

    /// Resets the playhead to the start of the sample (does not touch tracking).
    mutating func resetPosition() {
        samplePosition = 0
    }

    /// Forgets the last raw value so the next event re-seeds without moving. Use after
    /// a deck/source change or a pause, so a stale angle can't produce a giant delta.
    mutating func resetTracking() {
        lastRawPitchBend = nil
        lastWrappedDelta = 0
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

    /// Output gain for optional crossfader volume gating. Full gain (1.0) unless
    /// gating is enabled AND a valid crossfader value has arrived — so audio is never
    /// muted before the first crossfader CC is received.
    static func outputGain(applyGating: Bool, crossfaderValid: Bool, crossfader: Double) -> Float {
        guard applyGating, crossfaderValid else { return 1.0 }
        return Float(Swift.min(Swift.max(crossfader, 0), 1))
    }

    /// Whether a raw pitch-bend channel belongs to the selected deck. Only raw
    /// channels 0x0 (left) and 0x1 (right) are platters; everything else is rejected
    /// so a non-platter channel never drives the playhead.
    static func isPitchBendChannel(_ channel: Int?, forDeck deck: Int) -> Bool {
        guard let channel, ScratchPlatterDeck(rawValue: deck) != nil else { return false }
        return channel == deck
    }
}
