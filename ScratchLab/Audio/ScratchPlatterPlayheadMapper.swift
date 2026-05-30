import Foundation

// Scratch Playback Lab: pure platter → sample-position mapping.
//
// Scope guardrails (deliberate):
// - Pure value type + pure functions only. No AVFoundation, no Core MIDI, no device
//   I/O, no Serato, no DVS. This is the unit the Scratch Playback Lab tests exercise.
//
// Decode model (RANE ONE MKII, measured from the diagnostic recorder):
//   The platter interleaves TWO streams 1:1 on its channel — a 14-bit pitch bend AND
//   CC6. CC6 is the ground truth: it changes by EXACTLY ±1 per event (forward = +1,
//   reverse = −1, with zero exceptions across thousands of captured events), so its
//   sign is unambiguous platter direction and it effectively never aliases (to misread,
//   it would have to skip >64 of its 128 steps between events — many revolutions per
//   event, physically impossible). The 14-bit pitch bend, by contrast, jumps ~6,700
//   ticks per event and folds the wrong way constantly — its direction disagreed with
//   the true (CC6) direction up to 82% of the time on slow reverse. So:
//
//     step           = cc6Step(lastCC6 → cc6, modulus: 128)   // ±1 per event
//     step           = -step when inverted
//     samplePosition += step * sampleSecondsPerStep            // seconds
//     samplePosition  = clamp/loop(samplePosition, 0 ... sampleDuration)
//
// CC6 is the PRIMARY playback driver (`ingestCC6`). The pitch bend is kept only as a
// diagnostic readout (`trackPitchBend`) — it no longer moves the playhead, and the old
// velocity-continuity wrap-disambiguation heuristic has been removed from the playback
// path now that CC6 supplies direction directly.
//
// Sensitivity is `sampleSecondsPerStep` — seconds of sample moved per CC6 step. One
// physical revolution is ~3,932 CC6 steps (measured), so mapping one revolution to a
// sample of length D gives a step of D / 3,932.
//
// The first CC6 event only seeds `lastCC6Value` (no movement); `resetTracking` re-seeds.

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

/// Aliasing risk for a single pitch-bend wrapped delta — a DIAGNOSTIC signal only now
/// (the playhead is driven by CC6, which does not alias). Retained for the lab readout.
enum ScratchDeltaAliasRisk: Equatable {
    case none
    case warn   // > aliasWarnThreshold — getting large
    case fail   // > aliasFailThreshold — direction may have aliased
}

/// What the playhead does when it reaches a sample boundary.
enum ScratchPlayheadBoundaryMode: Equatable {
    /// Stick at the start (0) or end (sampleDuration). A debug/inspection mode.
    case clamp
    /// Wrap around the sample so continuous platter rotation keeps cycling instead of
    /// sticking at 0% or 100%. The lab default for scratch playback.
    case loop
}

/// Pure, testable mapping from the RANE platter streams to a sample position in seconds.
/// Forward rotation (CC6 +1) advances the position; reverse rotation (CC6 −1) retreats it.
struct ScratchPlatterPlayheadMapper: Equatable {
    /// CC6 companion-stream modulus (7-bit), used for the ±1 step ring delta.
    static let cc6Modulus = 128
    /// Measured CC6 steps per physical platter revolution (RANE ONE MKII).
    static let defaultStepsPerRevolution = 3932

    /// 14-bit pitch-bend modulus — used only for the diagnostic wrapped-delta readout.
    static let ticksPerRevolution = 16384
    /// Diagnostic-only: a per-event pitch-bend delta beyond this is "getting large".
    static let aliasWarnThreshold = 4096
    /// Diagnostic-only: a per-event pitch-bend delta beyond this may have aliased.
    static let aliasFailThreshold = 8192

    /// Seconds of sample moved per CC6 step. The sensitivity knob. Default maps roughly
    /// one revolution (~3,932 steps) to a ~1 s sample.
    var sampleSecondsPerStep: TimeInterval
    /// Sample length in seconds — the boundary bound.
    var sampleDuration: TimeInterval
    /// When true, platter direction is flipped (forward rotation retreats the playhead).
    /// A lab-only escape hatch if the hardware reports the opposite sign.
    var inverted: Bool
    /// Optional diagnostic threshold (in pitch-bend ticks): flags `lastDeltaClamped` when
    /// the pitch-bend wrapped delta exceeds it. No effect on playback (CC6 drives motion).
    var deltaSafetyLimit: Int?
    /// Whether the playhead clamps at the sample boundary or wraps around it (loop).
    var boundaryMode: ScratchPlayheadBoundaryMode

    /// Current sample-playback position in seconds, bounded to `0...sampleDuration`.
    private(set) var samplePosition: TimeInterval
    /// The most recent CC6 value, or nil until the first CC6 event seeds it.
    private(set) var lastCC6Value: Int?
    /// The signed CC6 step (±1, pre-invert) applied on the most recent `ingestCC6`;
    /// 0 on a seeding event. Exposed for the lab readout.
    private(set) var lastCC6Step: Int

