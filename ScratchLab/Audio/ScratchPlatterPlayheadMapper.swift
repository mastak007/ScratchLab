import Foundation

// Scratch Playback Lab: pure platter → sample-position mapping.
//
// Scope guardrails (deliberate):
// - Pure value type + pure functions only. No AVFoundation, no Core MIDI, no device
//   I/O, no Serato, no DVS. This is the unit the Scratch Playback Lab tests exercise.
//
// Decode model (RANE ONE MKII, from the platter-scrub videos):
//   The platter pitch bend behaves like an ABSOLUTE 14-bit angle that holds at rest
//   and sweeps as the platter turns, so the playhead tracks the *change* in angle:
//
//     delta          = wrappedDelta(lastRaw → raw, modulus: 16384)   // shortest signed path
//     delta          = clamp(delta, ±deltaSafetyLimit) when set       // anti-explosion only
//     delta          = -delta when inverted
//     samplePosition += delta * sampleSecondsPerTick                  // seconds
//     samplePosition  = clamp(samplePosition, 0 ... sampleDuration)
//
// Sensitivity is `sampleSecondsPerTick` — seconds of sample moved per platter tick —
// NOT a vinyl seconds-per-revolution figure. Measurement (see PlatterTickMeasurement)
// showed a *small* hand scratch produces thousands of ticks per event, i.e. 16384
// ticks ≠ one revolution; the encoder is far finer, so sensitivity must be small.
//
// The first event only seeds `lastRawPitchBend` (no movement). Clamp is deliberately
// *clamp*, not *wrap*: looping platter position is a later slice.

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

/// Aliasing risk for a single wrapped delta: wrapped tracking can only resolve motion
/// up to half the modulus between events, so a large per-event delta may have folded
/// to the wrong direction.
enum ScratchDeltaAliasRisk: Equatable {
    case none
    case warn   // > aliasWarnThreshold — getting large
    case fail   // > aliasFailThreshold — direction may have aliased
}

/// Pure, testable mapping from an absolute 14-bit platter angle to a sample position
/// in seconds. Forward platter rotation advances the position (playhead moves right);
/// reverse rotation retreats it (playhead moves left).
struct ScratchPlatterPlayheadMapper: Equatable {
    /// 14-bit pitch-bend modulus used for wrapped-delta tracking.
    static let ticksPerRevolution = 16384

    /// A per-event delta beyond this many ticks is flagged (motion is getting large
    /// relative to the wrap window).
    static let aliasWarnThreshold = 4096
    /// A per-event delta beyond this many ticks may have aliased to the wrong
    /// direction (it exceeds half the modulus headroom in practice).
    static let aliasFailThreshold = 8192

    /// Seconds of sample moved per platter tick. The sensitivity knob. Default is
    /// deliberately small (a small hand scratch emits thousands of ticks per event).
    var sampleSecondsPerTick: TimeInterval
    /// Sample length in seconds — the upper clamp bound.
    var sampleDuration: TimeInterval
    /// When true, platter direction is flipped (forward rotation retreats the
    /// playhead). A lab-only escape hatch if the hardware reports the opposite sign.
    var inverted: Bool
    /// Optional anti-explosion cap (in ticks) on the delta *applied* to the playhead.
    /// nil = no cap. The raw wrapped delta (`lastWrappedDelta`) is always preserved.
    var deltaSafetyLimit: Int?

    /// Current sample-playback position in seconds, clamped to `0...sampleDuration`.
    private(set) var samplePosition: TimeInterval
    /// The most recent raw pitch-bend value, or nil until the first event seeds it.
    private(set) var lastRawPitchBend: Int?
    /// The wrapped signed delta (in ticks, pre-invert, pre-safety-cap) applied on the
    /// most recent ingest; 0 on a seeding event. Exposed for the lab readout.
    private(set) var lastWrappedDelta: Int
    /// Whether the most recent ingest had its applied delta capped by `deltaSafetyLimit`.
    private(set) var lastDeltaClamped: Bool
    /// Largest `abs(wrappedDelta)` seen since the last `resetMaxObservedDelta()`.
    private(set) var maxObservedDelta: Int

