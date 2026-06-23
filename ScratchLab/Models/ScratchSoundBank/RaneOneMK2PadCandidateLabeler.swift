// RaneOneMK2PadCandidateLabeler.swift
// ScratchLab - Rane ONE MK2 Pad Candidate Labeler
//
// Pure diagnostic helper that labels MIDI CC events matching Rane ONE MK2 pad
// candidate ranges. Mirrors the djay Pro mapping constants in
// ScratchBankPadMappingCatalog; adds shifted small-pad ranges (CC 104–107) not
// yet represented in the Slice 1 model.
//
// No MIDI routing. No sample playback. No scoring. "Candidate" wording only
// until live hardware verification confirms messages.

import Foundation

/// Stateless labeler for Rane ONE MK2 pad-candidate MIDI CC messages.
enum RaneOneMK2PadCandidateLabeler {

    // MARK: - Pad CC ranges (mirror djay Pro mapping archive, 2026-06-24)

    /// Deck → (first large-pad CC, shifted/clear-pad CC, first small-pad CC, first shifted-small-pad CC).
    private static let deckRanges: [(deck: Int, channel: Int, largeFirstCC: Int, shiftedFirstCC: Int, smallFirstCC: Int, shiftedSmallFirstCC: Int)] = [
        (deck: 1, channel: 4, largeFirstCC: 20, shiftedFirstCC: 28, smallFirstCC: 100, shiftedSmallFirstCC: 104),
        (deck: 2, channel: 5, largeFirstCC: 20, shiftedFirstCC: 28, smallFirstCC: 100, shiftedSmallFirstCC: 104),
    ]

    /// Produces a diagnostic label for a Rane ONE MK2 pad-candidate CC message,
    /// or nil when the (channel, CC) pair does not match any known pad range.
    ///
    /// - Parameters:
    ///   - channel: MIDI channel (0-based, as received in the byte stream).
    ///   - cc: Control Change number.
    ///   - value: CC data value (0–127). 127 / non-zero = press; 0 = release.
    /// - Returns: A candidate label like `"Rane ONE MK2 pad candidate: deck 1 pad 1 CC20 ch4 value 127"`,
    ///   or nil if the message is not a Rane pad candidate.
    static func label(channel: Int, cc: Int, value: Int) -> String? {
        for range in deckRanges {
            guard channel == range.channel else { continue }

            // Large pads: CC 20–27 (pad 1…8)
            if cc >= range.largeFirstCC && cc <= range.largeFirstCC + 7 {
                let pad = (cc - range.largeFirstCC) + 1
                return "Rane ONE MK2 pad candidate: deck \(range.deck) pad \(pad) CC\(cc) ch\(channel) value \(value)"
            }

            // Shifted/clear pads: CC 28–35 (pad 1…8)
            if cc >= range.shiftedFirstCC && cc <= range.shiftedFirstCC + 7 {
                let pad = (cc - range.shiftedFirstCC) + 1
                return "Rane ONE MK2 shifted pad candidate: deck \(range.deck) pad \(pad) CC\(cc) ch\(channel) value \(value)"
            }

            // Small 4-pad strip: CC 100–103 (small pad 1…4)
            if cc >= range.smallFirstCC && cc <= range.smallFirstCC + 3 {
                let spad = (cc - range.smallFirstCC) + 1
                return "Rane ONE MK2 small pad candidate: deck \(range.deck) small pad \(spad) CC\(cc) ch\(channel) value \(value)"
            }

            // Shifted small 4-pad strip: CC 104–107 (shifted small pad 1…4)
            if cc >= range.shiftedSmallFirstCC && cc <= range.shiftedSmallFirstCC + 3 {
                let spad = (cc - range.shiftedSmallFirstCC) + 1
                return "Rane ONE MK2 shifted small pad candidate: deck \(range.deck) small pad \(spad) CC\(cc) ch\(channel) value \(value)"
            }
        }
        return nil
    }
}
