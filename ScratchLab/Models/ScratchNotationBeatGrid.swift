//  ScratchNotationBeatGrid.swift
//  ScratchLab — beat / bar timing markers for notation surfaces.
//
//  Pure, deterministic emitter of vertical grid lines at every beat
//  in a visible time window, with bar lines flagged at every
//  `beatsPerBar`-th beat. Used by the Mac Baby Scratch practice
//  guide to paint a rhythmic scaffold behind the trace so the eye
//  can read separated repeated scratches as deliberate timing
//  rather than visual noise.
//
//  The helper carries no clock and no UI dependencies. It takes
//  only primitive inputs (visible-window times, BPM, anchor,
//  beats-per-bar) and returns ordered grid lines. This isolates
//  grid generation from phrase / polyline / trace data and lets
//  the renderer paint the grid during idle, replay, and silence
//  alike — even when the trace itself is gated off by the phrase
//  / play-state gate.

import Foundation

// MARK: - ScratchNotationBeatGridLine

/// One renderable grid line. `time` is in audio-time seconds; `kind`
/// distinguishes downbeats / bar lines from intermediate beat lines
/// so the renderer can stroke them with different intensities.
struct ScratchNotationBeatGridLine: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case beat
        case bar
    }
    let time: TimeInterval
    let kind: Kind
}

// MARK: - ScratchNotationBeatGrid

enum ScratchNotationBeatGrid {

    /// Returns the ordered grid lines whose time falls inside
    /// `[visibleStart, visibleEnd]`.
    ///
    /// - `anchorTime` is the audio time at which `beat 0 / bar 1`
    ///   sits. For the Baby demo this is the first audible attack
    ///   (`0.27 s`) so the grid lines up with the music rather than
    ///   with `t = 0`.
    /// - `bpm` is the demo's reference tempo. For Baby this is 79
    ///   (matching `BabyScratchReferenceAsset.babyScratch79BPM`).
    /// - `beatsPerBar` flags every `beatsPerBar`-th beat as a bar
    ///   line. Default 4 (common time).
    ///
    /// Returns an empty list for non-finite inputs, non-positive
    /// BPM, non-positive `beatsPerBar`, or windows with
    /// `visibleEnd < visibleStart`. The renderer can therefore call
    /// this without guarding.
    static func gridLines(
        visibleStart: TimeInterval,
        visibleEnd: TimeInterval,
        bpm: Double,
        anchorTime: TimeInterval,
        beatsPerBar: Int = 4
    ) -> [ScratchNotationBeatGridLine] {
        guard bpm.isFinite, bpm > 0,
              visibleStart.isFinite, visibleEnd.isFinite,
              anchorTime.isFinite,
              visibleEnd >= visibleStart,
              beatsPerBar >= 1
        else { return [] }
        let beatDuration = 60.0 / bpm
        guard beatDuration.isFinite, beatDuration > 0 else { return [] }
        let firstIndexRaw = ((visibleStart - anchorTime) / beatDuration).rounded(.up)
        let lastIndexRaw = ((visibleEnd - anchorTime) / beatDuration).rounded(.down)
        guard firstIndexRaw.isFinite, lastIndexRaw.isFinite else { return [] }
        // Sanity cap: a typical 4 s viewport at 79 BPM produces ~6
        // beats. Even at 600 BPM that's ~40. 10_000 lines guards
        // against pathological inputs (e.g., enormous visible
        // windows from a misuse).
        guard (lastIndexRaw - firstIndexRaw) < 10_000 else { return [] }
        let firstIndex = Int(firstIndexRaw)
        let lastIndex = Int(lastIndexRaw)
        guard lastIndex >= firstIndex else { return [] }
        var lines: [ScratchNotationBeatGridLine] = []
        lines.reserveCapacity(lastIndex - firstIndex + 1)
        for index in firstIndex...lastIndex {
            let time = anchorTime + Double(index) * beatDuration
            let isBar = (index % beatsPerBar) == 0
            lines.append(
                ScratchNotationBeatGridLine(
                    time: time,
                    kind: isBar ? .bar : .beat
                )
            )
        }
        return lines
    }
}
