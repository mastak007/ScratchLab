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

    /// Derived continuous-position trace for the bundled stroke
    /// segments. The bundled JSON encodes every stroke as 0 ↔ 1, so
    /// the position model would force every stroke to slam to the
    /// boundary if used verbatim. The trace helper derives a bounded
    /// cursor from direction + duration (see
    /// `ScratchNotationPositionTrace.derive(...)`), carrying the
    /// cursor forward across reversals and clamping to `[0, 1]`.
    private let trace: [ScratchNotationPositionTraceSegment] =
        ScratchNotationPositionTrace.derive(
            from: BabyScratchReferenceMotionTimeline.strokeSegments
        )

    /// Loop duration matches the bundled audio's stroke span so the
    /// canvas wraps cleanly when the coach demo replays from t = 0.
    private let segmentLoopDuration: TimeInterval =
        BabyScratchReferenceMotionTimeline.phraseEnd

    /// Active-phrase ranges derived from the same stroke segments the
    /// trace uses. Strokes are only drawn when (a) the demo is playing
    /// and (b) the current loop-time is inside one of these ranges.
    /// This prevents the centered viewport from leaking upcoming-phrase
    /// strokes into the canvas during the 5+ s silences that sit
    /// between phrases, and suppresses all stroke drawing in the idle
    /// / paused / post-end states.
    private let phraseRanges: [ScratchNotationPhraseRange] =
        ScratchNotationPhraseGate.activePhraseRanges(
            from: BabyScratchReferenceMotionTimeline.strokeSegments
        )

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
            // Strokes are gated by *both* the play state and the
            // active-phrase membership of `now`. Background, baseline,
            // and playhead always paint so the lane stays present and
            // signals "ready to play" during idle / silence — only the
            // trace strokes themselves are suppressed.
            let shouldDrawStrokes =
                demoController.demoPlayer.isPlaying
                && ScratchNotationPhraseGate.isInActivePhrase(
                    now, ranges: phraseRanges
                )
            Canvas { ctx, size in
                drawBackground(in: ctx, size: size)
                drawBaseline(in: ctx, size: size)
                if shouldDrawStrokes {
                    drawStrokes(in: ctx, size: size, now: now, loopDuration: loopDuration)
                }
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
        guard !trace.isEmpty else { return }
        let baseline = Self.baselineY(in: size)
        // Vertical headroom above the baseline that maps to position
        // 1.0. Position 0.0 paints at the baseline.
        let positionHeight = size.height * 0.62
        let playheadX = size.width * CGFloat(Self.playheadFraction)
        let pps = size.width / CGFloat(Self.visibleSeconds)
        // Render three copies of the loop so seam transitions stay
        // continuous as audio replays from t = 0. Each trace segment
        // paints a single line from `(startTime, startPosition)` to
        // `(endTime, endPosition)` — direction is communicated by the
        // slope, not by mirroring below baseline. Silences between
        // strokes remain empty: nothing is drawn until the next
        // segment.
        for offset in [-loopDuration, 0, loopDuration] {
            for segment in trace {
                drawTraceSegment(
                    segment,
                    timeOffset: offset,
                    now: now,
                    playheadX: playheadX,
                    pps: pps,
                    baseline: baseline,
                    positionHeight: positionHeight,
                    canvasWidth: size.width,
                    ctx: ctx
                )
            }
        }
    }

    private func drawTraceSegment(
        _ segment: ScratchNotationPositionTraceSegment,
        timeOffset: TimeInterval,
        now: TimeInterval,
        playheadX: CGFloat,
        pps: CGFloat,
        baseline: CGFloat,
        positionHeight: CGFloat,
        canvasWidth: CGFloat,
        ctx: GraphicsContext
    ) {
        let startTime = segment.startTime + timeOffset
        let endTime = segment.endTime + timeOffset
        let xStart = playheadX + CGFloat(startTime - now) * pps
        let xEnd = playheadX + CGFloat(endTime - now) * pps
        // Cull off-screen segments (with a small bleed margin).
        guard xEnd > -8, xStart < canvasWidth + 8 else { return }
        // Forward = cyan/green; backward = warm pink. Direction encoded
        // by colour AND by slope sign (forward = upward slope, backward
        // = downward slope above the baseline).
        let color: Color
        switch segment.direction {
        case .forward:
            color = ScratchLabPalette.notationForward
        case .backward:
            color = Color(red: 1.00, green: 0.45, blue: 0.78)
        case .neutral:
            return
        }
        let yStart = baseline - positionHeight * CGFloat(segment.startPosition)
        let yEnd = baseline - positionHeight * CGFloat(segment.endPosition)
        var path = Path()
        path.move(to: CGPoint(x: xStart, y: yStart))
        path.addLine(to: CGPoint(x: xEnd, y: yEnd))
        ctx.stroke(
            path,
            with: .color(color.opacity(0.95)),
            style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
        )
        // Small node at the segment's end position so the cursor's
        // current height reads clearly even for very short strokes.
        let nodeRadius: CGFloat = 3.0
        let node = CGRect(
            x: xEnd - nodeRadius,
            y: yEnd - nodeRadius,
            width: nodeRadius * 2,
            height: nodeRadius * 2
        )
        ctx.fill(Path(ellipseIn: node), with: .color(color.opacity(0.85)))
    }

    /// Baseline y-coordinate inside the canvas. Sits near the bottom so
    /// the upward stroke geometry has room to peak without colliding
    /// with the header/caption.
    private static func baselineY(in size: CGSize) -> CGFloat {
        size.height * 0.82
    }
}
