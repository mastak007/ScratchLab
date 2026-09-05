import SwiftUI

// Static full-phrase notation chart — all strokes visible at once.
// Replaces ScratchNotationCanvasView in non-animated contexts (capture, review).
//
// Shared iOS/macOS target/performance chart. Legacy strokes and lossless
// canonical curves both route through ScratchStrokeGeometry / MotionPath /
// ScratchMotionRenderer. This view supplies the musical grid, separate
// platter/fader lanes, bone target/cyan performance styling and playhead.
// Canonical records require an explicit shared time and position frame.

struct ScratchPhraseChartView: View {

    enum ChartSource {
        case target(ScratchNotation)
        /// Raw captured events drawn in the telemetry language (FWD/BACK slashes
        /// above a baseline) — kept as the technical "Captured Evidence" view.
        case captured([CaptureCore.DetectedNotationRecordMovementEvent])
        /// Measured strokes drawn through the SAME platter-position geometry
        /// (`ScratchStrokeGeometry` / `ScratchMotionRenderer`) as `.target`,
        /// in the performed accent style — the learner-facing MY PERFORMANCE
        /// row of the stacked comparison.
        case performedPlatter([CaptureCore.DetectedNotationRecordMovementEvent])
        /// Lossless canonical curves in an explicit shared comparison frame.
        /// Both layers use the existing MotionPath / ScratchMotionRenderer.
        case canonical([ScratchNotation.GestureRecord],
                       layer: ScratchStrokeGeometry.CanonicalLayer,
                       frame: ScratchStrokeGeometry.CanonicalFrame)
        case empty(String)
    }

    let source: ChartSource
    var bpm: Double = 90
    /// Beatless audio references still need the notation renderer, but must not
    /// imply a tempo by drawing beat/subdivision lines and beat numbers.
    var showBeatGrid: Bool = true
    /// Review-only render-time window for the `.target` source. When `nil`,
    /// the chart renders the full notation timeline (Practice/iOS/preview
    /// behaviour preserved). When set, the chart maps `[lowerBound, upperBound]`
    /// onto the full chart width; the bundled notation JSON is never mutated.
    /// Ignored by `.captured` and `.empty` sources.
    var targetWindow: ClosedRange<TimeInterval>? = nil
    /// Displayed time window for the `.captured` source. When set, the chart
    /// maps `[lowerBound, upperBound]` onto the full width instead of fitting
    /// the captured take's own `[0, maxEndTime]` span. The stacked TARGET / MY
    /// PERFORMANCE comparison sets this to the TARGET's domain so both charts
    /// share one horizontal time axis; captured events may extend outside it,
    /// but never rescale the performed chart independently. Ignored by
    /// `.target` and `.empty` sources.
    var capturedWindow: ClosedRange<TimeInterval>? = nil
    var playheadTime: TimeInterval = 0
    var showPlayhead: Bool = false
    /// Optional target-vs-performed overlay drawn on top of the `.target`
    /// chart: performed strokes in the captured chart's own visual language
    /// (green forward `/`, orange backward `\` slashes), per-mark verdict
    /// dots on the baseline, and performed fader-edge ticks in the
    /// fader sub-lane. `nil` (every pre-existing call site) renders the
    /// chart byte-identically to before. Ignored by `.captured`/`.empty`.
    var comparisonOverlay: ScratchComparisonOverlay? = nil
    /// In-progress performed movement drawn directly over a target phrase.
    /// This is presentation-only: callers supply attempt-relative events and
    /// the chart renders them with the canonical cyan performance style on
    /// the target's time and vertical axes. Nothing here mutates, scores, or
    /// persists the events.
    var livePerformedEvents: [CaptureCore.DetectedNotationRecordMovementEvent] = []
    /// Captured fader spans for the `.performedPlatter` source's fader lane.
    /// Empty means "no trustworthy fader capture" — the lane shows a subdued
    /// "Fader not captured" state instead of inventing an open line. Non-empty
    /// draws real captured open/closed rails.
    var performedFaderSpans: [LaneFaderSpan] = []
    /// The TARGET's raw vertical frame (from `ScratchStrokeGeometry.rawRange`),
    /// passed so the `.performedPlatter` row normalizes its measured strokes
    /// against the SAME platter Y frame as the target. `nil` falls back to the
    /// performed content's own min/max (the historical, data-driven frame).
    var performedFrame: ClosedRange<CGFloat>? = nil

    /// The performed side's platter-path style — the accent-blue trace that
    /// reads stronger than the muted target. Forward and backward share one
    /// hue so direction stays geometric (slope + chevrons), not colour.
    private static let performedStyle = ScratchMotionRenderer.Style.performance

    // Lane background + grid palette — shared across target/captured paths,
    // resolved through the token layer so the two lane canvases stay distinct.
    /// Lane background override. `nil` renders the target canvas (`#101013`)
    /// so pre-existing call sites keep their behaviour; the performance lane
    /// passes `Notation.performanceCanvas` (`#0E131B`).
    var backgroundColor: Color? = nil
    private var bgColor: Color { backgroundColor ?? ScratchLabDesign.Notation.targetCanvas }
    private let gridMajor  = ScratchLabDesign.Notation.gridBeat
    private let gridMinor  = ScratchLabDesign.Notation.gridSubdivision
    // Captured-path stroke palette (kept; the captured path still draws its
    // own single-diagonal record-events because they aren't authored strokes).
    private let forwardCol = ScratchLabDesign.Notation.forward
    private let backCol    = ScratchLabDesign.Notation.backward
    private let dotCol     = ScratchLabDesign.Notation.dot
    private let laneDividerCol = ScratchLabDesign.Notation.lineNeutral

    // Fraction of the chart vertically reserved for the fader sub-lane.
    // The strokes region gets the remaining (1 - faderLaneFraction).
    private let faderLaneFraction: CGFloat = 0.30

    var body: some View {
        switch source {
        case .target:
            ScratchLabPerformanceSignpost.event("TargetNotationRender")
        case .captured(let events):
            ScratchLabPerformanceSignpost.event("CapturedNotationRender", count: events.count)
        case .performedPlatter(let events):
            ScratchLabPerformanceSignpost.event("PerformedPlatterRender", count: events.count)
        case .canonical:
            break
        case .empty:
            break
        }
        return Canvas { ctx, size in
            guard size.width > 0, size.height > 0 else { return }
            switch source {
            case .target(let notation):           drawTarget(ctx: ctx, size: size, notation: notation)
            case .captured(let events):           drawCaptured(ctx: ctx, size: size, events: events)
            case .performedPlatter(let events):   drawPerformedPlatter(ctx: ctx, size: size, events: events)
            case .canonical(let records, let layer, let frame):
                drawCanonical(ctx: ctx, size: size, records: records, layer: layer, frame: frame)
            case .empty(let message):             drawEmpty(ctx: ctx, size: size, message: message)
            }
        }
        .background(bgColor)
    }

