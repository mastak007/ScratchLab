// ScratchMotionLane.swift
// ScratchLab - Practice
//
// The Scratch Motion Lane — the notation surface as a motion graph of platter
// position over time, not block arrows.
//
// It is the unified action-line lane: a strip the notation scrolls along
// toward a fixed action line that marks "now". What scrolls is no longer a row
// of direction bars — it is one continuous, eased platter-position curve
// (`ScratchStrokeGeometry` → `MotionPath`, drawn by `ScratchMotionRenderer`):
// forward motion rises, backward falls, holds run flat; a slow drag is a long
// shallow curve, a fast stab a short steep one.
//
// Substrate kept from the timing lane: the axis-parametric `LaneViewport`, the
// `LaneClock` (audio is the master clock), the fixed action line, the
// demo/copy bands, the beat grid, the segment-label edge tabs, and the
// 60 Hz `TimelineView` ticker. The instructional "what's happening now"
// chip used to sit on top of this view — it is now a HUD line outside the
// graph, in the lane's header, so the Canvas contains only notation.
// Only the stroke layer changed from the original lane — bars and chevrons
// became the motion curve.
//
// Portrait runs the lane vertically (time flows top→bottom); landscape runs it
// horizontally (time flows left→right). It drives no capture, export, scoring
// or ML, and takes no live-mic input. `userEvents` is an inert scaffold for
// the future captured-motion overlay.

import SwiftUI

struct ScratchMotionLane: View {

    /// What the lane renders — strokes, demo/copy bands, tempo, duration.
    let content: LaneContent
    /// The timing master.
    let clock: LaneClock
    /// Which way the lane scrolls.
    let axis: LaneAxis
    /// User-attempt marks for the overlay. SCAFFOLD: empty on every shipping
    /// path, so the overlay draws nothing and scores nothing.
    var userEvents: [LaneUserEvent] = []

    /// The integrated platter-position curve, derived once from `content`.
    /// Used by the **classified-stroke fallback** path. When the lane
    /// renders via the raw integrated trace instead, this is computed
    /// but unused — a small allocation cost we accept in Phase 2 to
    /// keep the fallback init-side and pre-warmed.
    private let motionPath: MotionPath

    /// Phase 2 — derived once from `content.faderEvents`. Empty events
    /// yield an empty timeline; the renderer then draws nothing for
    /// the ribbon, matching the pre-Phase-2 behaviour where the
    /// crossfader never appeared on the lane at all.
    private let crossfaderTimeline: CrossfaderStateTimeline

    init(content: LaneContent, clock: LaneClock, axis: LaneAxis,
         userEvents: [LaneUserEvent] = []) {
        self.content = content
        self.clock = clock
        self.axis = axis
        self.userEvents = userEvents
        self.motionPath = ScratchStrokeGeometry.motionPath(for: content)
        // Coverage spans the lane's full timeline. `state(at:)` returns
        // `.closed` for any time outside this — but the lane only ever
        // queries within `[0, duration]`, so this is purely defensive.
        let coverage: ClosedRange<TimeInterval>? = content.duration > 0
            ? 0...content.duration
            : nil
        self.crossfaderTimeline = CrossfaderStateTimeline(
            from: content.faderEvents,
            coverage: coverage
        )
    }

    // MARK: Tuning

    private static let tickInterval: TimeInterval = 1.0 / 60.0
    private static let completionEpsilon: TimeInterval = 0.06

    /// Action-line position along the scroll axis, per orientation. The lane
    /// is heavily skewed toward the FUTURE so the playhead reads as a
    /// temporal divider — most of the visible area is upcoming notation,
    /// with just a short tail of recently-played content on the past side.
    /// A more centred line made the chart feel like two mirrored phrases
    /// flanking a gameplay target; this asymmetry restores the "one
    /// scrolling timeline" feel.
    private func actionLineFraction(for axis: LaneAxis) -> CGFloat {
        axis == .vertical ? 0.85 : 0.18
    }
    /// Lookahead window — landscape is wider, so it can show a little more.
    private func secondsAhead(for axis: LaneAxis) -> TimeInterval {
        axis == .vertical ? 5.5 : 6.5
    }

