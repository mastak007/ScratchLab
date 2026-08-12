import SwiftUI

/// Background rendering mode for `LiveNotationOverlayView`.
enum LiveNotationOverlayBackground {
    case solid
    case translucent
}

/// Stroke drawing mode for `LiveNotationOverlayView`.
enum LiveNotationOverlayDrawMode {
    case fullReference
    case replayReveal
}

/// Motion-style live notation overlay.
///
/// F/B pairs are drawn as **connected diagonal lines** — F rises from
/// baseline to the pair amplitude turning point, B mirrors back from
/// that same point to baseline.  The final forward let-go is a gold
/// release line.  No per-stroke text labels, no boundary dots.
///
/// An optional beat grid can be drawn behind the strokes.
struct LiveNotationOverlayView: View {

    let model: LiveNotationOverlayModel
    let currentTime: TimeInterval
    var background: LiveNotationOverlayBackground = .solid
    var drawMode: LiveNotationOverlayDrawMode = .fullReference
    var viewportSeconds: TimeInterval? = nil

    // Beat grid (optional)
    var beatGridBPM: Double? = nil
    var beatGridFirstBeatTime: Double = 0
    var beatsPerBar: Int = 4
    /// Caps the effective stroke travel fraction. Default `1.0` (no cap).
    /// Set to `0.35` for Baby Scratch to produce compact centre-band strokes.
    var maximumAmplitude: Double = 1.0

    /// Optional canonical notation used ONLY for fader authority.
    /// When non-nil, `faderAuthoritySpans(documentEnd:)` drives the fader
    /// lane; when nil (captured mode with no canonical reference), the
    /// fader lane shows guide rails and labels but no active rail.
    /// The renderer is technique-agnostic — Baby Scratch resolves to OPEN
    /// throughout because its canonical `faderEvents` say so, not because
    /// the renderer hard-codes that behaviour.
    var faderAuthorityNotation: ScratchNotation? = nil

    // Palette
    private let bgColor       = Color(white: 0.10)
    private let forwardColor  = Color(red: 0.20, green: 0.88, blue: 0.55)
    private let backColor     = Color(red: 1.00, green: 0.55, blue: 0.10)
    private let letgoColor    = Color(red: 1.00, green: 0.80, blue: 0.00)
    private let baselineColor = Color(white: 0.22)
    private let translucentBaselineColor = Color(white: 0.38)
    private let cursorColor   = Color.white
    private let playheadFraction: Double = 0.45
    private let beatLineColor   = Color(white: 0.22)
    private let barLineColor    = Color(white: 0.34)

    // MARK: - Viewport

    /// Returns the visible time window so that `currentTime` always maps
    /// to the fixed playhead position (`playheadFraction` from the left edge).
    ///
    /// There is **no clamping** — `tMin` is allowed to be negative (empty
    /// lead-in before the phrase) and `tMax` may extend past `model.duration`
    /// (empty tail-out after the phrase). This ensures the playhead is always
    /// at `currentTime` and strokes scroll continuously through it.
    private func canvasTimeRange(size: CGSize) -> (tMin: TimeInterval, tMax: TimeInterval) {
        if let vp = viewportSeconds, vp > 0 {
            let tMin = currentTime - vp * playheadFraction
            let tMax = tMin + vp
            return (tMin, tMax)
        }
        return (0, max(model.duration, 0.01))
    }

    // MARK: - Body

    /// Fraction of height reserved for the fader lane below the platter.
    private let faderLaneFraction: CGFloat = 0.26

    var body: some View {
        Canvas(opaque: false) { context, size in
            guard size.width > 0, size.height > 0 else { return }
            let (rangeMin, rangeMax) = canvasTimeRange(size: size)
            let vDur = max(rangeMax - rangeMin, 0.01)
            let rangeMaxV = rangeMin + vDur

            let recordH = size.height * (1 - faderLaneFraction)
            let faderY  = recordH

            if background == .solid {
                drawBackground(context: context, size: size)
            }
            drawBeatGrid(context: context, size: size,
                         rangeMin: rangeMin, rangeMax: rangeMaxV)

            // PLATTER lane (top)
            drawBaseline(context: context, size: CGSize(width: size.width, height: recordH))
            drawMotionStrokes(context: context, size: CGSize(width: size.width, height: recordH),
                              rangeMin: rangeMin, visibleDuration: vDur)
            // Lane divider
            var div = Path()
            div.move(to: CGPoint(x: 0, y: faderY))
            div.addLine(to: CGPoint(x: size.width, y: faderY))
            context.stroke(div, with: .color(Color(white: 0.28)), lineWidth: 0.5)

            // FADER lane (bottom) — binary OPEN/CLOSED rails
            drawFaderLane(context: context, size: size, faderY: faderY,
                          rangeMin: rangeMin, visibleDuration: vDur)

            // Cursor crosses both lanes
            drawCursor(context: context, size: size,
                       rangeMin: rangeMin, visibleDuration: vDur)
        }
        .background(
            Group {
                if background == .translucent {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.ultraThinMaterial)
                }
            }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live notation overlay")
        .accessibilityValue(accessibilityValue)
    }

