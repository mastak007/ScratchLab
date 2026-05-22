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

    /// Derives the platter-position curve for `content`. Strokes are taken in
    /// time order; a forward push drives the platter to the high rail, a
    /// backward pull to the low rail, and the gaps between them (plus any
    /// lead-in / lead-out) become flat holds at the current rail. The position
    /// is set to a rail rather than accumulated, so an uneven pattern can never
    /// drift off-centre — every push and pull stays a full, centred swing. The
    /// raw curve is then normalized to fill 0...1.
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

        // 1. Ordered spans: a lead-in hold, each stroke, the gap holds between
        //    consecutive strokes, and a trailing hold.
        struct Span {
            let kind: MotionSegmentKind
            let start: TimeInterval
            let end: TimeInterval
            let speed: ScratchNotationSpeedClassification
            let isGhost: Bool
        }
        var spans: [Span] = []

        if strokes[0].startTime > epsilon {
            spans.append(Span(kind: .hold, start: 0, end: strokes[0].startTime,
                               speed: .medium, isGhost: strokes[0].isGhost))
        }
        for (index, stroke) in strokes.enumerated() {
            spans.append(Span(kind: .stroke(stroke.direction),
                               start: stroke.startTime, end: stroke.endTime,
                               speed: stroke.speed, isGhost: stroke.isGhost))
            if index + 1 < strokes.count {
                let next = strokes[index + 1]
                if next.startTime > stroke.endTime + epsilon {
                    spans.append(Span(kind: .hold, start: stroke.endTime, end: next.startTime,
                                       speed: .medium, isGhost: stroke.isGhost))
                }
            }
        }
        if let last = strokes.last, last.endTime < duration - epsilon {
            spans.append(Span(kind: .hold, start: last.endTime, end: duration,
                               speed: .medium, isGhost: last.isGhost))
        }

        // 2. Raw boundary positions. A scratch oscillates the platter between
        //    two rails: a forward push drives it to the high rail (+1), a
        //    backward pull to the low rail (-1); a hold keeps it where it is.
        //    The position is SET to a rail, never accumulated, so an uneven
        //    pattern cannot drift — every push and pull is a full, centred
        //    swing, and the visible window always uses the full range.
        var raw: [CGFloat] = [0]
        var position: CGFloat = 0
        for span in spans {
            switch span.kind {
            case .stroke(.forward):  position = 1
            case .stroke(.backward): position = -1
            case .hold:              break
            }
            raw.append(position)
        }

        // 3. Normalize the raw curve into 0...1 — bounded, lane-fitting.
        let low = raw.min() ?? 0
        let high = raw.max() ?? 0
        let range = high - low
        func normalized(_ value: CGFloat) -> CGFloat {
            range > epsilon ? (value - low) / range : 0.5
        }

        let segments = spans.enumerated().map { index, span in
            MotionSegment(kind: span.kind,
                          startTime: span.start, endTime: span.end,
                          startPosition: normalized(raw[index]),
                          endPosition: normalized(raw[index + 1]),
                          speed: span.speed, isGhost: span.isGhost)
        }
        return MotionPath(segments: segments, timeRange: 0...duration)
    }
}
