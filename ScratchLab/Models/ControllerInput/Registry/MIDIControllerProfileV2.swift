import Foundation

// Pro-DJ MIDI registry layer (future-facing): device identity, confidence tier, and the
// binding-list controller profile that supersedes the v1 fixed-slot `ControllerProfile`.
//
// Scope guardrails (deliberate):
// - Pure value types only. No Core MIDI, no audio, no playback, no UI.
// - This is the GENERIC, future-facing profile. The existing v1 `ControllerProfile`
//   remains the playback-facing profile and is untouched. The type is named
//   `MIDIControllerProfile` (file `MIDIControllerProfileV2` = second-generation layer).
// - Schema is versioned and decoding fails closed on an unsupported version, so a future
//   profile file format can never be silently misread.

/// How confident ScratchLab is that a profile correctly describes a device — also the
/// certification tier. Comparable so the registry can rank matches (certified highest).
enum MIDIProfileConfidence: String, Codable, CaseIterable, Comparable {
    /// Verified by ScratchLab against real hardware.
    case certified
    /// Contributed or imported by a user; plausible but not first-party verified.
    case community
    /// Inferred from observed MIDI (MIDI-Learn) — a guess to be confirmed.
    case heuristic
    /// No match / not yet verified.
    case unverified

    /// Higher tier = more trustworthy.
    private var rank: Int {
        switch self {
        case .certified: return 3
        case .community: return 2
        case .heuristic: return 1
        case .unverified: return 0
        }
    }

    static func < (lhs: MIDIProfileConfidence, rhs: MIDIProfileConfidence) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// What a connected MIDI device tells us about itself. Sourced from Core MIDI endpoint
/// properties (display/source/port names, unique ID) and, where available, manufacturer /
/// model. All optional except `sourceName`, because class-compliant gear varies in what
/// it advertises. Pure value type — nothing here opens a device.
struct MIDIDeviceIdentity: Codable, Equatable, Hashable {
    /// The source endpoint display name (e.g. "RANE ONE"). Always present.
    let sourceName: String
    /// Core MIDI unique ID, when known.
    let uniqueID: Int32?
    /// Manufacturer string, when the endpoint advertises one.
    let manufacturer: String?
    /// Model string, when the endpoint advertises one.
    let model: String?
    /// Endpoint display name, when distinct from `sourceName`.
    let displayName: String?
    /// Port name, when useful for disambiguation.
    let portName: String?

    init(
        sourceName: String,
        uniqueID: Int32? = nil,
        manufacturer: String? = nil,
        model: String? = nil,
        displayName: String? = nil,
        portName: String? = nil
    ) {
        self.sourceName = sourceName
        self.uniqueID = uniqueID
        self.manufacturer = manufacturer
        self.model = model
        self.displayName = displayName
        self.portName = portName
    }

    /// Lowercased name-ish strings to test profile fragments against (deduped, non-empty).
    var nameHaystack: [String] {
        [sourceName, displayName, portName, model]
            .compactMap { $0?.lowercased() }
            .filter { !$0.isEmpty }
    }

    /// Lowercased manufacturer string, if any.
    var manufacturerHaystack: String? {
        manufacturer?.lowercased()
    }
}

/// How the registry recognises a device as a given profile: any matching name fragment or
/// manufacturer fragment (all compared lowercased, substring) makes the device a candidate.
struct MIDIProfileMatching: Codable, Equatable, Hashable {
    /// Lowercased substrings to look for in the device's name-ish strings.
    let nameFragments: [String]
    /// Lowercased substrings to look for in the device's manufacturer string.
    let manufacturerFragments: [String]

    init(nameFragments: [String] = [], manufacturerFragments: [String] = []) {
        self.nameFragments = nameFragments
        self.manufacturerFragments = manufacturerFragments
    }
}

/// Errors raised when loading a profile.
enum MIDIControllerProfileError: Error, Equatable {
    /// The decoded profile's `schemaVersion` is not supported by this build.
    case unsupportedSchemaVersion(Int)
}

/// A pure, Codable, future-facing controller profile: a LIST of role→signal bindings
/// (not fixed platter/crossfader/pitchBend slots), so it models platter decks, no-platter
/// mixers, multi-deck controllers, and media players alike. Nothing here drives playback.
struct MIDIControllerProfile: Codable, Equatable {
    /// Schema version this build writes and accepts (independent of v1 `ControllerProfile`).
    static let currentSchemaVersion = 1

    /// Schema version of this instance (fails closed on decode if unsupported).
    let schemaVersion: Int
    /// Stable identifier (e.g. "rane-one").
    let identifier: String
    /// Human-readable name.
    let displayName: String
    /// Manufacturer, when known.
    let manufacturer: String?
    /// Model, when known.
    let model: String?
    /// Certification tier / confidence for this profile.
    let confidence: MIDIProfileConfidence
    /// How a connected device is recognised as this profile.
    let matching: MIDIProfileMatching
    /// Number of decks the device exposes (0 for a deckless mixer).
    let deckCount: Int
    /// The control bindings.
    let bindings: [MIDIControlBinding]
    /// Optional provenance / notes.
    let notes: String?

    init(
        schemaVersion: Int = MIDIControllerProfile.currentSchemaVersion,
        identifier: String,
        displayName: String,
        manufacturer: String? = nil,
        model: String? = nil,
        confidence: MIDIProfileConfidence,
        matching: MIDIProfileMatching,
        deckCount: Int,
        bindings: [MIDIControlBinding],
        notes: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.identifier = identifier
        self.displayName = displayName
        self.manufacturer = manufacturer
        self.model = model
        self.confidence = confidence
        self.matching = matching
        self.deckCount = deckCount
        self.bindings = bindings
        self.notes = notes
    }

    /// Decodes a profile, failing closed if the schema version is unsupported, so an
    /// unknown future file format is never silently misread as a valid mapping.
    static func decode(from data: Data, decoder: JSONDecoder = JSONDecoder()) throws -> MIDIControllerProfile {
        let profile = try decoder.decode(MIDIControllerProfile.self, from: data)
        guard profile.schemaVersion == currentSchemaVersion else {
            throw MIDIControllerProfileError.unsupportedSchemaVersion(profile.schemaVersion)
        }
        return profile
    }

    /// The first binding for a given role kind (and optional deck), or nil. Convenience
    /// for verification/lookups; does not assume a particular control layout.
    func binding(for kind: MIDIControlRole.Kind, deck: Int? = nil) -> MIDIControlBinding? {
        bindings.first { $0.role.kind == kind && (deck == nil || $0.role.deck == deck) }
    }

    /// Bindings that should be exercised during guided verification (everything that is
    /// not diagnostic-only — diagnostic streams like the RANE pitch bend are not asked for).
    var verifiableBindings: [MIDIControlBinding] {
        bindings.filter { !$0.isDiagnosticOnly }
    }
}
