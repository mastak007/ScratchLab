//  ScratchNotationAttackMarkers.swift
//  ScratchLab — audible-attack onset markers for notation surfaces.
//
//  Pure, deterministic mapping from a list of bundled stroke segments
//  (`ScratchLabBabyScratchStrokeSegment`) to discrete attack markers —
//  one per audible scratch onset. This is an additive layer on top of
//  the existing raw-progress motion trace, NOT a replacement for it.
//
//  Why a separate layer: the motion trace renders platter position
//  over time (forward 0 → 1, backward 1 → 0), so equal-sounding hits
//  read as differently-shaped slopes and the silent platter resets
//  between consecutive same-direction strokes leave visual gaps. The
//  ear, however, tracks discrete attacks at each stroke onset. A row
//  of uniform onset markers makes the repeated hits legible as a
//  rhythm row without altering the honest motion trace.
//
//  Composition rules:
//   - One marker per non-`.neutral` stroke onset (`.neutral` segments
//     are explicit holds, not scratches).
//   - `time` is the stroke's `startTime` (audio-time seconds).
//   - A marker is emitted only when its onset falls inside one of the
//     supplied phrase ranges — markers share the trace's phrase gate
//     so idle / inter-phrase silence stays empty.
//   - `phraseIndex` is the index of the containing range in the
//     supplied `phraseRanges` array.
//   - Output is sorted by time. Same input → byte-identical output.

import Foundation

// MARK: - ScratchNotationAttackMarker

/// One audible-attack marker: a discrete onset event the ear tracks,
/// rendered on a separate low marker row (never on the motion trace
/// line). `time` is audio-time seconds; `phraseIndex` is the index of
/// the phrase range that contains the onset; `direction` is carried
/// through for callers that may wish to tint markers (the Mac guide
/// keeps them uniform).
struct ScratchNotationAttackMarker: Equatable, Sendable {
    let time: TimeInterval
    let phraseIndex: Int
    let direction: ScratchMotionDirection
}

// MARK: - ScratchNotationAttackMarkers

enum ScratchNotationAttackMarkers {

    /// Builds attack markers from a list of stroke segments. Skips
    /// `.neutral` segments (explicit holds) and any stroke whose onset
    /// does not fall inside one of the supplied phrase ranges. Markers
    /// are returned sorted by time. Pure mapper — no clock, no I/O, no
    /// UI; same input → byte-identical output.
    static func build(
        from segments: [ScratchLabBabyScratchStrokeSegment],
        phraseRanges: [ScratchNotationPhraseRange]
    ) -> [ScratchNotationAttackMarker] {
        guard !segments.isEmpty, !phraseRanges.isEmpty else { return [] }
        let epsilon = 1e-9
        var markers: [ScratchNotationAttackMarker] = []
        markers.reserveCapacity(segments.count)
        for segment in segments where segment.direction != .neutral {
            // The onset is what the ear locks to, so membership is
            // decided by the start time alone (the trace, by contrast,
            // requires both endpoints in range). Match the first phrase
            // range that contains the onset.
            guard let phraseIndex = phraseRanges.firstIndex(where: { range in
                segment.startTime >= range.start - epsilon
                    && segment.startTime <= range.end + epsilon
            }) else { continue }
            markers.append(
                ScratchNotationAttackMarker(
                    time: segment.startTime,
                    phraseIndex: phraseIndex,
                    direction: segment.direction
                )
            )
        }
        return markers.sorted { $0.time < $1.time }
    }
}
