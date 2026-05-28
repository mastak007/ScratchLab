import SwiftUI

// MARK: - MacBabyScratchPracticeGuideView

/// Compact "Baby Scratch guide" card embedded in the macOS Practice
/// surface. Pairs the coach/demo audio with a directional scratch
/// notation strip so the audio actually has a visible reference
/// partner.
///
/// **Visual grammar (kept honest):**
/// - Forward strokes paint as upward slopes above a single baseline.
/// - Backward strokes paint as upward slopes above the same baseline
///   but in a contrasting hue; the *direction* is encoded by colour,
///   not by mirroring below the centre line.
/// - There is one baseline. There is one playhead. The notation
///   scrolls past the fixed playhead as the demo audio advances.
/// - Reads like instructional scratch notation, not like an
///   oscilloscope or mirrored waveform.
///
/// **Sync to playback:** the canvas lives inside a `TimelineView` that
/// fires at the display refresh rate and reads
/// `BabyScratchDemoPlaybackCoordinator.currentAudioTime` *inside the
/// closure*, so each tick re-renders against a fresh demo clock — no
/// caching shenanigans, no manual `@Published` plumb. Tiling uses the
/// deterministic `notationCanvasLoopTime(for:cycleDuration:)` helper
/// (commit a4ea922) so every Baby Scratch repetition continues to
/// animate, not just the first.
///
/// **macOS-only** by file placement. iOS Practice is unchanged.
struct MacBabyScratchPracticeGuideView: View {

    @ObservedObject var demo: BabyScratchDemoPlaybackCoordinator

    private let notation: ScratchNotation? = ScratchNotation.loadBabyScratchFromBundle()

    private static let laneHeight: CGFloat = 156
    private static let playheadFraction: Double = 0.30
    private static let visibleSeconds: Double = 4.0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            timelineCanvas
            captionLine
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Subviews

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(CoachCopy.PracticeGuide.babyScratchTitle)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
            Text(CoachCopy.PracticeGuide.babyScratchSubtitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    private var timelineCanvas: some View {
        TimelineView(.animation) { _ in
            // Read demo clock *inside* the closure so the canvas
            // re-renders against the fresh audio time on every tick.
            let loopDuration = max(notation?.timelineDuration ?? 0, 0.0001)
            let now = BabyScratchDemoPlaybackCoordinator.notationCanvasLoopTime(
                for: demo.currentAudioTime,
                cycleDuration: loopDuration
            )
            Canvas { ctx, size in
                drawBackground(in: ctx, size: size)
                drawBaseline(in: ctx, size: size)
                drawStrokes(in: ctx, size: size, now: now, loopDuration: loopDuration)
                drawPlayhead(in: ctx, size: size)
            }
            .frame(height: Self.laneHeight)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var captionLine: some View {
        Text(
            demo.isPlaying
                ? CoachCopy.PracticeGuide.babyScratchPlayingCaption
                : CoachCopy.PracticeGuide.babyScratchIdleCaption
        )
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.55))
    }

    // MARK: Drawing

    private func drawBackground(in ctx: GraphicsContext, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        ctx.fill(Path(rect), with: .color(Color.black.opacity(0.22)))
    }

    private func drawBaseline(in ctx: GraphicsContext, size: CGSize) {
        let y = Self.baselineY(in: size)
        var path = Path()
        path.move(to: CGPoint(x: 0, y: y))
        path.addLine(to: CGPoint(x: size.width, y: y))
        ctx.stroke(path, with: .color(.white.opacity(0.18)), lineWidth: 0.5)
    }

    private func drawPlayhead(in ctx: GraphicsContext, size: CGSize) {
        let x = size.width * CGFloat(Self.playheadFraction)
        var path = Path()
        path.move(to: CGPoint(x: x, y: 0))
        path.addLine(to: CGPoint(x: x, y: size.height))
        ctx.stroke(path, with: .color(.white.opacity(0.50)), lineWidth: 1.0)
    }

    private func drawStrokes(
        in ctx: GraphicsContext,
        size: CGSize,
        now: TimeInterval,
        loopDuration: TimeInterval
    ) {
        guard let notation, !notation.strokes.isEmpty else { return }
        let baseline = Self.baselineY(in: size)
        let peakHeight = size.height * 0.58
        let playheadX = size.width * CGFloat(Self.playheadFraction)
        let pps = size.width / CGFloat(Self.visibleSeconds)
        // Render three copies of the loop so seam transitions stay
        // continuous as audio advances past loopDuration.
        for offset in [-loopDuration, 0, loopDuration] {
            for stroke in notation.strokes {
                drawStroke(
                    stroke,
                    timeOffset: offset,
                    now: now,
                    playheadX: playheadX,
                    pps: pps,
                    baseline: baseline,
                    peakHeight: peakHeight,
                    canvasWidth: size.width,
                    ctx: ctx
                )
            }
        }
    }

    private func drawStroke(
        _ stroke: ScratchNotation.Stroke,
        timeOffset: TimeInterval,
        now: TimeInterval,
        playheadX: CGFloat,
        pps: CGFloat,
        baseline: CGFloat,
        peakHeight: CGFloat,
        canvasWidth: CGFloat,
        ctx: GraphicsContext
    ) {
        let startTime = stroke.startTime + timeOffset
        let endTime = stroke.endTime + timeOffset
        let xStart = playheadX + CGFloat(startTime - now) * pps
        let xEnd = playheadX + CGFloat(endTime - now) * pps
        // Cull off-screen strokes (with a small bleed margin).
        guard xEnd > -8, xStart < canvasWidth + 8 else { return }
        // Forward = cyan/green; backward = warm pink. Direction encoded
        // by colour so the notation can stay one-sided above the
        // baseline. No grading verbs; no "good vs bad" connotation —
        // these are pure direction indicators.
        let color: Color
        switch stroke.direction {
        case .forward:
            color = ScratchLabPalette.notationForward
        case .backward:
            color = Color(red: 1.00, green: 0.45, blue: 0.78)
        }
        // Triangle stroke that peaks once above the baseline. Both
        // forward and backward strokes use the same upward triangle
        // shape so the notation never inverts below the baseline.
        let midX = (xStart + xEnd) / 2
        var path = Path()
        path.move(to: CGPoint(x: xStart, y: baseline))
        path.addLine(to: CGPoint(x: midX, y: baseline - peakHeight))
        path.addLine(to: CGPoint(x: xEnd, y: baseline))
        ctx.stroke(
            path,
            with: .color(color.opacity(0.95)),
            style: StrokeStyle(lineWidth: 2.4, lineJoin: .round)
        )
        // Filled apex node so the peak reads clearly even on short
        // strokes. Same colour, half opacity.
        let apexRadius: CGFloat = 3.5
        let apex = CGRect(
            x: midX - apexRadius,
            y: baseline - peakHeight - apexRadius,
            width: apexRadius * 2,
            height: apexRadius * 2
        )
        ctx.fill(Path(ellipseIn: apex), with: .color(color.opacity(0.85)))
    }

    /// Baseline y-coordinate inside the canvas. Sits near the bottom so
    /// the upward stroke geometry has room to peak without colliding
    /// with the header/caption.
    private static func baselineY(in size: CGSize) -> CGFloat {
        size.height * 0.82
    }
}