    init(
        sampleSecondsPerTick: TimeInterval = 0.00001,
        sampleDuration: TimeInterval,
        inverted: Bool = false,
        deltaSafetyLimit: Int? = nil,
        samplePosition: TimeInterval = 0,
        lastRawPitchBend: Int? = nil
    ) {
        self.sampleSecondsPerTick = max(0, sampleSecondsPerTick)
        self.sampleDuration = max(0, sampleDuration)
        self.inverted = inverted
        self.deltaSafetyLimit = deltaSafetyLimit
        self.samplePosition = Self.clampPosition(samplePosition, duration: self.sampleDuration)
        self.lastRawPitchBend = lastRawPitchBend
        self.lastWrappedDelta = 0
        self.lastDeltaClamped = false
        self.maxObservedDelta = 0
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

    /// Classifies a single wrapped delta's aliasing risk.
    static func aliasRisk(forDelta delta: Int) -> ScratchDeltaAliasRisk {
        let magnitude = abs(delta)
        if magnitude > aliasFailThreshold { return .fail }
        if magnitude > aliasWarnThreshold { return .warn }
        return .none
    }

    /// Tracks one absolute 14-bit platter angle into `samplePosition`. The first event
    /// only seeds `lastRawPitchBend` (no movement). Subsequent events move the playhead
    /// by the wrapped delta × sensitivity (optionally capped), clamped to the sample.
    /// Returns the wrapped (pre-invert, pre-cap) delta in ticks (0 on the seeding event).
    @discardableResult
    mutating func ingestPitchBend(_ raw: Int) -> Int {
        defer { lastRawPitchBend = raw }
        guard let last = lastRawPitchBend else {
            lastWrappedDelta = 0
            lastDeltaClamped = false
            return 0 // seed only — never jump on the first value
        }
        let delta = Self.wrappedDelta(from: last, to: raw)
        lastWrappedDelta = delta
        maxObservedDelta = Swift.max(maxObservedDelta, abs(delta))

        var applied = delta
        if let limit = deltaSafetyLimit, abs(applied) > limit {
            applied = applied > 0 ? limit : -limit
            lastDeltaClamped = true
        } else {
            lastDeltaClamped = false
        }

        let signed = inverted ? -applied : applied
        samplePosition = Self.clampPosition(
            samplePosition + Double(signed) * sampleSecondsPerTick,
            duration: sampleDuration
        )
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
        lastDeltaClamped = false
    }

    /// Clears the running max-observed-delta diagnostic.
    mutating func resetMaxObservedDelta() {
        maxObservedDelta = 0
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

/// Pure accumulator for the "rotate one revolution" tick-measurement workflow. Feed it
/// the wrapped per-event deltas while the user turns the platter exactly once; it
/// reports how many ticks that revolution produced so the real sensitivity can be set
/// from data instead of the (wrong) vinyl assumption.
struct PlatterTickMeasurement: Equatable {
    private(set) var totalSignedTicks = 0
    private(set) var absoluteTickSum = 0
    private(set) var maxPerEventDelta = 0
    private(set) var eventCount = 0
    /// True if any per-event delta exceeded the alias-fail threshold during measurement.
    private(set) var aliasObserved = false

    /// Records one wrapped per-event delta (in ticks).
    mutating func record(delta: Int) {
        totalSignedTicks += delta
        absoluteTickSum += abs(delta)
        maxPerEventDelta = Swift.max(maxPerEventDelta, abs(delta))
        eventCount += 1
        if abs(delta) > ScratchPlatterPlayheadMapper.aliasFailThreshold {
            aliasObserved = true
        }
    }

    /// Suggested `sampleSecondsPerTick` so that one measured revolution moves
    /// `targetSeconds` of sample. Based on the absolute tick sum (the true distance
    /// travelled in one turn, robust to the wrap that nets signed ticks back to ~0).
    /// Returns nil before any motion has been recorded.
    func suggestedSampleSecondsPerTick(targetSeconds: TimeInterval) -> TimeInterval? {
        guard absoluteTickSum > 0, targetSeconds > 0 else { return nil }
        return targetSeconds / Double(absoluteTickSum)
    }
}
