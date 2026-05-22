import SwiftUI

// Pure Canvas renderer for the Scratch Motion Lane.
//
// Draws a `MotionPath` — the integrated platter-position curve from
// `ScratchStrokeGeometry` — as a continuous, eased motion line through a
// `LaneViewport`. Forward motion rises, backward falls, holds run flat. The
// curve replaces the old block-arrow / rounded-bar stroke marks entirely.
//
// The renderer is presentation-agnostic: it reads only its arguments and draws
// only into the supplied `GraphicsContext` — no state, no clock, no SwiftUI
// view — so the one routine serves Practice (a scrolling lane) and, later,
// Review / Coach / Capture replay (a static lane). `Style` carries the
// per-layer look, so a target path, a copy-window ghost, and a future captured
// user path are all drawn by this same call.

enum ScratchMotionRenderer {

    // MARK: - Style

    /// The look of one motion-path layer.
    struct Style: Equatable {
        var color: Color
        /// Base line width; each segment scales it by its stroke speed.
        var lineWidth: CGFloat = 4
        /// Dashed rather than solid — for reference / ghost layers.
        var dashed: Bool = false
        /// Soft glow behind the line.
        var glow: Bool = true
        /// Faint area fill between the curve and the lane's low edge.
        var fillsUnderCurve: Bool = true
        /// Layer opacity — dimmed for ghost / reference layers.
        var opacity: Double = 1

        /// The solid reference path the learner follows.
        static let target = Style(color: Color(red: 0.34, green: 0.80, blue: 1.00))
        /// A copy-window ghost target (Demo mode) — dashed and dim.
        static let ghost = Style(color: .white, lineWidth: 3, dashed: true,
                                 glow: false, fillsUnderCurve: false, opacity: 0.45)
        /// The captured user path (future overlay) — bright and solid.
        static let user = Style(color: Color(red: 0.30, green: 0.88, blue: 0.55),
                                lineWidth: 3.5)
    }

    // MARK: - Tuning

    /// Inset of the motion band from the lane's cross-axis edges, as a fraction
    /// of the cross length — keeps the curve clear of the lane edges.
    private static let crossInsetFraction: CGFloat = 0.12
    /// Sample points per stroke ramp — enough for a smooth eased curve.
    private static let samplesPerStroke = 14

    // MARK: - Draw

    /// Draws `path` into `context`, mapped through `viewport`, in `style`.
    /// Pure — reads only its arguments, writes only to the context.
    static func draw(_ path: MotionPath,
                     in context: GraphicsContext,
                     viewport: LaneViewport,
                     style: Style) {
        let visible = path.segments.filter {
            viewport.isVisible(from: $0.startTime, to: $0.endTime)
        }
        guard !visible.isEmpty else { return }

        // Sample every visible segment once; reuse for fill, glow and line.
        let sampled = visible.map { ($0, points(for: $0, viewport: viewport)) }
        let polyline = sampled.flatMap { $0.1 }
        guard polyline.count > 1 else { return }

        var layer = context
        layer.opacity = style.opacity

        // 1. Faint area fill — gives the curve a lane "body", not a bare wire.
        if style.fillsUnderCurve {
            drawFill(polyline: polyline, viewport: viewport, color: style.color, in: layer)
        }

        // 2. Soft glow behind the line.
        if style.glow {
            var glow = Path()
            glow.addLines(polyline)
            layer.stroke(glow, with: .color(style.color.opacity(0.25)),
                         style: StrokeStyle(lineWidth: style.lineWidth * 2.4,
                                            lineCap: .round, lineJoin: .round))
        }

        // 3. The motion line itself — drawn per segment so each carries a line
        //    weight scaled to its stroke speed; shared endpoints and round caps
        //    keep the curve visually continuous.
        for (segment, pts) in sampled where pts.count > 1 {
            var line = Path()
            line.addLines(pts)
            let width = style.lineWidth * speedWeight(segment.speed)
            let stroke = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round,
                                     dash: style.dashed ? [width * 1.6, width * 1.5] : [])
            layer.stroke(line, with: .color(style.color), style: stroke)
        }
    }

    // MARK: - Geometry

    /// Eased screen-space sample points for one segment. Holds are a flat
    /// two-point line; strokes are a smooth-stepped ramp.
    private static func points(for segment: MotionSegment,
                               viewport: LaneViewport) -> [CGPoint] {
        if segment.isHold {
            return [
                screenPoint(time: segment.startTime, position: segment.startPosition,
                            viewport: viewport),
                screenPoint(time: segment.endTime, position: segment.endPosition,
                            viewport: viewport),
            ]
        }
        var pts: [CGPoint] = []
        for index in 0...samplesPerStroke {
            let fraction = CGFloat(index) / CGFloat(samplesPerStroke)
            let time = segment.startTime
                + Double(fraction) * (segment.endTime - segment.startTime)
            let eased = smoothStep(fraction)
            let position = segment.startPosition
                + (segment.endPosition - segment.startPosition) * eased
            pts.append(screenPoint(time: time, position: position, viewport: viewport))
        }
        return pts
    }

    /// Maps a `(time, position)` pair to a screen point for the active axis.
    /// `position` 0 is the lane's low edge, 1 the high edge; "rising" reads as
    /// up in landscape and as a forward deflection in portrait.
    private static func screenPoint(time: TimeInterval, position: CGFloat,
                                    viewport: LaneViewport) -> CGPoint {
        let cross = crossCoordinate(for: position, viewport: viewport)
        return viewport.point(scroll: viewport.pos(for: time), cross: cross)
    }

    /// Cross-axis screen coordinate for a normalized platter position.
    private static func crossCoordinate(for position: CGFloat,
                                        viewport: LaneViewport) -> CGFloat {
        let inset = crossInsetFraction * viewport.crossLength
        let band = max(viewport.crossLength - inset * 2, 1)
        let clamped = min(max(position, 0), 1)
        switch viewport.axis {
        case .vertical:   return inset + clamped * band
        case .horizontal: return (viewport.crossLength - inset) - clamped * band
        }
    }

    /// Faint fill between the curve and the lane's low edge (position 0).
    private static func drawFill(polyline: [CGPoint], viewport: LaneViewport,
                                 color: Color, in context: GraphicsContext) {
        guard let first = polyline.first, let last = polyline.last else { return }
        let lowCross = crossCoordinate(for: 0, viewport: viewport)
        var fill = Path()
        fill.addLines(polyline)
        fill.addLine(to: viewport.point(scroll: scroll(of: last, viewport: viewport),
                                        cross: lowCross))
        fill.addLine(to: viewport.point(scroll: scroll(of: first, viewport: viewport),
                                        cross: lowCross))
        fill.closeSubpath()
        context.fill(fill, with: .color(color.opacity(0.10)))
    }

    /// The scroll-axis coordinate of a screen point.
    private static func scroll(of point: CGPoint, viewport: LaneViewport) -> CGFloat {
        viewport.axis == .vertical ? point.y : point.x
    }

    /// Smoothstep ease — gentle acceleration in, deceleration out, so the
    /// motion reads musical rather than robotic.
    private static func smoothStep(_ value: CGFloat) -> CGFloat {
        let x = min(max(value, 0), 1)
        return x * x * (3 - 2 * x)
    }

    /// Line-weight multiplier per stroke speed — a fast stab reads heavier and
    /// more aggressive, a slow drag lighter and more controlled.
    private static func speedWeight(_ speed: ScratchNotationSpeedClassification) -> CGFloat {
        switch speed {
        case .slow:   return 0.8
        case .medium: return 1.0
        case .fast:   return 1.35
        }
    }
}
