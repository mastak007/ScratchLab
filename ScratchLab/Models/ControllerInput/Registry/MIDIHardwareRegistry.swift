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
            MIDIControlBinding(
                role: MIDIControlRole(kind: .platterMovement, deck: 0),
                signal: .relativeCC(number: 6, encoding: .ringCounter(modulus: 128)),
                channel: 0,
                ringModulus: 128,
                notes: "±1 per event; ~3932 steps/rev (measured). Playback driver."
            ),
            MIDIControlBinding(
                role: MIDIControlRole(kind: .platterMovement, deck: 1),
                signal: .relativeCC(number: 6, encoding: .ringCounter(modulus: 128)),
                channel: 1,
                ringModulus: 128,
                notes: "±1 per event; ~3932 steps/rev (measured). Playback driver."
            ),
            MIDIControlBinding(
                role: MIDIControlRole(kind: .crossfader),
                signal: .absoluteCC(number: 8)
            ),
            MIDIControlBinding(
                role: MIDIControlRole(kind: .platterAbsolute, deck: 0),
                signal: .pitchBend,
                channel: 0,
                isDiagnosticOnly: true,
                notes: "14-bit pitch bend — diagnostic only; aliases. CC6 is the driver."
            ),
            MIDIControlBinding(
                role: MIDIControlRole(kind: .platterAbsolute, deck: 1),
                signal: .pitchBend,
                channel: 1,
                isDiagnosticOnly: true,
                notes: "14-bit pitch bend — diagnostic only; aliases. CC6 is the driver."
            )
        ],
        notes: "Seed entry. Verified RANE facts: CC6 ±1 ring platter, CC8 crossfader, pitch bend diagnostic-only."
    )
}
