import SwiftUI

// MARK: - ScratchNotationCanvasView
//
// Detailed, ScratchLab-native notation visualizer — the animated/looping
// counterpart of `ScratchPhraseChartView`. Both go through the SAME shared
// renderer (`ScratchMotionRenderer` + `ScratchStrokeGeometry`) the iOS
// practice lane uses, so a Baby Scratch shown on macOS Review looks in
// exactly the same visual language as on iOS Practice: cyan forward push
// and hot pink backward pull, deflect-and-return tent ramps with
// direction-coloured apex nodes on each rail, and a dashed rest line
// between strokes.
//
// The view keeps the macOS-specific affordances around the shared
// renderer's output: a fixed playhead at 30% from the left, a CROSSFADER
// sub-lane that visualises fader state per stroke, and a beat-numbered
// grid. Loop tiling is done with `MotionPath.shifted(by:)`, so the
// curve is naturally seam-safe (both ends of the deflect-and-return path
// rest at the centre).
//
// Owns no state and does no IO — all data is passed in at init.

struct ScratchNotationCanvasView: View {

    let notation: ScratchNotation?
    let playbackTime: TimeInterval
    let loopDuration: TimeInterval

    // Optional: highlight a specific stroke index (currently unused by the
    // shared renderer; kept for API stability with existing call sites).
    var selectedStrokeIndex: Int? = nil

    // Layout fractions (record lane : fader lane)
    private let recordLaneFraction: CGFloat = 0.72
    private let faderLaneFraction:  CGFloat = 0.18

    // Timing window: how many seconds are visible at once.
    private let visibleSeconds: Double = 2.4
    // Playhead sits 30% from the left — past on the left, future on the right.
    private let playheadFraction: Double = 0.30

    // Palette
    private let bgRecord    = Color(white: 0.11)
    private let bgFader     = Color(white: 0.085)
    private let gridMajor   = Color(white: 0.22)
    private let gridMinor   = Color(white: 0.155)
    private let playheadCol = Color.white
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

            let faderRect  = CGRect(x: 0, y: faderY, width: size.width, height: faderH)

            if let notation = notation {
                // Record-lane strokes via the SHARED angular renderer — the
                // same path the iOS practice lane uses. `LaneViewport` is
                // sized to the record-lane region; with `actionLineFraction`
                // matching the playhead position and `secondsAhead` matching
                // the future portion of the visible window, a stroke at time
                // `t` lands at x = phX + (t − now) · pps. Loop tiling uses
                // `MotionPath.shifted(by:)`; the deflect-and-return geometry
                // is naturally seam-safe.
                let recordSize = CGSize(width: size.width, height: recordH)
                let viewport = LaneViewport(
                    size: recordSize,
                    now: now,
                    axis: .horizontal,
                    actionLineFraction: playheadFraction,
                    secondsAhead: visibleSeconds * (1 - playheadFraction))
                let content = LaneContent(notation: notation, beatsPerMinute: nil)
                let motionPath = ScratchStrokeGeometry.motionPath(for: content)
                for loopOffset in [-loop, 0, loop] {
                    ScratchMotionRenderer.draw(
                        motionPath.shifted(by: loopOffset),
                        in: ctx, viewport: viewport, style: .target)
                }

                // Crossfader sub-lane (macOS affordance, kept).
                for loopOffset in [-loop, 0, loop] {
                    for stroke in notation.strokes {
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

            // Playhead — sits on top of the strokes so the current time is
            // immediately readable.
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
