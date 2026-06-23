// ScratchBankPadEventRouter.swift
// ScratchLab - Scratch Bank Pad Event Router
//
// Pure, gated MIDI pad-to-sample router. Maps Rane ONE MK2 deck 1 large-pad
// CC events (and optional deck 2 mirror) to scratch bank sample IDs.
// No audio dependency. No MIDI listener. No scoring.
//
// Safety gate: enabled flag must be true for any sample ID to resolve.
// Release (value 0) always returns nil. Unmapped CC/channel returns nil.

import Foundation

/// Pure stateless router that resolves a MIDI CC event to a scratch bank sample ID.
/// Candidate-only — verification remains required on all mappings.
enum ScratchBankPadEventRouter {

    // MARK: - Pad-to-sample table (deck 1 large pads, pads 1–4 only)

    /// (channel, CC) → sample ID for the first 4 scratch bank pads.
    /// Deck 1: ch4 CC20–23.  Deck 2 mirror: ch5 CC20–23.
    /// Pads 5–8 (CC24–27) are intentionally absent from this slice.
    private static let padSampleTable: [PadKey: String] = [
        // Deck 1 large pads 1–4
        PadKey(channel: 4, cc: 20): "ahhh",
        PadKey(channel: 4, cc: 21): "fresh",
        PadKey(channel: 4, cc: 22): "ah_yeah",
        PadKey(channel: 4, cc: 23): "check_it_out",
        // Deck 2 mirror (same sample IDs, different channel)
        PadKey(channel: 5, cc: 20): "ahhh",
        PadKey(channel: 5, cc: 21): "fresh",
        PadKey(channel: 5, cc: 22): "ah_yeah",
        PadKey(channel: 5, cc: 23): "check_it_out",
    ]

    // MARK: - API

    /// Resolves a MIDI CC event to a scratch bank sample ID.
    ///
    /// - Parameters:
    ///   - channel: MIDI channel (0-based, as received in the byte stream).
    ///   - cc: Control Change number.
    ///   - value: CC data value (0–127). Returns nil for value 0 (release).
    ///   - isEnabled: Safety gate — must be true for any sample to resolve.
    /// - Returns: A sample ID like `"ahhh"`, or nil if the event is not a mapped
    ///   pad press, the gate is disabled, or the value is 0.
    static func sampleID(channel: Int, cc: Int, value: Int, isEnabled: Bool) -> String? {
        guard isEnabled else { return nil }
        guard value > 0 else { return nil }
        return padSampleTable[PadKey(channel: channel, cc: cc)]
    }
}

// MARK: - Pad Key (Hashable lookup)

extension ScratchBankPadEventRouter {
    fileprivate struct PadKey: Hashable {
        let channel: Int
        let cc: Int
    }
}