    // MARK: - Background

    private func drawBackground(context: GraphicsContext, size: CGSize) {
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(bgColor))
    }

    // MARK: - Baseline

    private func drawBaseline(context: GraphicsContext, size: CGSize) {
        let y = size.height * CGFloat(CapturedNotationStrokeGeometry.baselineFraction)
        var path = Path()
        path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
        let lc = background == .translucent ? translucentBaselineColor : baselineColor
        context.stroke(path, with: .color(lc), lineWidth: 0.5)
    }

    // MARK: - Beat Grid

    private func drawBeatGrid(context: GraphicsContext, size: CGSize,
                              rangeMin: TimeInterval, rangeMax: TimeInterval) {
        guard let bpm = beatGridBPM, bpm > 0 else { return }
        let bi = 60.0 / bpm
        let offset = beatGridFirstBeatTime
        let firstBeat = ceil((rangeMin - offset) / bi)
        let lastBeat  = floor((rangeMax - offset) / bi)
        let w = size.width; let d = rangeMax - rangeMin
        func xForBeat(_ beat: Double) -> CGFloat {
            CGFloat((offset + beat * bi - rangeMin) / d) * w
        }
        for beat in Int(firstBeat)...Int(lastBeat) {
            let x = xForBeat(Double(beat))
            let isBar = beat % beatsPerBar == 0
            let lineColor = isBar ? barLineColor : beatLineColor
            let lw: CGFloat = isBar ? 0.6 : 0.3
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(line, with: .color(lineColor.opacity(0.5)), lineWidth: lw)
        }
    }

    // MARK: - Motion strokes

    private func xForTime(_ t: TimeInterval, rangeMin: TimeInterval,
                          visibleDuration: TimeInterval, width: CGFloat) -> CGFloat {
        CGFloat((t - rangeMin) / visibleDuration) * width
    }

    /// Pair consecutive stroke events into F/B units.
    /// Each pair: F rises from baseline to peak, B returns from peak to baseline.
    /// The final event is the let-go release.
    private func drawMotionStrokes(context: GraphicsContext, size: CGSize,
                                   rangeMin: TimeInterval, visibleDuration: TimeInterval) {
        let rangeMax = rangeMin + visibleDuration
        let viewportEvents = model.eventsInViewport(
            rangeMin: rangeMin, rangeMax: rangeMax, currentTime: currentTime
        )
        guard !viewportEvents.isEmpty else { return }
        let baseline = size.height * CGFloat(CapturedNotationStrokeGeometry.baselineFraction)
        let maxBand  = size.height * CGFloat(CapturedNotationStrokeGeometry.maxBandFraction)
        let cap = CGFloat(maximumAmplitude)

        /// Capped travel fraction — limits stroke height to `maximumAmplitude`
        /// so Baby Scratch reads as a compact centre-band rather than full-height.
        func travelFor(_ event: CaptureCore.DetectedNotationRecordMovementEvent) -> CGFloat {
            min(cap, CGFloat(CapturedNotationStrokeGeometry.travelFraction(for: event)))
        }

        // Process events in F/B pairs
        var i = 0
        let events = viewportEvents
        while i < events.count {
            let e0 = events[i]
            let isLast = i == events.count - 1
            let hasNext = i + 1 < events.count

            // Determine if this is a standalone (let-go) or paired with next
            let isLetGo = e0.direction == "forward" && (!hasNext || events[i+1].direction != "backward")
            let pairUp = hasNext && !isLetGo && e0.direction == "forward" && events[i+1].direction == "backward"

            if isLetGo {
                // Final let-go: gold forward release line.  Rises from
                // baseline toward the peak — a single forward gesture, not
                // a pair, with no downward return.
                let ts = e0.startTime; let te = e0.endTime; guard te > ts else { i += 1; continue }
                let travel = travelFor(e0)
                let peak = baseline - travel * maxBand
                let x1 = xForTime(ts, rangeMin: rangeMin, visibleDuration: visibleDuration, width: size.width)
                let x2 = xForTime(te, rangeMin: rangeMin, visibleDuration: visibleDuration, width: size.width)
                guard x2 > x1 else { i += 1; continue }

                let isActive = currentTime >= ts && currentTime < te
                let isFuture = ts > currentTime
                let lw: CGFloat = 3.5
                let color: Color; let alpha: Double
                if isActive  { color = letgoColor; alpha = 0.85 }
                else if isFuture { color = Color(white: 0.45); alpha = 0.40 }
                else { color = letgoColor; alpha = 0.50 }

                let (p1, p2): (CGPoint, CGPoint)
                if drawMode == .replayReveal, isActive {
                    let progress = (te - ts) > 0 ? CGFloat((currentTime - ts) / (te - ts)) : 1
                    let cx = x1 + (x2 - x1) * progress
                    let cy = baseline - (baseline - peak) * progress
                    p1 = CGPoint(x: x1, y: baseline)
                    p2 = CGPoint(x: cx, y: cy)
                } else {
                    p1 = CGPoint(x: x1, y: baseline)
                    p2 = CGPoint(x: x2, y: peak)
                }
                var path = Path(); path.move(to: p1); path.addLine(to: p2)
                context.stroke(path, with: .color(color.opacity(alpha)), lineWidth: lw)
                i += 1

            } else if pairUp {
                // F/B pair: connected V-shaped diagonal lines
                let f = e0; let b = events[i+1]
                let f_ts = f.startTime; let b_te = b.endTime
                let turnPoint = b.startTime // F ends here, B starts here
                guard b_te > f_ts, turnPoint > f_ts, b_te > turnPoint else { i += 2; continue }

                let travel = travelFor(f)
                let peak = baseline - travel * maxBand

                let x_fs = xForTime(f_ts, rangeMin: rangeMin, visibleDuration: visibleDuration, width: size.width)
                let x_tp = xForTime(turnPoint, rangeMin: rangeMin, visibleDuration: visibleDuration, width: size.width)
                let x_be = xForTime(b_te, rangeMin: rangeMin, visibleDuration: visibleDuration, width: size.width)
                guard x_tp > x_fs, x_be > x_tp else { i += 2; continue }

                // Time-class each stroke
                let fActive = currentTime >= f_ts && currentTime < turnPoint
                let bActive = currentTime >= turnPoint && currentTime < b_te
                let fFuture = f_ts > currentTime
                let bFuture = !bActive && turnPoint > currentTime
                let fPast = turnPoint <= currentTime
                let bPast = b_te <= currentTime

                // F line
                let fColor: Color; let fAlpha: Double
                if fActive { fColor = forwardColor; fAlpha = 0.85 }
                else if fFuture { fColor = Color(white: 0.45); fAlpha = 0.40 }
                else { fColor = forwardColor; fAlpha = 0.48 }

                var fPath = Path(); fPath.move(to: CGPoint(x: x_fs, y: baseline))
                if drawMode == .replayReveal, fActive {
                    let prog = CGFloat((currentTime - f_ts) / (turnPoint - f_ts))
                    let cx = x_fs + (x_tp - x_fs) * prog
                    let cy = baseline - (baseline - peak) * prog
                    fPath.addLine(to: CGPoint(x: cx, y: cy))
                } else {
                    fPath.addLine(to: CGPoint(x: x_tp, y: peak))
                }
                context.stroke(fPath, with: .color(fColor.opacity(fAlpha)), lineWidth: 3.0)

                // B line
                let bColor: Color; let bAlpha: Double
                if bActive { bColor = backColor; bAlpha = 0.85 }
                else if bFuture { bColor = Color(white: 0.45); bAlpha = 0.40 }
                else { bColor = backColor; bAlpha = 0.48 }

                var bPath = Path(); bPath.move(to: CGPoint(x: x_tp, y: peak))
                if drawMode == .replayReveal, bActive {
                    let prog = CGFloat((currentTime - turnPoint) / (b_te - turnPoint))
                    let cx = x_tp + (x_be - x_tp) * prog
                    let cy = peak + (baseline - peak) * prog
                    bPath.addLine(to: CGPoint(x: cx, y: cy))
                } else {
                    bPath.addLine(to: CGPoint(x: x_be, y: baseline))
                }
                context.stroke(bPath, with: .color(bColor.opacity(bAlpha)), lineWidth: 3.0)
                i += 2

            } else {
                // Standalone backward or unpaired — draw as simple diagonal
                let ts = e0.startTime; let te = e0.endTime; guard te > ts else { i += 1; continue }
                let travel = travelFor(e0)
                let peak = baseline - travel * maxBand
                let x1 = xForTime(ts, rangeMin: rangeMin, visibleDuration: visibleDuration, width: size.width)
                let x2 = xForTime(te, rangeMin: rangeMin, visibleDuration: visibleDuration, width: size.width)
                guard x2 > x1 else { i += 1; continue }

                let isActive = currentTime >= ts && currentTime < te
                let isFuture = ts > currentTime
                let isFwd = e0.direction == "forward"
                let baseColor = isFwd ? forwardColor : backColor
                let color: Color; let alpha: Double
                if isActive  { color = baseColor; alpha = 0.85 }
                else if isFuture { color = Color(white: 0.45); alpha = 0.40 }
                else { color = baseColor; alpha = 0.48 }

                let y1 = isFwd ? baseline : peak; let y2 = isFwd ? peak : baseline
                var path = Path(); path.move(to: CGPoint(x: x1, y: y1)); path.addLine(to: CGPoint(x: x2, y: y2))
                context.stroke(path, with: .color(color.opacity(alpha)), lineWidth: 2.5)
                i += 1
            }
        }
    }

    // MARK: - Fader lane (binary rails)

    private func drawFaderLane(context: GraphicsContext, size: CGSize,
                                faderY: CGFloat,
                                rangeMin: TimeInterval, visibleDuration: TimeInterval) {
        let laneHeight = size.height - faderY
        let topY    = faderY + laneHeight * 0.15
        let bottomY = faderY + laneHeight * 0.88

        // FADER label anchored above the divider — sits in the bottom margin
        // of the platter region so it never competes with OPEN/CLOSED below.
        context.draw(
            Text("FADER")
                .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(white: 0.40)),
            at: CGPoint(x: 4, y: faderY),
            anchor: .bottomLeading
        )

        // Guide rails
        for y in [topY, bottomY] {
            var guide = Path()
            guide.move(to: CGPoint(x: 0, y: y))
            guide.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(guide, with: .color(Color(white: 0.28).opacity(0.16)),
                           lineWidth: 0.5)
        }

        // Active fader rails — consume canonical fader authority only.
        // No hard-coded technique behaviour. Baby Scratch produces OPEN
        // throughout because its canonical faderEvents say so.
        let duration = max(model.duration, 0.01)
        if let notation = faderAuthorityNotation {
            let spans = notation.faderAuthoritySpans(documentEnd: duration)
            for span in spans {
                guard span.endTime > span.startTime else { continue }
                let x1 = max(0, CGFloat((span.startTime - rangeMin) / visibleDuration) * size.width)
                let x2 = min(size.width, CGFloat((span.endTime - rangeMin) / visibleDuration) * size.width)
                guard x2 > x1 else { continue }
                let activeY = span.state == .open ? topY : bottomY
                let activeColor: Color = span.state == .open
                    ? Color(red: 0.20, green: 0.88, blue: 0.55)
                    : Color(red: 1.00, green: 0.25, blue: 0.25)
                var rail = Path()
                rail.move(to: CGPoint(x: max(0, x1), y: activeY))
                rail.addLine(to: CGPoint(x: min(size.width, x2), y: activeY))
                context.stroke(rail, with: .color(activeColor.opacity(0.70)), lineWidth: 2.5)
            }
        }
        // When faderAuthorityNotation is nil (captured mode), no active rail
        // is drawn — the fader lane shows empty guide rails only.

        // Rail labels on top. OPEN sits just below the open rail; CLOSED
        // sits just above the closed rail. At 80pt Practice Live height
        // these do not overlap with each other or with FADER above.
        context.draw(
            Text("OPEN")
                .font(.system(size: 5.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(white: 0.32)),
            at: CGPoint(x: 4, y: topY + 1),
            anchor: .topLeading
        )
        context.draw(
            Text("CLOSED")
                .font(.system(size: 5.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(white: 0.32)),
            at: CGPoint(x: 4, y: bottomY - 1),
            anchor: .bottomLeading
        )

        // PLATTER label
        context.draw(
            Text("PLATTER")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(white: 0.40)),
            at: CGPoint(x: 4, y: 3),
            anchor: .topLeading
        )
    }

    // MARK: - Cursor

    private func drawCursor(context: GraphicsContext, size: CGSize,
                            rangeMin: TimeInterval, visibleDuration: TimeInterval) {
        let x: CGFloat
        if viewportSeconds != nil {
            x = size.width * CGFloat(playheadFraction)
        } else {
            x = CGFloat(model.cursorFraction(at: currentTime)) * size.width
        }
        var glow = Path(); glow.move(to: CGPoint(x: x, y: 0)); glow.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(glow, with: .color(cursorColor.opacity(0.22)), lineWidth: 6)
        var line = Path(); line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(line, with: .color(cursorColor.opacity(0.95)), lineWidth: 2)
    }

    // MARK: - Accessibility

    private var accessibilityValue: String {
        String(format: "Cursor %.1fs, %d strokes", currentTime, model.events.count)
    }
}
