import SwiftUI

// Pure Canvas renderer for the Scratch Motion Lane.
//
// Draws a `MotionPath` — the integrated platter-position curve from
// `ScratchStrokeGeometry` — as an ANGULAR scratch-notation chart, not a smooth
// audio-style waveform. Every motion segment is one straight line: a stroke is
// a diagonal ramp (a forward push rises, a backward pull falls) and a hold is
// a flat horizontal line. There is no easing and no area-fill — the bare
// angular shape IS the notation. Stroke boundaries are punctuated with node
// dots, so each push, pull, stab and pause reads as a separate, deliberate
// mark rather than blurring into one continuous wave.
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
        /// Base stroke-ramp width; each stroke scales it by its speed.
        var lineWidth: CGFloat = 5
        /// Dashed rather than solid — for reference / ghost layers.
        var dashed: Bool = false
        /// A tight neon glow behind the stroke ramps — game-like, not a halo.
        var glow: Bool = true
        /// Node dots at every stroke boundary — the notation's "cuts".
        var showsNodes: Bool = true
        /// Layer opacity — dimmed for ghost / reference layers.
        var opacity: Double = 1

        /// The solid reference path the learner follows.
        static let target = Style(color: Color(red: 0.34, green: 0.80, blue: 1.00))
        /// A copy-window ghost target (Demo mode) — dashed, dim, unmarked.
        static let ghost = Style(color: .white, lineWidth: 3, dashed: true,
                                 glow: false, showsNodes: false, opacity: 0.45)
        /// The captured user path (future overlay) — bright and solid.
        static let user = Style(color: Color(red: 0.30, green: 0.88, blue: 0.55),
                                lineWidth: 4)
    }

    // MARK: - Tuning

    /// Inset of the motion band from each cross-axis edge, as a fraction of the
    /// cross length — a safe margin that keeps the curve, its boundary nodes
    /// and its glow clear of the lane edges. The motion fills the rest (~76%).
    static let crossInsetFraction: CGFloat = 0.12
    /// Hold width relative to a stroke ramp — a pause is a thinner, quieter line.
    private static let holdWidthScale: CGFloat = 0.5
    /// Hold opacity — a quiet flat line, clearly subordinate to the strokes.
    private static let holdOpacity: Double = 0.7
    /// Glow width relative to the stroke line — a tight edge, not a soft halo.
    private static let glowWidthScale: CGFloat = 1.7
    /// Node-dot radius marking each stroke boundary.
    private static let nodeRadius: CGFloat = 3.2

    // MARK: - Draw

    /// Draws `path` into `context`, mapped through `viewport`, in `style`.
    /// Pure — reads only its arguments, writes only to the context.
    ///
    /// Each segment is ONE straight line: a stroke ramp or a flat hold. No
    /// easing, no multi-sampling — the angular shape itself is the notation.
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
                let width = style.lineWidth * speedWeight(item.segment.speed) * glowWidthScale
                layer.stroke(segmentPath(item.a, item.b),
                             with: .color(style.color.opacity(0.3)),
                             style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
        }

        // 2. The notation line, per segment. A stroke is a bold angular ramp;
        //    a hold is a thin, quiet, flat line — an unmistakable pause.
        for item in drawn {
            if item.segment.isHold {
                let width = max(style.lineWidth * holdWidthScale, 1.5)
                layer.stroke(segmentPath(item.a, item.b),
                             with: .color(style.color.opacity(holdOpacity)),
                             style: StrokeStyle(lineWidth: width, lineCap: .round))
            } else {
                let width = style.lineWidth * speedWeight(item.segment.speed)
                let dash: [CGFloat] = style.dashed ? [width * 1.5, width * 1.4] : []
                layer.stroke(segmentPath(item.a, item.b),
                             with: .color(style.color),
                             style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))
            }
        }

        // 3. Node dots at every stroke boundary — the cuts that keep a push, a
        //    pull, a stab and a pause from blurring into one continuous wave.
        if style.showsNodes {
            if let first = drawn.first {
                drawNode(at: first.a, color: style.color, in: layer)
            }
            for item in drawn {
                drawNode(at: item.b, color: style.color, in: layer)
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

    /// A boundary node — a filled disc with a bright core, a clear stroke mark.
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

    /// Line-weight multiplier per stroke speed — a fast stab reads heavier and
    /// more aggressive, a slow drag lighter and more controlled.
    private static func speedWeight(_ speed: ScratchNotationSpeedClassification) -> CGFloat {
        switch speed {
        case .slow:   return 0.85
        case .medium: return 1.0
        case .fast:   return 1.3
        }
    }
}
