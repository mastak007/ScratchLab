import SwiftUI

// MARK: - ScratchNotationCanvasView
//
// Detailed, ScratchLab-native notation renderer.
// Shows the record-movement lane and a fader lane, inspired by standard
// scratch notation conventions (forward = rising slope, back = falling slope,
// fast = steep, slow = shallow, hold = flat, fader cuts = markers on fader lane).
//
// Owns no state and does no IO — all data is passed in at init.

struct ScratchNotationCanvasView: View {

    let notation: ScratchNotation?
    let playbackTime: TimeInterval
    let loopDuration: TimeInterval

    // Optional: highlight a specific stroke index
    var selectedStrokeIndex: Int? = nil

    // Layout fractions (record lane : fader lane)
    private let recordLaneFraction: CGFloat = 0.72
    private let faderLaneFraction:  CGFloat = 0.18
    private let labelWidth: CGFloat = 52

    // Timing window: how many seconds are visible at once
    private let visibleSeconds: Double = 2.4
    // Playhead sits 30% from the left
    private let playheadFraction: Double = 0.30

    // Palette
    private let bgRecord    = Color(white: 0.11)
    private let bgFader     = Color(white: 0.085)
    private let gridMajor   = Color(white: 0.22)
    private let gridMinor   = Color(white: 0.155)
    private let playheadCol = Color.white
    private let forwardCol  = Color(red: 0.20, green: 0.88, blue: 0.55)
    private let backCol     = Color(red: 1.00, green: 0.55, blue: 0.10)
    private let holdCol     = Color(white: 0.45)
    private let releaseCol  = Color(red: 0.55, green: 0.75, blue: 1.00)
    private let dotCol      = Color(white: 0.82)
    private let faderOpenCol   = Color(red: 0.20, green: 0.88, blue: 0.55).opacity(0.7)
    private let faderClosedCol = Color(red: 1.00, green: 0.25, blue: 0.25).opacity(0.85)
    private let cutCol         = Color(white: 0.90)

