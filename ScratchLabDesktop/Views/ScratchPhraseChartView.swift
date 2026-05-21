import SwiftUI

// Static full-phrase notation chart — all strokes visible at once.
// Replaces ScratchNotationCanvasView in non-animated contexts (capture, review).

struct ScratchPhraseChartView: View {

    enum ChartSource {
        case target(ScratchNotation)
        case captured([CaptureCore.DetectedNotationRecordMovementEvent])
        case empty(String)
    }

    let source: ChartSource
    var bpm: Double = 90
    var playheadTime: TimeInterval = 0
    var showPlayhead: Bool = false

    // Palette matches ScratchNotationCanvasView
    private let bgColor    = Color(white: 0.10)
    private let gridMajor  = Color(white: 0.22)
    private let gridMinor  = Color(white: 0.14)
    private let forwardCol = Color(red: 0.20, green: 0.88, blue: 0.55)
    private let backCol    = Color(red: 1.00, green: 0.55, blue: 0.10)
    private let holdCol    = Color(white: 0.40)
    private let dotCol     = Color(white: 0.82)
    private let faderOpenCol   = Color(red: 0.20, green: 0.88, blue: 0.55).opacity(0.55)
    private let faderClosedCol = Color(red: 1.00, green: 0.25, blue: 0.25).opacity(0.65)
    private let laneDividerCol = Color(white: 0.28)

    // Fraction of the chart vertically reserved for the crossfader sub-lane.
    // The strokes region gets the remaining (1 - faderLaneFraction).
    private let faderLaneFraction: CGFloat = 0.22

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
        let duration = max(notation.timelineDuration, 0.1)
        let pps = size.width / CGFloat(duration)
        let strokeRegionHeight = size.height * (1 - faderLaneFraction)
        let midY = strokeRegionHeight / 2

        drawBeatGrid(ctx: ctx, size: size, duration: duration, pps: pps,
                     labelBottomY: strokeRegionHeight - 2)

        for i in 0..<notation.strokes.count {
            let after = notation.strokes[i]
            let before = i + 1 < notation.strokes.count ? notation.strokes[i + 1] : nil
            drawHold(ctx: ctx, size: size, afterEnd: after.endTime, beforeStart: before?.startTime ?? duration,
                     pps: pps, midY: midY)
        }

        for stroke in notation.strokes {
            drawTargetStroke(ctx: ctx, size: size, stroke: stroke, pps: pps, midY: midY,
                             strokeRegionHeight: strokeRegionHeight)
        }

        drawLaneDivider(ctx: ctx, size: size, y: strokeRegionHeight)
        drawTargetCrossfaderLane(ctx: ctx, size: size, notation: notation,
                                  pps: pps, strokeRegionTop: strokeRegionHeight)
        drawTargetAxisLabels(ctx: ctx, size: size, midY: midY,
                             strokeRegionHeight: strokeRegionHeight)

