import SwiftUI

// Static full-phrase notation chart — all strokes visible at once.
// Replaces ScratchNotationCanvasView in non-animated contexts (capture, review).
//
// The TARGET case routes its strokes through the shared `ScratchMotionRenderer`
// and `ScratchStrokeGeometry` — the same renderer the iOS practice lane uses —
// so a Baby Scratch reference shown in macOS Review reads in exactly the same
// visual language as the iOS lane: cyan forward push and hot pink backward
// pull, deflect-and-return tent ramps with apex nodes on each rail, and a
// dashed rest line between strokes. macOS-specific affordances (beat-number
// labels, PLATTER/FADER lane labels, turnaround diamonds, OPEN/CLOSED binary
// fader rails with transition markers, and the optional playhead) live around
// the shared renderer's record-lane output. The CAPTURED / EMPTY cases are
// unchanged.

struct ScratchPhraseChartView: View {

    enum ChartSource {
        case target(ScratchNotation)
        case captured([CaptureCore.DetectedNotationRecordMovementEvent])
        case empty(String)
    }

    let source: ChartSource
    var bpm: Double = 90
    /// Review-only render-time window for the `.target` source. When `nil`,
    /// the chart renders the full notation timeline (Practice/iOS/preview
    /// behaviour preserved). When set, the chart maps `[lowerBound, upperBound]`
    /// onto the full chart width; the bundled notation JSON is never mutated.
    /// Ignored by `.captured` and `.empty` sources.
    var targetWindow: ClosedRange<TimeInterval>? = nil
    var playheadTime: TimeInterval = 0
    var showPlayhead: Bool = false
    /// Optional target-vs-performed overlay drawn on top of the `.target`
    /// chart: performed strokes in the captured chart's own visual language
    /// (green forward `/`, orange backward `\` slashes), per-mark verdict
    /// dots on the baseline, and performed fader-edge ticks in the
    /// fader sub-lane. `nil` (every pre-existing call site) renders the
    /// chart byte-identically to before. Ignored by `.captured`/`.empty`.
    var comparisonOverlay: ScratchComparisonOverlay? = nil

    // Background and grid palette — shared across both target/captured paths.
    private let bgColor    = Color(white: 0.10)
    private let gridMajor  = Color(white: 0.22)
    private let gridMinor  = Color(white: 0.14)
    // Captured-path stroke palette (kept; the captured path still draws its
    // own single-diagonal record-events because they aren't authored strokes).
    private let forwardCol = Color(red: 0.20, green: 0.88, blue: 0.55)
    private let backCol    = Color(red: 1.00, green: 0.55, blue: 0.10)
    private let dotCol     = Color(white: 0.82)
    private let laneDividerCol = Color(white: 0.28)

    // Fraction of the chart vertically reserved for the fader sub-lane.
    // The strokes region gets the remaining (1 - faderLaneFraction).
    private let faderLaneFraction: CGFloat = 0.26

    var body: some View {
        switch source {
        case .target:
            ScratchLabPerformanceSignpost.event("TargetNotationRender")
        case .captured(let events):
            ScratchLabPerformanceSignpost.event("CapturedNotationRender", count: events.count)
        case .empty:
            break
        }
        return Canvas { ctx, size in
            guard size.width > 0, size.height > 0 else { return }
            switch source {
            case .target(let notation):    drawTarget(ctx: ctx, size: size, notation: notation)
            case .captured(let events):    drawCaptured(ctx: ctx, size: size, events: events)
            case .empty(let message):      drawEmpty(ctx: ctx, size: size, message: message)
            }
        }
        .background(bgColor)
    }

    // MARK: - Target (ScratchNotation)

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

        // Turnaround markers — small diamonds at forward→backward boundaries
        drawTurnaroundMarkers(ctx: ctx, notation: notation,
                              windowStart: windowStart, pps: pps,
                              strokeRegionHeight: strokeRegionHeight)

