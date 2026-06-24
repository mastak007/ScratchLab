import Foundation

// Pro-DJ MIDI registry layer (future-facing): the known-hardware registry and its
// identity→profile matching, plus the minimal verified RANE seed entry.
//
// Scope guardrails (deliberate):
// - Pure value logic only. No Core MIDI, no audio, no playback, no UI.
// - The registry starts SMALL on purpose: one verified seed (RANE ONE). The architecture
//   supports many tiers of gear (Rane Twelve, DJM-S9, DDJ-SRT/1000SRT, CDJ/XDJ, Denon,
//   Numark, …) but those entries are added incrementally in later slices, not here.
// - Matching is name/manufacturer-fragment based and ranked by certification tier. An
//   unknown device yields NO certified match and resolves to an explicit unverified
//   fallback, so the caller always has a profile to drive the MIDI-Learn path.

/// One ranked match of a device to a known profile.
struct MIDIProfileMatch: Equatable {
    /// The matched (or fallback) profile.
    let profile: MIDIControllerProfile
    /// The confidence for THIS match — a real match carries the profile's tier; the
    /// unverified fallback carries `.unverified`.
    let confidence: MIDIProfileConfidence
    /// The fragment that matched (longest wins), or nil for the unverified fallback.
    let matchedFragment: String?
}

/// A registry of known controller profiles. Injectable (`init(profiles:)`) so tests can
/// supply their own set; `shared` holds the minimal shipped seed.
struct MIDIHardwareRegistry {
    /// The known profiles, in declaration order (ranking is computed, not positional).
    let profiles: [MIDIControllerProfile]

    init(profiles: [MIDIControllerProfile]) {
        self.profiles = profiles
    }

    /// The shipped registry. Minimal by design — one verified seed for now.
    static let shared = MIDIHardwareRegistry(profiles: [.raneOneSeed])

    /// Manufacturer-only matches are never trusted beyond this tier — a generic "USB MIDI
    /// Device" advertising manufacturer "RANE" is at best a candidate to verify, NOT a
    /// certified RANE ONE. Certification requires specific model / profile-name evidence.
    static let manufacturerOnlyConfidenceCeiling: MIDIProfileConfidence = .heuristic

    /// All profiles that match a device, best first. Ranking: higher certification tier
    /// first, then the longer matched fragment (more specific), then identifier for a
    /// stable deterministic order. Profiles that do not match are omitted.
    ///
    /// Match strength depends on the EVIDENCE:
    /// - A name / model / profile-name fragment hit is specific evidence → the profile's
    ///   full confidence (a certified profile certifies).
    /// - A manufacturer-only hit is weak evidence → capped at
    ///   `manufacturerOnlyConfidenceCeiling` so it can never certify a model-specific
    ///   profile; it surfaces as a candidate that still needs guided verification.
    func matches(for identity: MIDIDeviceIdentity) -> [MIDIProfileMatch] {
        let haystack = identity.nameHaystack
        let manufacturer = identity.manufacturerHaystack

        let found: [MIDIProfileMatch] = profiles.compactMap { profile in
            // Longest matching name fragment found anywhere in the device's names.
            let nameHit = profile.matching.nameFragments
                .filter { fragment in haystack.contains { $0.contains(fragment) } }
                .max(by: { $0.count < $1.count })

            // Longest matching manufacturer fragment.
            let mfrHit: String? = {
                guard let manufacturer else { return nil }
                return profile.matching.manufacturerFragments
                    .filter { manufacturer.contains($0) }
                    .max(by: { $0.count < $1.count })
            }()

            // Prefer specific name evidence; fall back to a weak manufacturer-only hit.
            let resolvedConfidence: MIDIProfileConfidence
            let matchedFragment: String
            if let nameHit {
                resolvedConfidence = profile.confidence
                matchedFragment = nameHit
            } else if let mfrHit {
                resolvedConfidence = min(profile.confidence, Self.manufacturerOnlyConfidenceCeiling)
                matchedFragment = mfrHit
            } else {
                return nil
            }

            return MIDIProfileMatch(
                profile: profile,
                confidence: resolvedConfidence,
                matchedFragment: matchedFragment
            )
        }

        return found.sorted { lhs, rhs in
            if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
            let lhsLen = lhs.matchedFragment?.count ?? 0
            let rhsLen = rhs.matchedFragment?.count ?? 0
            if lhsLen != rhsLen { return lhsLen > rhsLen }
            return lhs.profile.identifier < rhs.profile.identifier
        }
    }

