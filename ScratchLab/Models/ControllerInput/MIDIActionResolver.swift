// MIDIActionResolver.swift
// ScratchLab - Shared MIDI Semantic Action Resolver
//
// Single pure, stateless resolver that maps a parsed MIDI message to a semantic
// action, shared by both the macOS and iOS runtimes. This is the ONE place that
// answers "what action is this MIDI message?" — neither `MacCaptureEngine` nor
// `IOSMIDIControllerDispatcher` re-implements matching.
//
// Scope guardrails (deliberate):
// - Pure value logic only. No Core MIDI, no audio, no playback, no UI, no I/O.
// - Resolves against the user's learned mappings first, then the built-in
//   hardware registry bindings, reusing the existing `MIDIHardwareRegistry`
//   matching rules and `MIDIControlBinding.matches(_:)`.
// - Does NOT define a new semantic-action enum. It composes the existing
//   `MIDISemanticAction` (learned actions) with the registry's `MIDIControlRole`
//   (which is where `.transport` lives) and emits a small resolved-action result.

import Foundation

// MARK: - Mapping provenance

/// Where a resolved fader control's mapping came from.
///
/// ScratchLab can recognise a crossfader two ways: from the user's own learned
/// mapping, or from a `.certified` hardware-registry binding when the connected
/// device genuinely matches a verified profile. The two are not equivalent —
/// only the first represents an explicit user action — so evidence carries the
/// distinction all the way through the sidecar, review, and export rather than
/// presenting a registry default as though the user had mapped it.
enum FaderMappingSource: String, Codable, Equatable, Sendable, CaseIterable {
    /// The user's per-device `MIDIDeviceMapping`. Always takes priority.
    case learned
    /// A `.certified` registry binding for a device the registry matched.
    /// Evidence-only: this never drives audible playback.
    case certifiedRegistry
}

// MARK: - Control normalization

/// Normalization for controls recognised without a learned mapping.
///
/// A `MIDILearnedControl` carries the user's own min/max/inverted calibration.
/// A certified registry binding has none, so it uses the plain 7-bit range the
/// profile documents — never another action's calibration borrowed by accident.
/// Shared so both platforms and the tests use one definition.
enum MIDIControlNormalization {
    static func sevenBit(_ rawValue: Int) -> Double {
        Double(max(0, min(127, rawValue))) / 127.0
    }
}

// MARK: - Resolved action

/// The outcome of resolving a parsed MIDI message to a semantic action.
enum MIDIResolvedAction: Equatable {
    /// A transport Start/Stop press. The Rane ONE has a single toggle button per
    /// deck; consumers toggle play/stop in response.
    case transport

    /// A hot-cue press. `action` is the learned semantic hot-cue action when the
    /// message matched a user-learned mapping, or nil when it fell through to the
    /// built-in pad router. `sampleID` is the scratch sample to play (nil when the
    /// hot-cue has no assigned sample).
    case hotCue(action: MIDISemanticAction?, sampleID: String?)

    /// A crossfader Control Change (`value` is the raw 0–127 value). `source`
    /// records whether this came from the user's learned mapping or from a
    /// certified hardware-registry binding, so downstream evidence can name its
    /// provenance instead of implying the user mapped the control themselves.
    case crossfader(value: Int, source: FaderMappingSource)

    /// A per-deck channel (up) fader. `deck` is 0-based; `value` is raw 0–127.
    case upfader(deck: Int, value: Int)

    /// The message did not resolve to any known action.
    case unknown
}

// MARK: - Resolver

/// Pure resolver that answers "what action is this MIDI message?".
///
/// Resolution order:
/// 1. Transport — a press matching a registry `.transport` binding.
/// 2. Learned mapping — the user's per-device `MIDIDeviceMapping`, preferred.
/// 2b. Certified-registry crossfader — evidence-only fallback for recognised
///    hardware with no learned crossfader (see `matchesCertifiedCrossfader`).
/// 3. Built-in pad router — Rane ONE pad notes fall back to the confirmed
///    `ScratchBankPadEventRouter` sample table.
///
/// KNOWN PLATFORM DIVERGENCE (deliberate, not an oversight): only the iOS
/// dispatcher resolves crossfader through this path. macOS keeps its own
/// `CrossfaderCCMapping` persisted separately in `UserDefaults`
/// (`MacCaptureEngine`), which predates the shared learned-mapping model and is
/// not registry-aware. Unifying the two is its own slice; until then a certified
/// registry crossfader default applies on iOS only, and macOS still requires an
/// explicit crossfader learn.
enum MIDIActionResolver {

