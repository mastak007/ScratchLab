import SwiftUI

// Pure Canvas renderer for the Scratch Motion Lane.
//
// Draws a `MotionPath` — the integrated platter-position curve from
// `ScratchStrokeGeometry` — as an ANGULAR scratch-notation chart, not a smooth
// audio-style waveform. Every motion segment is one straight line: a stroke is
// a diagonal ramp (a forward push rises, a backward pull falls) and a hold is
// a flat horizontal line. There is no easing and no area-fill — the bare
// angular shape IS the notation.
//
// To keep tightly packed strokes from blending into one triangular wave, push
// and pull are drawn in DIFFERENT colours — by default cyan for a forward push
// and a contrasting hot pink for a backward pull — and a hold at the centre
// line is drawn as a DASHED rest line, clearly subordinate to the strokes.
// Every stroke's peak (where it lands on its rail) is then punctuated with a
// direction-coloured node dot, so each push, pull and pause reads as a
// separate, deliberate mark.
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
        /// Forward (push) stroke colour — also the colour of holds.
        var color: Color
        /// Base stroke-ramp width; each stroke scales it by its speed. The
        /// default sits in the "technical study chart" range — thin enough
        /// to read as a notation line rather than a neon trace.
        var lineWidth: CGFloat = 2.8
        /// Dashed rather than solid — for reference / ghost layers.
        var dashed: Bool = false
        /// Optional tight glow behind the stroke ramps. OFF by default — the
        /// notation reads cleaner as a hairline. Kept as a per-style switch
        /// so future high-emphasis layers (e.g. captured-user overlay) can
        /// opt back in without changing the renderer.
        var glow: Bool = false
        /// Node dots at every stroke apex — the notation's "cuts".
        var showsNodes: Bool = true
        /// Layer opacity — dimmed for ghost / reference layers.
        var opacity: Double = 1
        /// Backward (pull) stroke colour. A contrasting hue from `color` so a
        /// push and a pull read as visibly distinct events. A muted rose-coral
        /// against cyan — direction is still unambiguous, without the neon
        /// "synthwave" cast the louder pink read as.
        var backwardColor: Color = Color(red: 0.94, green: 0.55, blue: 0.66)

        /// The solid reference path the learner follows.
        static let target = Style(color: Color(red: 0.34, green: 0.80, blue: 1.00))
        /// A copy-window ghost target (Demo mode) — dashed, dim, unmarked,
        /// single colour (no direction split).
        static let ghost = Style(color: .white,
                                  lineWidth: 2, dashed: true,
                                  glow: false, showsNodes: false, opacity: 0.45,
                                  backwardColor: .white)
        /// The captured user path (future overlay) — bright green, single
        /// colour, slightly heavier than the target with an opt-in glow so it
        /// stands out when drawn alongside the reference curve.
        static let user = Style(color: Color(red: 0.30, green: 0.88, blue: 0.55),
                                 lineWidth: 3, glow: true,
                                 backwardColor: Color(red: 0.30, green: 0.88, blue: 0.55))
    }

    // MARK: - Tuning

    /// Inset of the motion band from each cross-axis edge, as a fraction of the
    /// cross length — a safe margin that keeps the curve, its apex nodes and
    /// its glow clear of the lane edges. The motion fills the rest (~76%).
    static let crossInsetFraction: CGFloat = 0.12
    /// Hold width relative to a stroke ramp — a pause is a thinner, quieter
    /// line so it reads as subordinate to the strokes themselves.
    private static let holdWidthScale: CGFloat = 0.5
    /// Hold opacity — a soft dashed rest line, clearly subordinate to strokes.
    private static let holdOpacity: Double = 0.55
    /// Glow width relative to the stroke line — a tight edge, not a soft halo.
    private static let glowWidthScale: CGFloat = 1.6
    /// Node-dot radius at every stroke apex (rail peak).
    private static let nodeRadius: CGFloat = 3.6
    /// A normalized position counts as "at a rail" within this tolerance.
    /// Strokes terminate on the high (1) or low (0) rail; the centre is 0.5.
    private static let railTolerance: CGFloat = 0.05

    // MARK: - Draw

    /// Draws `path` into `context`, mapped through `viewport`, in `style`.
    /// Pure — reads only its arguments, writes only to the context.
    ///
    /// Each segment is ONE straight line — a stroke ramp or a flat hold —
    /// drawn in its direction colour; nodes punctuate the stroke peaks.
    static func draw(_ path: MotionPath,
                     in context: GraphicsContext,
                     viewport: LaneViewport,
                     style: Style) {
        let visible = path.segments.filter {
            viewport.isVisible(from: $0.startTime, to: $0.endTime)
        }
        guard !visible.isEmpty else { return }

        // One straight line per segment — endpoints only, no sampling.
        let drawn = visible.map { segment in
            (segment: segment,
             a: screenPoint(time: segment.startTime, position: segment.startPosition,
                            viewport: viewport),
             b: screenPoint(time: segment.endTime, position: segment.endPosition,
                            viewport: viewport))
        }

        var layer = context
        layer.opacity = style.opacity

        // 1. A tight glow behind the STROKE ramps — holds stay quiet.
        if style.glow {
            for item in drawn where !item.segment.isHold {
                let color = strokeColor(for: item.segment, style: style)
                let width = style.lineWidth * speedWeight(item.segment.speed) * glowWidthScale
                layer.stroke(segmentPath(item.a, item.b),
                             with: .color(color.opacity(0.3)),
                             style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
        }

        // 2. The notation line, per segment. A stroke is a bold angular ramp in
        //    its direction colour; a hold is a DASHED, thin, quiet line at the
        //    centre — clearly a rest, separating each push and pull as its own
        //    notation event.
        for item in drawn {
            let color = strokeColor(for: item.segment, style: style)
            if item.segment.isHold {
                let width = max(style.lineWidth * holdWidthScale, 1.5)
                let dashUnit = max(width * 1.6, 3)
                layer.stroke(segmentPath(item.a, item.b),
                             with: .color(color.opacity(holdOpacity)),
                             style: StrokeStyle(lineWidth: width, lineCap: .round,
                                                dash: [dashUnit, dashUnit * 1.2]))
            } else {
                let width = style.lineWidth * speedWeight(item.segment.speed)
                let dash: [CGFloat] = style.dashed ? [width * 1.5, width * 1.4] : []
                layer.stroke(segmentPath(item.a, item.b),
                             with: .color(color),
                             style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))
            }
        }

        // 3. Apex nodes — direction-coloured dots at every stroke peak (the
        //    point where the line lands on a rail). Centre-line transitions
        //    between segments stay un-marked so the rest line remains uncluttered
        //    and each stroke's peak reads as the visual "beat" of the notation.
        if style.showsNodes {
            if let first = drawn.first, isAtRail(first.segment.startPosition) {
                let color = strokeColor(for: first.segment, style: style)
                drawNode(at: first.a, color: color, in: layer)
            }
            for item in drawn where isAtRail(item.segment.endPosition) {
                let color = strokeColor(for: item.segment, style: style)
                drawNode(at: item.b, color: color, in: layer)
            }
        }
    }

    // MARK: - Marks

    /// A two-point straight path — one motion segment.
    private static func segmentPath(_ a: CGPoint, _ b: CGPoint) -> Path {
        var path = Path()
        path.move(to: a)
        path.addLine(to: b)
        return path
    }

    /// A boundary node — a filled disc with a bright white core, the clear
    /// stroke mark that punctuates a push or a pull's apex.
    private static func drawNode(at point: CGPoint, color: Color,
                                 in context: GraphicsContext) {
        let outer = CGRect(x: point.x - nodeRadius, y: point.y - nodeRadius,
                           width: nodeRadius * 2, height: nodeRadius * 2)
        context.fill(Path(ellipseIn: outer), with: .color(color))
        let coreRadius = nodeRadius * 0.42
        let core = CGRect(x: point.x - coreRadius, y: point.y - coreRadius,
                          width: coreRadius * 2, height: coreRadius * 2)
        context.fill(Path(ellipseIn: core), with: .color(.white.opacity(0.9)))
    }

    // MARK: - Geometry

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

    /// Whether a normalized position is at one of the rails (an apex), versus
    /// resting on the lane's centre line.
    private static func isAtRail(_ position: CGFloat) -> Bool {
        position < railTolerance || position > 1 - railTolerance
    }

    /// The colour for a segment — its direction colour for strokes, the base
    /// colour for holds. Lets push and pull read as distinct events.
    private static func strokeColor(for segment: MotionSegment,
                                    style: Style) -> Color {
        switch segment.kind {
        case .stroke(.forward):  return style.color
        case .stroke(.backward): return style.backwardColor
        case .hold:              return style.color
        }
    }

    /// Line-weight multiplier per stroke speed — a slight differentiation,
    /// not a dramatic one. With the base line dropped to a study-chart
    /// hairline, the multipliers are compressed so a fast stab still reads
    /// heavier than a slow drag without ballooning back into a neon trace.
    private static func speedWeight(_ speed: ScratchNotationSpeedClassification) -> CGFloat {
        switch speed {
        case .slow:   return 0.92
        case .medium: return 1.00
        case .fast:   return 1.15
        }
    }
}