        // PLATTER lane label — top-left anchor at the head of the stroke region
        ctx.draw(
            Text("PLATTER")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
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

    // MARK: - Captured (recordMovementEvents)

    private func drawCaptured(ctx: GraphicsContext, size: CGSize,
                               events: [CaptureCore.DetectedNotationRecordMovementEvent]) {
        guard !events.isEmpty else {
            drawEmpty(ctx: ctx, size: size, message: "No movement data")
            return
        }

        let duration = max(events.map(\.endTime).max() ?? 1.0, 0.1)
        let pps = size.width / CGFloat(duration)
        // Baseline sits near the bottom of the chart; strokes rise above it proportionally
        // to the actual platter/hand travel distance — short scratches stay short.
        let baseline = size.height * CGFloat(CapturedNotationStrokeGeometry.baselineFraction)
        let maxBand  = size.height * CGFloat(CapturedNotationStrokeGeometry.maxBandFraction)

        drawBeatGrid(ctx: ctx, size: size, duration: duration, pps: pps,
                     labelBottomY: size.height - 2)

        for event in events {
            let x1 = CGFloat(event.startTime) * pps
            let x2 = CGFloat(event.endTime) * pps
            guard x2 > x1 else { continue }

            let travel = CGFloat(CapturedNotationStrokeGeometry.travelFraction(for: event))
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
            drawPlayhead(ctx: ctx, size: size, x: CGFloat(playheadTime) * pps)
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
            let slashColor: Color = mark.direction == .backward ? backCol : forwardCol
            ctx.stroke(slash, with: .color(slashColor.opacity(0.85)),
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
                              labelBottomY: CGFloat) {
        let beatInterval = 60.0 / max(bpm, 1)

        // Width-aware label thinning. A beat number is ~14 pt wide, so when
        // beats pack closer than that the number row becomes an unreadable
        // strip (e.g. a long phrase at iPhone width). Draw every Nth label
        // so neighbours stay legible. On wide charts (macOS Review) the
        // stride resolves to 1 — every beat labelled, behaviour unchanged.
        // Grid lines are always drawn; only the numerals are thinned.
        let beatSpacing = CGFloat(beatInterval) * pps
        let minLabelGap: CGFloat = 26
        let labelStride = max(1, Int((minLabelGap / max(beatSpacing, 0.5)).rounded(.up)))

        // Beat numbering tracks absolute timeline beats, so a windowed
        // target chart shows the same beat indices as the un-windowed full
        // phrase (and matches the captured chart for a window starting at 0).
        let endTime = startTime + duration
        var beat = Int((startTime / beatInterval).rounded(.down))
        var t = Double(beat) * beatInterval
        while t <= endTime + beatInterval * 0.5 {
            let x = CGFloat(t - startTime) * pps
            if x >= 0 && x <= size.width {
                let isMajor = beat % 4 == 0
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(line, with: .color(isMajor ? gridMajor : gridMinor),
                           lineWidth: isMajor ? 0.8 : 0.35)
                if beat > 0 && beat % labelStride == 0 {
                    ctx.draw(
                        Text("\(beat)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color(white: 0.55)),
                        at: CGPoint(x: x + 2, y: labelBottomY),
                        anchor: .bottomLeading
                    )
                }
            }
            t += beatInterval
            beat += 1
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
                .font(.system(size: 6.5, weight: .bold, design: .monospaced))
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
            let activeColor: Color = span.state == .open
                ? Color(red: 0.20, green: 0.88, blue: 0.55)
                : Color(red: 1.00, green: 0.25, blue: 0.25)

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
                .font(.system(size: 5.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(white: 0.32)),
            at: CGPoint(x: 4, y: topY + 1),
            anchor: .topLeading
        )
        ctx.draw(
            Text("CLOSED")
                .font(.system(size: 5.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(white: 0.32)),
            at: CGPoint(x: 4, y: bottomY - 1),
            anchor: .bottomLeading
        )
    }

    /// Small diamonds at forward→backward direction-change boundaries.
    /// Turnaround semantics are unambiguous: a diamond at the exact end time
    /// of stroke `i` where stroke `i+1` has the opposite direction.
    private func drawTurnaroundMarkers(ctx: GraphicsContext,
                                        notation: ScratchNotation,
                                        windowStart: Double,
                                        pps: CGFloat,
                                        strokeRegionHeight: CGFloat) {
        let baseline = strokeRegionHeight * CGFloat(CapturedNotationStrokeGeometry.baselineFraction)
        let maxBand  = strokeRegionHeight * CGFloat(CapturedNotationStrokeGeometry.maxBandFraction)
        let peakY = baseline - maxBand * 0.55  // centre-band peak for turnaround diamonds
        let strokes = notation.strokes
        guard strokes.count >= 2 else { return }

        for i in 0..<(strokes.count - 1) {
            let a = strokes[i]
            let b = strokes[i + 1]
            guard a.direction == .forward, b.direction == .backward else { continue }
            let turnaroundTime = a.endTime
            let x = CGFloat(turnaroundTime - windowStart) * pps
            guard x >= -20 else { continue }

            let d: CGFloat = 2.5
            var diamond = Path()
            diamond.move(to: CGPoint(x: x, y: peakY - d))
            diamond.addLine(to: CGPoint(x: x + d, y: peakY))
            diamond.addLine(to: CGPoint(x: x, y: peakY + d))
            diamond.addLine(to: CGPoint(x: x - d, y: peakY))
            diamond.closeSubpath()
            ctx.fill(diamond, with: .color(Color(white: 0.72).opacity(0.45)))
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
