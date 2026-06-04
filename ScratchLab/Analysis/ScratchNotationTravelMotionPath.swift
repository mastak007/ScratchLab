// ScratchNotationTravelMotionPath — Stage A: an ADDITIVE, UI-free builder that turns a
// `ScratchNotationLaneDisplayModel` into a renderer-compatible `MotionPath` whose stroke
// excursion is driven by `normalizedTravel` (platter travel), not the speed bucket.
//
// This is a PROOF adapter, not the production renderer path. It deliberately:
// - does NOT modify ScratchStrokeGeometry / LaneStroke / ScratchMotionRenderer,
// - does NOT touch any view, and
// - reuses the existing `MotionPath` / `MotionSegment` value types so a future renderer could
//   consume its output unchanged.
//
// Geometry mirrors the existing speed-bucket motion path exactly (centre-rest, out/return halves
// meeting at the stroke mid-time, lead-in / gap / trailing holds at centre, raw positions
// normalized to 0...1 across the phrase so the loop seam closes at centre) — the ONLY difference
// is the per-stroke rail magnitude: here it is `stroke.normalizedTravel` (already 0...1, clamped
// by ScratchNotationLaneDisplayAdapter against the caller-supplied fullScaleTravelPercent), so a
// short-travel stroke reads short and a full-travel stroke approaches the rail. When the display
// model's scale was unusable, every `normalizedTravel` is 0, so all strokes render flat at centre.
//
// Pure, deterministic, Foundation + CoreGraphics only. No SwiftUI, no audio/MIDI, no I/O.

import CoreGraphics
import Foundation

enum ScratchNotationTravelMotionPath {

    /// Build a `MotionPath` from a travel-display model over `[0, duration]`.
    ///
    /// `duration` is caller-supplied (the lane/timeline span); it is floored at a small positive
    /// value to avoid divide-by-zero. Stroke times are taken verbatim from the model — the caller
    /// is responsible for supplying a `duration` that spans them (typically the timeline duration).
    static func motionPath(
        for model: ScratchNotationLaneDisplayModel,
        duration: TimeInterval
    ) -> MotionPath {
        let totalDuration = max(duration, 0.001)
        let epsilon = 1e-6
        let strokes = model.strokes.sorted { $0.startTime < $1.startTime }

        guard !strokes.isEmpty else {
            return MotionPath(
                segments: [MotionSegment(kind: .hold, startTime: 0, endTime: totalDuration,
                                         startPosition: 0.5, endPosition: 0.5,
                                         speed: .medium, isGhost: false)],
                timeRange: 0...totalDuration)
        }

        // Raw un-normalized spans. 0 = centre (rest), ±1 = rails.
        struct Span {
            let kind: MotionSegmentKind
            let start: TimeInterval
            let end: TimeInterval
            let startPos: CGFloat
            let endPos: CGFloat
        }
        var spans: [Span] = []

        func appendHold(start: TimeInterval, end: TimeInterval) {
            guard end > start + epsilon else { return }
            spans.append(Span(kind: .hold, start: start, end: end, startPos: 0, endPos: 0))
        }

        appendHold(start: 0, end: strokes[0].startTime)

        for (index, stroke) in strokes.enumerated() {
            // Sign from direction; magnitude from travel (NOT speed). reverse maps to backward.
            let laneDirection: ScratchNotationDirection = (stroke.direction == .forward) ? .forward : .backward
            let sign: CGFloat = (stroke.direction == .forward) ? 1 : -1
            let rail: CGFloat = sign * CGFloat(stroke.normalizedTravel)

            if stroke.endTime - stroke.startTime <= epsilon {
                spans.append(Span(kind: .stroke(laneDirection),
                                  start: stroke.startTime, end: stroke.endTime,
                                  startPos: 0, endPos: rail))
            } else {
                let mid = (stroke.startTime + stroke.endTime) / 2
                spans.append(Span(kind: .stroke(laneDirection),
                                  start: stroke.startTime, end: mid,
                                  startPos: 0, endPos: rail))
                spans.append(Span(kind: .stroke(laneDirection),
                                  start: mid, end: stroke.endTime,
                                  startPos: rail, endPos: 0))
            }

            if index + 1 < strokes.count {
                appendHold(start: stroke.endTime, end: strokes[index + 1].startTime)
            }
        }

        if let last = strokes.last {
            appendHold(start: last.endTime, end: totalDuration)
        }

        // Normalize raw positions into 0...1 across the whole phrase (centre maps to a constant,
        // both ends sit at centre so a looped pattern is seamless).
        let allRaw = spans.flatMap { [$0.startPos, $0.endPos] }
        let low = allRaw.min() ?? -1
        let high = allRaw.max() ?? 1
        let range = high - low
        func normalized(_ value: CGFloat) -> CGFloat {
            range > epsilon ? (value - low) / range : 0.5
        }

        // `speed` is a fixed renderer-hint placeholder (.medium) — it drives only line weight /
        // easing in the renderer, never geometry, and is NOT derived from the data. `isGhost` is
        // false: a travel preview is not a copy-window ghost.
        let segments = spans.map {
            MotionSegment(kind: $0.kind,
                          startTime: $0.start, endTime: $0.end,
                          startPosition: normalized($0.startPos),
                          endPosition: normalized($0.endPos),
                          speed: .medium, isGhost: false)
        }
        return MotionPath(segments: segments, timeRange: 0...totalDuration)
    }
}
