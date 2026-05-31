import SwiftUI

/// Display-only render configuration for the Scratch Playback Lab notation
/// previews (roadmap slice **R0** — "render-config foundation").
///
/// The single source of truth for *how* captured notation is drawn — never for
/// *what* was captured. It maps onto primitives that already exist
/// (`ScratchMotionRenderer.Style`, the `LaneViewport` time density) so future
/// controls (R1–R9) can read and mutate one object instead of touching scattered
/// literals. Per the roadmap's non-negotiable rule this is **strictly
/// display-only**: it does NOT mutate the captured `ScratchSampleTimeline`,
/// exported JSON positions, notation geometry, scoring, or analysis. It is
/// intentionally NOT `Codable` — nothing here is persisted or exported.
///
/// The memberwise defaults reproduce today's captured-notation preview exactly:
/// at `PlaybackLabRenderConfig()` the derived `motionStyle` is byte-equal to
/// `ScratchMotionRenderer.Style.user`, `mutedAlpha` matches the current muted
/// band, and `horizontalZoom == 1` leaves the viewport's time density unchanged.
/// No UI controls are surfaced yet (R0 is foundation only).
struct PlaybackLabRenderConfig: Equatable {

    // MARK: - Wired display fields (read by the captured-notation preview today)

    /// Base stroke-ramp width handed to `ScratchMotionRenderer.Style.lineWidth`.
    /// Default matches the `.user` style (the captured-user overlay look). R3.
    var lineWidth: CGFloat = 3

    /// Tight glow behind the stroke ramps (`Style.glow`). Default ON to match
    /// the `.user` style the preview uses today.
    var glow: Bool = true

    /// Junction articulation dots (`Style.showsNodes`). Default ON, as today.
    var showsNodes: Bool = true

    /// Opacity of the faint band drawn over crossfader-closed (muted) spans.
    /// Default matches the current preview's `.white.opacity(0.06)`. R1.
    var mutedAlpha: Double = 0.06

    /// Horizontal time density multiplier. The preview fits the whole capture
    /// left→right by setting the viewport's `secondsAhead` to the capture
    /// duration; this scales that window (`secondsAhead = duration / zoom`).
    /// Default `1` is the identity — `duration / 1` is byte-identical to the
    /// current behaviour, so the out-of-box render is unchanged. R5.
    var horizontalZoom: CGFloat = 1

    // MARK: - Future-ready fields (held, not yet consumed by the renderer)

    /// Junction/reversal dot radius. Recorded here so R2 can surface it, but the
    /// renderer still reads its own private `nodeRadius` (2.5) — wiring this
    /// through requires the renderer API change that belongs to R2, not R0. The
    /// default mirrors the renderer's current constant so promotion is a no-op.
    var nodeRadius: CGFloat = 2.5

    /// Master gate for the eventual R1–R9 UI controls. No controls exist yet, so
    /// this is inert in R0; it lives here so the foundation already carries the
    /// flag the later slices land behind.
    var controlsEnabled: Bool = false

    // MARK: - Derived render inputs

    /// The motion-path style the captured-notation preview draws with. Starts
    /// from the shared `.user` style (bright green, single hue, opt-in glow) and
    /// applies the display fields above. At defaults this is equal to
    /// `ScratchMotionRenderer.Style.user`, so the render is unchanged.
    var motionStyle: ScratchMotionRenderer.Style {
        var style = ScratchMotionRenderer.Style.user
        style.lineWidth = lineWidth
        style.glow = glow
        style.showsNodes = showsNodes
        return style
    }

    /// The viewport `secondsAhead` for fitting a capture of `duration` seconds.
    /// Identity at the default `horizontalZoom == 1`.
    func secondsAhead(forDuration duration: TimeInterval) -> TimeInterval {
        duration / Double(horizontalZoom)
    }
}