    // Diagnostic-only pitch-bend tracking (does not move the playhead):
    /// The most recent raw pitch-bend value, or nil until the first event seeds it.
    private(set) var lastRawPitchBend: Int?
    /// The shortest signed wrapped delta of the most recent pitch-bend event (0 on seed).
    private(set) var lastWrappedDelta: Int
    /// Whether the most recent pitch-bend delta exceeded `deltaSafetyLimit` (diagnostic).
    private(set) var lastDeltaClamped: Bool
    /// Largest `abs(wrappedDelta)` seen since the last `resetMaxObservedDelta()`.
    private(set) var maxObservedDelta: Int

    init(
        sampleSecondsPerStep: TimeInterval = 0.000266,
        sampleDuration: TimeInterval,
        inverted: Bool = false,
        deltaSafetyLimit: Int? = nil,
        boundaryMode: ScratchPlayheadBoundaryMode = .clamp,
        samplePosition: TimeInterval = 0,
        lastCC6Value: Int? = nil
    ) {
        self.sampleSecondsPerStep = max(0, sampleSecondsPerStep)
        self.sampleDuration = max(0, sampleDuration)
        self.inverted = inverted
        self.deltaSafetyLimit = deltaSafetyLimit
        self.boundaryMode = boundaryMode
        self.samplePosition = Self.clampPosition(samplePosition, duration: self.sampleDuration)
        self.lastCC6Value = lastCC6Value
        self.lastCC6Step = 0
        self.lastRawPitchBend = nil
        self.lastWrappedDelta = 0
        self.lastDeltaClamped = false
        self.maxObservedDelta = 0
    }

    // MARK: - CC6 (primary playback driver)

    /// Shortest signed step from `last` to `current` on the CC6 ring (`modulus` = 128).
    /// Result is in `(-modulus/2 ... modulus/2]`: a 127→0 wrap is +1, a 0→127 wrap is −1.
    /// In practice the platter only ever emits ±1, so this stays exact and never aliases.
    static func cc6Step(from last: Int, to current: Int, modulus: Int = cc6Modulus) -> Int {
        guard modulus > 0 else { return 0 }
        var delta = (current - last) % modulus
        if delta < 0 { delta += modulus }           // 0 ..< modulus
        if delta > modulus / 2 { delta -= modulus }  // fold to (-modulus/2 ... modulus/2]
        return delta
    }

    /// Drives `samplePosition` from one CC6 event — the primary platter movement path.
    /// The first event only seeds `lastCC6Value` (no movement). Subsequent events move
    /// the playhead by the signed CC6 step × sensitivity, bounded to the sample. Returns
    /// the signed step (pre-invert; 0 on the seeding event).
    @discardableResult
    mutating func ingestCC6(_ value: Int) -> Int {
        defer { lastCC6Value = value }
        guard let last = lastCC6Value else {
            lastCC6Step = 0
            return 0 // seed only — never jump on the first value
        }
        let step = Self.cc6Step(from: last, to: value)
        lastCC6Step = step
        let signed = inverted ? -step : step
        samplePosition = boundedPosition(samplePosition + Double(signed) * sampleSecondsPerStep)
        return step
    }

    // MARK: - Pitch bend (diagnostic only — does NOT move the playhead)

    /// Shortest signed distance from `last` to `current` on a ring of `modulus` ticks.
    /// Result is in `(-modulus/2 ... modulus/2]`. Used for the diagnostic readout only.
    static func wrappedDelta(from last: Int, to current: Int, modulus: Int = ticksPerRevolution) -> Int {
        guard modulus > 0 else { return 0 }
        var delta = (current - last) % modulus
        if delta < 0 { delta += modulus }
        if delta > modulus / 2 { delta -= modulus }
        return delta
    }

    /// Classifies a single pitch-bend wrapped delta's aliasing risk (diagnostic readout).
    static func aliasRisk(forDelta delta: Int) -> ScratchDeltaAliasRisk {
        let magnitude = abs(delta)
        if magnitude > aliasFailThreshold { return .fail }
        if magnitude > aliasWarnThreshold { return .warn }
        return .none
    }

    /// Tracks one pitch-bend value for the diagnostic readout/recording ONLY. It updates
    /// the wrapped-delta and alias diagnostics but never moves the playhead (CC6 does).
    /// Returns the shortest wrapped delta (0 on a seeding event).
    @discardableResult
    mutating func trackPitchBend(_ raw: Int) -> Int {
        defer { lastRawPitchBend = raw }
        guard let last = lastRawPitchBend else {
            lastWrappedDelta = 0
            lastDeltaClamped = false
            return 0 // seed only
        }
        let delta = Self.wrappedDelta(from: last, to: raw)
        lastWrappedDelta = delta
        maxObservedDelta = Swift.max(maxObservedDelta, abs(delta))
        lastDeltaClamped = deltaSafetyLimit.map { abs(delta) > $0 } ?? false
        return delta
    }

