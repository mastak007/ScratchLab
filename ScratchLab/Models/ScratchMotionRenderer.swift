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
// and a contrasting muted rose-coral for a backward pull. Holds (lead-in,
// inter-stroke gaps, trailing rest) draw no visible line: with every hold
// rendered, the geometry's centre-resting endpoints concatenated into a
// continuous baseline across the lane and the chart read as two notation
// half-lanes flanking a visible centre spine. Dropping the hold line
// removes the spine; the path reads as one trace of angular stroke
// triangles. Every stroke-endpoint junction (centre entry, rail apex,
// centre return) is then punctuated with a small neutral dot — the
// dot row at centre provides the trace-continuity hint the eye needs
// without drawing a baseline.
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
        /// Small dots at every motion-path junction — the notation's
        /// articulation ticks: stroke starts, rail apexes, centre returns,
        /// hold endpoints.
        var showsNodes: Bool = true
        /// Layer opacity — dimmed for ghost / reference layers.
        var opacity: Double = 1
        /// Backward (pull) stroke colour. A contrasting hue from `color` so a
        /// push and a pull read as visibly distinct events. A muted rose-coral
        /// against cyan — direction is still unambiguous, without the neon
        /// "synthwave" cast the louder pink read as.
        var backwardColor: Color = Color(red: 0.94, green: 0.55, blue: 0.66)
        /// Phase 2 — crossfader-ribbon fill colour for `.closed` segments
        /// drawn along the lane's bottom (portrait) / trailing (landscape)
        /// edge. `.open` segments are transparent (no fill). A quiet
        /// neutral by default so the ribbon supports the motion trace
        /// without competing with it.
        var crossfaderRibbonColor: Color = Color.white.opacity(0.18)
        /// Phase 2 — colour for cut/pulse/flare tick marks rendered on top
        /// of the ribbon. Slightly brighter than the ribbon fill so a tick
        /// reads as a discrete event against a quiet open/closed bar.
        var crossfaderTickColor: Color = Color.white.opacity(0.65)

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
    /// cross length — a safe margin that keeps the curve, its junction dots
    /// and any glow clear of the lane edges. The motion fills the rest (~76%).
    static let crossInsetFraction: CGFloat = 0.12
    /// Glow width relative to the stroke line — a tight edge, not a soft halo.
    private static let glowWidthScale: CGFloat = 1.6
    /// Junction-node radius — small enough to read as a tick on a study
    /// chart, not a game-pad badge.
    private static let nodeRadius: CGFloat = 2.5
    /// Phase 2 — crossfader ribbon thickness, in points, along the lane's
    /// bottom (portrait) / trailing (landscape) edge.
    static let crossfaderRibbonThickness: CGFloat = 6
    /// Phase 2 — cut/pulse/flare tick height, in points. Slightly taller
    /// than the ribbon so the tick is readable as a discrete event.
    static let crossfaderTickHeight: CGFloat = 10
    /// Phase 2 — cut/pulse/flare tick width, in points.
    static let crossfaderTickWidth: CGFloat = 1.5
    /// Phase 2 — raw-trace velocity-to-thickness mapping. `min` is the
    /// hairline at zero speed; `max` is the cap at the fastest stroke.
    /// `gain` scales |dp/dt| (platter-axis displacement units / second
    /// — see `PlatterPositionSample.position`) into the sqrt-based
    /// thickness curve so a slow drag stays thin without disappearing
    /// and a fast stab is heavy without ballooning.
    private static let rawTraceMinWidthScale: CGFloat = 0.5
    private static let rawTraceMaxWidthScale: CGFloat = 1.8
    private static let rawTraceVelocityGain: Double = 3.0
    /// Junction-node opacity. The dots mark timing structure; the strokes
    /// carry the direction colour and stay the primary visual object, so
    /// the dots are a quiet neutral white rather than a popping accent.
    private static let nodeOpacity: Double = 0.55
    /// Dedup tolerance for junction nodes. Consecutive segments share their
    /// shared endpoint (the return-half's end IS the next hold's start; an
    /// out-half's end IS its return-half's start), so the same junction can
    /// be recorded twice within rounding noise. Drop the duplicate so a
    /// junction never reads as a heavier blob than its neighbours.
    private static let junctionTimeEpsilon: TimeInterval = 1e-4
    private static let junctionPositionEpsilon: CGFloat = 0.005

    // MARK: - Draw

    /// Draws `path` into `context`, mapped through `viewport`, in `style`.
    /// Pure — reads only its arguments, writes only to the context.
    ///
    /// ONLY stroke segments draw a visible line; holds are skipped so the
    /// chart reads as one continuous SXRATCH-style trace of angular
    /// triangles rather than two notation half-lanes flanking a centre
    /// baseline. Small junction dots mark every stroke endpoint (centre
    /// entry, rail apex, centre return) so the dot row at centre carries
    /// the trace-continuity hint without drawing a spine.
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

        // 2. The notation line. ONLY stroke segments draw a visible line —
        //    holds (lead-in, gaps between strokes, trailing rest) are skipped
        //    entirely. With every hold rendered, the geometry's centre-
        //    resting endpoints concatenated into a continuous horizontal
        //    line across the lane and the chart read as two notation
        //    half-lanes flanking a visible centre spine. Dropping the hold
        //    line removes the spine; the path reads as a series of angular
        //    stroke triangles, and the Tier 3A junction dots at every
        //    stroke endpoint provide the timing-continuity hint the eye
        //    needs without drawing a baseline.
        for item in drawn where !item.segment.isHold {
            let color = strokeColor(for: item.segment, style: style)
            let width = style.lineWidth * speedWeight(item.segment.speed)
            let dash: [CGFloat] = style.dashed ? [width * 1.5, width * 1.4] : []
            layer.stroke(segmentPath(item.a, item.b),
                         with: .color(color),
                         style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))
        }

        // 3. Junction nodes — small neutral dots at every meaningful timing
        //    junction along the path: stroke starts, rail apexes, returns
        //    to centre, and hold endpoints. The dots are read as TIMING
        //    marks, not direction marks, so they stay one quiet colour and
        //    let the lines carry the push/pull split. Consecutive segments
        //    share endpoints (return-half end == next hold start, etc.),
        //    so each shared point is drawn once via a time+position dedupe.
        //    Loop tiling is naturally seam-safe: two adjacent tiles each
        //    draw the seam point at the centre, but the two dots overlap
        //    pixel-for-pixel so the seam never reads as a heavier blob.
        if style.showsNodes {
            var lastTime: TimeInterval = -.infinity
            var lastPosition: CGFloat = -.infinity
            func drawIfNew(time: TimeInterval, position: CGFloat,
                           point: CGPoint) {
                if abs(time - lastTime) < junctionTimeEpsilon
                    && abs(position - lastPosition) < junctionPositionEpsilon {
                    return
                }
                drawJunctionNode(at: point, in: layer)
                lastTime = time
                lastPosition = position
            }
            if let first = drawn.first {
                drawIfNew(time: first.segment.startTime,
                          position: first.segment.startPosition,
                          point: first.a)
            }
            for item in drawn {
                drawIfNew(time: item.segment.endTime,
                          position: item.segment.endPosition,
                          point: item.b)
            }
        }
    }

    // MARK: - Draw (action-notation trace)

    /// Draws each stroke as a single diagonal slash anchored above the
    /// lane's baseline. Pure — reads only its arguments, writes only to
    /// the context.
    ///
    /// Forward strokes rise from baseline to peak height (`/` shape).
    /// Backward strokes fall from peak height to baseline (`\` shape).
    /// Every slash lives ABOVE the baseline — backward strokes never
    /// dip below it. Each stroke is one independent line segment with
    /// no return-to-centre tail and no connector between strokes; the
    /// silence between strokes is therefore empty space by construction.
    ///
    /// Horizontal extent of each slash equals the authored
    /// `endTime - startTime`, so longer (slower) strokes produce
    /// visibly wider slashes than tighter (faster) strokes. Vertical
    /// amplitude is fixed by `actionNotationBaselineFraction` /
    /// `actionNotationPeakFraction`. Line weight scales with the speed
    /// bucket via `speedWeight(_:)`; the hue is a single cyan
    /// (`style.color`) — no forward/backward colour split, no junction
    /// nodes.
    ///
    /// Ghosts are dropped defensively; copy-window emptiness is delivered
    /// upstream by `LaneContent.init(reel:)` which no longer folds ghosts
    /// in.
    ///
    /// Intended for the iOS Practice target lane (`ScratchMotionLane`).
    /// macOS Review renderers (`ScratchPhraseChartView`,
    /// `ScratchNotationCanvasView`) keep calling
    /// `draw(_:in:viewport:style:)` directly and are unaffected.
    static func drawActionNotationTrace(_ strokes: [LaneStroke],
                                        in context: GraphicsContext,
                                        viewport: LaneViewport,
                                        style: Style) {
        let visible = strokes.filter {
            !$0.isGhost
                && $0.endTime > $0.startTime
                && viewport.isVisible(from: $0.startTime, to: $0.endTime)
        }
        guard !visible.isEmpty else { return }

        let baselineCross = crossCoordinate(for: actionNotationBaselineFraction,
                                            viewport: viewport)
        let peakCross = crossCoordinate(for: actionNotationPeakFraction,
                                        viewport: viewport)

        var layer = context
        layer.opacity = style.opacity

        for stroke in visible {
            let x1 = viewport.pos(for: stroke.startTime)
            let x2 = viewport.pos(for: stroke.endTime)
            let lowEnd: CGPoint
            let peakEnd: CGPoint
            switch stroke.direction {
            case .forward:
                // `/` — rises from baseline at startTime to peak at endTime.
                lowEnd = viewport.point(scroll: x1, cross: baselineCross)
                peakEnd = viewport.point(scroll: x2, cross: peakCross)
            case .backward:
                // `\` — falls from peak at startTime to baseline at endTime.
                lowEnd = viewport.point(scroll: x2, cross: baselineCross)
                peakEnd = viewport.point(scroll: x1, cross: peakCross)
            }
            var line = Path()
            line.move(to: lowEnd)
            line.addLine(to: peakEnd)
            layer.stroke(
                line,
                with: .color(style.color),
                style: StrokeStyle(
                    lineWidth: style.lineWidth * speedWeight(stroke.speed),
                    lineCap: .round
                )
            )
        }
    }

    /// Cross-axis position of the slash baseline — a hair above the band's
    /// low edge so the line cap doesn't visually merge with the band's
    /// boundary.
    private static let actionNotationBaselineFraction: CGFloat = 0.06
    /// Cross-axis position of the slash peak — just below the band's high
    /// edge so the line cap stays inside the lane chrome.
    private static let actionNotationPeakFraction: CGFloat = 0.88

    // MARK: - Draw (Phase 2 — raw integrated trace)

    /// Draws a raw integrated platter-position timeline as a single
    /// continuous polyline. Pure — reads only its arguments, writes only
    /// to the context.
    ///
    /// Sample positions are normalised onto the lane's cross-axis 0…1 via
    /// `timeline.positionRange`. Each segment between consecutive samples
    /// is drawn with **velocity-modulated thickness** (Karl's Phase 2
    /// decision): line width scales with `sqrt(|dp/dt| * gain)`, clamped
    /// between `rawTraceMinWidthScale` and `rawTraceMaxWidthScale`. Single
    /// hue (`style.color`) — no forward/backward split, because the raw
    /// trace's direction reads from the slope itself.
    ///
    /// Renders nothing when the timeline has fewer than two samples or
    /// when `positionRange` collapses to zero span (no observed motion).
    static func drawRawTrace(_ timeline: PlatterPositionTimeline,
                             in context: GraphicsContext,
                             viewport: LaneViewport,
                             style: Style) {
        guard timeline.samples.count >= 2,
              let positionRange = timeline.positionRange else {
            return
        }
        let span = positionRange.upperBound - positionRange.lowerBound

        // Restrict to samples that touch the visible window — including
        // one lead-in and one lead-out so the polyline meets the edge.
        let visible = viewport.visibleTimeRange
        let samples = timeline.samples
        var firstIndex = 0
        for i in 0..<samples.count where samples[i].time <= visible.lowerBound {
            firstIndex = i
        }
        var lastIndex = samples.count - 1
        for i in (0..<samples.count).reversed() where samples[i].time >= visible.upperBound {
            lastIndex = i
        }
        guard lastIndex > firstIndex else { return }

        var layer = context
        layer.opacity = style.opacity

        func point(for sample: PlatterPositionSample) -> CGPoint {
            let normalised: CGFloat = span > 0
                ? CGFloat((sample.position - positionRange.lowerBound) / span)
                : 0.5
            let cross = crossCoordinate(for: normalised, viewport: viewport)
            return viewport.point(scroll: viewport.pos(for: sample.time), cross: cross)
        }

        for i in (firstIndex + 1)...lastIndex {
            let prev = samples[i - 1]
            let curr = samples[i]
            let dt = curr.time - prev.time
            let dp = abs(curr.position - prev.position)
            let speed = dt > 0 ? dp / dt : 0
            let scaled = sqrt(max(0, speed * rawTraceVelocityGain))
            let factor = max(rawTraceMinWidthScale,
                             min(rawTraceMaxWidthScale, CGFloat(scaled)))
            let width = style.lineWidth * factor
            var seg = Path()
            seg.move(to: point(for: prev))
            seg.addLine(to: point(for: curr))
            layer.stroke(seg, with: .color(style.color),
                         style: StrokeStyle(lineWidth: width, lineCap: .round))
        }
    }

    /// Draws the crossfader open/closed ribbon along the lane's bottom
    /// (portrait) / trailing (landscape) edge. Pure — reads only its
    /// arguments, writes only to the context.
    ///
    /// `.closed` segments fill with `style.crossfaderRibbonColor`; `.open`
    /// segments are transparent (no fill); `.transitioning(progress:)`
    /// segments fill with reduced opacity proportional to `(1 - progress)`
    /// so a closing ramp fades in and an opening ramp fades out across
    /// the segment span. Cut / pulse / flare event marks are drawn
    /// separately by `drawCrossfaderTicks`.
    static func drawCrossfaderRibbon(_ timeline: CrossfaderStateTimeline,
                                     in context: GraphicsContext,
                                     viewport: LaneViewport,
                                     style: Style) {
        guard !timeline.segments.isEmpty else { return }

        let (cross0, cross1) = ribbonCrossRange(viewport: viewport,
                                                thickness: crossfaderRibbonThickness)

        var layer = context
        layer.opacity = style.opacity

        for segment in timeline.segments
        where viewport.isVisible(from: segment.startTime, to: segment.endTime) {
            let pos0 = viewport.pos(for: segment.startTime)
            let pos1 = viewport.pos(for: segment.endTime)
            let rect = viewport.rect(scroll0: pos0, scroll1: pos1,
                                     cross0: cross0, cross1: cross1)
            switch segment.state {
            case .open:
                continue
            case .closed:
                layer.fill(Path(rect), with: .color(style.crossfaderRibbonColor))
            case .transitioning(let target):
                let opacity = max(0, min(1, 1 - target))
                guard opacity > 0 else { continue }
                layer.fill(Path(rect),
                           with: .color(style.crossfaderRibbonColor.opacity(opacity)))
            }
        }
    }

    /// Draws cut / pulse / transform / flare event ticks on top of the
    /// crossfader ribbon. Each event becomes a short vertical line
    /// (perpendicular to the scroll axis) at the event's `startTime`.
    /// Pure — reads only its arguments, writes only to the context.
    ///
    /// Only `.cut`, `.pulse`, `.transformPulse`, and `.flareClick` events
    /// draw a tick; `.open`, `.closed`, and `.unknown` are handled by
    /// the ribbon fill and produce no separate mark.
    static func drawCrossfaderTicks(
        _ events: [CaptureCore.DetectedNotationFaderEvent],
        in context: GraphicsContext,
        viewport: LaneViewport,
        style: Style
    ) {
        guard !events.isEmpty else { return }

        let (cross0, cross1) = ribbonCrossRange(viewport: viewport,
                                                thickness: crossfaderTickHeight)

        var layer = context
        layer.opacity = style.opacity

        for event in events
        where viewport.isVisible(from: event.startTime, to: event.endTime) {
            switch event.eventKind {
            case .cut, .pulse, .transformPulse, .flareClick:
                let pos = viewport.pos(for: event.startTime)
                let rect = viewport.rect(scroll0: pos - crossfaderTickWidth / 2,
                                         scroll1: pos + crossfaderTickWidth / 2,
                                         cross0: cross0, cross1: cross1)
                layer.fill(Path(rect), with: .color(style.crossfaderTickColor))
            case .open, .closed, .unknown:
                continue
            }
        }
    }

    /// Cross-axis `[start, end]` range for ribbon / tick elements.
    ///
    /// **Phase 2.1**: the ribbon now lives in its own dedicated Canvas
    /// below the motion lane (see `ScratchMotionLane` VStack split), so
    /// the renderer fills the **entire cross extent** of the viewport
    /// it is given. The strip's physical thickness is decided by the
    /// caller's viewport size, not by the renderer. This replaces the
    /// pre-2.1 behaviour where the ribbon sat at the larger-cross-edge
    /// of the motion lane itself (which placed it on the right side in
    /// portrait — visually wrong per Karl's 2026-05-24 review).
    private static func ribbonCrossRange(
        viewport: LaneViewport,
        thickness: CGFloat
    ) -> (CGFloat, CGFloat) {
        return (0, viewport.crossLength)
    }

    // MARK: - Marks

    /// A two-point straight path — one motion segment.
    private static func segmentPath(_ a: CGPoint, _ b: CGPoint) -> Path {
        var path = Path()
        path.move(to: a)
        path.addLine(to: b)
        return path
    }

    /// A junction node — a small filled disc that marks one timing point
    /// along the motion path. Kept subtle and neutral: one quiet colour,
    /// no popping white core, no glow halo — so the strokes themselves
    /// stay the primary visual object and the dots act as articulation
    /// ticks the eye reads as the chart's pulse.
    private static func drawJunctionNode(at point: CGPoint,
                                          in context: GraphicsContext) {
        let rect = CGRect(x: point.x - nodeRadius, y: point.y - nodeRadius,
                          width: nodeRadius * 2, height: nodeRadius * 2)
        context.fill(Path(ellipseIn: rect),
                     with: .color(.white.opacity(nodeOpacity)))
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
