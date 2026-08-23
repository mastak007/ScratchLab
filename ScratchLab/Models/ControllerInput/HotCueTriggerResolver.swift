// HotCueTriggerResolver.swift
// ScratchLab - Shared HotCue Trigger Decision Model
//
// Pure, stateless decision layer that turns a resolved MIDI action into a
// hot-cue trigger decision. Consolidates the hot-cue detection, sample-presence,
// and transport-gating rules previously duplicated across iOS and macOS.
// No playback, no audio, no MIDI, no UI — a decision abstraction only.

import Foundation

/// The outcome of deciding whether a hot-cue should actually fire.
struct HotCueTriggerDecision {
    let shouldTrigger: Bool
    let sampleID: String?
}

enum HotCueTriggerResolver {

    /// Decide whether `action` should trigger a hot-cue.
    ///
    /// - Parameter transportState: when non-nil, the trigger is gated on
    ///   `isPlaying` (iOS, where PLAY arms hot-cues). When nil, transport gating
    ///   is disabled (macOS, whose platter-driven hot-cue path has no transport
    ///   toggle and must keep firing regardless).
    static func resolve(
        action: MIDIResolvedAction,
        transportState: TransportState? = nil
    ) -> HotCueTriggerDecision {
        // 1. Must be a hot-cue with a usable sample.
        guard case .hotCue(_, let sampleID) = action,
              let sampleID, !sampleID.isEmpty else {
            return HotCueTriggerDecision(shouldTrigger: false, sampleID: nil)
        }
        // 2. Transport must be playing when gating is enabled.
        if let transportState, !transportState.isPlaying {
            return HotCueTriggerDecision(shouldTrigger: false, sampleID: nil)
        }
        return HotCueTriggerDecision(shouldTrigger: true, sampleID: sampleID)
    }
}
