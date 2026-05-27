import CoreGraphics
import Foundation

// MARK: - CinematicFrameRenderer

/// Pure, deterministic rasteriser for a `CinematicFrame`. Renders the
/// projected lane / gridlines / playhead into a CGImage with an
/// alpha channel — the same geometry the SwiftUI `Canvas` already
/// renders, drawn via Core Graphics so the output can be fed into
/// `AVAssetWriter` (Phase D-X1) without re-deriving from SwiftUI.
///
/// **Pure / deterministic.** Same inputs → byte-identical CGImage
/// across calls. No clock, no AVFoundation, no UIKit, no SwiftUI, no
/// Combine, no AppKit. Uses only Foundation + CoreGraphics; semantic
/// palette tokens are inlined as deterministic sRGB constants so the
/// rasteriser never depends on platform colour-conversion paths.
///
/// **Lane / gridline / playhead vocabulary** mirrors the on-screen
/// `NotationLaneGeometryView` so the exported video reads identically
/// to the rendered surface — same opacities, same line widths, same
/// semantic colours.
enum CinematicFrameRenderer {

    static func renderImage(
        frame: CinematicFrame,
        width: Int,
        height: Int
    ) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let context = makeContext(width: width, height: height)
        guard let context else { return nil }

        // Coordinate convention: CGContext is bottom-up by default.
        // Flip Y so the SwiftUI top-down geometry maps directly.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        drawBackground(context: context, width: width, height: height)
        drawGridlines(context: context, frame: frame)
        drawStrokes(context: context, frame: frame)
        drawPlayhead(context: context, frame: frame)

        return context.makeImage()
    }

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        )
    }

    private static func drawBackground(context: CGContext, width: Int, height: Int) {
        // Transparent background — D-X1's whole point is the alpha
        // channel. The SwiftUI host paints a faint lane wash; the
        // exporter intentionally drops that so OBS / Premiere consumers
        // get a clean notation overlay.
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
    }

    private static func drawGridlines(context: CGContext, frame: CinematicFrame) {
        guard let gridlines = frame.gridlineGeometry else { return }
        for line in gridlines.gridlines {
            let style = strokeStyle(for: line.kind)
            let rgba = paletteRGBA(.neutralGrid, opacity: style.opacity)
            context.setStrokeColor(red: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a)
            context.setLineWidth(CGFloat(style.width))
            context.beginPath()
            context.move(to: CGPoint(x: line.x, y: 0))
            context.addLine(to: CGPoint(x: line.x, y: frame.viewport.height))
            context.strokePath()
        }
    }

    private static func drawStrokes(context: CGContext, frame: CinematicFrame) {
        for stroke in frame.laneGeometry.strokes {
            let opacity = stroke.family == nil ? 0.7 : 0.95
            let lineWidth = stroke.coachingKinds.isEmpty ? 2.0 : 2.8
            let token = paletteToken(for: stroke.coachingKinds)
            let rgba = paletteRGBA(token, opacity: opacity)
            context.setStrokeColor(red: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a)
            context.setLineWidth(CGFloat(lineWidth))
            context.beginPath()
            context.move(to: CGPoint(x: stroke.xStart, y: stroke.yStart))
            context.addLine(to: CGPoint(x: stroke.xEnd, y: stroke.yEnd))
            context.strokePath()
        }
    }

    private static func drawPlayhead(context: CGContext, frame: CinematicFrame) {
        guard let playhead = frame.playhead else { return }
        let opacity = playhead.isWithinViewport ? 0.85 : 0.35
        let rgba = paletteRGBA(.playhead, opacity: opacity)
        context.setStrokeColor(red: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a)
        context.setLineWidth(1.5)
        context.beginPath()
        context.move(to: CGPoint(x: playhead.x, y: playhead.yTop))
        context.addLine(to: CGPoint(x: playhead.x, y: playhead.yBottom))
        context.strokePath()
    }

    // MARK: Style helpers (mirror the on-screen view)

    private static func strokeStyle(for kind: NotationGridlineKind) -> (width: Double, opacity: Double) {
        switch kind {
        case .bar:         return (1.2, 0.55)
        case .beat:        return (0.8, 0.35)
        case .subdivision: return (0.5, 0.18)
        }
    }

    private enum PaletteToken {
        case neutralGrid
        case primaryStroke
        case success
        case info
        case warning
        case playhead
    }

    private static func paletteToken(for kinds: [CoachingEventKind]) -> PaletteToken {
        // Phase B1 judgment-color rules mirrored verbatim.
        if kinds.contains(.lateReversal)  { return .warning }
        if kinds.contains(.earlyReversal) { return .info }
        return .primaryStroke
    }

    private static func paletteRGBA(
        _ token: PaletteToken,
        opacity: Double
    ) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        let safeOpacity = max(0, min(1, opacity))
        let rgb = paletteRGB(token)
        return (
            r: CGFloat(rgb.0),
            g: CGFloat(rgb.1),
            b: CGFloat(rgb.2),
            a: CGFloat(safeOpacity)
        )
    }

    /// Resolves a semantic palette token to deterministic sRGB
    /// components. Mirrors `ScratchLabPalette` literal values so the
    /// rendered video matches the on-screen surface byte-for-byte
    /// without going through `NSColor`'s sRGB conversion at every
    /// frame.
    private static func paletteRGB(_ token: PaletteToken) -> (Double, Double, Double) {
        switch token {
        case .neutralGrid:
            return (0.5, 0.5, 0.5) // matches Color.gray neutral
        case .primaryStroke:
            return (1.0, 1.0, 1.0) // matches Color.primary on dark canvas
        case .success:
            return (34.0 / 255.0, 197.0 / 255.0, 94.0 / 255.0)
        case .info:
            return (14.0 / 255.0, 165.0 / 255.0, 233.0 / 255.0)
        case .warning:
            return (245.0 / 255.0, 158.0 / 255.0, 11.0 / 255.0)
        case .playhead:
            return (1.0, 1.0, 1.0) // matches Color.accentColor in the host
        }
    }
}
