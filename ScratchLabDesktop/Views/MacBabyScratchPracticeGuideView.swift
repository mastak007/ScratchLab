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
/// - During silences between scratches the canvas paints **nothing**
///   — only the baseline holds. The guide is honest about whether the
///   coach audio is currently scratching: no scratch sound → no
///   notation.
///
/// **Data source:** the bundled extracted-stroke resource
/// (`baby_scratch_strokes.json` → `phraseEnd: 42.4`) encodes every
/// real scratch position across the full 42-second coach audio, with
/// gaps where the audio is silent. Using these segments — instead of
/// the single 5-second notation loop — means the guide paints a
/// stroke only when the audio is actually scratching at that time.
///
/// **Sync to playback:** observes `ScratchLabDemoModeController`
/// (the same controller wired to the sidebar's visible Coach →
/// Replay button) so the canvas follows the audio the user can
/// actually hear. Reads
/// `demoController.demoPlayer.sampledPlaybackTime()` *inside* the
/// `TimelineView` closure each tick — that is the host-clock-
/// interpolated, latency-compensated playhead the iOS Demo lane
/// already uses. Tiling flows through the deterministic
/// `BabyScratchDemoPlaybackCoordinator.notationCanvasLoopTime(
/// for:cycleDuration:)` helper (commit a4ea922).
///
/// **macOS-only** by file placement. iOS Practice is unchanged.
struct MacBabyScratchPracticeGuideView: View {

    @ObservedObject var demoController: ScratchLabDemoModeController

    private let strokeSegments: [ScratchLabBabyScratchStrokeSegment] =
        BabyScratchReferenceMotionTimeline.strokeSegments

    /// Loop duration matches the bundled audio's stroke span so the
    /// canvas wraps cleanly when the coach demo replays from t = 0.
    private let segmentLoopDuration: TimeInterval =
        BabyScratchReferenceMotionTimeline.phraseEnd

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
            //
            // Source: `demoController.demoPlayer.sampledPlaybackTime()`
            // — the same host-clock-interpolated playhead the iOS Demo
            // lane uses and the same player the sidebar's visible
            // Replay button drives.
            let loopDuration = max(segmentLoopDuration, 0.0001)
            let audioTime = demoController.demoPlayer.sampledPlaybackTime()
            let now = BabyScratchDemoPlaybackCoordinator.notationCanvasLoopTime(
                for: audioTime,
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
            demoController.demoPlayer.isPlaying
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
        guard !strokeSegments.isEmpty else { return }
        let baseline = Self.baselineY(in: size)
        let peakHeight = size.height * 0.58
        let playheadX = size.width * CGFloat(Self.playheadFraction)
        let pps = size.width / CGFloat(Self.visibleSeconds)
        // Render three copies of the loop so seam transitions stay
        // continuous as audio replays from t = 0. Each segment paints
        // only at its real audio position — silences between scratches
        // remain empty.
        for offset in [-loopDuration, 0, loopDuration] {
            for segment in strokeSegments {
                drawSegment(
                    segment,
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

    private func drawSegment(
        _ segment: ScratchLabBabyScratchStrokeSegment,
        timeOffset: TimeInterval,
        now: TimeInterval,
        playheadX: CGFloat,
        pps: CGFloat,
        baseline: CGFloat,
        peakHeight: CGFloat,
        canvasWidth: CGFloat,
        ctx: GraphicsContext
    ) {
        // Skip explicit hold segments — no scratch sound is occurring,
        // so the guide stays silent (baseline only) during that span.
        guard segment.direction != .neutral else { return }

        let startTime = segment.startTime + timeOffset
        let endTime = segment.endTime + timeOffset
        let xStart = playheadX + CGFloat(startTime - now) * pps
        let xEnd = playheadX + CGFloat(endTime - now) * pps
        // Cull off-screen segments (with a small bleed margin).
        guard xEnd > -8, xStart < canvasWidth + 8 else { return }
        // Forward = cyan/green; backward = warm pink. Direction encoded
        // by colour so the notation can stay one-sided above the
        // baseline. No grading verbs; no "good vs bad" connotation —
        // these are pure direction indicators.
        let color: Color
        switch segment.direction {
        case .forward:
            color = ScratchLabPalette.notationForward
        case .backward:
            color = Color(red: 1.00, green: 0.45, blue: 0.78)
        case .neutral:
            return
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
        // segments. Same colour, slightly lower opacity.
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
