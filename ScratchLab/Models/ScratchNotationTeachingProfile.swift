//  ScratchNotationTeachingProfile.swift
//  ScratchLab — demo-only teaching-profile projection for the macOS
//  Baby Scratch practice guide.
//
//  Pure, deterministic position reshaper. The bundled Baby demo encodes
//  every stroke as a full-sample sweep (forward 0 → 1, backward 1 → 0),
//  so the raw trace renders as a uniform picket of full-height humps.
//  The SXRATCH reference visualisers instead show a baby scratch as a
//  run of SHALLOW repeated humps low in the sample, resolving into one
//  LARGER motion at the phrase tail. This helper projects the raw trace
//  into that teaching shape by scaling each stroke's position amplitude:
//  repeated hits collapse into a low band, and each phrase's resolving
//  stroke keeps full height.
//
//  **Scope:** this is a *demo teaching aid only*. It is called solely
//  from `MacBabyScratchPracticeGuideView`. It must never sit in the
//  captured / Review notation path — captured notation is the source of
//  truth and is rendered from real positions, not from this projection.
//
//  **Honesty note:** the raw `0 ↔ 1` sweeps are themselves an extraction
//  over-statement (a baby scratch traverses only a small slice of the
//  sample, not the whole record). The shallow repeats produced here are
//  arguably closer to the real motion, not further from it — but because
//  it is still an authored shape, it stays demo-only by construction.
//
//  Contract (locked by `ScratchNotationTeachingProfileTests`):
//   - Resolve stroke = the LAST forward stroke in each phrase (max
//     `endTime` among forward strokes in the phrase). It is scaled by
//     `resolveCeiling`.
//   - Every other in-phrase stroke is a repeat, scaled by `repeatCeiling`.
//   - Position scaling only: `newStart = start * amp`, `newEnd = end * amp`.
//   - `startTime`, `endTime`, `direction` are preserved EXACTLY — so the
//     attack-marker timing, phrase gate, and beat grid are untouched.
//   - A phrase with no forward stroke → all repeats (no resolve).
//   - A segment outside every phrase range → passed through unchanged.
//   - Same input → byte-identical output.

import Foundation

enum ScratchNotationTeachingProfile {

    /// Default low-band ceiling for repeated baby hits, as a fraction of
    /// the lane's full position range. ~0.30–0.35 reads as "small
    /// repeated motion" against the full-height resolve.
    static let defaultRepeatCeiling: Double = 0.32

    /// Default ceiling for the resolving stroke — full lane height.
    static let defaultResolveCeiling: Double = 1.0

    /// Membership epsilon — matches `ScratchNotationPhrasePolyline`'s
    /// in-range test so a stroke lands in the same phrase for both.
    private static let epsilon: Double = 1e-9

    static func project(
        trace: [ScratchNotationPositionTraceSegment],
        phraseRanges: [ScratchNotationPhraseRange],
        repeatCeiling: Double = ScratchNotationTeachingProfile.defaultRepeatCeiling,
        resolveCeiling: Double = ScratchNotationTeachingProfile.defaultResolveCeiling
    ) -> [ScratchNotationPositionTraceSegment] {
        guard !trace.isEmpty else { return [] }

        // Resolve stroke per phrase: the last forward stroke (max
        // endTime) whose extent sits inside the range. Stored as the
        // index into `trace` so identical-valued strokes can't collide.
        var resolveIndices = Set<Int>()
        for range in phraseRanges {
            var bestIndex: Int?
            var bestEndTime = -Double.infinity
            for (index, segment) in trace.enumerated() {
                guard segment.direction == .forward,
                      isInRange(segment, range) else { continue }
                if segment.endTime > bestEndTime {
                    bestEndTime = segment.endTime
                    bestIndex = index
                }
            }
            if let bestIndex { resolveIndices.insert(bestIndex) }
        }

        return trace.enumerated().map { index, segment in
            // Out-of-phrase strokes pass through untouched (the phrase
            // gate excludes them downstream anyway).
            guard phraseRanges.contains(where: { isInRange(segment, $0) }) else {
                return segment
            }
            let amplitude = resolveIndices.contains(index) ? resolveCeiling : repeatCeiling
            return ScratchNotationPositionTraceSegment(
                startTime: segment.startTime,
                endTime: segment.endTime,
                startPosition: segment.startPosition * amplitude,
                endPosition: segment.endPosition * amplitude,
                direction: segment.direction
            )
        }
    }

    private static func isInRange(
        _ segment: ScratchNotationPositionTraceSegment,
        _ range: ScratchNotationPhraseRange
    ) -> Bool {
        segment.startTime >= range.start - epsilon
            && segment.endTime <= range.end + epsilon
    }
}
