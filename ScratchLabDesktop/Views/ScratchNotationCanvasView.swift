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
// renderer's output: a fixed playhead at 30% from the left, a FADER
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

    /// Whether playback has wrapped through the loop at least once. When
    /// `false`, adjacent loop tiles (-4.7, +4.7) are suppressed so the
    /// initial view shows only the current phrase with empty lead-in/tail.
    var hasWrapped: Bool = false

    // Layout fractions (record lane : fader lane)
    private let recordLaneFraction: CGFloat = 0.70
    private let faderLaneFraction:  CGFloat = 0.20

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
            drawLaneLabel(ctx: ctx, text: "FADER",  y: faderY + faderH * 0.18, size: size)

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

                // Dynamic loop tiling: when the viewport hasn't wrapped
                // through the loop yet, only the current (0-offset) tile
                // is drawn so the visible window shows the notation's
                // phrase with empty lead-in before `phraseStart` and empty
                // tail after `phraseEnd`. Once playback has wrapped
                // (`hasWrapped == true`), all overlapping tiles are drawn
                // for continuous seamless looping.
                let tileOffsets: [Double] = {
                    if hasWrapped {
                        let visibleStart = now - Double(phX) / Double(pps)
                        let visibleEnd   = visibleStart + visibleSeconds
                        let kMin = Int((visibleStart / loop).rounded(.down))
                        let kMax = Int((visibleEnd   / loop).rounded(.up))
                        return (kMin...kMax).map { Double($0) * loop }
                    } else {
                        return [0]
                    }
                }()

                // Draw each stroke as a single diagonal slash — the same
                // action-notation trace the iOS Practice target lane uses.
                // Forward strokes rise (`/`), backward strokes fall (`\`).
                // No V-shaped out-and-return tents, no junction nodes.
                for loopOffset in tileOffsets {
                    let shifted = loopOffset == 0
                        ? content.strokes
                        : content.strokes.map { $0.shifted(by: loopOffset) }
                    ScratchMotionRenderer.drawActionNotationTrace(
                        shifted, in: ctx, viewport: viewport, style: .target)
                }

                // Fader sub-lane — binary OPEN/CLOSED rails (V2).
                // Non-empty canonical `faderEvents` is authoritative; otherwise
                // falls back to one span per stroke's own `faderState`.
                let faderSpans = notation.faderAuthoritySpans(documentEnd: content.duration)
                for loopOffset in tileOffsets {
                    drawFaderRails(ctx: ctx, spans: faderSpans,
                                   loopOffset: loopOffset, now: now,
                                   phX: phX, pps: pps,
                                   laneRect: faderRect, canvasWidth: size.width)
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

    // MARK: - Fader lane (binary rails)

    /// Draws the fader lane as two binary rails — OPEN (top) and
    /// CLOSED (bottom) — with the active rail highlighted and vertical
    /// transition marks at state-change edges.  This replaces the older
    /// continuous-span treatment with a two-rail V2 presentation.
    ///
    /// Baby Scratch (OPEN throughout) renders as a single solid OPEN rail
    /// with no transitions.
    private func drawFaderRails(
        ctx: GraphicsContext,
        spans: [LaneFaderSpan],
        loopOffset: Double,
        now: Double,
        phX: CGFloat,
        pps: CGFloat,
        laneRect: CGRect,
        canvasWidth: CGFloat
    ) {
        let topY    = laneRect.minY + laneRect.height * 0.15
        let bottomY = laneRect.minY + laneRect.height * 0.88
        let guideAlpha: Double = 0.18
        let activeAlpha: Double = 0.80
        let pastAlpha: Double = 0.22
        let transitionAlpha: Double = 0.55

        // Guide rails — faint horizontal lines for OPEN (top) and CLOSED (bottom)
        for (y, label) in [(topY, "OPEN"), (bottomY, "CLOSED")] {
            var guide = Path()
            guide.move(to: CGPoint(x: max(0, laneRect.minX), y: y))
            guide.addLine(to: CGPoint(x: min(canvasWidth, laneRect.maxX), y: y))
            ctx.stroke(guide, with: .color(Color(white: 0.28).opacity(guideAlpha)),
                       lineWidth: 0.5)
            // Rail label — OPEN just below the open rail, CLOSED just above
            // the closed rail (compact placement, no overlap).
            if label == "OPEN" {
                ctx.draw(
                    Text(label)
                        .font(.system(size: 5.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color(white: 0.32)),
                    at: CGPoint(x: 4, y: y + 1),
                    anchor: .topLeading
                )
            } else {
                ctx.draw(
                    Text(label)
                        .font(.system(size: 5.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color(white: 0.32)),
                    at: CGPoint(x: 4, y: y - 1),
                    anchor: .bottomLeading
                )
            }
        }

        guard !spans.isEmpty else { return }

        // Sort merged spans and draw active-rail segments + transitions
        let merged = mergeAdjacentSpans(spans)
        for span in merged {
            let x1 = phX + CGFloat(span.startTime + loopOffset - now) * pps
            let x2 = phX + CGFloat(span.endTime   + loopOffset - now) * pps
            guard x2 >= -60, x1 <= canvasWidth + 60 else { continue }

            let isPast = x2 < phX
            let alpha = isPast ? pastAlpha : activeAlpha
            let activeY = span.state == .open ? topY : bottomY
            let activeColor: Color = span.state == .open
                ? Color(red: 0.20, green: 0.88, blue: 0.55)
                : Color(red: 1.00, green: 0.25, blue: 0.25)

            // Active rail segment
            var rail = Path()
            let clampedX1 = max(laneRect.minX, x1)
            let clampedX2 = min(canvasWidth, x2)
            rail.move(to: CGPoint(x: clampedX1, y: activeY))
            rail.addLine(to: CGPoint(x: clampedX2, y: activeY))
            ctx.stroke(rail, with: .color(activeColor.opacity(alpha)), lineWidth: 2.5)

            // Transition mark at span start (except very first span)
            if span.startTime > 0.001 {
                let prevState: ScratchNotationFaderState = span.state == .open ? .closed : .open
                let prevY = prevState == .open ? topY : bottomY
                var trans = Path()
                trans.move(to: CGPoint(x: x1, y: prevY))
                trans.addLine(to: CGPoint(x: x1, y: activeY))
                ctx.stroke(trans, with: .color(Color(white: 0.75).opacity(transitionAlpha)),
                           lineWidth: 1.2)
                // Small diamond at the transition point
                let d: CGFloat = 2.5
                var diamond = Path()
                diamond.move(to: CGPoint(x: x1, y: activeY - d))
                diamond.addLine(to: CGPoint(x: x1 + d, y: activeY))
                diamond.addLine(to: CGPoint(x: x1, y: activeY + d))
                diamond.addLine(to: CGPoint(x: x1 - d, y: activeY))
                diamond.closeSubpath()
                ctx.fill(diamond, with: .color(Color(white: 0.82).opacity(transitionAlpha)))
            }
        }
    }

    /// Merges consecutive spans that share the same state, producing a
    /// minimal set of contiguous open/closed intervals.
    private func mergeAdjacentSpans(_ spans: [LaneFaderSpan]) -> [LaneFaderSpan] {
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
}

// MARK: - Preview

#if DEBUG
// Preview macro disabled: PreviewsMacros.SwiftUIView plugin unavailable.
#if false
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
#endif // #if false
#endif
