import SwiftUI

/// Canvas view for the Phase 1 live notation overlay.
///
/// Renders a single captured-notation lane: baseline, proportional strokes
/// (reusing `CapturedNotationStrokeGeometry` for travel fraction and visual
/// geometry — the same helper used by `ScratchPhraseChartView.drawCaptured`),
/// FWD / BACK axis labels, and a time-synced cursor.
///
/// The caller drives `currentTime` via an `OverlayReplayController` inside a
/// `TimelineView` — this view owns no animation state, no timer, and no
/// playback logic.
///
/// In `.captured` mode, `LiveNotationOverlayModel.visibleEvents(at:)` ensures
/// no future strokes appear before `currentTime` reaches their `startTime`.
/// Silence/idle events (zero travel fraction) are suppressed by the model.
struct LiveNotationOverlayView: View {

    let model: LiveNotationOverlayModel
    let currentTime: TimeInterval

    private let bgColor       = Color(white: 0.10)
    private let forwardColor  = Color(red: 0.20, green: 0.88, blue: 0.55)
    private let backColor     = Color(red: 1.00, green: 0.55, blue: 0.10)
    private let dotColor      = Color(white: 0.82)
    private let baselineColor = Color(white: 0.22)
    private let cursorColor   = Color.white

    var body: some View {
        Canvas(opaque: false) { context, size in
            guard size.width > 0, size.height > 0 else { return }
            drawBackground(context: context, size: size)
            drawBaseline(context: context, size: size)
            drawStrokes(context: context, size: size)
            drawAxisLabels(context: context, size: size)
            drawCursor(context: context, size: size)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live notation overlay")
        .accessibilityValue(accessibilityValue)
    }

    // MARK: - Background

    private func drawBackground(context: GraphicsContext, size: CGSize) {
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .color(bgColor)
        )
    }

    // MARK: - Baseline

    private func drawBaseline(context: GraphicsContext, size: CGSize) {
        let y = size.height * CGFloat(CapturedNotationStrokeGeometry.baselineFraction)
        var path = Path()
        path.move(to: CGPoint(x: 0, y: y))
        path.addLine(to: CGPoint(x: size.width, y: y))
        context.stroke(path, with: .color(baselineColor), lineWidth: 0.5)
    }

    // MARK: - Strokes

    private func drawStrokes(context: GraphicsContext, size: CGSize) {
        let visible = model.visibleEvents(at: currentTime)
        guard !visible.isEmpty else { return }
        let duration = max(model.duration, 0.01)
        let pps = size.width / CGFloat(duration)
        let baseline = size.height * CGFloat(CapturedNotationStrokeGeometry.baselineFraction)
        let maxBand  = size.height * CGFloat(CapturedNotationStrokeGeometry.maxBandFraction)

        for event in visible {
            let x1 = CGFloat(event.startTime) * pps
            let x2 = CGFloat(event.endTime) * pps
            guard x2 > x1 else { continue }

            let travel = CGFloat(CapturedNotationStrokeGeometry.travelFraction(for: event))
            let peak = baseline - travel * maxBand
            let isForward = event.direction == "forward"

            // Forward `/` rises from baseline at x1 to peak at x2.
            // Backward `\` falls from peak at x1 to baseline at x2.
            let (p1, p2): (CGPoint, CGPoint) = isForward
                ? (CGPoint(x: x1, y: baseline), CGPoint(x: x2, y: peak))
                : (CGPoint(x: x1, y: peak),     CGPoint(x: x2, y: baseline))

            let color = isForward ? forwardColor : backColor
            let alpha = 0.55 + event.confidence * 0.45

            var path = Path()
            path.move(to: p1)
            path.addLine(to: p2)
            context.stroke(path, with: .color(color.opacity(alpha)), lineWidth: 2.5)
            drawDot(context: context, at: p1)
            drawDot(context: context, at: p2)
        }
    }

    private func drawDot(context: GraphicsContext, at point: CGPoint) {
        let r: CGFloat = 4
        let rect = CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)
        context.fill(Path(ellipseIn: rect), with: .color(dotColor))
    }

    // MARK: - Axis labels

    private func drawAxisLabels(context: GraphicsContext, size: CGSize) {
        let baseline = size.height * CGFloat(CapturedNotationStrokeGeometry.baselineFraction)
        let maxBand  = size.height * CGFloat(CapturedNotationStrokeGeometry.maxBandFraction)
        context.draw(
            Text("FWD")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(forwardColor.opacity(0.55)),
            at: CGPoint(x: 4, y: baseline - maxBand * 0.92),
            anchor: .leading
        )
        context.draw(
            Text("BACK")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(backColor.opacity(0.55)),
            at: CGPoint(x: 4, y: baseline - maxBand * 0.72),
            anchor: .leading
        )
    }

    // MARK: - Cursor

    private func drawCursor(context: GraphicsContext, size: CGSize) {
        let fraction = model.cursorFraction(at: currentTime)
        let x = CGFloat(fraction) * size.width
        // Soft glow so the cursor reads clearly against dense notation.
        var glow = Path()
        glow.move(to: CGPoint(x: x, y: 0))
        glow.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(glow, with: .color(cursorColor.opacity(0.22)), lineWidth: 6)
        // Main cursor line.
        var line = Path()
        line.move(to: CGPoint(x: x, y: 0))
        line.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(line, with: .color(cursorColor.opacity(0.95)), lineWidth: 2)
    }

    // MARK: - Accessibility

    private var accessibilityValue: String {
        let visible = model.visibleEvents(at: currentTime)
        let fraction = model.cursorFraction(at: currentTime)
        return String(
            format: "Cursor %.0f%%, %d of %d strokes visible",
            fraction * 100,
            visible.count,
            model.events.count
        )
    }
}
