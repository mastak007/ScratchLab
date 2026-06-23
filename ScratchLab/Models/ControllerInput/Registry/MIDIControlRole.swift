import Foundation

// Pro-DJ MIDI registry layer (future-facing): the semantic role a physical control plays.
//
// Scope guardrails (deliberate):
// - Pure value type only. No Core MIDI, no AVFoundation, no device I/O, no audio,
//   no playback, no UI. Nothing here drives the Scratch Playback Lab.
// - This layer is INDEPENDENT of the existing playback-facing `ControllerProfile`
//   (v1). v1 stays the current playback profile; this is the generic registry /
//   verification model that future pro-DJ hardware support is built on.
// - A role is "what this control means to a DJ" (platter, crossfader, pad, …),
//   decoupled from "how it reports over MIDI" (that is `MIDIControlSignalType`).

/// The semantic meaning of a physical control, independent of its MIDI encoding.
/// `deck` is a 0-based deck index for per-deck controls (0 = left), nil for
/// deck-agnostic controls (e.g. a single crossfader). Modelled as a struct (kind +
/// deck + label) so it stays trivially Codable and extensible as new gear is added.
struct MIDIControlRole: Codable, Equatable, Hashable {

    /// The catalogue of roles ScratchLab understands. New kinds are additive; decoding
    /// is intentionally NOT failed on an unknown kind by callers — `.unknown` is the
    /// explicit catch-all for controls a profile could not classify.
    enum Kind: String, Codable, CaseIterable {
        /// Relative platter / jog rotation (the scratch driver). RANE ONE = CC6 ring.
        case platterMovement
        /// Absolute platter angle within a turn, where the hardware reports it.
        case platterAbsolute
        /// The crossfader.
        case crossfader
        /// A per-channel line fader.
        case channelFader
        /// A momentary button (cue, sync, …).
        case button
        /// A performance pad.
        case pad
        /// Transport (play / pause / cue) — modelled distinctly from a generic button.
        case transport
        /// A needle / strip-search position control.
        case needleStrip
        /// Tempo / pitch fader.
        case tempo
        /// A deck-select control.
        case deckSelect
        /// Unclassified — a control a profile could not map to a known role.
        case unknown
    }

    /// What the control means.
    let kind: Kind
    /// 0-based deck index for per-deck controls; nil when deck-agnostic.
    let deck: Int?
    /// Optional human label (e.g. "Performance Pad 3"); nil to use the default.
    let label: String?

    init(kind: Kind, deck: Int? = nil, label: String? = nil) {
        self.kind = kind
        self.deck = deck
        self.label = label
    }

    /// A short human name for this role, using `label` when supplied, else a default
    /// derived from the kind and (where present) the deck number.
    var displayName: String {
        if let label { return label }
        let deckSuffix = deck.map { " (Deck \($0 + 1))" } ?? ""
        let base: String
        switch kind {
        case .platterMovement: base = "Platter"
        case .platterAbsolute: base = "Platter Position"
        case .crossfader: base = "Crossfader"
        case .channelFader: base = "Channel Fader"
        case .button: base = "Button"
        case .pad: base = "Pad"
        case .transport: base = "Transport"
        case .needleStrip: base = "Needle Strip"
        case .tempo: base = "Tempo / Pitch"
        case .deckSelect: base = "Deck Select"
        case .unknown: base = "Unknown Control"
        }
        return base + deckSuffix
    }

    /// The default verification instruction shown when guiding a user to exercise this
    /// control. Pure presentation text; no behaviour depends on it.
    var defaultInstruction: String {
        let deckName = deck.map { "Deck \($0 + 1) " } ?? ""
        switch kind {
        case .platterMovement, .platterAbsolute:
            return "Spin the \(deckName)platter forward and back."
        case .crossfader:
            return "Move the crossfader fully open and closed."
        case .channelFader:
            return "Move the \(deckName)channel fader up and down."
        case .tempo:
            return "Move the \(deckName)tempo / pitch fader."
        case .needleStrip:
            return "Slide along the \(deckName)needle strip."
        case .button, .transport, .pad, .deckSelect:
            return "Press \(displayName)."
        case .unknown:
            return "Move \(displayName)."
        }
    }
}
