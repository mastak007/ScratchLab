import CoreGraphics
import Foundation

// Derived platter-motion geometry for the Scratch Motion Lane.
//
// The notation renderer used to draw each stroke as an isolated block. This
// turns the SAME stroke data into a *platter-position curve* — a
// continuous line of where the platter sits over time. Forward motion rises,
// backward motion falls, gaps and holds stay flat; a stroke's duration is the
// curve's horizontal length and its travel is the vertical rise or fall.
//
// `MotionPath` is pure, derived, and never persisted — it adds no field to any
// notation JSON schema. It is computed from the existing `LaneContent` /
// `LaneStroke` data, so it touches no capture, export, session, or training
// code. `ScratchMotionRenderer` consumes it; this file only shapes it.

// MARK: - Segment

/// Whether a motion segment is a platter stroke (a ramp) or a hold (flat).
enum MotionSegmentKind: Equatable, Sendable {
    /// A platter stroke — `forward` ramps the curve up, `backward` ramps it down.
    case stroke(ScratchNotationDirection)
    /// A pause between strokes — the curve holds flat.
    case hold
}

/// One span of the platter-position curve. Positions are normalized 0...1
/// (0 = the curve's lowest point, 1 = its highest) so the path always fits the
/// lane whatever the pattern.
struct MotionSegment: Equatable, Sendable {
    let kind: MotionSegmentKind
    let startTime: TimeInterval
    let endTime: TimeInterval
    /// Normalized platter position at `startTime` (0...1).
    let startPosition: CGFloat
    /// Normalized platter position at `endTime` (0...1).
    let endPosition: CGFloat
    /// Speed of the originating stroke — `medium` for holds. Drives the
    /// renderer's easing sharpness and line weight, not the geometry.
    let speed: ScratchNotationSpeedClassification
    /// True for a derived copy-window ghost (Demo mode).
    let isGhost: Bool

    var duration: TimeInterval { max(0, endTime - startTime) }

    /// Vertical distance the platter travelled across this segment.
    var travel: CGFloat { abs(endPosition - startPosition) }

    var isHold: Bool {
        if case .hold = kind { return true }
        return false
    }

    /// `true` for a forward (rising) stroke, `false` for backward, `nil` for a hold.
    var isRising: Bool? {
        switch kind {
        case .stroke(let direction): return direction == .forward
        case .hold:                  return nil
        }
    }
}

// MARK: - Path

/// The integrated platter-position curve for one stretch of lane content — a
/// continuous chain of `MotionSegment`s covering `timeRange` with no gaps.
struct MotionPath: Equatable, Sendable {
    let segments: [MotionSegment]
    /// The timeline span the path covers.
    let timeRange: ClosedRange<TimeInterval>

    var isEmpty: Bool { segments.isEmpty }

    /// Linearly-interpolated platter position (0...1) at `time`, clamped to the
    /// path's ends. This is the geometric ground truth; the renderer adds
    /// easing on top purely for display.
    func position(at time: TimeInterval) -> CGFloat {
        guard let first = segments.first, let last = segments.last else { return 0.5 }
        if time <= first.startTime { return first.startPosition }
        if time >= last.endTime { return last.endPosition }
        for segment in segments where time >= segment.startTime && time <= segment.endTime {
            let span = segment.endTime - segment.startTime
            guard span > 1e-9 else { return segment.startPosition }
            let fraction = CGFloat((time - segment.startTime) / span)
            return segment.startPosition
                + (segment.endPosition - segment.startPosition) * fraction
        }
        return last.endPosition
    }

    /// The path with every time shifted by `offset` — used to tile a looping
    /// pattern seamlessly across the lane.
    func shifted(by offset: TimeInterval) -> MotionPath {
        guard offset != 0 else { return self }
        return MotionPath(
            segments: segments.map {
                MotionSegment(kind: $0.kind,
                              startTime: $0.startTime + offset,
                              endTime: $0.endTime + offset,
                              startPosition: $0.startPosition,
                              endPosition: $0.endPosition,
                              speed: $0.speed, isGhost: $0.isGhost)
            },
            timeRange: (timeRange.lowerBound + offset)...(timeRange.upperBound + offset))
    }
}

// MARK: - Derivation

/// Turns lane content into its platter-position curve.
enum ScratchStrokeGeometry {

