// ScratchBankPadEventRouter.swift
// ScratchLab - Scratch Bank Pad Event Router
//
// Pure, gated MIDI pad-to-sample router. Maps Rane ONE MK2 large-pad events to
// scratch bank sample IDs. Two routing paths:
//   CC path  — unverified legacy candidate mapping (ch4/ch5, CC20–23).
//   Note path — confirmed Rane ONE MK2 hardware capture (ch6=channel5, notes 20–23).
// No audio dependency. No MIDI listener. No scoring.
//
// Safety gate: enabled flag must be true for any sample ID to resolve.
// Release (value/velocity 0) always returns nil. Unmapped CC/note/channel returns nil.

import Foundation

/// Pure stateless router that resolves a MIDI CC or Note On event to a scratch bank sample ID.
/// CC mapping is candidate-only — verification remains required.
/// Note mapping is confirmed from Rane ONE MK2 hardware capture via MIDI Monitor (decimal format).
enum ScratchBankPadEventRouter {

    // MARK: - CC Pad-to-sample table (unverified legacy candidates)

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

    // MARK: - Note Pad-to-sample table (confirmed Rane ONE MK2 hardware)
    //
    // Captured with MIDI Monitor (Note format: Decimal number):
    //   Pad 1: Note On ch6 note20 velocity127 / Note Off ch6 note20 velocity0
    //   Pad 2: Note On ch6 note21 velocity127 / Note Off ch6 note21 velocity0
    //   Pad 3: Note On ch6 note22 velocity127 / Note Off ch6 note22 velocity0
    //   Pad 4: Note On ch6 note23 velocity127 / Note Off ch6 note23 velocity0
    // "ch6" in MIDI Monitor (1-indexed) = channel 5 (0-indexed raw byte).
    private static let notePadSampleTable: [NoteKey: String] = [
        NoteKey(channel: 5, noteNumber: 20): "ahhh",
        NoteKey(channel: 5, noteNumber: 21): "fresh",
        NoteKey(channel: 5, noteNumber: 22): "ah_yeah",
        NoteKey(channel: 5, noteNumber: 23): "check_it_out",
    ]

    // MARK: - CC API

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

    // MARK: - Note On API

    /// Resolves a MIDI Note On event to a scratch bank sample ID.
    ///
    /// Confirmed Rane ONE MK2: Scratch Bank pads send Note On on ch6 (MIDI Monitor 1-indexed)
    /// = channel 5 (0-indexed), notes 20–23, velocity 127 on press / 0 on release.
    ///
    /// - Parameters:
    ///   - channel: MIDI channel (0-based). Channel 5 = ch6 in MIDI Monitor.
    ///   - noteNumber: MIDI note number. Confirmed pad notes are 20–23.
    ///   - velocity: Note velocity (0–127). Returns nil for velocity 0 (Note Off / zero-velocity).
    ///   - isEnabled: Safety gate — must be true for any sample to resolve.
    /// - Returns: A sample ID, or nil if not a mapped pad press, gate is off, or velocity is 0.
    static func sampleID(channel: Int, noteNumber: Int, velocity: Int, isEnabled: Bool) -> String? {
        guard isEnabled else { return nil }
        guard velocity > 0 else { return nil }
        return notePadSampleTable[NoteKey(channel: channel, noteNumber: noteNumber)]
    }
}

// MARK: - Lookup Keys (Hashable)

extension ScratchBankPadEventRouter {
    fileprivate struct PadKey: Hashable {
        let channel: Int
        let cc: Int
    }

    fileprivate struct NoteKey: Hashable {
        let channel: Int
        let noteNumber: Int
    }
}