    /// Phase 2.2 — dedicated action-line fraction for the ribbon strip
    /// below the motion canvas. The strip is **always** horizontal, so
    /// "fraction" here is along the strip's x-axis.
    ///
    /// - Portrait: `0.5` (centered NOW marker). The motion canvas above
    ///   uses a vertical scroll axis with action line at y = 0.85; the
    ///   ribbon's horizontal NOW marker can't visually intersect that,
    ///   so a centered ribbon-now reads as a clean independent timeline
    ///   rather than a 85%-from-the-left past-dominated strip.
    /// - Landscape: matches the motion's `actionLineFraction(for:)`
    ///   (0.18 leading), so the ribbon's NOW indicator sits directly
    ///   below the motion's action line — vertically aligned because
    ///   both axes are horizontal.
    ///
    /// The motion canvas's own `actionLineFraction(for:)` is **NOT**
    /// changed by this; only the ribbon strip uses the override.
    private func ribbonActionLineFraction(for axis: LaneAxis) -> CGFloat {
        axis == .vertical ? 0.5 : actionLineFraction(for: axis)
    }
    /// Opacity of past notation at the far past edge of the lane. A linear
    /// gradient mask reaches this value at the trailing past edge so what
    /// has already played fades into a quiet tail rather than competing
    /// with the upcoming notation as a second, equal-weight cluster.
    private static let pastFadeOpacity: Double = 0.30

    /// Phase 2.1 — height (in points) of the dedicated crossfader ribbon
    /// strip rendered BELOW the motion canvas in a `VStack(spacing: 0)`
    /// split. The strip only exists when `content.faderEvents` is
    /// non-empty, so the no-events path collapses the VStack back to a
    /// single full-height motion canvas (visually identical to
    /// pre-Phase-2). The chosen height is enough to read open/closed
    /// fills + tick marks without crowding the motion area above.
    private static let ribbonStripHeight: CGFloat = 14

    // MARK: Palette — one shared language across both orientations

    /// Flat dark gray — a study-chart canvas, not a tinted gradient. Keeps the
    /// notation as the only thing carrying colour information.
    private static let background = Color(white: 0.10)
    /// Demo segments read cool; copy windows read warm/active.
    private static let demoAccent = Color(red: 0.23, green: 0.51, blue: 0.96)
    private static let copyAccent = Color(red: 0.96, green: 0.62, blue: 0.07)
    /// One quiet weight for every beat — the grid supports timing, it doesn't
    /// compete with the strokes. (Wider macOS Review keeps numeric beat
    /// labels via its own chart helper; the iOS lane stays single-weight.)
    private static let beatLineColor = Color.white.opacity(0.06)

    // MARK: Body