    // MARK: - Target (ScratchNotation)

    private func drawCanonical(ctx: GraphicsContext, size: CGSize,
                               records: [ScratchNotation.GestureRecord],
                               layer: ScratchStrokeGeometry.CanonicalLayer,
                               frame: ScratchStrokeGeometry.CanonicalFrame) {
        let geometry = ScratchStrokeGeometry.canonicalGeometry(records: records, layer: layer, frame: frame)
        let start = frame.timeRange.lowerBound
        let duration = frame.timeRange.upperBound - start
        let pps = size.width / CGFloat(duration)
        let platterHeight = size.height * (1 - faderLaneFraction)
        let style: ScratchMotionRenderer.Style = layer == .target ? .target : .performance
        drawBeatGrid(ctx: ctx, size: size, startTime: start, duration: duration, pps: pps,
                     labelBottomY: platterHeight - 2, beatsPerMinute: frame.beatsPerMinute)
        let viewport = LaneViewport(size: CGSize(width: size.width, height: platterHeight),
                                    now: start, axis: .horizontal, actionLineFraction: 0,
                                    secondsAhead: duration)
        var platterContext = ctx
        platterContext.clip(to: Path(CGRect(origin: .zero, size: viewport.size)))
        ScratchMotionRenderer.draw(geometry.motion, in: platterContext, viewport: viewport, style: style)
        drawUnknownIntervals(geometry.missingMotion, label: "MOTION UNKNOWN", ctx: platterContext,
                             start: start, pps: pps, top: 16, height: max(0, platterHeight - 30))
        ctx.draw(Text("PLATTER").font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(Color(white: 0.42)), at: CGPoint(x: 4, y: 3), anchor: .topLeading)
        drawLaneDivider(ctx: ctx, size: size, y: platterHeight)

        let faderHeight = size.height - platterHeight
        let openY = platterHeight + faderHeight * 0.15
        let closedY = platterHeight + faderHeight * 0.88
        for y in [openY, closedY] {
            var guide = Path()
            guide.move(to: CGPoint(x: 0, y: y)); guide.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(guide, with: .color(Color(white: 0.28).opacity(0.16)), lineWidth: 0.5)
        }
        for interval in geometry.fader {
            guard let state = interval.state else { continue }
            let y = state == .open ? openY : closedY
            var rail = Path()
            rail.move(to: CGPoint(x: CGFloat(interval.range.lowerBound - start) * pps, y: y))
            rail.addLine(to: CGPoint(x: CGFloat(interval.range.upperBound - start) * pps, y: y))
            ctx.stroke(rail, with: .color(style.color.opacity(0.78)), lineWidth: 2.5)
        }
        drawUnknownIntervals(geometry.fader.filter { $0.state == nil }.map(\.range),
                             label: "FADER UNKNOWN", ctx: ctx, start: start, pps: pps,
                             top: openY, height: closedY - openY)
        // Fader glyphs come ONLY from explicit supported fader transitions.
        // A hold, reversal or two differently coloured rails cannot mint one.
        for edge in geometry.faderEdges {
            let x = CGFloat(edge.time - start) * pps
            let y = edge.state == .open ? openY : closedY
            var tick = Path()
            tick.move(to: CGPoint(x: x, y: openY)); tick.addLine(to: CGPoint(x: x, y: closedY))
            ctx.stroke(tick, with: .color(style.color.opacity(0.5)), lineWidth: 1.2)
            var diamond = Path()
            diamond.move(to: CGPoint(x: x, y: y - 2.5))
            diamond.addLine(to: CGPoint(x: x + 2.5, y: y))
            diamond.addLine(to: CGPoint(x: x, y: y + 2.5))
            diamond.addLine(to: CGPoint(x: x - 2.5, y: y))
            diamond.closeSubpath()
            ctx.fill(diamond, with: .color(style.color.opacity(0.65)))
        }
        ctx.draw(Text("FADER").font(.system(size: 8.5, weight: .bold, design: .monospaced))
            .foregroundStyle(Color(white: 0.40)), at: CGPoint(x: 4, y: platterHeight), anchor: .bottomLeading)
        for (label, y, anchor) in [("OPEN", openY + 1, UnitPoint.topLeading),
                                   ("CLOSED", closedY - 1, UnitPoint.bottomLeading)] {
            ctx.draw(Text(label).font(.system(size: 7.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(white: 0.32)), at: CGPoint(x: 4, y: y), anchor: anchor)
        }
        if geometry.hasUnplacedEvidence {
            ctx.draw(Text("UNPLACED / INVALID EVIDENCE").font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Color(white: 0.65)), at: CGPoint(x: size.width - 4, y: 3), anchor: .topTrailing)
        }
        if showPlayhead {
            drawPlayhead(ctx: ctx, size: size, x: CGFloat(playheadTime - start) * pps)
        }
    }

