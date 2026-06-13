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

    /// How raw signed cross-axis positions (0 = centre/rest, ±1 = rails) become 0...1 lane
    /// positions. `.perPhrase` is the production-shaped default; the two `absolute*` modes are
    /// DEBUG/proof modes that keep `fullScaleTravelPercent` visually meaningful (the factor no
    /// longer cancels), differing only in how direction is shown.
    enum Scaling {
        /// Existing behaviour: fit the phrase's own min…max excursion to 0...1. Because every
        /// stroke's `normalizedTravel` scales by the same `fullScaleTravelPercent` factor, that
        /// factor cancels in the fit — so the display scale is visually inert except where the
        /// 0...1 clamp in the display adapter bites. This is the default and is unchanged.
        case perPhrase
        /// DEBUG diagnostic: map each signed excursion directly with `0.5 + 0.5 * value` (clamped)
        /// — centre → 0.5, forward rail (+1) → 1.0, reverse rail (−1) → 0.0. The scale is visible,
        /// but reverse dips BELOW the mid-line, which is NOT how scratch notation reads (reverse is
        /// a return/reversal stroke above the line, not "below the staff"). Kept only as a raw
        /// signed read; the DEBUG view uses `.absoluteAboveBaseline` for notation-truthful output.
        case absoluteSigned
        /// DEBUG notation mode: fold the sign so EVERY stroke rises ABOVE a single baseline.
        /// Baseline (rest / centre / a hold) → 0 (lane floor); a stroke's apex → its
        /// `normalizedTravel` (0...1) regardless of direction, so forward and reverse both read as
        /// upward excursions whose height is the travel and never dip below the baseline. Direction
        /// is still carried truthfully by the segment's `MotionSegmentKind` (the renderer colours
        /// forward vs reverse), not by a below-line dip. `fullScaleTravelPercent` stays meaningful:
        /// a smaller scale makes strokes taller (more rail hits), a larger scale shorter, and a
        /// short travel stays short.
        case absoluteAboveBaseline
    }

    /// Build a `MotionPath` from a travel-display model over `[0, duration]`.
    ///
    /// `duration` is caller-supplied (the lane/timeline span); it is floored at a small positive
    /// value to avoid divide-by-zero. Stroke times are taken verbatim from the model — the caller
    /// is responsible for supplying a `duration` that spans them (typically the timeline duration).
    ///
    /// `scaling` defaults to `.perPhrase` (the existing behaviour); the `.absolute*` modes are
    /// DEBUG proof modes that make `fullScaleTravelPercent` visibly meaningful. Only the cross-axis
    /// position mapping differs between modes — stroke times, direction kinds, holds and the
    /// loop seam are identical.
    static func motionPath(
        for model: ScratchNotationLaneDisplayModel,
        duration: TimeInterval,
        scaling: Scaling = .perPhrase
    ) -> MotionPath {
        let totalDuration = max(duration, 0.001)
        let epsilon = 1e-6
        let strokes = model.strokes.sorted { $0.startTime < $1.startTime }

        // The rest position a hold / centre maps to: the lane mid-line for the fitted and signed
        // modes, the lane floor for the above-baseline notation mode (everything rises from it).
        let baseline: CGFloat
        switch scaling {
        case .perPhrase, .absoluteSigned: baseline = 0.5
        case .absoluteAboveBaseline:      baseline = 0
        }

        guard !strokes.isEmpty else {
            return MotionPath(
                segments: [MotionSegment(kind: .hold, startTime: 0, endTime: totalDuration,
                                         startPosition: baseline, endPosition: baseline,
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

        // Map raw positions into 0...1.
        //   • .perPhrase            — fit the phrase's own min…max (centre maps to a constant,
        //                             both ends sit at centre so a looped pattern is seamless).
        //   • .absoluteSigned       — map the signed excursion directly (centre 0.5, ± by
        //                             direction) so the display scale is preserved; reverse dips
        //                             below the mid-line (raw signed read, not notation).
        //   • .absoluteAboveBaseline — fold the sign (|value|): baseline 0, every stroke rises to
        //                             its travel height, nothing below the baseline; the loop seam
        //                             closes at the baseline because holds/centre map to 0.
        let allRaw = spans.flatMap { [$0.startPos, $0.endPos] }
        let low = allRaw.min() ?? -1
        let high = allRaw.max() ?? 1
        let range = high - low
        func normalized(_ value: CGFloat) -> CGFloat {
            switch scaling {
            case .perPhrase:
                return range > epsilon ? (value - low) / range : 0.5
            case .absoluteSigned:
                return min(1, max(0, 0.5 + 0.5 * value))
            case .absoluteAboveBaseline:
                return min(1, max(0, abs(value)))
            }
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