    /// Per-stroke amplitude — how far the platter moves in one stroke.
    /// A slow drag reads as a small excursion; a medium push is mid-amplitude;
    /// a fast stab hits the rail. The speed bucket is the only signal driving
    /// this first amplitude pass — duration, direction sign, fader state and
    /// confidence stay out of it. Rest / starting position is always raw 0,
    /// so a balanced forward/backward pair returns to 0 and the loop seam
    /// closes regardless of how the rail end is scaled.
    private static func rawAmplitude(for stroke: LaneStroke) -> CGFloat {
        // Travel-driven amplitude takes precedence when present (PR 2 supplies it from analysis);
        // otherwise the existing speed-bucket amplitude is used unchanged.
        if let travel = stroke.normalizedTravel {
            return min(1, max(0, CGFloat(travel)))
        }
        switch stroke.speed {
        case .slow:   return 0.55
        case .medium: return 0.78
        case .fast:   return 1.0
        }
    }

    /// Derives the platter-position curve for `content` as ONE continuous
    /// physical position trace, not a series of isolated out/return bumps.
    /// The platter starts at its resting position (raw 0) and integrates
    /// forward: a forward stroke raises the position over its full
    /// `[startTime, endTime]` window, a backward stroke lowers it, and the
    /// next stroke begins exactly where the previous one ended. Gaps and
    /// holds keep the position flat, so the platter never springs back to
    /// centre between strokes. A balanced forward/backward pair returns to
    /// its starting position; an unbalanced or incomplete phrase ends
    /// wherever its last stroke left it (no fabricated closing move). A
    /// stroke with measured endpoints (`LaneStroke.measuredStartPosition` /
    /// `.measuredEndPosition`) is drawn as that exact measured span instead
    /// of an integrated amplitude — that is how the MY PERFORMANCE row
    /// preserves captured motion truthfully.
    /// A raw (un-normalized) platter-position span before the 0…1 vertical
    /// normalization. Raw 0 is the platter's starting/rest position; forward
    /// motion raises it and backward motion lowers it, cumulatively.
    private struct RawMotionSpan {
        let kind: MotionSegmentKind
        let start: TimeInterval
        let end: TimeInterval
        let startPos: CGFloat
        let endPos: CGFloat
        let speed: ScratchNotationSpeedClassification
        let isGhost: Bool
    }

    /// Builds the ordered raw spans for `content` (one directional segment
    /// per stroke + holds), shared by every normalization variant so a stroke
    /// is shaped identically no matter which vertical frame the caller
    /// chooses. Stroke times are preserved exactly — each stroke is a single
    /// segment covering `[stroke.startTime, stroke.endTime]` and nothing else.
    private static func rawSpans(for content: LaneContent) -> [RawMotionSpan] {
        let duration = max(content.duration, 0.001)
        let strokes = content.strokes.sorted { $0.startTime < $1.startTime }
        let epsilon = 1e-6

        guard !strokes.isEmpty else {
            // No strokes — one flat hold across the whole timeline.
            return [RawMotionSpan(kind: .hold, start: 0, end: duration,
                                  startPos: 0, endPos: 0,
                                  speed: .medium, isGhost: false)]
        }

        var spans: [RawMotionSpan] = []
        func appendHold(start: TimeInterval, end: TimeInterval, position: CGFloat,
                        isGhost: Bool) {
            guard end > start + epsilon else { return }
            spans.append(RawMotionSpan(kind: .hold, start: start, end: end,
                                       startPos: position, endPos: position,
                                       speed: .medium, isGhost: isGhost))
        }

        // The platter starts at rest (raw 0) for authored content, or at the
        // first measured position for captured content, and integrates from
        // there. Holds freeze `current`; strokes move it.
        var current: CGFloat = strokes[0].measuredStartPosition.map { CGFloat($0) } ?? 0

        appendHold(start: 0, end: strokes[0].startTime, position: current,
                   isGhost: strokes[0].isGhost)

        for (index, stroke) in strokes.enumerated() {
            // One directional segment over the stroke's full window. Measured
            // endpoints are used verbatim (preserving the captured trace);
            // authored strokes integrate a signed amplitude from the current
            // position.
            let startPos: CGFloat
            let endPos: CGFloat
            if let measuredStart = stroke.measuredStartPosition,
               let measuredEnd = stroke.measuredEndPosition {
                startPos = CGFloat(measuredStart)
                endPos = CGFloat(measuredEnd)
            } else {
                let sign: CGFloat = (stroke.direction == .forward) ? 1 : -1
                let delta = sign * rawAmplitude(for: stroke)
                startPos = current
                endPos = current + delta
            }
            spans.append(RawMotionSpan(kind: .stroke(stroke.direction),
                                       start: stroke.startTime, end: stroke.endTime,
                                       startPos: startPos, endPos: endPos,
                                       speed: stroke.speed, isGhost: stroke.isGhost))
            current = endPos
            if index + 1 < strokes.count {
                appendHold(start: stroke.endTime,
                           end: strokes[index + 1].startTime,
                           position: current,
                           isGhost: stroke.isGhost)
            }
        }

        if let last = strokes.last {
            appendHold(start: last.endTime, end: duration, position: current,
                       isGhost: last.isGhost)
        }

        return spans
    }