    var body: some View {
        GeometryReader { geo in
            // The TimelineView is only a render-side ticker. `now` comes
            // solely from the clock, so no layout state feeds back into timing.
            TimelineView(.periodic(from: .now, by: Self.tickInterval)) { timeline in
                let now = clock.now(at: timeline.date)
                // Phase 2.1: VStack split — motion canvas on top, dedicated
                // ribbon strip below (only when fader events are present).
                // When no events, the strip is omitted and the motion canvas
                // fills the full geometry exactly as pre-Phase-2.
                let hasRibbon = !content.faderEvents.isEmpty
                let motionHeight = hasRibbon
                    ? max(0, geo.size.height - Self.ribbonStripHeight)
                    : geo.size.height
                let motionSize = CGSize(width: geo.size.width, height: motionHeight)
                let motionViewport = LaneViewport(
                    size: motionSize,
                    now: now,
                    axis: axis,
                    actionLineFraction: actionLineFraction(for: axis),
                    secondsAhead: secondsAhead(for: axis))

                VStack(spacing: 0) {
                    laneContent(motionViewport)
                        .frame(width: motionSize.width, height: motionSize.height)
                    if hasRibbon {
                        ribbonStrip(width: geo.size.width, now: now)
                            .frame(width: geo.size.width, height: Self.ribbonStripHeight)
                    }
                }
            }
        }
        .background(Self.background)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    /// Phase 2.1 — dedicated horizontal ribbon canvas below the motion
    /// lane. Time always flows left → right, regardless of the motion
    /// canvas's axis. The ribbon shares the motion's `secondsAhead`
    /// (visible window length) but uses a strip-specific action-line
    /// fraction via `ribbonActionLineFraction(for:)` — see Phase 2.2
    /// docstring there. The strip is NOT subject to the motion's
    /// past-fade mask: full opacity across the whole visible fader
    /// history.
    @ViewBuilder
    private func ribbonStrip(width: CGFloat, now: TimeInterval) -> some View {
        let viewport = LaneViewport(
            size: CGSize(width: width, height: Self.ribbonStripHeight),
            now: now,
            axis: .horizontal,
            actionLineFraction: ribbonActionLineFraction(for: axis),
            secondsAhead: secondsAhead(for: axis))
        Canvas { context, _ in
            ScratchMotionRenderer.drawCrossfaderRibbon(
                crossfaderTimeline, in: context, viewport: viewport,
                style: .target
            )
            ScratchMotionRenderer.drawCrossfaderTicks(
                content.faderEvents, in: context, viewport: viewport,
                style: .target
            )
        }
    }

    /// One render frame — a pure function of `viewport`. The `Canvas` paints
    /// the dense graphics; the overlays carry crisp text. No view state is
    /// written here.
    private func laneContent(_ viewport: LaneViewport) -> some View {
        let currentSegment = content.segment(at: viewport.now)
        let isComplete = !content.loops
            && viewport.now >= content.duration - Self.completionEpsilon

        return ZStack {
            Canvas { context, _ in
                drawRegionBands(in: context, viewport: viewport)
                drawBeatGrid(in: context, viewport: viewport)
                drawMotionPath(in: context, viewport: viewport)
                drawUserEvents(in: context, viewport: viewport)
                drawActionLine(in: context, viewport: viewport, segment: currentSegment)
            }
            // Past content fades into a quiet tail. Future stays full
            // opacity. The fade only masks the notation layer, so the
            // chip and segment labels stay crisp on top.
            .mask(pastFadeMask(for: viewport))

            segmentLabelOverlay(viewport)

            if isComplete {
                completionCard
            }
        }
    }

    // MARK: - Past-fade mask

    /// A linear gradient that runs along the scroll axis: full opacity on the
    /// future side, fading to `pastFadeOpacity` at the far past edge, with
    /// the transition starting exactly at the action line. Applied as a
    /// `.mask(...)` on the notation `Canvas` only — segment-label edge tabs
    /// keep their full visual weight on top.
    private func pastFadeMask(for viewport: LaneViewport) -> LinearGradient {
        let frac = actionLineFraction(for: viewport.axis)
        let fadeColor = Color.white.opacity(Self.pastFadeOpacity)
        switch viewport.axis {
        case .vertical:
            // Future = top, past = bottom. Fade starts at the action line
            // (`frac` from the top) and reaches `pastFadeOpacity` at the
            // very bottom.
            return LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: .white,    location: 0.0),
                    .init(color: .white,    location: frac),
                    .init(color: fadeColor, location: 1.0),
                ]),
                startPoint: .top, endPoint: .bottom)
        case .horizontal:
            // Past = leading, future = trailing. Fade starts at the past
            // edge and reaches full opacity at the action line.
            return LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: fadeColor, location: 0.0),
                    .init(color: .white,    location: frac),
                    .init(color: .white,    location: 1.0),
                ]),
                startPoint: .leading, endPoint: .trailing)
        }
    }

    // MARK: - Canvas: region bands

    /// Full-cross-width demo / copy bands. Both kinds are a near-invisible
    /// tint (~0.04 alpha) — segment structure stays detectable without a
    /// loud background block competing with the notation. Each band is
    /// anchored by a 3 pt accent stripe at its leading cross-edge and a thin
    /// white boundary line across the lane at its start. Scored content
    /// has no segments — nothing is drawn.
    private func drawRegionBands(in context: GraphicsContext, viewport: LaneViewport) {
        for segment in content.segments
        where viewport.isVisible(from: segment.startTime, to: segment.endTime) {
            let startPos = viewport.pos(for: segment.startTime)
            let endPos = viewport.pos(for: segment.endTime)
            let isCopy = segment.kind == .copy
            let accent = isCopy ? Self.copyAccent : Self.demoAccent

            let band = viewport.rect(scroll0: startPos, scroll1: endPos,
                                     cross0: 0, cross1: viewport.crossLength)
            context.fill(Path(band), with: .color(accent.opacity(0.04)))

            // Accent stripe down the cross-start edge of the band.
            let edge = viewport.rect(scroll0: startPos, scroll1: endPos,
                                     cross0: 0, cross1: 3)
            context.fill(Path(edge), with: .color(accent.opacity(0.85)))

            // Thin boundary line across the lane at the segment start.
            var boundary = Path()
            boundary.move(to: viewport.point(scroll: startPos, cross: 0))
            boundary.addLine(to: viewport.point(scroll: startPos, cross: viewport.crossLength))
            context.stroke(boundary, with: .color(.white.opacity(0.07)), lineWidth: 1)
        }
    }

    // MARK: - Canvas: beat grid

    /// Beat lines across the lane, drawn only when the content declares a
    /// tempo. The interim no-beat Demo asset has none, so the grid is simply
    /// absent; a tempo-bearing asset lights it up with no code change.
    private func drawBeatGrid(in context: GraphicsContext, viewport: LaneViewport) {
        guard let bpm = content.beatsPerMinute, bpm > 0 else { return }
        let beatInterval = 60.0 / bpm
        guard beatInterval > 0 else { return }

        let window = viewport.visibleTimeRange
        var index = max(0, Int(window.lowerBound / beatInterval))
        while true {
            let beatTime = Double(index) * beatInterval
            if beatTime > window.upperBound { break }
            if beatTime > content.duration { break }
            let pos = viewport.pos(for: beatTime)
            var line = Path()
            line.move(to: viewport.point(scroll: pos, cross: 0))
            line.addLine(to: viewport.point(scroll: pos, cross: viewport.crossLength))
            context.stroke(line, with: .color(Self.beatLineColor), lineWidth: 1)
            index += 1
        }
    }

    // MARK: - Canvas: motion path

    /// The platter-position curve — the heart of the lane.
    ///
    /// Phase 2 routes through `LaneContent.shouldRenderRawTrace(...)`:
    /// when the content carries a sufficiently dense raw
    /// `PlatterPositionTimeline`, the renderer draws a single continuous
    /// integrated trace. Otherwise it falls back to the existing
    /// classified-stroke `MotionPath` path — pixel-identical to
    /// pre-Phase-2 output when `content.platterTimeline == nil`, which
    /// is every shipping call path today (no producer yet).
    ///
    /// The raw-trace path does NOT tile: a raw timeline is a recording
    /// of one take and is not a loopable pattern. Looping content always
    /// uses the classified fallback.
    private func drawMotionPath(in context: GraphicsContext, viewport: LaneViewport) {
        if let rawTimeline = content.platterTimeline,
           content.shouldRenderRawTrace() {
            ScratchMotionRenderer.drawRawTrace(rawTimeline, in: context,
                                                viewport: viewport, style: .target)
            return
        }
        guard !motionPath.isEmpty else { return }
        guard content.loops, content.duration > 0 else {
            ScratchMotionRenderer.draw(motionPath, in: context,
                                       viewport: viewport, style: .target)
            return
        }
        let span = content.duration
        let window = viewport.visibleTimeRange
        let kLow = Int((window.lowerBound / span).rounded(.down)) - 1
        let kHigh = Int((window.upperBound / span).rounded(.up)) + 1
        guard kLow <= kHigh else { return }
        for k in kLow...kHigh {
            ScratchMotionRenderer.draw(motionPath.shifted(by: Double(k) * span),
                                       in: context, viewport: viewport, style: .target)
        }
    }

    // MARK: - Canvas: user-attempt overlay (scaffold)

    /// Draws the user's own attempt marks alongside the reference curve.
    ///
    /// SCAFFOLD. `userEvents` is empty on every shipping call path, so this
    /// draws nothing today. It keeps a populated render path ready for the
    /// future timing-comparison overlay; wiring `userEvents` to a live source
    /// (mic analysis, capture, scoring) is deliberately out of scope here.
    private func drawUserEvents(in context: GraphicsContext, viewport: LaneViewport) {
        let inset = min(max(viewport.crossLength * 0.14, 14), 40)
        for event in userEvents
        where viewport.isVisible(from: event.startTime, to: event.endTime) {
            let p0 = viewport.pos(for: event.startTime)
            let p1 = viewport.pos(for: event.endTime)
            let mark = viewport.rect(scroll0: p0, scroll1: p1,
                                     cross0: viewport.crossLength - inset + 5,
                                     cross1: viewport.crossLength - inset + 9)
            context.fill(
                Path(roundedRect: mark, cornerRadius: 2, style: .continuous),
                with: .color(.white.opacity(0.85)))
        }
    }

    // MARK: - Canvas: action line

    /// The fixed "now" line — perpendicular to the scroll axis. A hairline,
    /// not a glowing band: a 1.5 pt white line and two small accent-coloured
    /// end dots are enough to read the playhead without taking over the lane.
    /// The accent picks up the active segment: amber while copying, blue
    /// while watching the demo (and blue when there's no segment, e.g.
    /// scored modes).
    private func drawActionLine(in context: GraphicsContext, viewport: LaneViewport,
                                segment: LaneSegment?) {
        let pos = viewport.actionLinePos
        let tint: Color = switch segment?.kind {
        case .copy: Self.copyAccent
        case .demo: Self.demoAccent
        case nil:   Self.demoAccent
        }

        var line = Path()
        line.move(to: viewport.point(scroll: pos, cross: 0))
        line.addLine(to: viewport.point(scroll: pos, cross: viewport.crossLength))
        context.stroke(line, with: .color(.white.opacity(0.8)), lineWidth: 1.5)

        let dotRadius: CGFloat = 2.5
        for cross in [CGFloat(0), viewport.crossLength] {
            let center = viewport.point(scroll: pos, cross: cross)
            context.fill(
                Path(ellipseIn: CGRect(x: center.x - dotRadius, y: center.y - dotRadius,
                                       width: dotRadius * 2, height: dotRadius * 2)),
                with: .color(tint))
        }
    }

    // MARK: - Overlay: segment labels

    /// Per-segment labels — `DEMO 1`, `YOUR TURN` — riding each band so an
    /// upcoming segment announces itself as it scrolls in. Positioned a little
    /// way into the band and clamped to stay on screen.
    @ViewBuilder
    private func segmentLabelOverlay(_ viewport: LaneViewport) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(content.segments.enumerated()), id: \.offset) { _, segment in
                if viewport.isVisible(from: segment.startTime, to: segment.endTime) {
                    let anchorTime = segment.startTime + segment.duration * 0.15
                    let rawScroll = viewport.pos(for: anchorTime)
                    let scroll = min(max(rawScroll, 20), viewport.scrollLength - 20)
                    let point = viewport.point(scroll: scroll, cross: 16)
                    segmentLabelChip(segment)
                        .offset(x: point.x, y: point.y)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func segmentLabelChip(_ segment: LaneSegment) -> some View {
        let accent = segment.kind == .copy ? Self.copyAccent : Self.demoAccent
        // A quiet inline label — secondary to the strokes. Tinted with its
        // segment accent, no heavy capsule fill, no shadow.
        return Text(laneLabel(for: segment).uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.3)
            .foregroundColor(.white.opacity(0.85))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(accent.opacity(0.40))
            .clipShape(Capsule())
    }

    // MARK: - Overlay: completion

    /// Parked state once a non-looping lane (Demo) reaches the end of its
    /// audio. Derived purely from the clock crossing `duration` — no
    /// audio-player delegate callback, so it carries no lifecycle risk.
    private var completionCard: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundColor(Color(red: 0.20, green: 0.80, blue: 0.45))
            Text("Demo complete")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
            Text("You ran the full call-and-response.")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.75))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(Color.white.opacity(0.12), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Demo complete")
    }

    // MARK: - Labels

    /// A practical label for a segment: the content's own label when present,
    /// otherwise a plain `Demo` / `Your turn` fallback.
    private func laneLabel(for segment: LaneSegment) -> String {
        if let label = segment.label,
           !label.trimmingCharacters(in: .whitespaces).isEmpty {
            return label
        }
        return segment.kind == .copy ? "Your turn" : "Demo"
    }
}