        if showPlayhead {
            drawPlayhead(ctx: ctx, size: size, x: CGFloat(playheadTime) * pps)
        }
    }

    private func drawTargetStroke(ctx: GraphicsContext, size: CGSize,
                                   stroke: ScratchNotation.Stroke, pps: CGFloat, midY: CGFloat,
                                   strokeRegionHeight: CGFloat) {
        let x1 = CGFloat(stroke.startTime) * pps
        let x2 = CGFloat(stroke.endTime) * pps
        guard x2 > x1 else { return }

        let halfH = slopeHalfHeight(strokeRegionHeight: strokeRegionHeight,
                                    fast: stroke.speedClassification == .fast,
                                    slow: stroke.speedClassification == .slow)
        let isForward = stroke.direction == .forward
        let (y1, y2) = isForward ? (midY + halfH, midY - halfH) : (midY - halfH, midY + halfH)
        let color = isForward ? forwardCol : backCol

        var path = Path()
        path.move(to: CGPoint(x: x1, y: y1))
        path.addLine(to: CGPoint(x: x2, y: y2))
        ctx.stroke(path, with: .color(color), lineWidth: 2.5)

        drawDots(ctx: ctx, p1: CGPoint(x: x1, y: y1), p2: CGPoint(x: x2, y: y2))

        let label = isForward ? "F" : "B"
        let labelOffset: CGFloat = isForward ? -10 : 10
        ctx.draw(
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(color.opacity(0.9)),
            at: CGPoint(x: (x1 + x2) / 2, y: (y1 + y2) / 2 + labelOffset),
            anchor: .center
        )
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
        let midY = size.height / 2

        drawBeatGrid(ctx: ctx, size: size, duration: duration, pps: pps,
                     labelBottomY: size.height - 2)

        for event in events {
            let x1 = CGFloat(event.startTime) * pps
            let x2 = CGFloat(event.endTime) * pps
            guard x2 > x1 else { continue }

            let isForward = event.direction == "forward"
            let halfH = capturedHalfHeight(size: size, kind: event.movementKind)
            let (y1, y2) = isForward ? (midY + halfH, midY - halfH) : (midY - halfH, midY + halfH)
            let color = isForward ? forwardCol : backCol
            let alpha = 0.55 + event.confidence * 0.45

            var path = Path()
            path.move(to: CGPoint(x: x1, y: y1))
            path.addLine(to: CGPoint(x: x2, y: y2))
            ctx.stroke(path, with: .color(color.opacity(alpha)), lineWidth: 2.5)
            drawDots(ctx: ctx, p1: CGPoint(x: x1, y: y1), p2: CGPoint(x: x2, y: y2), alpha: alpha)
        }

        drawCapturedAxisLabels(ctx: ctx, size: size, midY: midY)

        if showPlayhead {
            drawPlayhead(ctx: ctx, size: size, x: CGFloat(playheadTime) * pps)
        }
    }

    // MARK: - Helpers

    private func slopeHalfHeight(strokeRegionHeight: CGFloat, fast: Bool, slow: Bool) -> CGFloat {
        let fraction: CGFloat = fast ? 0.84 : slow ? 0.38 : 0.60
        return strokeRegionHeight * 0.44 * fraction
    }

    private func capturedHalfHeight(size: CGSize, kind: ScratchMovementKind) -> CGFloat {
        let fraction: Double = {
            switch kind {
            case .fastPush, .fastPull:     return 0.90
            case .normalPush, .normalPull: return 0.62
            case .slowDrag, .slowPullDrag: return 0.38
            default:                       return 0.55
            }
        }()
        return size.height * 0.44 * CGFloat(fraction)
    }

    private func drawHold(ctx: GraphicsContext, size: CGSize,
                           afterEnd: TimeInterval, beforeStart: TimeInterval,
                           pps: CGFloat, midY: CGFloat) {
        let x1 = CGFloat(afterEnd) * pps
        let x2 = CGFloat(beforeStart) * pps
        guard x2 > x1 else { return }
        var path = Path()
        path.move(to: CGPoint(x: x1, y: midY))
        path.addLine(to: CGPoint(x: x2, y: midY))
        ctx.stroke(path, with: .color(holdCol.opacity(0.40)), lineWidth: 1.2)
    }

    private func drawDots(ctx: GraphicsContext, p1: CGPoint, p2: CGPoint, alpha: Double = 1) {
        let r: CGFloat = 4
        ctx.fill(Path(ellipseIn: CGRect(x: p1.x - r, y: p1.y - r, width: r * 2, height: r * 2)),
                 with: .color(dotCol.opacity(alpha)))
        ctx.fill(Path(ellipseIn: CGRect(x: p2.x - r, y: p2.y - r, width: r * 2, height: r * 2)),
                 with: .color(dotCol.opacity(alpha)))
    }

    private func drawBeatGrid(ctx: GraphicsContext, size: CGSize, duration: Double, pps: CGFloat,
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

        var t = 0.0
        var beat = 0
        while t <= duration + beatInterval * 0.5 {
            let x = CGFloat(t) * pps
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

    private func drawTargetCrossfaderLane(ctx: GraphicsContext, size: CGSize,
                                           notation: ScratchNotation,
                                           pps: CGFloat,
                                           strokeRegionTop: CGFloat) {
        let laneHeight = size.height - strokeRegionTop
        let inset: CGFloat = 3
        let barTop = strokeRegionTop + inset
        let barHeight = max(0, laneHeight - inset * 2)

        // Each stroke contributes a colored bar over its time interval.
        // Color reflects the crossfader state on that stroke (open vs. closed).
        for stroke in notation.strokes {
            let x1 = CGFloat(stroke.startTime) * pps
            let x2 = CGFloat(stroke.endTime) * pps
            guard x2 > x1, barHeight > 0 else { continue }

            let rect = CGRect(x: x1, y: barTop, width: x2 - x1, height: barHeight)
            let isOpen = stroke.faderState == .open
            let fill = isOpen ? faderOpenCol : faderClosedCol
            ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(fill))
        }

        // Lane label: keep copy short and user-facing.
        ctx.draw(
            Text("CROSSFADER")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(white: 0.55)),
            at: CGPoint(x: 4, y: strokeRegionTop + laneHeight / 2),
            anchor: .leading
        )
    }

    private func drawTargetAxisLabels(ctx: GraphicsContext, size: CGSize, midY: CGFloat,
                                       strokeRegionHeight: CGFloat) {
        ctx.draw(
            Text("FWD")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(forwardCol.opacity(0.55)),
            at: CGPoint(x: 4, y: midY - strokeRegionHeight * 0.38),
            anchor: .leading
        )
        ctx.draw(
            Text("BACK")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(backCol.opacity(0.55)),
            at: CGPoint(x: 4, y: midY + strokeRegionHeight * 0.30),
            anchor: .leading
        )
    }

    private func drawCapturedAxisLabels(ctx: GraphicsContext, size: CGSize, midY: CGFloat) {
        ctx.draw(
            Text("FWD")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(forwardCol.opacity(0.55)),
            at: CGPoint(x: 4, y: midY - size.height * 0.38),
            anchor: .leading
        )
        ctx.draw(
            Text("BACK")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(backCol.opacity(0.55)),
            at: CGPoint(x: 4, y: midY + size.height * 0.30),
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

// MARK: - Preview

#if DEBUG
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
#endif
