#if os(macOS)
import Foundation

// Scratch Playback Lab: pure recognition of whether the active MIDI source matches
// the controller the lab's mapping was built around (RANE ONE / ONE MKII).
//
// Scope guardrails (deliberate):
// - Pure value logic only. No Core MIDI, no AVFoundation, no device I/O, no Serato.
// - This NEVER touches mapper math, timeline capture, or any export. Its only job is
//   to decide whether to show the tester a "this mapping may be wrong" warning, so an
//   unsupported/unknown controller cannot silently produce garbage captured notation.
// - It is name-based on purpose: the verified RANE mapping (CC6 platter, CC8 crossfader,
//   measured steps/rev) is specific to that hardware, so any source that does not look
//   like a RANE ONE is treated as unverified rather than assumed-compatible.

/// Pure recognition of the verified Playback Lab controller, by MIDI source display name.
enum ControllerRecognition {
    /// Lowercased display-name fragment identifying the verified controller. "rane one"
    /// matches both "RANE ONE" and "RANE ONE MKII"; it is intentionally NOT just "rane"
    /// so an unrelated RANE mixer is not mistaken for the verified deck mapping.
    static let recognizedNameFragment = "rane one"

    /// Warning shown when the active source is not the verified controller.
    static let unverifiedWarning = "Unverified controller mapping — captured notation may be invalid."

    /// Whether a single source display name looks like the verified controller.
    static func isRecognized(sourceName: String) -> Bool {
        sourceName.lowercased().contains(recognizedNameFragment)
    }

    /// Whether the active selection is covered by the verified mapping:
    /// - A specific selected source is recognized iff its own name matches.
    /// - "All sources" (nil selection) is recognized iff a verified source is present
    ///   among those available (the RANE drives capture even if other gear is attached).
    /// - No sources at all is treated as recognized — nothing is connected to capture, so
    ///   there is no garbage to warn about and no false alarm on an empty lab.
    static func isRecognized(selectedSourceName: String?, availableSourceNames: [String]) -> Bool {
        if let selected = selectedSourceName {
            return isRecognized(sourceName: selected)
        }
        if availableSourceNames.isEmpty { return true }
        return availableSourceNames.contains { isRecognized(sourceName: $0) }
    }

    /// The warning string for the active selection, or nil when the selection is the
    /// verified controller (current behaviour, no warning).
    static func warning(selectedSourceName: String?, availableSourceNames: [String]) -> String? {
        isRecognized(selectedSourceName: selectedSourceName, availableSourceNames: availableSourceNames)
            ? nil
            : unverifiedWarning
    }
}

/// The controller profile the Scratch Playback Lab is currently treating as active.
/// Initially just the verified built-in profile or "Unverified" — there is no profile
/// editor and no MIDI learn yet. The unknown-controller warning is routed through this
/// state so there is one source of truth for "is the active mapping trustworthy".
enum ActiveControllerProfile: Equatable {
    /// A verified, built-in profile (currently only RANE ONE MKII).
    case builtIn(ControllerProfile)
    /// The active source does not match a verified profile; captured notation may be invalid.
    case unverified

    /// Name for the read-only "Controller profile: …" UI line.
    var displayName: String {
        switch self {
        case .builtIn(let profile): return profile.displayName
        case .unverified: return "Unverified"
        }
    }

    /// Whether the active profile is verified (current behaviour) versus unverified (warn).
    var isVerified: Bool {
        if case .builtIn = self { return true }
        return false
    }

    /// The tester warning for an unverified active profile, or nil when verified. Routing
    /// the warning through here keeps it consistent with the displayed profile.
    var warning: String? {
        isVerified ? nil : ControllerRecognition.unverifiedWarning
    }

    /// Resolves the active profile purely from the live MIDI selection: a recognized
    /// RANE-like selection is the built-in RANE profile, anything else is unverified.
    /// Pure and side-effect free — it touches no timeline, capture, or export state.
    static func resolve(selectedSourceName: String?, availableSourceNames: [String]) -> ActiveControllerProfile {
        ControllerRecognition.isRecognized(
            selectedSourceName: selectedSourceName,
            availableSourceNames: availableSourceNames
        ) ? .builtIn(.raneOneMKII) : .unverified
    }
}
#endif
