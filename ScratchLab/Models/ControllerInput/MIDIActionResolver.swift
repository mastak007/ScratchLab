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

    /// A crossfader Control Change (`value` is the raw 0–127 value).
    case crossfader(value: Int)

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
/// 3. Built-in pad router — Rane ONE pad notes fall back to the confirmed
///    `ScratchBankPadEventRouter` sample table.
enum MIDIActionResolver {

    /// Resolve a parsed message against learned mappings (preferred) and the
    /// hardware registry (fallback).
    static func resolve(
        message: ParsedMIDIMessage,
        mapping: MIDIDeviceMapping?,
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
                return .crossfader(value: Int(message.value))
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
