import SwiftUI

/// Read-only overlay diff viewer that draws the authored target
/// notation under the captured notation along a shared time axis.
///
/// Slice 4.1 (foundation): visual verification only — no editing, no
/// drift heatmap, no annotation tools, no export hooks. Drift between
/// the two lanes is implicit in the horizontal offset between paired
/// target and captured events on the shared axis.
///
/// Visual rules:
///   - target events render as outlined "ghost" marks at low opacity
///   - captured events render as solid primary marks
///   - the playhead cursor is a vertical line at `currentTime`
///     clamped via `ReviewOverlayTimeline.clamp(time:)`
///
/// The view is a pure function of `(overlay, currentTime)` — it owns
/// no animation state, no timer, no replay cursor of its own. The
/// caller drives `currentTime` from a `SessionReplayClock`
/// (typically `clock.currentTime(hostTime:)` inside a `TimelineView`
/// schedule) which guarantees deterministic seek-safety end-to-end.
struct ReviewOverlayLaneView: View {

    let overlay: ReviewOverlayTimeline
    let currentTime: TimeInterval

    private static let laneInsetX: CGFloat = 8
    private static let laneInsetY: CGFloat = 8
    private static let laneGap: CGFloat = 6
    private static let cursorWidth: CGFloat = 1.0
    private static let pointWidth: CGFloat = 2.0
    private static let intervalMinWidth: CGFloat = 2.0

    var body: some View {
        Canvas(opaque: false) { context, size in
            drawBackground(context: context, size: size)
            let layout = laneLayout(in: size)
            drawLaneBaseline(context: context, frame: layout.target)
            drawLaneBaseline(context: context, frame: layout.captured)
            drawEvents(
                context: context,
                events: overlay.target.events,
                frame: layout.target,
                style: .ghost
            )
            drawEvents(
                context: context,
                events: overlay.captured.events,
                frame: layout.captured,
                style: .primary
            )
            drawCursor(context: context, size: size)
        }
        .frame(minHeight: 64)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Overlay diff viewer")
        .accessibilityValue(accessibilityValue)
    }

    // MARK: - Layout

    private struct LaneLayout {
        let target: CGRect
        let captured: CGRect
    }

    private func laneLayout(in size: CGSize) -> LaneLayout {
        let drawableHeight = max(
            0,
            size.height - (Self.laneInsetY * 2) - Self.laneGap
        )
        let laneHeight = drawableHeight / 2
        let drawableWidth = max(0, size.width - (Self.laneInsetX * 2))
        let target = CGRect(
            x: Self.laneInsetX,
            y: Self.laneInsetY,
            width: drawableWidth,
            height: laneHeight
        )
        let captured = CGRect(
            x: Self.laneInsetX,
            y: target.maxY + Self.laneGap,
            width: drawableWidth,
            height: laneHeight
        )
        return LaneLayout(target: target, captured: captured)
    }

    // MARK: - Drawing

    private enum LaneStyle {
        case ghost
        case primary

        var fill: Color {
            switch self {
            case .ghost:   return ScratchLabDesign.Notation.dot.opacity(0.28)
            case .primary: return ScratchLabDesign.Notation.audioBurst
            }
        }

        var stroke: Color {
            switch self {
            case .ghost:   return ScratchLabDesign.Notation.dot.opacity(0.45)
            case .primary: return ScratchLabDesign.Notation.audioBurst
            }
        }
    }

    private func drawBackground(context: GraphicsContext, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        context.fill(
            Path(rect),
            with: .color(ScratchLabDesign.Notation.canvasBg)
        )
    }

    private func drawLaneBaseline(context: GraphicsContext, frame: CGRect) {
        guard frame.width > 0, frame.height > 0 else { return }
        let midY = frame.midY
        var path = Path()
        path.move(to: CGPoint(x: frame.minX, y: midY))
        path.addLine(to: CGPoint(x: frame.maxX, y: midY))
        context.stroke(
            path,
            with: .color(ScratchLabDesign.Notation.gridMinor),
            lineWidth: 1
        )
    }

    private func drawEvents(
        context: GraphicsContext,
        events: [SessionReplayEvent],
        frame: CGRect,
        style: LaneStyle
    ) {
        guard frame.width > 0, frame.height > 0, !events.isEmpty else { return }
        let span = overlay.displayDurationSeconds
        guard span > 0 else { return }

        for event in events {
            let startX = frame.minX + xOffset(for: event.startTime, frame: frame, span: span)
            let endX: CGFloat
            if let endTime = event.endTime, endTime > event.startTime {
                endX = frame.minX + xOffset(for: endTime, frame: frame, span: span)
            } else {
                endX = startX
            }
            let drawnWidth = max(
                endX > startX ? Self.intervalMinWidth : Self.pointWidth,
                endX - startX
            )
            let rect = CGRect(
                x: startX,
                y: frame.minY + frame.height * 0.2,
                width: drawnWidth,
                height: frame.height * 0.6
            )
            let path = Path(roundedRect: rect, cornerRadius: 1.5)
            context.fill(path, with: .color(style.fill))
            if style == .ghost {
                context.stroke(path, with: .color(style.stroke), lineWidth: 0.75)
            }
        }
    }

    private func drawCursor(context: GraphicsContext, size: CGSize) {
        let span = overlay.displayDurationSeconds
        guard span > 0, size.width > Self.laneInsetX * 2 else { return }
        let clamped = overlay.clamp(time: currentTime)
        let drawableWidth = size.width - (Self.laneInsetX * 2)
        let x = Self.laneInsetX + CGFloat(clamped / span) * drawableWidth
        var path = Path()
        path.move(to: CGPoint(x: x, y: 0))
        path.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(
            path,
            with: .color(ScratchLabDesign.Sem.accent),
            lineWidth: Self.cursorWidth
        )
    }

    private func xOffset(for time: TimeInterval, frame: CGRect, span: Double) -> CGFloat {
        let clamped = max(0, min(time, span))
        let ratio = clamped / span
        return CGFloat(ratio) * frame.width
    }

    // MARK: - Accessibility

    private var accessibilityValue: String {
        let span = overlay.displayDurationSeconds
        if span <= 0 {
            return "Empty overlay"
        }
        let cursor = overlay.clamp(time: currentTime)
        return String(
            format: "Target events: %d, captured events: %d, cursor %.2fs of %.2fs",
            overlay.target.events.count,
            overlay.captured.events.count,
            cursor,
            span
        )
    }
}