    // MARK: - Boundary / position

    /// Applies the boundary mode to a candidate position: clamp to the sample, or wrap
    /// around it (loop) so continuous rotation keeps cycling instead of sticking.
    private func boundedPosition(_ value: TimeInterval) -> TimeInterval {
        switch boundaryMode {
        case .clamp: return Self.clampPosition(value, duration: sampleDuration)
        case .loop:  return Self.wrapPosition(value, duration: sampleDuration)
        }
    }

    /// Wraps a position into `0 ..< duration` (loop mode); 0 for non-positive duration.
    /// Direction is preserved: a forward step past the end re-enters near the start, a
    /// reverse step past the start re-enters near the end.
    static func wrapPosition(_ value: TimeInterval, duration: TimeInterval) -> TimeInterval {
        guard duration > 0 else { return 0 }
        let m = value.truncatingRemainder(dividingBy: duration)
        return m < 0 ? m + duration : m
    }

    /// Resets the playhead to the start of the sample (does not touch tracking).
    mutating func resetPosition() {
        samplePosition = 0
    }

    /// Forgets the last CC6 and pitch-bend values so the next events re-seed without
    /// moving. Use after a deck/source change or a pause.
    mutating func resetTracking() {
        lastCC6Value = nil
        lastCC6Step = 0
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

    // MARK: - Crossfader + deck filtering (unchanged)

    /// Normalises a 7-bit CC value (0...127) to a `0...1` crossfader position.
    static func normalizedCrossfader(cc value: Int) -> Double {
        Swift.min(Swift.max(Double(value) / 127.0, 0), 1)
    }

    /// Width (fraction of crossfader travel) of the cut-in zone at the off end — a small
    /// transition keeps the hard cut click-safe without being an audible slope.
    static let crossfaderCutWidth = 0.05

    /// Output gain for optional crossfader volume gating. Full gain (1.0) unless gating
    /// is enabled AND a valid crossfader value has arrived (never mutes before the first
    /// CC). Uses a HARD-CUT (scratch) curve, not a linear slope: full gain across the
    /// whole throw, dropping to silence only within `crossfaderCutWidth` of the off (0)
    /// end. So at rest (e.g. 0.70) the deck is fully on, and it cuts sharply near 0.
    static func outputGain(applyGating: Bool, crossfaderValid: Bool, crossfader: Double) -> Float {
        guard applyGating, crossfaderValid else { return 1.0 }
        let position = Swift.min(Swift.max(crossfader, 0), 1)
        guard crossfaderCutWidth > 0 else { return position > 0 ? 1.0 : 0.0 }
        return Float(Swift.min(1.0, position / crossfaderCutWidth))
    }

    /// Whether a raw pitch-bend channel belongs to the selected deck. Only raw
    /// channels 0x0 (left) and 0x1 (right) are platters; everything else is rejected
    /// so a non-platter channel never drives the playhead.
    static func isPitchBendChannel(_ channel: Int?, forDeck deck: Int) -> Bool {
        guard let channel, ScratchPlatterDeck(rawValue: deck) != nil else { return false }
        return channel == deck
    }
}

/// Pure accumulator for the "rotate one revolution" measurement. Fed the per-event CC6
/// steps (±1) while the user turns the platter exactly once, it reports how many steps
/// that revolution produced so the real sensitivity can be set from data (~3,932 steps).
struct PlatterTickMeasurement: Equatable {
    private(set) var totalSignedTicks = 0
    private(set) var absoluteTickSum = 0
    private(set) var maxPerEventDelta = 0
    private(set) var eventCount = 0
    /// True if any per-event delta exceeded the alias-fail threshold during measurement.
    private(set) var aliasObserved = false

    /// Records one per-event delta (CC6 steps in the live path; any delta in tests).
    mutating func record(delta: Int) {
        totalSignedTicks += delta
        absoluteTickSum += abs(delta)
        maxPerEventDelta = Swift.max(maxPerEventDelta, abs(delta))
        eventCount += 1
        if abs(delta) > ScratchPlatterPlayheadMapper.aliasFailThreshold {
            aliasObserved = true
        }
    }

    /// Suggested per-step sensitivity so one measured revolution moves `targetSeconds`
    /// of sample. Based on the absolute step sum. Returns nil before any motion.
    func suggestedSampleSecondsPerTick(targetSeconds: TimeInterval) -> TimeInterval? {
        guard absoluteTickSum > 0, targetSeconds > 0 else { return nil }
        return targetSeconds / Double(absoluteTickSum)
    }
}