    /// Normalizes raw spans into 0…1 over an explicit raw `[low, high]` frame
    /// and packages them as a `MotionPath`. A balanced phrase returns to its
    /// starting position, so a looping pattern is naturally seamless when
    /// tiled.
    private static func normalizedPath(spans: [RawMotionSpan],
                                       low: CGFloat, high: CGFloat,
                                       duration: TimeInterval) -> MotionPath {
        let epsilon = 1e-6
        let range = high - low
        func normalized(_ value: CGFloat) -> CGFloat {
            range > epsilon ? (value - low) / range : 0.5
        }
        let segments = spans.map {
            MotionSegment(kind: $0.kind,
                          startTime: $0.start, endTime: $0.end,
                          startPosition: normalized($0.startPos),
                          endPosition: normalized($0.endPos),
                          speed: $0.speed, isGhost: $0.isGhost)
        }
        return MotionPath(segments: segments, timeRange: 0...max(duration, 0.001))
    }

    static func motionPath(for content: LaneContent) -> MotionPath {
        let spans = rawSpans(for: content)
        let positions = spans.flatMap { [$0.startPos, $0.endPos] }
        let low = positions.min() ?? -1
        let high = positions.max() ?? 1
        return normalizedPath(spans: spans, low: low, high: high,
                              duration: max(content.duration, 0.001))
    }

    /// The same curve, but normalized against an explicit raw `[lowerBound,
    /// upperBound]` frame instead of the content's own min/max. The stacked
    /// TARGET / MY PERFORMANCE comparison passes the TARGET's `rawRange(for:)`
    /// here so a sparse performed take keeps the target's vertical coordinate
    /// frame — the neutral position and a given travel land on the same Y in
    /// both rows rather than rescaling to the performed take's own extremes.
    static func motionPath(for content: LaneContent,
                           normalizingTo frame: ClosedRange<CGFloat>) -> MotionPath {
        let spans = rawSpans(for: content)
        return normalizedPath(spans: spans,
                              low: frame.lowerBound, high: frame.upperBound,
                              duration: max(content.duration, 0.001))
    }

    /// The raw vertical frame `[min, max]` that `content`'s own
    /// `motionPath(for:)` normalization uses — the value the performed row
    /// reuses as its frame so both rows share one vertical coordinate frame.
    static func rawRange(for content: LaneContent) -> ClosedRange<CGFloat> {
        let positions = rawSpans(for: content).flatMap { [$0.startPos, $0.endPos] }
        let low = positions.min() ?? -1
        let high = positions.max() ?? 1
        return low...high
    }

    /// One forward→backward reversal boundary on a continuous motion path —
    /// the time a stroke changes direction, and the path's own position at
    /// that instant (the apex the following backward stroke returns from).
    struct TurnaroundAnchor: Equatable, Sendable {
        let time: TimeInterval
        let position: CGFloat
    }

    /// Explicit turnaround anchors at forward→backward direction-change
    /// boundaries, derived from canonical stroke direction alone (never
    /// inferred from drawn geometry). The single reversal-detection
    /// implementation every consumer (macOS phrase chart, the shared
    /// `ScratchNotationPanel`) reuses instead of re-deriving its own —
    /// extracted verbatim from `ScratchPhraseChartView.drawTurnaroundMarkers`.
    static func turnaroundAnchors(strokes: [LaneStroke], path: MotionPath) -> [TurnaroundAnchor] {
        let sorted = strokes.sorted { $0.startTime < $1.startTime }
        guard sorted.count >= 2 else { return [] }
        var anchors: [TurnaroundAnchor] = []
        for i in 0..<(sorted.count - 1) {
            let a = sorted[i]
            let b = sorted[i + 1]
            guard a.direction == .forward, b.direction == .backward else { continue }
            anchors.append(TurnaroundAnchor(time: a.endTime, position: path.position(at: a.endTime)))
        }
        return anchors
    }
}