    var body: some View {
        Canvas { ctx, size in
            guard size.width > 0, size.height > 0 else { return }
            let pps = CGFloat(size.width / visibleSeconds)
            let phX = size.width * playheadFraction
            let now = playbackTime
            let loop = loopDuration > 0 ? loopDuration : 1

            let recordH = size.height * recordLaneFraction
            let faderH  = size.height * faderLaneFraction
            let faderY  = recordH

            // Backgrounds
            ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: recordH)), with: .color(bgRecord))
            ctx.fill(Path(CGRect(x: 0, y: faderY, width: size.width, height: faderH)), with: .color(bgFader))

            // Grid (shared vertical lines across both lanes)
            drawGrid(ctx: ctx, size: size, phX: phX, pps: pps, now: now, loop: loop)

            // Lane labels (left side, inside the canvas)
            drawLaneLabel(ctx: ctx, text: "RECORD", y: recordH * 0.08, size: size)
            drawLaneLabel(ctx: ctx, text: "CROSSFADER",  y: faderY + faderH * 0.18, size: size)

            let recordRect = CGRect(x: 0, y: 0, width: size.width, height: recordH)
            let faderRect  = CGRect(x: 0, y: faderY, width: size.width, height: faderH)

            if let strokes = notation?.strokes {
                // Draw 3 loop copies so the canvas fills seamlessly
                for loopOffset in [-loop, 0, loop] {
                    // Hold segments between strokes
                    for i in 0..<strokes.count {
                        let next = i + 1 < strokes.count ? strokes[i + 1] : nil
                        drawHold(ctx: ctx, after: strokes[i], before: next,
                                 loopOffset: loopOffset, loopDuration: loop,
                                 now: now, phX: phX, pps: pps,
                                 laneRect: recordRect, canvasWidth: size.width)
                    }
                    // Stroke traces
                    for (i, stroke) in strokes.enumerated() {
                        let isSelected = selectedStrokeIndex == i
                        drawStroke(ctx: ctx, stroke: stroke,
                                   loopOffset: loopOffset, now: now,
                                   phX: phX, pps: pps,
                                   laneRect: recordRect, canvasWidth: size.width,
                                   selected: isSelected)
                        // Fader marker
                        drawFaderMarker(ctx: ctx, stroke: stroke,
                                        loopOffset: loopOffset, now: now,
                                        phX: phX, pps: pps,
                                        laneRect: faderRect, canvasWidth: size.width)
                    }
                }
            }

            // Divider between record and fader lanes
            var div = Path()
            div.move(to: CGPoint(x: 0, y: faderY))
            div.addLine(to: CGPoint(x: size.width, y: faderY))
            ctx.stroke(div, with: .color(Color(white: 0.32)), lineWidth: 1)

            // Playhead
            var ph = Path()
            ph.move(to: CGPoint(x: phX, y: 0))
            ph.addLine(to: CGPoint(x: phX, y: size.height))
            ctx.stroke(ph, with: .color(playheadCol.opacity(0.85)), lineWidth: 1.5)

            // Playhead time label
            ctx.draw(
                Text(String(format: "%.3fs", now))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.55)),
                at: CGPoint(x: phX + 3, y: size.height - 4),
                anchor: .bottomLeading
            )
        }
    }

    // MARK: - Grid

    private func drawGrid(ctx: GraphicsContext, size: CGSize, phX: CGFloat, pps: CGFloat, now: Double, loop: Double) {
        let majorInterval: Double = 0.5
        let minorInterval: Double = 0.125
        let tStart = now - Double(phX) / Double(pps)
        let tEnd   = tStart + Double(size.width) / Double(pps)

        var t = (tStart / minorInterval).rounded(.down) * minorInterval
        while t <= tEnd {
            let isMajor = t.truncatingRemainder(dividingBy: majorInterval).magnitude < 0.001
            let x = phX + CGFloat(t - now) * pps
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: size.height))
            ctx.stroke(line, with: .color(isMajor ? gridMajor : gridMinor),
                       lineWidth: isMajor ? 0.8 : 0.35)
            if isMajor {
                let loopT = t.truncatingRemainder(dividingBy: loop)
                ctx.draw(
                    Text(String(format: "%.2f", loopT < 0 ? loopT + loop : loopT))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color(white: 0.33)),
                    at: CGPoint(x: x + 3, y: size.height - 2),
                    anchor: .bottomLeading
                )
            }
            t += minorInterval
        }
    }

    // MARK: - Lane label

    private func drawLaneLabel(ctx: GraphicsContext, text: String, y: CGFloat, size: CGSize) {
        ctx.draw(
            Text(text)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(white: 0.38)),
            at: CGPoint(x: 6, y: y),
            anchor: .topLeading
        )
    }

    // MARK: - Stroke rendering

    private func drawStroke(
        ctx: GraphicsContext,
        stroke: ScratchNotation.Stroke,
        loopOffset: Double,
        now: Double,
        phX: CGFloat,
        pps: CGFloat,
        laneRect: CGRect,
        canvasWidth: CGFloat,
        selected: Bool
    ) {
        let x1 = phX + CGFloat(stroke.startTime + loopOffset - now) * pps
        let x2 = phX + CGFloat(stroke.endTime   + loopOffset - now) * pps
        guard x2 >= -60, x1 <= canvasWidth + 60 else { return }

        let kind = stroke.movementKind
        let isPast = x2 < phX

        // Slope: fast=steep (full height), normal=medium, slow=shallow (40% height)
        let heightFraction: CGFloat = {
            switch kind {
            case .fastPush, .fastPull: return 0.84
            case .normalPush, .normalPull: return 0.60
            case .slowDrag, .slowPullDrag: return 0.38
            default: return 0.60
            }
        }()

        let margin = laneRect.height * 0.08
        let midY   = laneRect.midY
        let halfH  = laneRect.height * heightFraction / 2

        let (y1, y2): (CGFloat, CGFloat) = switch kind {
        case .fastPush, .normalPush, .slowDrag:
            (midY + halfH, midY - halfH)
        case .fastPull, .normalPull, .slowPullDrag:
            (midY - halfH, midY + halfH)
        default:
            (midY, midY)
        }
        _ = margin

        let baseColor: Color = {
            switch kind {
            case .fastPush, .normalPush, .slowDrag:     return forwardCol
            case .fastPull, .normalPull, .slowPullDrag: return backCol
            case .releaseNormalPlayback:                return releaseCol
            default: return holdCol
            }
        }()

        let alpha: Double = isPast ? (selected ? 0.55 : 0.22) : (selected ? 1.0 : 0.95)
        let lineWidth: CGFloat = isPast ? 1.5 : (selected ? 3.5 : 2.5)

        // releaseNormalPlayback uses dashed stroke
        if kind == .releaseNormalPlayback {
            var ghostPath = Path()
            ghostPath.move(to: CGPoint(x: x1, y: y1))
            ghostPath.addLine(to: CGPoint(x: x2, y: y2))
            ctx.stroke(
                ghostPath,
                with: .color(baseColor.opacity(alpha * 0.65)),
                style: StrokeStyle(lineWidth: lineWidth, dash: [6, 4])
            )
        } else {
            var path = Path()
            path.move(to: CGPoint(x: x1, y: y1))
            path.addLine(to: CGPoint(x: x2, y: y2))
            ctx.stroke(path, with: .color(baseColor.opacity(alpha)), lineWidth: lineWidth)
        }

        // Endpoint dots
        let dotR: CGFloat = isPast ? 3 : (selected ? 5.5 : 4)
        drawDot(ctx: ctx, at: CGPoint(x: x1, y: y1), r: dotR, color: dotCol.opacity(alpha))
        drawDot(ctx: ctx, at: CGPoint(x: x2, y: y2), r: dotR, color: dotCol.opacity(alpha))
    }

    // MARK: - Hold segment

    private func drawHold(
        ctx: GraphicsContext,
        after stroke: ScratchNotation.Stroke,
        before next: ScratchNotation.Stroke?,
        loopOffset: Double,
        loopDuration: Double,
        now: Double,
        phX: CGFloat,
        pps: CGFloat,
        laneRect: CGRect,
        canvasWidth: CGFloat
    ) {
        let holdStart = stroke.endTime + loopOffset
        let holdEnd   = (next?.startTime ?? loopDuration) + loopOffset
        guard holdEnd > holdStart else { return }

        let x1 = phX + CGFloat(holdStart - now) * pps
        let x2 = phX + CGFloat(holdEnd   - now) * pps
        guard x2 >= -60, x1 <= canvasWidth + 60 else { return }

        let midY = laneRect.midY
        var path = Path()
        path.move(to: CGPoint(x: x1, y: midY))
        path.addLine(to: CGPoint(x: x2, y: midY))
        let isPast = x2 < phX
        ctx.stroke(path, with: .color(holdCol.opacity(isPast ? 0.18 : 0.40)), lineWidth: 1.2)
    }

    // MARK: - Fader lane marker

    private func drawFaderMarker(
        ctx: GraphicsContext,
        stroke: ScratchNotation.Stroke,
        loopOffset: Double,
        now: Double,
        phX: CGFloat,
        pps: CGFloat,
        laneRect: CGRect,
        canvasWidth: CGFloat
    ) {
        let x1 = phX + CGFloat(stroke.startTime + loopOffset - now) * pps
        let x2 = phX + CGFloat(stroke.endTime   + loopOffset - now) * pps
        guard x2 >= -60, x1 <= canvasWidth + 60 else { return }

        let midY   = laneRect.midY
        let halfH  = laneRect.height * 0.38
        let isPast = x2 < phX

        switch stroke.faderState {
        case .open:
            var bar = Path()
            bar.move(to: CGPoint(x: x1, y: midY - halfH))
            bar.addLine(to: CGPoint(x: x1, y: midY + halfH))
            bar.addLine(to: CGPoint(x: x2, y: midY + halfH))
            bar.addLine(to: CGPoint(x: x2, y: midY - halfH))
            bar.closeSubpath()
            ctx.fill(bar, with: .color(faderOpenCol.opacity(isPast ? 0.25 : 0.55)))
        case .closed:
            var line = Path()
            line.move(to: CGPoint(x: x1, y: midY))
            line.addLine(to: CGPoint(x: x2, y: midY))
            ctx.stroke(line, with: .color(faderClosedCol.opacity(isPast ? 0.25 : 0.70)), lineWidth: 2)
            // Cut markers at endpoints
            for cx in [x1, x2] {
                var cut = Path()
                cut.move(to: CGPoint(x: cx, y: midY - halfH))
                cut.addLine(to: CGPoint(x: cx, y: midY + halfH))
                ctx.stroke(cut, with: .color(cutCol.opacity(isPast ? 0.20 : 0.80)), lineWidth: 1.5)
            }
        }
    }

    // MARK: - Dot helper

    private func drawDot(ctx: GraphicsContext, at point: CGPoint, r: CGFloat, color: Color) {
        let dotRect = CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)
        ctx.fill(Path(ellipseIn: dotRect), with: .color(color))
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    let notation = ScratchNotation.babyScratch
    return ScratchNotationCanvasView(
        notation: notation,
        playbackTime: 0.3,
        loopDuration: notation?.timelineDuration ?? 2.1
    )
    .frame(width: 700, height: 200)
    .background(Color.black)
}
#endif