    /// Unknown spans are shaded bands with a question mark, never a line at a
    /// made-up platter position or fader rail. Narrow gaps remain visible.
    private func drawUnknownIntervals(_ ranges: [ClosedRange<Double>], label: String,
                                      ctx: GraphicsContext, start: Double, pps: CGFloat,
                                      top: CGFloat, height: CGFloat) {
        for range in ranges {
            let x = CGFloat(range.lowerBound - start) * pps
            let width = CGFloat(range.upperBound - range.lowerBound) * pps
            let rect = CGRect(x: x, y: top, width: width, height: height)
            ctx.fill(Path(rect), with: .color(Color.gray.opacity(0.12)))
            ctx.stroke(Path(rect), with: .color(Color.gray.opacity(0.4)),
                       style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
            if width >= 8 {
                ctx.draw(Text(width >= 100 ? label : "?").font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(Color(white: 0.6)), at: CGPoint(x: rect.midX, y: rect.midY))
            }
        }
    }

    private func drawTarget(ctx: GraphicsContext, size: CGSize, notation: ScratchNotation) {
        let full = max(notation.timelineDuration, 0.1)
        // Resolve render-time window. Nil = full phrase (existing behaviour).
        // Clamp to the phrase and guarantee a minimum 0.1s span so pps is finite.
        let windowStart = max(0, min(full, targetWindow?.lowerBound ?? 0))
        let windowEnd = max(windowStart + 0.1, min(full, targetWindow?.upperBound ?? full))
        let duration = windowEnd - windowStart
        let pps = size.width / CGFloat(duration)
        let strokeRegionHeight = size.height * (1 - faderLaneFraction)

        drawBeatGrid(ctx: ctx, size: size,
                     startTime: windowStart, duration: duration, pps: pps,
                     labelBottomY: strokeRegionHeight - 2)

        // Strokes + holds + apex nodes via the shared angular renderer — the
        // identical language used by the iOS lane. The viewport spans the
        // chosen `[windowStart, windowEnd]` slice at fixed pps (static, no
        // scrolling). With actionLineFraction = 0, time `now = windowStart`
        // lands at the left edge and the pattern stretches rightward; the
        // renderer never draws a per-frame action line, so no "now" marker
        // bleeds into this static reference. Strokes outside the window are
        // skipped by `LaneViewport.isVisible(from:to:)` inside the renderer.
        let strokeRegion = CGSize(width: size.width, height: strokeRegionHeight)
        let viewport = LaneViewport(
            size: strokeRegion,
            now: windowStart,
            axis: .horizontal,
            actionLineFraction: 0,
            secondsAhead: duration)
        let laneContent = LaneContent(notation: notation, beatsPerMinute: bpm)
        let motionPath = ScratchStrokeGeometry.motionPath(for: laneContent)
        ScratchMotionRenderer.draw(motionPath, in: ctx, viewport: viewport,
                                    style: .target)

        // Per-stroke directional chevrons keep FORWARD / BACKWARD readable
        // without reusing the fader-transition diamond on platter reversals.
        // A diamond is reserved for a real OPEN/CLOSED fader transition.
        drawPlatterDirectionCues(ctx: ctx, strokes: laneContent.strokes,
                                  windowStart: windowStart, pps: pps,
                                  strokeRegionHeight: strokeRegionHeight)

        drawLivePerformedOverlay(
            ctx: ctx,
            size: strokeRegion,
            events: livePerformedEvents,
            windowStart: windowStart,
            duration: duration,
            targetFrame: ScratchStrokeGeometry.rawRange(for: laneContent)
        )

        // PLATTER lane label — top-left anchor at the head of the stroke region
        ctx.draw(
            Text("PLATTER")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(white: 0.42)),
            at: CGPoint(x: 4, y: 3),
            anchor: .topLeading
        )

        drawLaneDivider(ctx: ctx, size: size, y: strokeRegionHeight)
        drawTargetFaderLane(ctx: ctx, size: size, notation: notation,
                             documentEnd: full,
                             windowStart: windowStart, windowEnd: windowEnd,
                             pps: pps, strokeRegionTop: strokeRegionHeight)

        if let overlay = comparisonOverlay {
            drawComparisonOverlay(ctx: ctx, size: size, overlay: overlay,
                                  windowStart: windowStart, windowEnd: windowEnd,
                                  pps: pps, strokeRegionHeight: strokeRegionHeight)
        }

        if showPlayhead {
            drawPlayhead(ctx: ctx, size: size,
                         x: CGFloat(playheadTime - windowStart) * pps)
        }
    }

    /// Draws the live take with the same motion-path renderer as Review, but
    /// without adding a second grid, label set, or fader lane. The target is
    /// already the chart substrate; this layer contributes only measured
    /// platter motion in the stronger performance colour.
    private func drawLivePerformedOverlay(
        ctx: GraphicsContext,
        size: CGSize,
        events: [CaptureCore.DetectedNotationRecordMovementEvent],
        windowStart: TimeInterval,
        duration: TimeInterval,
        targetFrame: ClosedRange<CGFloat>
    ) {
        let strokes = events.compactMap(PerformedStrokeAdapter.laneStroke)
        guard !strokes.isEmpty else { return }

        let content = LaneContent(
            strokes: strokes,
            segments: [],
            beatsPerMinute: bpm,
            duration: max(windowStart + duration, 0.001),
            loops: false
        )
        let path = ScratchStrokeGeometry.motionPath(
            for: content,
            normalizingTo: targetFrame
        )
        let viewport = LaneViewport(
            size: size,
            now: windowStart,
            axis: .horizontal,
            actionLineFraction: 0,
            secondsAhead: duration
        )
        ScratchMotionRenderer.draw(
            path,
            in: ctx,
            viewport: viewport,
            style: Self.performedStyle
        )
    }

    // MARK: - Captured (recordMovementEvents)

    private func drawCaptured(ctx: GraphicsContext, size: CGSize,
                               events: [CaptureCore.DetectedNotationRecordMovementEvent]) {
        guard !events.isEmpty else {
            drawEmpty(ctx: ctx, size: size, message: "No movement data")
            return
        }

        // Displayed time window. A caller-supplied `capturedWindow` (the
        // stacked comparison's COMMON domain, authored by the target) always
        // wins — captured events may extend outside it, but never silently
        // rescale the performed chart. Without one, the chart fits the
        // captured take's own span as before.
        let windowStart: Double
        let duration: Double
        if let capturedWindow {
            windowStart = capturedWindow.lowerBound
            duration = max(capturedWindow.upperBound - capturedWindow.lowerBound, 0.1)
        } else {
            windowStart = 0
            duration = max(events.map(\.endTime).max() ?? 1.0, 0.1)
        }
        let pps = size.width / CGFloat(duration)
        // Baseline sits near the bottom of the chart; strokes rise above it proportionally
        // to the actual platter/hand travel distance — short scratches stay short.
        let baseline = size.height * CGFloat(CapturedNotationStrokeGeometry.baselineFraction)
        let maxBand  = size.height * CGFloat(CapturedNotationStrokeGeometry.maxBandFraction)

        drawBeatGrid(ctx: ctx, size: size, startTime: windowStart, duration: duration, pps: pps,
                     labelBottomY: size.height - 2)

        for event in events {
            let x1 = CGFloat(event.startTime - windowStart) * pps
            let x2 = CGFloat(event.endTime - windowStart) * pps
            guard x2 > x1 else { continue }

            let travel = CGFloat(
                ControllerGestureNotationDisplayScale.displayTravelFraction(
                    for: event
                )
            )
            guard travel > 0 else { continue }  // idle / no movement: draw nothing

            let isForward = event.direction == "forward"
            // All strokes live ABOVE the baseline; forward `/` rises from baseline at x1
            // to peak at x2, backward `\` falls from peak at x1 to baseline at x2.
            let peak = baseline - travel * maxBand
            let (p1, p2): (CGPoint, CGPoint) = isForward
                ? (CGPoint(x: x1, y: baseline), CGPoint(x: x2, y: peak))
                : (CGPoint(x: x1, y: peak),     CGPoint(x: x2, y: baseline))
            let color = isForward ? forwardCol : backCol
            let alpha = 0.55 + event.confidence * 0.45

            var path = Path()
            path.move(to: p1)
            path.addLine(to: p2)
            ctx.stroke(path, with: .color(color.opacity(alpha)), lineWidth: 2.5)
            drawDots(ctx: ctx, p1: p1, p2: p2, alpha: alpha)
        }

        drawCapturedAxisLabels(ctx: ctx, size: size, baseline: baseline, maxBand: maxBand)

        if showPlayhead {
            drawPlayhead(ctx: ctx, size: size, x: CGFloat(playheadTime - windowStart) * pps)
        }
    }

