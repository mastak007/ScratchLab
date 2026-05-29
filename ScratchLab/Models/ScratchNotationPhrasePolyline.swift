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

/// One continuous polyline for a single active phrase. The polyline
/// composes stroke slopes AND intra-phrase holds into one ordered
/// vertex list, so a single stroked `CGPath` paints both.
struct ScratchNotationPhrasePolyline: Equatable, Sendable {
    let phraseRange: ScratchNotationPhraseRange
    let vertices: [ScratchNotationPolylineVertex]

    /// Builds one polyline per active phrase range. Pure mapper —
    /// same input → byte-identical output. No clock, no I/O, no UI.
    /// Strokes outside any phrase range are ignored (the phrase gate
    /// is the authority on what counts as an active phrase).
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
            var vertices: [ScratchNotationPolylineVertex] = []
            vertices.reserveCapacity(inRange.count * 2 + 1)
            // First vertex: the first stroke's (startTime,
            // startPosition). All subsequent strokes contribute only
            // their end vertex (their start vertex is the same as
            // the previous stroke's end vertex by the carry-forward
            // rule of `ScratchNotationPositionTrace`, so emitting it
            // would duplicate).
            let first = inRange[0]
            vertices.append(
                ScratchNotationPolylineVertex(
                    time: first.startTime,
                    position: first.startPosition
                )
            )
            for index in 0..<inRange.count {
                let current = inRange[index]
                vertices.append(
                    ScratchNotationPolylineVertex(
                        time: current.endTime,
                        position: current.endPosition
                    )
                )
                // Intra-phrase hold gap: insert a flat horizontal
                // vertex at the next stroke's start time, keeping
                // the previous stroke's end Y. The line from
                // `current.end` to this flat vertex paints as the
                // hold; the line from the flat vertex to the next
                // stroke's end paints as the next stroke's slope.
                guard index + 1 < inRange.count else { continue }
                let next = inRange[index + 1]
                let gap = next.startTime - current.endTime
                if gap > 0 && gap <= safeThreshold {
                    vertices.append(
                        ScratchNotationPolylineVertex(
                            time: next.startTime,
                            position: current.endPosition
                        )
                    )
                }
                // gap == 0 (back-to-back): nothing inserted; the
                // next stroke's end vertex follows directly.
                // gap > safeThreshold should not happen inside a
                // single phrase range (by construction of the
                // phrase gate), but is defensively skipped.
            }
            guard vertices.count >= 2 else { continue }
            result.append(
                ScratchNotationPhrasePolyline(
                    phraseRange: range,
                    vertices: vertices
                )
            )
        }
        return result
    }
}

// MARK: - MacBabyScratchPracticeGuideRate

/// Calibration constants for the Mac Baby Scratch practice guide's
/// duration-proxy trace. Relocated from the now-removed
/// `ScratchNotationHoldConnector.swift` because the connector helper
/// became dead code when the renderer moved to one polyline per
/// phrase. The calibrated rate stays the same — only its home file
/// moved.
///
/// **Rate semantics:** cursor units moved per second of stroke.
/// `1.0` would mean a 1-second stroke walks the full lane (0 → 1).
/// Baby Scratch strokes in the bundled JSON average ~0.4 s — at rate
/// 1.0 each stroke moves the cursor by 40 % of the lane and saturates
/// within one or two repeats. Rate 0.25 gives a visible walk across
/// the eleven-stroke phrase while still letting deliberately long
/// strokes approach the lane boundary.
///
/// **Why a constant, not data:** the bundled
/// `baby_scratch_strokes.json` encodes only direction + duration
/// (`startProgress` / `endProgress` are always 0 or 1). Real sample
/// position is not in the source data today, so the trace is a
/// duration-proxy. Per-scratch calibration is the honest interim
/// fix; the long-term answer is a JSON that ships real platter
/// position, at which point this constant becomes irrelevant.
enum MacBabyScratchPracticeGuideRate {
    /// Cursor units per second of stroke, calibrated for the bundled
    /// Baby Scratch demo.
    static let calibratedBabyRate: Double = 0.25
}
