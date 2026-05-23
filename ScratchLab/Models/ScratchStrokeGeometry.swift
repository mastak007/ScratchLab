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

    /// Derives the platter-position curve for `content`. Each stroke is a
    /// brief deflection from the resting centre to its rail and back: a
    /// forward push rises to the high rail then returns, a backward pull dips
    /// to the low rail then returns, both within the stroke's own
    /// `[startTime, endTime]` window. The lead-in, the gaps between strokes
    /// and the trailing tail stay flat at the centre — the platter's resting
    /// position — so every scratched stroke shows as a distinct bump aligned
    /// in time to its audio. There is no cumulative integration, so an
    /// unbalanced pattern cannot drift; and consecutive same-direction
    /// strokes each show as their own bump rather than collapsing into one
    /// move followed by a long flat run. The raw curve is then normalized
    /// into 0...1.
    static func motionPath(for content: LaneContent) -> MotionPath {
        let duration = max(content.duration, 0.001)
        let strokes = content.strokes.sorted { $0.startTime < $1.startTime }
        let epsilon = 1e-6

        guard !strokes.isEmpty else {
            // No strokes — one flat hold across the whole timeline.
            return MotionPath(
                segments: [MotionSegment(kind: .hold, startTime: 0, endTime: duration,
                                         startPosition: 0.5, endPosition: 0.5,
                                         speed: .medium, isGhost: false)],
                timeRange: 0...duration)
        }

        // 1. Ordered sub-spans. Each stroke becomes two: an "out" sub from
        //    centre to its rail and a "return" sub back to centre, meeting at
        //    the stroke's mid-time. The lead-in, gap-holds and trailing tail
        //    rest flat at the centre. Stroke times are preserved exactly —
        //    the out + return halves cover [stroke.startTime, stroke.endTime]
        //    and nothing else.
        struct Span {
            let kind: MotionSegmentKind
            let start: TimeInterval
            let end: TimeInterval
            /// Un-normalized cross-axis position. 0 = centre (rest), ±1 = rails.
            let startPos: CGFloat
            let endPos: CGFloat
            let speed: ScratchNotationSpeedClassification
            let isGhost: Bool
        }
        var spans: [Span] = []

        func appendHold(start: TimeInterval, end: TimeInterval, isGhost: Bool) {
            guard end > start + epsilon else { return }
            spans.append(Span(kind: .hold, start: start, end: end,
                              startPos: 0, endPos: 0,
                              speed: .medium, isGhost: isGhost))
        }

        appendHold(start: 0, end: strokes[0].startTime, isGhost: strokes[0].isGhost)

        for (index, stroke) in strokes.enumerated() {
            let rail: CGFloat = (stroke.direction == .forward) ? 1 : -1
            let strokeDuration = stroke.endTime - stroke.startTime
            if strokeDuration <= epsilon {
                // Degenerate zero-duration stroke — render as one
                // instantaneous mark to the rail without dividing by zero.
                spans.append(Span(kind: .stroke(stroke.direction),
                                  start: stroke.startTime, end: stroke.endTime,
                                  startPos: 0, endPos: rail,
                                  speed: stroke.speed, isGhost: stroke.isGhost))
            } else {
                let mid = (stroke.startTime + stroke.endTime) / 2
                // Out half: centre → rail. The platter leaves rest, deflects.
                spans.append(Span(kind: .stroke(stroke.direction),
                                  start: stroke.startTime, end: mid,
                                  startPos: 0, endPos: rail,
                                  speed: stroke.speed, isGhost: stroke.isGhost))
                // Return half: rail → centre. The platter springs back to rest.
                spans.append(Span(kind: .stroke(stroke.direction),
                                  start: mid, end: stroke.endTime,
                                  startPos: rail, endPos: 0,
                                  speed: stroke.speed, isGhost: stroke.isGhost))
            }
            if index + 1 < strokes.count {
                appendHold(start: stroke.endTime,
                           end: strokes[index + 1].startTime,
                           isGhost: stroke.isGhost)
            }
        }

        if let last = strokes.last {
            appendHold(start: last.endTime, end: duration, isGhost: last.isGhost)
        }

        // 2. Normalize raw positions into 0...1. Because every stroke leaves
        //    and returns to the centre, the path is naturally seamless when
        //    tiled for a looping pattern — both ends sit at the centre — and
        //    `content.loops` needs no extra closure step.
        let allRaw = spans.flatMap { [$0.startPos, $0.endPos] }
        let low = allRaw.min() ?? -1
        let high = allRaw.max() ?? 1
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
        return MotionPath(segments: segments, timeRange: 0...duration)
    }
}