    /// The single best real match, or nil when nothing in the registry matches.
    func bestMatch(for identity: MIDIDeviceIdentity) -> MIDIProfileMatch? {
        matches(for: identity).first
    }

    /// Always returns a usable match: the best real match if any, else an explicit
    /// unverified fallback so the caller can route to guided MIDI-Learn.
    func resolve(for identity: MIDIDeviceIdentity) -> MIDIProfileMatch {
        bestMatch(for: identity) ?? MIDIHardwareRegistry.unverifiedFallback(for: identity)
    }

    /// An empty, unverified profile synthesised for an unrecognised device. It carries no
    /// bindings (nothing is known yet) — verification / MIDI-Learn fills them in.
    static func unverifiedFallback(for identity: MIDIDeviceIdentity) -> MIDIProfileMatch {
        let profile = MIDIControllerProfile(
            identifier: "unverified",
            displayName: identity.sourceName.isEmpty ? "Unverified Controller" : identity.sourceName,
            manufacturer: identity.manufacturer,
            model: identity.model,
            confidence: .unverified,
            matching: MIDIProfileMatching(),
            deckCount: 0,
            bindings: [],
            notes: "No known profile matched this device — use guided verification / MIDI Learn."
        )
        return MIDIProfileMatch(profile: profile, confidence: .unverified, matchedFragment: nil)
    }
}

