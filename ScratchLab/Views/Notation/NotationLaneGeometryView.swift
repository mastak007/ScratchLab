import SwiftUI

// MARK: - NotationLaneGeometryView

/// A standalone, dependency-free SwiftUI view that renders the
/// Section 5 geometry models on a single `Canvas`.
///
/// **Purpose:** prove the Section 5 geometry layer renders without
/// disturbing the existing notation surfaces (`ScratchMotionLane`,
/// `PracticeModeView`, etc.). This view is not wired into Practice,
/// Review, Capture, Coach, or any analyzer/visualizer surface; it
/// exists so Section 5's `NotationLaneGeometryModel`,
/// `NotationGridlineGeometryModel`, and `NotationPlayheadGeometry`
/// have a stable, App-Store-safe rendering target while the team
/// iterates on look.
///
/// **What the view does (and only this):**
///
/// - Fills the canvas with a faint lane background.
/// - Strokes vertical gridlines at the times in
///   `gridlines.gridlines`, using a heavier stroke for `.bar`,
///   medium for `.beat`, and a hairline for `.subdivision`.
/// - Strokes each `NotationLaneStrokeGeometry` as a single line
///   segment from `(xStart, yStart)` to `(xEnd, yEnd)`. Strokes that
///   carry a non-nil `family` draw at full opacity; strokes that
///   carry one or more `coachingKinds` use a slightly thicker line —
///   no labels, no copy, no claim.
/// - When `playhead != nil`, strokes a single vertical line from
///   `playhead.yTop` to `playhead.yBottom` at `playhead.x`. The line
///   dims when `playhead.isWithinViewport == false`.
///
/// **What the view does not do:** no model derivation, no clock, no
/// AVFoundation / capture / replay coupling, no scoring, no ML, no
/// export, no user-facing copy. Geometry is consumed verbatim from
/// the three input models; the only computation here is `SwiftUI`
/// path construction.
struct NotationLaneGeometryView: View {

    let geometry: NotationLaneGeometryModel
    let gridlines: NotationGridlineGeometryModel
    let playhead: NotationPlayheadGeometry?

    var body: some View {
        Canvas { context, size in
            drawBackground(in: &context, size: size)
            drawGridlines(in: &context, size: size)
            drawStrokes(in: &context)
            drawPlayhead(in: &context)
        }
    }

    // MARK: Drawing

    private func drawBackground(in context: inout GraphicsContext, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        context.fill(Path(rect), with: .color(Color.gray.opacity(0.05)))
    }

    private func drawGridlines(in context: inout GraphicsContext, size: CGSize) {
        for line in gridlines.gridlines {
            let style = strokeStyle(for: line.kind)
            var path = Path()
            path.move(to: CGPoint(x: line.x, y: 0))
            path.addLine(to: CGPoint(x: line.x, y: size.height))
            context.stroke(
                path,
                with: .color(Color.gray.opacity(style.opacity)),
                lineWidth: style.width
            )
        }
    }

    private func drawStrokes(in context: inout GraphicsContext) {
        let tintEnabled = FeatureFlags.laneJudgmentTintEnabled
        for stroke in geometry.strokes {
            var path = Path()
            path.move(to: CGPoint(x: stroke.xStart, y: stroke.yStart))
            path.addLine(to: CGPoint(x: stroke.xEnd, y: stroke.yEnd))
            let opacity: Double = stroke.family == nil ? 0.7 : 0.95
            let lineWidth: Double = stroke.coachingKinds.isEmpty ? 2.0 : 2.8
            let baseColor: Color = tintEnabled
                ? Self.judgmentTint(for: stroke.coachingKinds)
                : Color.primary
            context.stroke(
                path,
                with: .color(baseColor.opacity(opacity)),
                lineWidth: lineWidth
            )
        }
    }

    /// Maps a stroke's `coachingKinds` to a `ScratchLabPalette` semantic
    /// alias so the spatial replay renderer (Phase D-S) can address the
    /// same color by name. Strokes with no usable timing signal fall
    /// back to `Color.primary` so the lane stays a neutral reference
    /// surface — the app never asserts an on-beat verdict from absence
    /// of evidence.
    ///
    /// Pure static function so the DEBUG-only test target can lock the
    /// mapping. Phase B1 release-default-false until checkpoint α.
    static func judgmentTint(for kinds: [CoachingEventKind]) -> Color {
        if kinds.contains(.lateReversal)  { return ScratchLabPalette.warning }
        if kinds.contains(.earlyReversal) { return ScratchLabPalette.info }
        return Color.primary
    }

    private func drawPlayhead(in context: inout GraphicsContext) {
        guard let playhead else { return }
        var path = Path()
        path.move(to: CGPoint(x: playhead.x, y: playhead.yTop))
        path.addLine(to: CGPoint(x: playhead.x, y: playhead.yBottom))
        let opacity: Double = playhead.isWithinViewport ? 0.85 : 0.35
        context.stroke(
            path,
            with: .color(Color.accentColor.opacity(opacity)),
            lineWidth: 1.5
        )
    }

    private func strokeStyle(for kind: NotationGridlineKind) -> (width: Double, opacity: Double) {
        switch kind {
        case .bar:         return (width: 1.2, opacity: 0.55)
        case .beat:        return (width: 0.8, opacity: 0.35)
        case .subdivision: return (width: 0.5, opacity: 0.18)
        }
    }
}
