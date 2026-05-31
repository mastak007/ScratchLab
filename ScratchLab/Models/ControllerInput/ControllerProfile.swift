import Foundation

// Controller-input: pure, Codable controller mapping profile.
//
// Scope guardrails (deliberate):
// - Pure value types only. No Core MIDI, no AVFoundation, no device I/O, no Serato.
// - This is the *profile* layer: unlike `MIDIMessageParsing` (which is deliberately
//   device-agnostic byte parsing), a `ControllerProfile` names a specific controller
//   and how ScratchLab reads its platter/crossfader. It is the single description of the
//   constants that were previously hard-coded across the Scratch Playback Lab.
// - Introducing this type changes NO behaviour: the built-in `.raneOneMKII` profile
//   reproduces the existing `ScratchPlatterPlayheadMapper` constants exactly (locked by
//   tests). It touches no timeline/session export schema.
// - Schema is versioned and decoding fails closed on unknown versions, so a future
//   profile file format cannot be silently misread.

/// How a single physical control reports over MIDI.
enum ControllerControlSignal: Codable, Equatable {
    /// A Control Change message on `number` (e.g. RANE ONE platter = CC6, crossfader = CC8).
    case controlChange(number: Int)
    /// A 14-bit pitch-bend message (RANE ONE platter companion stream; diagnostic-only).
    case pitchBend
}

/// One named control on a deck and how ScratchLab reads it.
struct ControllerControlBinding: Codable, Equatable {
    /// The MIDI signal this control emits.
    let signal: ControllerControlSignal
    /// Step-ring modulus for a relative CC counter (RANE ONE platter CC6 = 128); nil for
    /// absolute controls (crossfader) and for pitch bend.
    let ringModulus: Int?
    /// True when the control is read for diagnostics but never drives playback. The RANE
    /// ONE platter pitch bend is diagnostic-only — CC6 is the ground-truth driver.
    let isDiagnosticOnly: Bool

    init(signal: ControllerControlSignal, ringModulus: Int? = nil, isDiagnosticOnly: Bool = false) {
        self.signal = signal
        self.ringModulus = ringModulus
        self.isDiagnosticOnly = isDiagnosticOnly
    }
}

/// The per-deck control mapping: the platter driver, the crossfader, and the
/// diagnostic-only pitch-bend companion stream.
struct ControllerDeckMapping: Codable, Equatable {
    /// Primary platter driver (RANE ONE = relative CC6, modulus 128).
    let platter: ControllerControlBinding
    /// Crossfader (RANE ONE = absolute CC8, 0...127).
    let crossfader: ControllerControlBinding
    /// Pitch-bend companion stream (RANE ONE = 14-bit, diagnostic-only).
    let pitchBend: ControllerControlBinding
}

/// Errors raised when loading a profile.
enum ControllerProfileError: Error, Equatable {
    /// The decoded profile's `schemaVersion` is newer/older than this build supports.
    case unsupportedSchemaVersion(Int)
}

/// A pure, Codable description of a controller and how the Scratch Playback Lab reads it.
/// The built-in `.raneOneMKII` reproduces the existing hard-coded constants exactly.
struct ControllerProfile: Codable, Equatable {
    /// The schema version this build writes and accepts. Bump when the shape changes.
    static let currentSchemaVersion = 1

    /// Schema version of this profile instance (fails closed on decode if unsupported).
    let schemaVersion: Int
    /// Stable identifier (e.g. "rane-one-mkii"); used to match a built-in profile.
    let identifier: String
    /// Human-readable name (e.g. "RANE ONE MKII").
    let displayName: String
    /// The deck control mapping (platter / crossfader / pitch bend).
    let deck: ControllerDeckMapping
    /// Measured CC6 steps per physical platter revolution.
    let stepsPerRevolution: Int
    /// 14-bit pitch-bend modulus, for the diagnostic wrapped-delta readout.
    let pitchBendTicksPerRevolution: Int
    /// Diagnostic pitch-bend per-event delta beyond which motion is "getting large".
    let aliasWarnThreshold: Int
    /// Diagnostic pitch-bend per-event delta beyond which direction may have aliased.
    let aliasFailThreshold: Int
    /// Crossfader hard-cut transition width (fraction of throw) at the off end.
    let crossfaderCutWidth: Double

    /// Decodes a profile, failing closed if the schema version is not supported, so an
    /// unknown future file format is never silently misread as a valid mapping.
    static func decode(from data: Data, decoder: JSONDecoder = JSONDecoder()) throws -> ControllerProfile {
        let profile = try decoder.decode(ControllerProfile.self, from: data)
        guard profile.schemaVersion == currentSchemaVersion else {
            throw ControllerProfileError.unsupportedSchemaVersion(profile.schemaVersion)
        }
        return profile
    }
}

extension ControllerProfile {
    /// Built-in, verified profile. Its values reproduce the current
    /// `ScratchPlatterPlayheadMapper` constants exactly (locked by tests), so adopting the
    /// profile layer changes no behaviour.
    static let raneOneMKII = ControllerProfile(
        schemaVersion: currentSchemaVersion,
        identifier: "rane-one-mkii",
        displayName: "RANE ONE MKII",
        deck: ControllerDeckMapping(
            platter: ControllerControlBinding(signal: .controlChange(number: 6), ringModulus: 128),
            crossfader: ControllerControlBinding(signal: .controlChange(number: 8)),
            pitchBend: ControllerControlBinding(signal: .pitchBend, isDiagnosticOnly: true)
        ),
        stepsPerRevolution: 3932,
        pitchBendTicksPerRevolution: 16384,
        aliasWarnThreshold: 4096,
        aliasFailThreshold: 8192,
        crossfaderCutWidth: 0.05
    )
}

extension ScratchPlatterPlayheadMapper {
    /// Builds a mapper for a controller profile, defaulting to the built-in RANE profile.
    /// Every shipped profile currently carries the same platter constants the mapper uses
    /// internally, so this changes no behaviour today; it is the seam that lets a future
    /// profile supply different values without touching call sites. Sensitivity, duration,
    /// inversion, safety limit, and boundary mode stay per-session, not per-profile.
    static func forProfile(_ profile: ControllerProfile = .raneOneMKII,
                           sampleSecondsPerStep: TimeInterval = 0.000266,
                           sampleDuration: TimeInterval,
                           inverted: Bool = false,
                           deltaSafetyLimit: Int? = nil,
                           boundaryMode: ScratchPlayheadBoundaryMode = .clamp) -> ScratchPlatterPlayheadMapper {
        ScratchPlatterPlayheadMapper(
            sampleSecondsPerStep: sampleSecondsPerStep,
            sampleDuration: sampleDuration,
            inverted: inverted,
            deltaSafetyLimit: deltaSafetyLimit,
            boundaryMode: boundaryMode
        )
    }
}