extension MIDIControllerProfile {
    /// Minimal VERIFIED seed profile, built from ScratchLab's already-verified RANE facts:
    /// the platter is a relative CC6 ring counter (±1/event, ~3932 steps/rev), the
    /// crossfader is absolute CC8, and the platter pitch bend is a diagnostic-only stream
    /// (it aliases — CC6 is the driver). These constants mirror the v1 profile's verified
    /// values but DO NOT depend on or modify it; this is the future-facing layer's seed.
    static let raneOneSeed = MIDIControllerProfile(
        identifier: "rane-one",
        displayName: "RANE ONE / ONE MKII",
        manufacturer: "RANE",
        model: "ONE",
        confidence: .certified,
        matching: MIDIProfileMatching(
            nameFragments: ["rane one"],
            manufacturerFragments: ["rane"]
        ),
        deckCount: 2,
        bindings: [

            // ── Motorized platters ────────────────────────────────────────────────────
            // Left/right platter: relative CC6 ring counter on ch1/ch2 (MIDI Monitor
            // 1-indexed) = ch=0/ch=1 (0-indexed raw byte). ~3932 steps/rev measured.
            MIDIControlBinding(
                role: MIDIControlRole(kind: .platterMovement, deck: 0),
                signal: .relativeCC(number: 6, encoding: .ringCounter(modulus: 128)),
                channel: 0,
                ringModulus: 128,
                notes: "Left deck platter: CC6 ch1 (ch=0). ±1/event, ~3932 steps/rev. Motorized, not touch-jog."
            ),
            MIDIControlBinding(
                role: MIDIControlRole(kind: .platterMovement, deck: 1),
                signal: .relativeCC(number: 6, encoding: .ringCounter(modulus: 128)),
                channel: 1,
                ringModulus: 128,
                notes: "Right deck platter: CC6 ch2 (ch=1). ±1/event, ~3932 steps/rev. Verified via re-capture 2026-06-25."
            ),

            // ── Crossfader ────────────────────────────────────────────────────────────
            // Confirmed: CC8 on ch=15 (MIDI Monitor ch16). Full 0–127 sweep, all
            // 128 values observed in isolation.
            MIDIControlBinding(
                role: MIDIControlRole(kind: .crossfader),
                signal: .absoluteCC(number: 8),
                channel: 15,
                notes: "Confirmed: CC8 ch=15 (ch16 MIDI Monitor). Full 0–127 sweep. 0=left, 127=right."
            ),

            // ── Pitch bend diagnostic (aliasing; not a control signal) ────────────────
            MIDIControlBinding(
                role: MIDIControlRole(kind: .platterAbsolute, deck: 0),
                signal: .pitchBend,
                channel: 0,
                isDiagnosticOnly: true,
                notes: "Pitch Wheel ch=0 — diagnostic only; aliases during platter rotation. CC6 is the driver."
            ),
            MIDIControlBinding(
                role: MIDIControlRole(kind: .platterAbsolute, deck: 1),
                signal: .pitchBend,
                channel: 1,
                isDiagnosticOnly: true,
                notes: "Pitch Wheel ch=1 — diagnostic only; aliases during platter rotation. CC6 is the driver. Verified via re-capture 2026-06-25."
            ),

            // ── Left deck channel fader ───────────────────────────────────────────────
            // Confirmed: CC28 ch1 (MIDI Monitor) = ch=0 (0-indexed). 0=closed, 127=open.
            MIDIControlBinding(
                role: MIDIControlRole(kind: .channelFader, deck: 0, label: "Left Channel Fader"),
                signal: .absoluteCC(number: 28),
                channel: 0,
                notes: "Confirmed: CC28 ch1 (ch=0). 0=down/closed, 127=up/open."
            ),

            // ── Left deck pitch/tempo fader (14-bit high-res) ────────────────────────
            // CC9 (MSB) + CC41 (LSB) on ch1 (ch=0). 14-bit resolution.
            // Calibration required before this can feed scoring or tempo display.
            // CC9 + 32 = CC41 is the standard MIDI high-res pairing convention.
            MIDIControlBinding(
                role: MIDIControlRole(kind: .tempo, deck: 0, label: "Left Pitch/Tempo Fader (raw 14-bit)"),
                signal: .highResCCPair(msb: 9, lsb: 41),
                channel: 0,
                notes: "Confirmed: CC9 MSB + CC41 LSB, ch1 (ch=0). Calibration (direction, range) needed."
            ),

            // ── Right deck channel fader ──────────────────────────────────────────────
            // Confirmed via re-capture 2026-06-25: CC28 on ch=1 (ch2 MIDI Monitor).
            // 0=closed, 127=open. Full sweep observed.
            MIDIControlBinding(
                role: MIDIControlRole(kind: .channelFader, deck: 1, label: "Right Channel Fader"),
                signal: .absoluteCC(number: 28),
                channel: 1,
                notes: "Confirmed: CC28 ch=1 (ch2 MIDI Monitor). 0=down/closed, 127=up/open. Verified via re-capture 2026-06-25."
            ),

            // ── Right deck pitch/tempo fader (14-bit high-res) ───────────────────────
            // Confirmed via re-capture 2026-06-25: CC9 (MSB) + CC41 (LSB) on ch=1
            // (ch2 MIDI Monitor). 14-bit range 0–16383 observed.
            MIDIControlBinding(
                role: MIDIControlRole(kind: .tempo, deck: 1, label: "Right Pitch/Tempo Fader (raw 14-bit)"),
                signal: .highResCCPair(msb: 9, lsb: 41),
                channel: 1,
                notes: "Confirmed: CC9 MSB + CC41 LSB, ch=1 (ch2 MIDI Monitor). Verified via re-capture 2026-06-25."
            ),

            // ── Transport Start/Stop ────────────────────────────────────────────────
            // The Rane ONE MKII has a single Start/Stop (▶⏸) button per deck — no
            // separate CUE transport button. Both emit Note On note=0 vel=127 on press,
            // Note Off note=0 vel=0 on release, on their deck's continuous channel.
            // Hotcue recall is handled by the performance pads (notes 20–27).
            MIDIControlBinding(
                role: MIDIControlRole(kind: .transport, deck: 0, label: "Left Start/Stop"),
                signal: .note(number: 0),
                channel: 0,
                notes: "Confirmed: Note On/Off ch=0 note=0. Single transport button per deck — no separate CUE."
            ),
            MIDIControlBinding(
                role: MIDIControlRole(kind: .transport, deck: 1, label: "Right Start/Stop"),
                signal: .note(number: 0),
                channel: 1,
                notes: "Confirmed: Note On/Off ch=1 note=0. Single transport button per deck — no separate CUE."
            ),

            // ── Left deck EQ / gain controls ──────────────────────────────────────────
            // Confirmed via isolated knob turns 2026-06-25. Full 0–127 sweep per knob.
            MIDIControlBinding(
                role: MIDIControlRole(kind: .unknown, deck: 0, label: "Left Bass EQ"),
                signal: .absoluteCC(number: 25),
                channel: 0,
                notes: "Confirmed: CC25 ch=0. Full 0–127 sweep verified in isolation."
            ),
            MIDIControlBinding(
                role: MIDIControlRole(kind: .unknown, deck: 0, label: "Left Mid EQ"),
                signal: .absoluteCC(number: 24),
                channel: 0,
                notes: "Confirmed: CC24 ch=0. Full 0–127 sweep verified in isolation."
            ),
            MIDIControlBinding(
                role: MIDIControlRole(kind: .unknown, deck: 0, label: "Left Highs EQ"),
                signal: .absoluteCC(number: 23),
                channel: 0,
                notes: "Confirmed: CC23 ch=0. Full 0–127 sweep verified in isolation."
            ),
            MIDIControlBinding(
                role: MIDIControlRole(kind: .unknown, deck: 0, label: "Left Gain"),
                signal: .absoluteCC(number: 22),
                channel: 0,
                notes: "Confirmed: CC22 ch=0. Full 0–127 sweep verified in isolation."
            ),

            // ── Right deck EQ / gain controls ─────────────────────────────────────────
            // Confirmed via isolated knob turns 2026-06-25. Full 0–127 sweep per knob.
            MIDIControlBinding(
                role: MIDIControlRole(kind: .unknown, deck: 1, label: "Right Bass EQ"),
                signal: .absoluteCC(number: 25),
                channel: 1,
                notes: "Confirmed: CC25 ch=1. Full 0–127 sweep verified in isolation."
            ),
            MIDIControlBinding(
                role: MIDIControlRole(kind: .unknown, deck: 1, label: "Right Mid EQ"),
                signal: .absoluteCC(number: 24),
                channel: 1,
                notes: "Confirmed: CC24 ch=1. Full 0–127 sweep verified in isolation."
            ),
            MIDIControlBinding(
                role: MIDIControlRole(kind: .unknown, deck: 1, label: "Right Highs EQ"),
                signal: .absoluteCC(number: 23),
                channel: 1,
                notes: "Confirmed: CC23 ch=1. Full 0–127 sweep verified in isolation."
            ),
            MIDIControlBinding(
                role: MIDIControlRole(kind: .unknown, deck: 1, label: "Right Gain"),
                signal: .absoluteCC(number: 22),
                channel: 1,
                notes: "Confirmed: CC22 ch=1. Full 0–127 sweep verified in isolation."
            ),

            // ── Left deck performance pads 1–8 ───────────────────────────────────────
            // Confirmed: Note On/Off ch5 (MIDI Monitor 1-indexed) = ch=4 (0-indexed).
            // Press: velocity 127. Release: Note Off velocity 0.
            // Pads 1–8: notes 20–27.
            MIDIControlBinding(
                role: MIDIControlRole(kind: .pad, deck: 0, label: "Left Deck Pad 1"),
                signal: .note(number: 20),
                channel: 4,
                notes: "Confirmed: Note On ch5 (ch=4) note20 vel127=press; Note Off vel0=release."
            ),
            MIDIControlBinding(
                role: MIDIControlRole(kind: .pad, deck: 0, label: "Left Deck Pad 2"),
                signal: .note(number: 21),
                channel: 4,
                notes: "Confirmed: Note On ch5 note21."
            ),
            MIDIControlBinding(
                role: MIDIControlRole(kind: .pad, deck: 0, label: "Left Deck Pad 3"),
                signal: .note(number: 22),
                channel: 4,
                notes: "Confirmed: Note On ch5 note22."
            ),
            MIDIControlBinding(
                role: MIDIControlRole(kind: .pad, deck: 0, label: "Left Deck Pad 4"),
                signal: .note(number: 23),
                channel: 4,
                notes: "Confirmed: Note On ch5 note23."
            ),
            MIDIControlBinding(
                role: MIDIControlRole(kind: .pad, deck: 0, label: "Left Deck Pad 5"),
                signal: .note(number: 24),
                channel: 4,
                notes: "Confirmed: Note On ch5 note24."
            ),
            MIDIControlBinding(
                role: MIDIControlRole(kind: .pad, deck: 0, label: "Left Deck Pad 6"),
                signal: .note(number: 25),
                channel: 4,
                notes: "Confirmed: Note On ch5 note25."
            ),
            MIDIControlBinding(
                role: MIDIControlRole(kind: .pad, deck: 0, label: "Left Deck Pad 7"),
                signal: .note(number: 26),
                channel: 4,
                notes: "Confirmed: Note On ch5 note26."
            ),
            MIDIControlBinding(
                role: MIDIControlRole(kind: .pad, deck: 0, label: "Left Deck Pad 8"),
                signal: .note(number: 27),
                channel: 4,
                notes: "Confirmed: Note On ch5 note27."
            ),

            // ── Right deck performance pads 1–8 ──────────────────────────────────────
            // Confirmed: Note On/Off ch6 (MIDI Monitor 1-indexed) = ch=5 (0-indexed).
            // Pads 1–4 (notes 20–23) confirmed earlier. Pads 5–8 (notes 24–27) confirmed
            // in latest capture. Press: velocity 127. Release: Note Off velocity 0.
            MIDIControlBinding(
                role: MIDIControlRole(kind: .pad, deck: 1, label: "Right Deck Pad 1"),
                signal: .note(number: 20),
                channel: 5,
                notes: "Confirmed: Note On ch6 (ch=5) note20 vel127=press; Note Off vel0=release."
            ),
            MIDIControlBinding(
                role: MIDIControlRole(kind: .pad, deck: 1, label: "Right Deck Pad 2"),
                signal: .note(number: 21),
                channel: 5,
                notes: "Confirmed: Note On ch6 note21."
            ),
            MIDIControlBinding(
                role: MIDIControlRole(kind: .pad, deck: 1, label: "Right Deck Pad 3"),
                signal: .note(number: 22),
                channel: 5,
                notes: "Confirmed: Note On ch6 note22."
            ),
            MIDIControlBinding(
                role: MIDIControlRole(kind: .pad, deck: 1, label: "Right Deck Pad 4"),
                signal: .note(number: 23),
                channel: 5,
                notes: "Confirmed: Note On ch6 note23."
            ),
            MIDIControlBinding(
                role: MIDIControlRole(kind: .pad, deck: 1, label: "Right Deck Pad 5"),
                signal: .note(number: 24),
                channel: 5,
                notes: "Confirmed: Note On ch6 note24."
            ),
            MIDIControlBinding(
                role: MIDIControlRole(kind: .pad, deck: 1, label: "Right Deck Pad 6"),
                signal: .note(number: 25),
                channel: 5,
                notes: "Confirmed: Note On ch6 note25."
            ),
            MIDIControlBinding(
                role: MIDIControlRole(kind: .pad, deck: 1, label: "Right Deck Pad 7"),
                signal: .note(number: 26),
                channel: 5,
                notes: "Confirmed: Note On ch6 note26."
            ),
            MIDIControlBinding(
                role: MIDIControlRole(kind: .pad, deck: 1, label: "Right Deck Pad 8"),
                signal: .note(number: 27),
                channel: 5,
                notes: "Confirmed: Note On ch6 note27."
            ),
        ],
        notes: "Seed entry — verified Rane ONE MKII hardware facts (2026-06-25). " +
               "Deck channel pattern (MIDI Monitor 1-indexed): left continuous=ch1, right continuous=ch2, " +
               "left pads=ch5, right pads=ch6, crossfader=ch16. " +
               "Left deck: CC6 platter (ring), CC28 channel fader, CC9+CC41 14-bit pitch, " +
               "CC22-25 EQ/gain (confirmed via isolated knob turns 2026-06-25: CC25=Bass, CC24=Mid, CC23=Highs, CC22=Gain). " +
               "Right deck: CC6 platter (ring), CC28 channel fader, CC9+CC41 14-bit pitch — verified via re-capture. " +
               "Crossfader: CC8 on ch=15 (ch16 MIDI Monitor) — verified full 0–127 sweep. " +
               "Transport (Start/Stop): left=ch=0 note=0, right=ch=1 note=0 (Note On press, Note Off release); " +
               "single ▶⏸ button per deck — no separate CUE transport; hotcue recall is via performance pads. " +
               "Pads 1–8: left=ch5 notes 20–27, right=ch6 notes 20–27; Note On/Off not CC. " +
               "Pitch bend streams are diagnostic-only (alias during rotation; CC6 is the driver)."
    )
}