    // MARK: - Performed platter (stacked MY PERFORMANCE row)

    /// Renders measured captured strokes through the SAME platter-position
    /// geometry as `.target` (`ScratchStrokeGeometry.motionPath` →
    /// `ScratchMotionRenderer`), in the performed accent style. The displayed
    /// time window is the common comparison domain when `capturedWindow` is
    /// set, so a given musical time maps to the same x as the target row.
    private func drawPerformedPlatter(ctx: GraphicsContext, size: CGSize,
                                      events: [CaptureCore.DetectedNotationRecordMovementEvent]) {
        // Common domain wins when set (stacked comparison); otherwise fit the
        // captured take's own span, as before.
        let windowStart: Double
        let duration: Double
        if let capturedWindow {
            windowStart = capturedWindow.lowerBound
            duration = max(capturedWindow.upperBound - capturedWindow.lowerBound, 0.1)
        } else {
            windowStart = 0
            duration = max(events.map(\.endTime).max() ?? 1.0, 0.1)
        }
        let pps = size.width / CGFloat(duration)
        let strokeRegionHeight = size.height * (1 - faderLaneFraction)

        drawBeatGrid(ctx: ctx, size: size, startTime: windowStart, duration: duration, pps: pps,
                     labelBottomY: strokeRegionHeight - 2)

        // Measured strokes → shared platter geometry. Indeterminate-direction
        // and non-stroke events are dropped — never fabricated.
        let laneStrokes = events.compactMap(PerformedStrokeAdapter.laneStroke)
        guard !laneStrokes.isEmpty else {
            // Distinguish "nothing measured" from "movement measured but its
            // direction wasn't resolved" — never fabricate a flat line or a
            // guessed direction.
            let emptyMessage = events.isEmpty ? "No measured movement" : "DIRECTION UNAVAILABLE"
            drawEmpty(ctx: ctx, size: size, message: emptyMessage)
            return
        }

        let strokeRegion = CGSize(width: size.width, height: strokeRegionHeight)
        let viewport = LaneViewport(size: strokeRegion, now: windowStart, axis: .horizontal,
                                    actionLineFraction: 0, secondsAhead: duration)
        let content = LaneContent(strokes: laneStrokes, segments: [], beatsPerMinute: bpm,
                                  duration: duration, loops: false)
        // The target's vertical frame stabilizes the performed row: measured
        // strokes normalize against it so a sparse take never rescales its own
        // min/max (which would move the neutral position off-centre).
        let motionPath: MotionPath
        if let performedFrame {
            motionPath = ScratchStrokeGeometry.motionPath(for: content, normalizingTo: performedFrame)
        } else if let gestureFrame = PerformedStrokeAdapter.gestureRelativeNormalizationFrame(
            for: events
        ) {
            // Gesture-relative controller notation owns a stable one-revolution
            // frame. Do not normalize against the take's extrema: a multi-turn
            // motor run would otherwise shrink every later scratch even though
            // their local baselines are correct.
            motionPath = ScratchStrokeGeometry.motionPath(
                for: content,
                normalizingTo: gestureFrame
            )
        } else {
            motionPath = ScratchStrokeGeometry.motionPath(for: content)
        }
        ScratchMotionRenderer.draw(motionPath, in: ctx, viewport: viewport,
                                    style: Self.performedStyle)

        drawPlatterDirectionCues(ctx: ctx, strokes: laneStrokes,
                                  windowStart: windowStart, pps: pps,
                                  strokeRegionHeight: strokeRegionHeight)

        ctx.draw(
            Text("PLATTER")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(white: 0.42)),
            at: CGPoint(x: 4, y: 3),
            anchor: .topLeading
        )

        drawLaneDivider(ctx: ctx, size: size, y: strokeRegionHeight)
        drawPerformedFaderLane(ctx: ctx, size: size, strokeRegionTop: strokeRegionHeight,
                               windowStart: windowStart, windowEnd: windowStart + duration,
                               pps: pps)

