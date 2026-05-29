//  ScratchNotationPhrasePolyline.swift
//  ScratchLab — phrase polyline geometry for notation surfaces.
//
//  Pure, deterministic helper that converts a derived position trace
//  + phrase ranges into one continuous polyline per active phrase.
//  This replaces the prior tokenized-stroke renderer model (stroke
//  segments + hold connectors + endpoint dots) with the SXRATCH-
//  style continuous sample-position polyline observed in the
//  reference videos.
//
//  Composition rules (locked by `ScratchNotationPhrasePolylineTests`):
//   - One polyline per active phrase range.
//   - Vertices are ordered in time.
//   - First vertex = first stroke's `(startTime, startPosition)`.
//   - Each subsequent stroke contributes its `(endTime, endPosition)`.
//   - Intra-phrase holds (gaps `> 0`, `≤ silenceThreshold`) inject a
//     flat horizontal vertex `(nextStroke.startTime, current.
//     endPosition)` between strokes, so the path stays geometrically
//     continuous through holds.
//   - Inter-phrase silences (gaps `> silenceThreshold`) split into
//     separate polylines — never bridged.
//   - No loop tiling: vertices stay inside the audio's time range
//     because the audio is single-shot, not a continuous loop.
//
//  The renderer's job is then trivial: per visible polyline, build
//  one `CGPath` by `move`ing to the first vertex and `addLine`-ing
//  to each subsequent vertex, then stroke once. No endpoint dots,
//  no separate connector tokens, no `[-loopDuration, 0,
//  loopDuration]` tiling.

import Foundation

// MARK: - ScratchNotationPolylineVertex

/// One vertex on a phrase polyline. `time` is in audio-time seconds,
/// `position` is the cursor value in `[0, 1]` (Y axis on the rendered
/// lane).
struct ScratchNotationPolylineVertex: Equatable, Sendable {
    let time: TimeInterval
    let position: Double
}

// MARK: - ScratchNotationPhrasePolyline

/// One renderable polyline group for a single active phrase. A
/// phrase may contain multiple **sub-paths** when consecutive
/// strokes inside it do not carry forward (their endpoints do not
/// share a position) — those non-carry-forward transitions are
/// **silent platter resets** in the source motion, and the renderer
/// must not draw a visible line through them. Each sub-path is a
/// contiguous vertex run; sub-paths within a phrase share no
/// geometry. Holds within a carry-forward run remain flat
/// horizontal vertices in the same sub-path.
struct ScratchNotationPhrasePolyline: Equatable, Sendable {
    let phraseRange: ScratchNotationPhraseRange
    let subPaths: [[ScratchNotationPolylineVertex]]

    /// Builds one polyline per active phrase range. Pure mapper —
    /// same input → byte-identical output. No clock, no I/O, no UI.
    /// Strokes outside any phrase range are ignored (the phrase gate
    /// is the authority on what counts as an active phrase).
    ///
    /// **Sub-path break rule:** within a phrase, the current sub-path
    /// is closed and a new one is opened whenever
    /// `next.startPosition != current.endPosition`. The interval
    /// between `current.endTime` and `next.startTime` represents a
    /// silent platter reset and produces **no vertex at all** —
    /// neither a vertical jump nor a diagonal slope nor a flat
    /// hold. The visual result is a gap in the rendered path. This
    /// replaces the earlier "hold-then-jump" rule that emitted a
    /// flat hold then a vertical line at every silent reset
    /// (forensic on `sl notation review 3.mp4` / the four 2:26–2:27
    /// PM screenshots).
    static func build(
        from trace: [ScratchNotationPositionTraceSegment],
        phraseRanges: [ScratchNotationPhraseRange],
        silenceThreshold: TimeInterval = ScratchNotationPhraseGate.defaultSilenceThreshold
    ) -> [ScratchNotationPhrasePolyline] {
        guard !trace.isEmpty, !phraseRanges.isEmpty else { return [] }
        let safeThreshold = silenceThreshold.isFinite ? max(0, silenceThreshold) : 0
        let sortedTrace = trace.sorted { $0.startTime < $1.startTime }
        var result: [ScratchNotationPhrasePolyline] = []
        result.reserveCapacity(phraseRanges.count)
        for range in phraseRanges {
            // A stroke "belongs to" this phrase when its start/end
            // both sit inside the range (with a small epsilon for
            // floating-point boundary tolerance). Phrase ranges are
            // computed from the same stroke timings by
            // `ScratchNotationPhraseGate.activePhraseRanges`, so
            // alignment is exact in normal use.
            let epsilon = 1e-9
            let inRange = sortedTrace.filter { segment in
                segment.startTime >= range.start - epsilon
                    && segment.endTime <= range.end + epsilon
            }
            guard !inRange.isEmpty else { continue }

            var subPaths: [[ScratchNotationPolylineVertex]] = []
            var current: [ScratchNotationPolylineVertex] = []
            current.reserveCapacity(inRange.count * 2 + 1)
            // Start the first sub-path at the first stroke's start
            // vertex. Every subsequent stroke contributes its end
            // vertex; carry-forward transitions add an optional flat
            // hold vertex; non-carry-forward transitions close the
            // current sub-path and open a new one at the next
            // stroke's start vertex.
            let first = inRange[0]
            current.append(
                ScratchNotationPolylineVertex(
                    time: first.startTime,
                    position: first.startPosition
                )
            )
            for index in 0..<inRange.count {
                let stroke = inRange[index]
                current.append(
                    ScratchNotationPolylineVertex(
                        time: stroke.endTime,
                        position: stroke.endPosition
                    )
                )
                guard index + 1 < inRange.count else { continue }
                let next = inRange[index + 1]
                let gap = next.startTime - stroke.endTime
                let carriesForward =
                    abs(next.startPosition - stroke.endPosition) < epsilon
                if carriesForward {
                    // Same sub-path. If there is a positive
                    // intra-phrase hold gap, paint it as a flat
                    // horizontal segment by adding one vertex at the
                    // next stroke's startTime, same Y as the
                    // previous stroke's endPosition.
                    if gap > 0, gap <= safeThreshold {
                        current.append(
                            ScratchNotationPolylineVertex(
                                time: next.startTime,
                                position: stroke.endPosition
                            )
                        )
                    }
                    // gap == 0 (back-to-back, shared endpoint):
                    // nothing inserted; the next stroke's end vertex
                    // follows directly. gap > safeThreshold should
                    // not happen inside a single phrase range (by
                    // construction of the phrase gate); defensively
                    // ignored.
                } else {
                    // Non-carry-forward: silent platter reset. Close
                    // the current sub-path and start a new one at
                    // the next stroke's start vertex. No vertex is
                    // emitted in the gap interval, so nothing is
                    // drawn between them.
                    if current.count >= 2 { subPaths.append(current) }
                    current = [
                        ScratchNotationPolylineVertex(
                            time: next.startTime,
                            position: next.startPosition
                        )
                    ]
                }
            }
            if current.count >= 2 { subPaths.append(current) }
            guard !subPaths.isEmpty else { continue }
            result.append(
                ScratchNotationPhrasePolyline(
                    phraseRange: range,
                    subPaths: subPaths
                )
            )
        }
        return result
    }
}