    /// Resolve a parsed message against learned mappings (preferred) and the
    /// hardware registry (fallback).
    static func resolve(
        message: ParsedMIDIMessage,
        mapping: MIDIDeviceMapping?,
        identity: MIDIDeviceIdentity? = nil,
        registry: MIDIHardwareRegistry = .shared
    ) -> MIDIResolvedAction {
        // 1. Transport (registry `.transport` binding, press only).
        if message.value > 0, matchesTransport(message, registry: registry) {
            return .transport
        }

        // 2. Learned mapping (preferred).
        if let mapping,
           let control = mapping.controls.first(where: { matches($0, message) }) {
            switch control.action {
            case .crossfader:
                return .crossfader(value: Int(message.value), source: .learned)
            case .leftUpfader:
                return .upfader(deck: 0, value: Int(message.value))
            case .rightUpfader:
                return .upfader(deck: 1, value: Int(message.value))
            case .hotCue1, .hotCue2, .hotCue3, .hotCue4,
                 .hotCue5, .hotCue6, .hotCue7, .hotCue8:
                if let sampleID = control.assignedSampleID, !sampleID.isEmpty {
                    return .hotCue(action: control.action, sampleID: sampleID)
                }
                // Empty assigned sample → fall through to the pad router, matching
                // the established iOS fallback behaviour.
            case .unassigned:
                break
            }
        }

        // 2b. Certified-registry crossfader fallback.
        //
        // Mirrors the transport fallback above: the registry already carries a
        // verified crossfader binding for recognised hardware, and without this
        // a connected device with no learned mapping produced `.unknown` and
        // recorded no fader evidence at all. Deliberately narrow — it requires
        // an identity that the registry actually matched at `.certified`
        // confidence, so an unknown controller is never sniffed for CC8.
        if let identity,
           matchesCertifiedCrossfader(message, identity: identity, registry: registry) {
            return .crossfader(value: Int(message.value), source: .certifiedRegistry)
        }

        // 3. Pad-router fallback (Rane ONE pad note → sample ID).
        if message.messageType == .noteOn, message.value > 0,
           let sampleID = ScratchBankPadEventRouter.sampleID(
               channel: Int(message.channel),
               noteNumber: Int(message.noteNumber),
               velocity: Int(message.value),
               isEnabled: true
           ) {
            return .hotCue(action: nil, sampleID: sampleID)
        }

        return .unknown
    }

    /// Convenience for the macOS hot-cue path, which works from a learned message
    /// type + channel/control/value rather than an already-parsed message.
    static func resolve(
        learnedType: LearnedMIDIMessageType,
        channel: Int,
        controlNumber: Int,
        value: Int,
        mapping: MIDIDeviceMapping?,
        registry: MIDIHardwareRegistry = .shared
    ) -> MIDIResolvedAction {
        let message = ParsedMIDIMessage(
            channel: UInt8(clamping: channel),
            messageType: learnedType == .note ? .noteOn : .controlChange,
            controlNumber: UInt8(clamping: controlNumber),
            noteNumber: UInt8(clamping: controlNumber),
            value: UInt8(clamping: value)
        )
        return resolve(message: message, mapping: mapping, registry: registry)
    }

    // MARK: - Helpers

    /// Whether a learned control matches a parsed message on (message type,
    /// channel, control number). Mirrors the shared `MIDIControlBinding.matches`
    /// semantics for the learned-mapping model.
    private static func matches(_ control: MIDILearnedControl, _ message: ParsedMIDIMessage) -> Bool {
        switch control.messageType {
        case .note:
            return message.messageType == .noteOn
                && control.channel == Int(message.channel)
                && control.controlNumber == Int(message.noteNumber)
        case .controlChange:
            return message.messageType == .controlChange
                && control.channel == Int(message.channel)
                && control.controlNumber == Int(message.controlNumber)
        }
    }

    /// Whether a message is the crossfader of a device the registry matched at
    /// `.certified` confidence.
    ///
    /// Three conditions must all hold, and each one exists to stop this from
    /// becoming a blind "any CC8 is a crossfader" sniff:
    /// 1. the registry produced a real match for this device identity;
    /// 2. that match is `.certified`, not `.verified`/`.unverified` — the
    ///    values are only trustworthy for hardware that has been confirmed;
    /// 3. a non-diagnostic `.crossfader` binding on that profile matches the
    ///    message, reusing the shared `MIDIControlBinding.matches(_:)` channel
    ///    and CC-number rules rather than a second comparison.
    private static func matchesCertifiedCrossfader(
        _ message: ParsedMIDIMessage,
        identity: MIDIDeviceIdentity,
        registry: MIDIHardwareRegistry
    ) -> Bool {
        guard let match = registry.bestMatch(for: identity), match.confidence == .certified else {
            return false
        }
        return match.profile.bindings.contains { binding in
            binding.role.kind == .crossfader
                && !binding.isDiagnosticOnly
                && binding.matches(message)
        }
    }

    /// Whether a message is a transport Start/Stop press against any registry
    /// `.transport` binding.
    private static func matchesTransport(_ message: ParsedMIDIMessage, registry: MIDIHardwareRegistry) -> Bool {
        for profile in registry.profiles {
            for binding in profile.bindings
            where binding.role.kind == .transport && binding.matches(message) {
                return true
            }
        }
        return false
    }
}