        if showPlayhead {
            drawPlayhead(ctx: ctx, size: size, x: CGFloat(playheadTime - windowStart) * pps)
        }
    }

    /// Fader sub-lane for the performed row — the same guide rails + OPEN/CLOSED
    /// labels as the target so the two rows stay vertically comparable, but no
    /// active rail unless real captured fader spans are present. When absent,
    /// an honest subdued "Fader not captured" state replaces any invented
    /// open line.
    private func drawPerformedFaderLane(ctx: GraphicsContext, size: CGSize,
                                        strokeRegionTop: CGFloat,
                                        windowStart: Double, windowEnd: Double,
                                        pps: CGFloat) {
        let laneHeight = size.height - strokeRegionTop
        let topY = strokeRegionTop + laneHeight * 0.15
        let bottomY = strokeRegionTop + laneHeight * 0.88
        let guideAlpha: Double = 0.16

        ctx.draw(
            Text("FADER")
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(white: 0.40)),
            at: CGPoint(x: 4, y: strokeRegionTop),
            anchor: .bottomLeading
        )

        for y in [topY, bottomY] {
            var guide = Path()
            guide.move(to: CGPoint(x: 0, y: y))
            guide.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(guide, with: .color(Color(white: 0.28).opacity(guideAlpha)), lineWidth: 0.5)
        }

        ctx.draw(
            Text("OPEN")
                .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(white: 0.32)),
            at: CGPoint(x: 4, y: topY + 1),
            anchor: .topLeading
        )
        ctx.draw(
            Text("CLOSED")
                .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(white: 0.32)),
            at: CGPoint(x: 4, y: bottomY - 1),
            anchor: .bottomLeading
        )

        if performedFaderSpans.isEmpty {
            ctx.draw(
                Text("FADER DATA NOT CAPTURED")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(white: 0.52)),
                at: CGPoint(x: size.width / 2, y: (topY + bottomY) / 2),
                anchor: .center
            )
            return
        }

        // Trustworthy captured fader evidence — draw open/closed rails with
        // vertical transitions, matching the target lane's grammar.
        let merged = mergeAdjacentFaderSpans(performedFaderSpans)
        var previousState: ScratchNotationFaderState? = nil
        for span in merged {
            guard span.endTime > windowStart, span.startTime < windowEnd,
                  span.endTime > span.startTime else { continue }
            let x1 = CGFloat(max(span.startTime, windowStart) - windowStart) * pps
            let x2 = CGFloat(min(span.endTime, windowEnd) - windowStart) * pps
            guard x2 > x1 else { continue }

            let activeY = span.state == .open ? topY : bottomY
            // Active rail is the performed trace colour (cyan) — position +
            // transition encode OPEN/CLOSED, not a status colour.
            let activeColor: Color = ScratchLabDesign.Notation.performanceTrace

            var rail = Path()
            rail.move(to: CGPoint(x: x1, y: activeY))
            rail.addLine(to: CGPoint(x: x2, y: activeY))
            ctx.stroke(rail, with: .color(activeColor.opacity(0.78)), lineWidth: 2.5)

            if let prev = previousState, prev != span.state {
                let prevY = prev == .open ? topY : bottomY
                var trans = Path()
                trans.move(to: CGPoint(x: x1, y: prevY))
                trans.addLine(to: CGPoint(x: x1, y: activeY))
                ctx.stroke(trans, with: .color(Color(white: 0.75).opacity(0.50)), lineWidth: 1.2)
            }
            previousState = span.state
        }
    }

    // MARK: - Target-vs-performed overlay

    /// Verdict palette — the SAME colours `NotationFeedbackStyle` uses for the
    /// iOS lane's live feedback overlay, so a verdict reads identically on
    /// both surfaces. Missing marks are the dim `.missed` white; extra marks
    /// the neutral user-mark white.
    private static let verdictCorrectCol = Color(red: 0.20, green: 0.88, blue: 0.55)
    private static let verdictEarlyCol   = Color(red: 0.85, green: 0.65, blue: 0.15)
    private static let verdictLateCol    = Color(red: 1.00, green: 0.55, blue: 0.10)
    private static let verdictWrongDirCol = Color(red: 0.80, green: 0.35, blue: 0.35)
    private static let verdictMissingCol = Color(white: 0.40)
    private static let verdictExtraCol   = Color(white: 0.85)
    /// Boundary (setup / incomplete) strokes render dim and de-emphasized —
    /// they are retained evidence, never scored, so they read as context
    /// rather than as an ordinary in-phrase verdict.
    private static let verdictBoundaryCol = Color(white: 0.55)

    /// Fixed amplitude for performed-stroke slashes. Beat-domain comparison
    /// marks carry no travel evidence (the normalization deliberately drops
    /// positions), so a constant mid-band height states "when and which way",
    /// never a fabricated "how far".
    private static let overlayTravelFraction: CGFloat = 0.62

    private func verdictColor(for kind: ScratchComparisonOverlay.MarkKind) -> Color {
        switch kind {
        case .matched(let timing, let directionCorrect):
            if directionCorrect == false { return Self.verdictWrongDirCol }
            switch timing {
            case .correct: return Self.verdictCorrectCol
            case .early:   return Self.verdictEarlyCol
            case .late:    return Self.verdictLateCol
            }
        case .missingTarget:  return Self.verdictMissingCol
        case .extraPerformed: return Self.verdictExtraCol
        case .boundarySetup, .boundaryIncomplete: return Self.verdictBoundaryCol
        }
    }

    /// Draws the performed side of a target-vs-performed comparison over the
    /// target chart: each performed mark is a single diagonal slash in the
    /// captured chart's direction language (green `/` forward, orange `\`
    /// backward; direction-indeterminate marks draw a flat dash — no
    /// direction is invented), with a verdict dot at the mark's start on the
    /// baseline. Missing target slots draw a hollow verdict circle at the
    /// unplayed slot instead of a slash — nothing was performed there.
    /// Performed fader edges draw as verdict-coloured ticks in the
    /// fader sub-lane; missing target edges draw hollow.
    private func drawComparisonOverlay(ctx: GraphicsContext, size: CGSize,
                                       overlay: ScratchComparisonOverlay,
                                       windowStart: Double, windowEnd: Double,
                                       pps: CGFloat, strokeRegionHeight: CGFloat) {
        let baseline = strokeRegionHeight * CGFloat(CapturedNotationStrokeGeometry.baselineFraction)
        let maxBand = strokeRegionHeight * CGFloat(CapturedNotationStrokeGeometry.maxBandFraction)
        let peakRise = maxBand * Self.overlayTravelFraction
        let dotRadius: CGFloat = 3.5

        for mark in overlay.strokeMarks {
            guard mark.endTime > windowStart, mark.startTime < windowEnd else { continue }
            let x1 = CGFloat(mark.startTime - windowStart) * pps
            let x2 = CGFloat(mark.endTime - windowStart) * pps
            let color = verdictColor(for: mark.kind)

            if case .missingTarget = mark.kind {
                // Unplayed slot: hollow circle at the slot start, no slash.
                let rect = CGRect(x: x1 - dotRadius, y: baseline - dotRadius,
                                  width: dotRadius * 2, height: dotRadius * 2)
                ctx.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: 1.5)
                continue
            }

            // Performed slash — captured-chart language.
            let peak = baseline - peakRise
            var slash = Path()
            switch mark.direction {
            case .forward:
                slash.move(to: CGPoint(x: x1, y: baseline))
                slash.addLine(to: CGPoint(x: max(x2, x1 + 1), y: peak))
            case .backward:
                slash.move(to: CGPoint(x: x1, y: peak))
                slash.addLine(to: CGPoint(x: max(x2, x1 + 1), y: baseline))
            case nil:
                // Direction indeterminate — a flat mid-band dash, no slope.
                let mid = baseline - peakRise * 0.5
                slash.move(to: CGPoint(x: x1, y: mid))
                slash.addLine(to: CGPoint(x: max(x2, x1 + 1), y: mid))
            }
            let isBoundary: Bool
            switch mark.kind {
            case .boundarySetup, .boundaryIncomplete: isBoundary = true
            case .matched, .missingTarget, .extraPerformed: isBoundary = false
            }
            let slashColor: Color = isBoundary
                ? Self.verdictBoundaryCol
                : (mark.direction == .backward ? backCol : forwardCol)
            ctx.stroke(slash, with: .color(slashColor.opacity(isBoundary ? 0.45 : 0.85)),
                       style: StrokeStyle(lineWidth: 2.5, lineCap: .round,
                                          dash: mark.direction == nil ? [4, 3] : []))

            // Verdict dot at the mark start, on the baseline.
            let dot = CGRect(x: x1 - dotRadius, y: baseline - dotRadius,
                             width: dotRadius * 2, height: dotRadius * 2)
            ctx.fill(Path(ellipseIn: dot), with: .color(color))
        }

        // Performed fader edges — ticks in the fader sub-lane.
        let laneTop = strokeRegionHeight + 2
        let laneBottom = size.height - 2
        for mark in overlay.faderMarks {
            guard mark.time >= windowStart, mark.time <= windowEnd,
                  laneBottom > laneTop else { continue }
            let x = CGFloat(mark.time - windowStart) * pps
            let color = verdictColor(for: mark.kind)
            let tick = CGRect(x: x - 1, y: laneTop, width: 2, height: laneBottom - laneTop)
            if case .missingTarget = mark.kind {
                ctx.stroke(Path(roundedRect: tick, cornerRadius: 1),
                           with: .color(color), lineWidth: 1)
            } else {
                ctx.fill(Path(roundedRect: tick, cornerRadius: 1), with: .color(color))
            }
        }
    }

    // MARK: - Helpers

    private func drawDots(ctx: GraphicsContext, p1: CGPoint, p2: CGPoint, alpha: Double = 1) {
        let r: CGFloat = 4
        ctx.fill(Path(ellipseIn: CGRect(x: p1.x - r, y: p1.y - r, width: r * 2, height: r * 2)),
                 with: .color(dotCol.opacity(alpha)))
        ctx.fill(Path(ellipseIn: CGRect(x: p2.x - r, y: p2.y - r, width: r * 2, height: r * 2)),
                 with: .color(dotCol.opacity(alpha)))
    }

    private func drawBeatGrid(ctx: GraphicsContext, size: CGSize,
                              startTime: Double = 0,
                              duration: Double, pps: CGFloat,
                              labelBottomY: CGFloat, beatsPerMinute: Double? = nil) {
        guard showBeatGrid else { return }
        let beatInterval = 60.0 / (beatsPerMinute ?? max(bpm, 1))
        let subdivInterval = beatInterval / 2  // eighth-note subdivision

        // Width-aware density. Subdivisions only appear when a beat is wide
        // enough to read them; labels thin independently of the line grid.
        let beatSpacing = CGFloat(beatInterval) * pps
        let minLabelGap: CGFloat = 26
        let labelStride = max(1, Int((minLabelGap / max(beatSpacing, 0.5)).rounded(.up)))
        let showSubdivisions = beatSpacing >= 9

        let gridStep = showSubdivisions ? subdivInterval : beatInterval
        let endTime = startTime + duration
        var index = Int((startTime / gridStep).rounded(.down))
        var t = Double(index) * gridStep
        while t <= endTime + gridStep * 0.5 {
            let x = CGFloat(t - startTime) * pps
            if x >= 0 && x <= size.width {
                let beatIndex = Int((t / beatInterval).rounded())
                let onBeat = abs(t - Double(beatIndex) * beatInterval) < beatInterval * 0.25
                let isBar = onBeat && beatIndex % 4 == 0

                // Bar > beat > subdivision, by weight and opacity — a quiet
                // hierarchy from the canonical beat grid, never decorative.
                let lineColor: Color
                let lineWidth: CGFloat
                let lineOpacity: Double
                if isBar {
                    lineColor = gridMajor; lineWidth = 0.9;  lineOpacity = 1.0
                } else if onBeat {
                    lineColor = gridMajor; lineWidth = 0.45; lineOpacity = 0.7
                } else {
                    lineColor = gridMinor; lineWidth = 0.25; lineOpacity = 0.5
                }

                var line = Path()
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(line, with: .color(lineColor.opacity(lineOpacity)), lineWidth: lineWidth)

                // Numerals track absolute timeline beats; subdivisions carry none.
                if onBeat, beatIndex > 0, beatIndex % labelStride == 0 {
                    ctx.draw(
                        Text("\(beatIndex)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color(white: 0.55)),
                        at: CGPoint(x: x + 2, y: labelBottomY),
                        anchor: .bottomLeading
                    )
                }
            }
            t += gridStep
            index += 1
        }
    }

    private func drawLaneDivider(ctx: GraphicsContext, size: CGSize, y: CGFloat) {
        var line = Path()
        line.move(to: CGPoint(x: 0, y: y))
        line.addLine(to: CGPoint(x: size.width, y: y))
        ctx.stroke(line, with: .color(laneDividerCol), lineWidth: 0.5)
    }

    private func drawTargetFaderLane(ctx: GraphicsContext, size: CGSize,
                                      notation: ScratchNotation,
                                      documentEnd: Double,
                                      windowStart: Double,
                                      windowEnd: Double,
                                      pps: CGFloat,
                                      strokeRegionTop: CGFloat) {
        let laneHeight = size.height - strokeRegionTop
        let topY    = strokeRegionTop + laneHeight * 0.15
        let bottomY = strokeRegionTop + laneHeight * 0.88
        let guideAlpha: Double = 0.16
        let activeAlpha: Double = 0.78
        let transitionAlpha: Double = 0.50

        // FADER label anchored above the divider — sits in the bottom margin
        // of the platter region so it never competes with OPEN/CLOSED below.
        ctx.draw(
            Text("FADER")
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(white: 0.40)),
            at: CGPoint(x: 4, y: strokeRegionTop),
            anchor: .bottomLeading
        )

        // Guide rails — faint lines for OPEN (top) and CLOSED (bottom).
        // Labels are drawn AFTER the active-rail loop so they sit on top.
        for y in [topY, bottomY] {
            var guide = Path()
            guide.move(to: CGPoint(x: 0, y: y))
            guide.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(guide, with: .color(Color(white: 0.28).opacity(guideAlpha)),
                       lineWidth: 0.5)
        }

        let faderSpans = notation.faderAuthoritySpans(documentEnd: documentEnd)
        guard !faderSpans.isEmpty else {
            // Lane stays visible per V2 spec even with no fader spans —
            // the guide rails and labels above already render.
            return
        }

        let merged = mergeAdjacentFaderSpans(faderSpans)
        var previousState: ScratchNotationFaderState? = nil

        for span in merged {
            guard span.endTime > windowStart, span.startTime < windowEnd,
                  span.endTime > span.startTime else { continue }
            let x1 = CGFloat(max(span.startTime, windowStart) - windowStart) * pps
            let x2 = CGFloat(min(span.endTime, windowEnd) - windowStart) * pps
            guard x2 > x1 else { continue }

            let activeY = span.state == .open ? topY : bottomY
            // Active rail is the target trace colour (bone). OPEN/CLOSED is
            // encoded by rail position + the vertical transition — never by a
            // green/red status colour (Figma: fader state is structural).
            let activeColor: Color = ScratchLabDesign.Notation.targetTrace

            var rail = Path()
            rail.move(to: CGPoint(x: x1, y: activeY))
            rail.addLine(to: CGPoint(x: x2, y: activeY))
            ctx.stroke(rail, with: .color(activeColor.opacity(activeAlpha)), lineWidth: 2.5)

            // Vertical transition when state changes
            if let prev = previousState, prev != span.state {
                let prevY = prev == .open ? topY : bottomY
                var trans = Path()
                trans.move(to: CGPoint(x: x1, y: prevY))
                trans.addLine(to: CGPoint(x: x1, y: activeY))
                ctx.stroke(trans, with: .color(Color(white: 0.75).opacity(transitionAlpha)),
                           lineWidth: 1.2)
                let d: CGFloat = 2.5
                var diamond = Path()
                diamond.move(to: CGPoint(x: x1, y: activeY - d))
                diamond.addLine(to: CGPoint(x: x1 + d, y: activeY))
                diamond.addLine(to: CGPoint(x: x1, y: activeY + d))
                diamond.addLine(to: CGPoint(x: x1 - d, y: activeY))
                diamond.closeSubpath()
                ctx.fill(diamond, with: .color(Color(white: 0.82).opacity(transitionAlpha)))
            }
            previousState = span.state
        }

        // Rail labels drawn AFTER active rails so they sit on top.
        // OPEN sits just below the open rail; CLOSED sits just above
        // the closed rail. At 80pt Practice Live height these do not
        // overlap with each other or with FADER above.
        ctx.draw(
            Text("OPEN")
                .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(white: 0.32)),
            at: CGPoint(x: 4, y: topY + 1),
            anchor: .topLeading
        )
        ctx.draw(
            Text("CLOSED")
                .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(white: 0.32)),
            at: CGPoint(x: 4, y: bottomY - 1),
            anchor: .bottomLeading
        )
    }

    /// Restrained directional chevrons on the platter lane — a small up chevron
    /// at each forward stroke's apex and a down chevron at each backward
    /// stroke's trough. Direction reads from the chevron's geometry alone (no
    /// colour), matching the shared renderer's cross-axis mapping; the
    /// continuous platter-position path stays the primary object.
    private func drawPlatterDirectionCues(ctx: GraphicsContext,
                                           strokes: [LaneStroke],
                                           windowStart: Double,
                                           pps: CGFloat,
                                           strokeRegionHeight: CGFloat) {
        let inset = strokeRegionHeight * ScratchMotionRenderer.crossInsetFraction
        let topRailY = inset                              // forward apex (position 1.0)
        let bottomRailY = strokeRegionHeight - inset      // backward trough (position 0.0)
        let chevron: CGFloat = 4.0
        let colour = Color(white: 0.85).opacity(0.70)

        for stroke in strokes.sorted(by: { $0.startTime < $1.startTime }) {
            let x = CGFloat(((stroke.startTime + stroke.endTime) / 2) - windowStart) * pps
            guard x >= -10 else { continue }
            var chevronPath = Path()
            switch stroke.direction {
            case .forward:
                // "∧" just below the forward apex, pointing up.
                let y = topRailY + chevron + 2
                chevronPath.move(to: CGPoint(x: x - chevron, y: y + chevron))
                chevronPath.addLine(to: CGPoint(x: x, y: y - chevron))
                chevronPath.addLine(to: CGPoint(x: x + chevron, y: y + chevron))
            case .backward:
                // "∨" just above the backward trough, pointing down.
                let y = bottomRailY - chevron - 2
                chevronPath.move(to: CGPoint(x: x - chevron, y: y - chevron))
                chevronPath.addLine(to: CGPoint(x: x, y: y + chevron))
                chevronPath.addLine(to: CGPoint(x: x + chevron, y: y - chevron))
            }
            ctx.stroke(chevronPath,
                       with: .color(colour),
                       style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        }
    }

    private func mergeAdjacentFaderSpans(_ spans: [LaneFaderSpan]) -> [LaneFaderSpan] {
        guard spans.count > 1 else { return spans }
        let sorted = spans.sorted { $0.startTime < $1.startTime }
        var merged: [LaneFaderSpan] = [sorted[0]]
        for span in sorted.dropFirst() {
            let last = merged[merged.count - 1]
            if span.state == last.state, abs(span.startTime - last.endTime) < 0.001 {
                merged[merged.count - 1] = LaneFaderSpan(
                    startTime: last.startTime,
                    endTime: span.endTime,
                    state: last.state
                )
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    private func drawCapturedAxisLabels(ctx: GraphicsContext, size: CGSize,
                                         baseline: CGFloat, maxBand: CGFloat) {
        // Both directions peak above the baseline; labels sit near the top of the band
        // so they read alongside their respective stroke directions without overlapping strokes.
        ctx.draw(
            Text("FWD")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(forwardCol.opacity(0.55)),
            at: CGPoint(x: 4, y: baseline - maxBand * 0.92),
            anchor: .leading
        )
        ctx.draw(
            Text("BACK")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(backCol.opacity(0.55)),
            at: CGPoint(x: 4, y: baseline - maxBand * 0.72),
            anchor: .leading
        )
    }

    private func drawPlayhead(ctx: GraphicsContext, size: CGSize, x: CGFloat) {
        // Soft glow so the playhead reads clearly against dense notation.
        var glow = Path()
        glow.move(to: CGPoint(x: x, y: 0))
        glow.addLine(to: CGPoint(x: x, y: size.height))
        ctx.stroke(glow, with: .color(Color.white.opacity(0.22)), lineWidth: 6)

        // Main playhead line — brighter and thicker than a hairline cursor
        // so the current timing position is obvious at arm's length.
        var ph = Path()
        ph.move(to: CGPoint(x: x, y: 0))
        ph.addLine(to: CGPoint(x: x, y: size.height))
        ctx.stroke(ph, with: .color(Color.white.opacity(0.95)), lineWidth: 2.5)

        // Downward marker at the top edge anchors the eye to the playhead.
        var marker = Path()
        marker.move(to: CGPoint(x: x - 5, y: 0))
        marker.addLine(to: CGPoint(x: x + 5, y: 0))
        marker.addLine(to: CGPoint(x: x, y: 8))
        marker.closeSubpath()
        ctx.fill(marker, with: .color(Color.white.opacity(0.95)))
    }

    private func drawEmpty(ctx: GraphicsContext, size: CGSize, message: String) {
        ctx.draw(
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.45)),
            at: CGPoint(x: size.width / 2, y: size.height / 2),
            anchor: .center
        )
    }
}

// MARK: - CapturedNotationStrokeGeometry

/// Pure, Foundation-only geometry helper for the captured record-movement notation lane.
///
/// Extracted from `ScratchPhraseChartView` so that the travel-fraction derivation
/// can be tested without a SwiftUI canvas or `GraphicsContext`. All methods and
/// constants are `Double`-based so tests need only `@testable import ScratchLab`
/// with no `CoreGraphics` or `SwiftUI` import.
///
/// `travelFraction` is computed from the normalized position delta already stored
/// in `DetectedNotationRecordMovementEvent.startPosition` / `.endPosition`.
/// Camera-tracked hand positions are normalised to 0…1 at the point of capture
/// (`normalizedPosition = min(max(point.x, 0), 1)`), so their delta is
/// already in 0…1 and needs only a `min/max` clamp. The value drives the
/// stroke's visual height: short scratches render short, full scratches reach
/// the peak of the notation band.
enum CapturedNotationStrokeGeometry {
    /// Fraction of the chart height at which the notation baseline sits.
    /// Strokes grow upward from this y-coordinate.
    static let baselineFraction: Double = 0.85
    /// Maximum band height above the baseline, as a fraction of the chart height.
    /// A stroke with `travelFraction == 1.0` peaks at `baseline − maxBand`.
    static let maxBandFraction: Double = 0.78

    /// Normalised travel fraction (0…1) for a captured record-movement event.
    ///
    /// Computed from `abs(endPosition − startPosition)`, clamped to `0…1`.
    /// Returns `0.0` when both positions are identical (idle / zero travel),
    /// which the renderer uses as the guard to suppress phantom notation strokes.
    static func travelFraction(for event: CaptureCore.DetectedNotationRecordMovementEvent) -> Double {
        let delta = abs(event.endPosition - event.startPosition)
        return min(1.0, max(0.0, delta))
    }
}

// MARK: - Controller gesture display scale

/// Fixed presentation zoom for locally rebased controller notation.
///
/// CaptureCore keeps each event's exact, unbounded physical excursion in
/// platter revolutions. The notation lane maps one quarter revolution to its
/// full cross-axis so normal scratches remain legible; this mapping never
/// depends on the take's extrema, so a later multi-revolution run cannot move
/// or shrink an already committed stroke. Camera/DVS/target evidence keeps its
/// established 0...1 presentation.
enum ControllerGestureNotationDisplayScale {
    static let fullScaleExcursionRevolutions: Double = 0.25

    static func displayTravelFraction(
        for event: CaptureCore.DetectedNotationRecordMovementEvent
    ) -> Double {
        let physicalTravel = CapturedNotationStrokeGeometry.travelFraction(
            for: event
        )
        guard CaptureCore.usesGestureRelativeControllerNotation(event) else {
            return physicalTravel
        }
        return min(
            1,
            max(0, physicalTravel / fullScaleExcursionRevolutions)
        )
    }

    static func displayPositions(
        for event: CaptureCore.DetectedNotationRecordMovementEvent
    ) -> (start: Double, end: Double) {
        guard CaptureCore.usesGestureRelativeControllerNotation(event) else {
            return (event.startPosition, event.endPosition)
        }
        let travel = displayTravelFraction(for: event)
        switch event.direction {
        case "forward": return (0, travel)
        case "backward": return (travel, 0)
        default: return (event.startPosition, event.endPosition)
        }
    }
}

// MARK: - Performed stroke adapter

/// Pure, Foundation-only adapter that maps a captured record-movement event
/// to a `LaneStroke` for the shared platter geometry. This is what lets the
/// MY PERFORMANCE row render measured strokes through the SAME
/// `ScratchStrokeGeometry.motionPath` the target uses — one vertical mapping.
///
/// Returns `nil` (never fabricates) for non-stroke movement kinds (`hold`,
/// `releaseNormalPlayback`) and for indeterminate direction (anything other
/// than "forward"/"backward").
enum PerformedStrokeAdapter {

    static func laneStroke(from event: CaptureCore.DetectedNotationRecordMovementEvent) -> LaneStroke? {
        // Snapshot-aware callers supply physical gesture events re-derived
        // from raw MIDI. This event-only fallback still guarantees a local
        // baseline for older/isolated controller events, while preserving
        // their stored excursion and never interpreting normalized speed as
        // raw motor steps.
        let projectedEvent = CaptureCore.locallyRebasedControllerNotationEvent(event)
        guard PerformedScratchTimelineAdapter.isStrokeKind(projectedEvent.movementKind) else { return nil }

        let direction: ScratchNotationDirection
        switch projectedEvent.direction {
        case "forward": direction = .forward
        case "backward": direction = .backward
        default: return nil
        }

        let speed: ScratchNotationSpeedClassification
        switch projectedEvent.movementKind {
        case .fastPush, .fastPull: speed = .fast
        case .slowDrag, .slowPullDrag: speed = .slow
        default: speed = .medium
        }

        let displayPositions = ControllerGestureNotationDisplayScale
            .displayPositions(for: projectedEvent)

        return LaneStroke(
            startTime: projectedEvent.startTime,
            endTime: projectedEvent.endTime,
            direction: direction,
            speed: speed,
            faderState: .open,
            isGhost: false,
            normalizedTravel: CapturedNotationStrokeGeometry.travelFraction(for: projectedEvent),
            measuredStartPosition: displayPositions.start,
            measuredEndPosition: displayPositions.end
        )
    }

    /// Standalone controller-performance lanes use one stable display frame.
    /// `laneStroke(from:)` has already projected a quarter revolution onto
    /// that frame without changing the physical event. Target/performance
    /// comparisons still use the caller-supplied target frame, which takes
    /// precedence. Camera/DVS events retain their existing content-derived
    /// frame.
    static func gestureRelativeNormalizationFrame(
        for events: [CaptureCore.DetectedNotationRecordMovementEvent]
    ) -> ClosedRange<CGFloat>? {
        let usableStrokeEvents = events.filter { laneStroke(from: $0) != nil }
        guard !usableStrokeEvents.isEmpty,
              usableStrokeEvents.allSatisfy(
                CaptureCore.usesGestureRelativeControllerNotation
              ) else {
            return nil
        }
        return 0...1
    }
}

// MARK: - Comparison time domain

/// Pure, Foundation-only horizontal time→x mapping shared by the stacked
/// TARGET / MY PERFORMANCE comparison, extracted so the common-domain
/// guarantee can be tested without a SwiftUI canvas.
///
/// The TARGET's notation duration is the single authority for the displayed
/// window. The performed chart must consume the SAME window — it must never
/// derive its own domain from the captured take's span, or identical musical
/// times would land on different x coordinates in the two charts.
enum ScratchPhraseChartComparisonDomain {

    /// The one displayed `[0, duration]` window for a stacked comparison.
    /// Defined by the target notation's duration alone; independent of any
    /// captured events.
    static func commonDomain(targetDuration: TimeInterval) -> ClosedRange<TimeInterval> {
        0...max(targetDuration, 0.1)
    }

    /// Normalized x (0…width) for `time` within `domain`. Deterministic; the
    /// same `(time, domain, width)` always yields the same x, which is what
    /// makes the two charts' x mapping identical.
    static func normalizedX(time: TimeInterval,
                            domain: ClosedRange<TimeInterval>,
                            width: Double) -> Double {
        let span = max(domain.upperBound - domain.lowerBound, 0.1)
        return (time - domain.lowerBound) / span * width
    }
}

// MARK: - Preview

#if DEBUG
// Preview macros disabled: PreviewsMacros.SwiftUIView plugin unavailable.
#if false
#Preview("Target — Baby Scratch") {
    ScratchPhraseChartView(
        source: .target(ScratchNotation.babyScratch ?? ScratchNotation(
            version: 1, scratchID: "preview", demoStart: 0, demoEnd: 2.1,
            phraseStart: 0, phraseEnd: 2.1, timingBasis: "beat", strokes: []
        )),
        bpm: 90,
        showPlayhead: false
    )
    .frame(width: 640, height: 160)
}

#Preview("Empty") {
    ScratchPhraseChartView(source: .empty("Choose a scratch type to load target notation."))
        .frame(width: 640, height: 100)
}
#endif // #if false
#endif
