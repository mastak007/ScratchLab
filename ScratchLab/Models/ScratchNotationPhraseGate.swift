//  ScratchNotationPhraseGate.swift
//  ScratchLab — phrase-activity gate for notation surfaces.
//
//  Pure, deterministic helper that turns a list of stroke segments into
//  a small set of "active phrase" ranges, plus a point-in-range lookup.
//  Used by the macOS Baby Scratch practice guide to suppress trace
//  rendering during inter-phrase silences (and idle / post-end states),
//  so the centered viewport does not leak upcoming-phrase strokes into
//  the canvas while the audio is currently silent.
//
//  The bundled `baby_scratch_strokes.json` does not contain explicit
//  silence markers — phrase boundaries are implicit in the gap between
//  consecutive strokes' `endTime` and the next `startTime`. This helper
//  derives them from the gap directly: any gap above `silenceThreshold`
//  (default 1.5 s) is treated as inter-phrase silence. For the bundled
//  data the inter-phrase gaps are ≥ 5 s and the intra-phrase gaps are
//  ≤ 0.5 s, so 1.5 s sits robustly between the two without being
//  fragile to small drift if the JSON is regenerated.

import Foundation

// MARK: - ScratchNotationPhraseRange

/// One active-phrase range. `start` and `end` are both audio-time
/// values in seconds, taken directly from the first stroke's
/// `startTime` and the last stroke's `endTime` inside the phrase.
struct ScratchNotationPhraseRange: Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
}

// MARK: - ScratchNotationPhraseGate

/// Pure mapper from a list of stroke segments to phrase ranges + a
/// point-in-range lookup. Same input → byte-identical output. No
/// clock, no I/O, no UI.
enum ScratchNotationPhraseGate {

    /// Default inter-phrase silence threshold in seconds. Anything
    /// longer is treated as a phrase boundary. The bundled Baby Scratch
    /// data has intra-phrase gaps ≤ 0.5 s and inter-phrase gaps ≥ 5 s,
    /// so 1.5 s sits between the two. Callers can override the
    /// threshold for techniques with different rhythms.
    static let defaultSilenceThreshold: TimeInterval = 1.5

    /// Builds the active-phrase ranges from a list of stroke segments.
    /// Skips `.neutral` segments (explicit holds — they are not real
    /// scratches and must not extend or bridge phrases). Sorts by
    /// start time defensively so callers do not have to.
    static func activePhraseRanges(
        from segments: [ScratchLabBabyScratchStrokeSegment],
        silenceThreshold: TimeInterval = ScratchNotationPhraseGate.defaultSilenceThreshold
    ) -> [ScratchNotationPhraseRange] {
        let safeThreshold = silenceThreshold.isFinite ? max(0, silenceThreshold) : 0
        let active = segments
            .filter { $0.direction != .neutral && $0.endTime >= $0.startTime }
            .sorted { $0.startTime < $1.startTime }
        guard let first = active.first else { return [] }
        var ranges: [ScratchNotationPhraseRange] = []
        var currentStart = first.startTime
        var currentEnd = first.endTime
        for segment in active.dropFirst() {
            let gap = segment.startTime - currentEnd
            if gap > safeThreshold {
                ranges.append(
                    ScratchNotationPhraseRange(start: currentStart, end: currentEnd)
                )
                currentStart = segment.startTime
                currentEnd = segment.endTime
            } else {
                currentEnd = max(currentEnd, segment.endTime)
            }
        }
        ranges.append(
            ScratchNotationPhraseRange(start: currentStart, end: currentEnd)
        )
        return ranges
    }

    /// True when `time` lies inside any range in `ranges`. Both ends
    /// are inclusive so the boundary frame at phrase start / end paints
    /// with the rest of the phrase rather than flickering for one
    /// frame.
    static func isInActivePhrase(
        _ time: TimeInterval,
        ranges: [ScratchNotationPhraseRange]
    ) -> Bool {
        guard time.isFinite else { return false }
        for range in ranges where time >= range.start && time <= range.end {
            return true
        }
        return false
    }
}
