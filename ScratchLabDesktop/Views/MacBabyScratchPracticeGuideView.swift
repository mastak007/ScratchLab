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
    ///
    /// Calibrated rate per `MacBabyScratchPracticeGuideRate` — the
    /// helper's default rate of 1.0 cursor / sec saturates the cursor
    /// in a single Baby-Scratch-length stroke, killing dynamic range.
    /// Calibration is the honest interim until the JSON ships real
    /// sample-position data.
    private let trace: [ScratchNotationPositionTraceSegment] =
        ScratchNotationPositionTrace.derive(
            from: BabyScratchReferenceMotionTimeline.strokeSegments,
            movementRatePerSecond:
                MacBabyScratchPracticeGuideRate.calibratedBabyRate
        )

    /// Active-phrase ranges derived from the same stroke segments the
    /// trace uses. The renderer suppresses all drawing when (a) the
    /// demo is not playing or (b) the current loop-time is not inside
    /// one of these ranges. Inherited unchanged from Stage 0
    /// (commit cad51fe).
    private let phraseRanges: [ScratchNotationPhraseRange] =
        ScratchNotationPhraseGate.activePhraseRanges(
            from: BabyScratchReferenceMotionTimeline.strokeSegments
        )

    /// One continuous polyline per active phrase. Replaces the prior
    /// tokenized model (stroke segments + hold connectors + endpoint
    /// dots, tiled across `[-loopDuration, 0, loopDuration]`) with
    /// one stroked `CGPath` per phrase — the SXRATCH reference
    /// visualizer's model observed in the upper lane of every coach
    /// video in this session.
    ///
    /// Hold gaps between strokes inside the same phrase are folded
    /// into the same polyline as flat horizontal vertices, so the
    /// path reads as continuous sample-position motion. Inter-phrase
    /// silences split into separate polylines and Stage 0's phrase
    /// gate keeps them from drawing at all when the playhead is
    /// inside a silence.
    private let phrasePolylines: [ScratchNotationPhrasePolyline] =
        ScratchNotationPhrasePolyline.build(
            from: ScratchNotationPositionTrace.derive(
                from: BabyScratchReferenceMotionTimeline.strokeSegments,
                movementRatePerSecond:
                    MacBabyScratchPracticeGuideRate.calibratedBabyRate
            ),
            phraseRanges: ScratchNotationPhraseGate.activePhraseRanges(
                from: BabyScratchReferenceMotionTimeline.strokeSegments
            )
        )

    /// Audio duration the canvas tracks. The bundled demo is
    /// single-shot: it plays once through `phraseEnd` and stops —
    /// it does not loop within a playback. No tile array; the
    /// renderer draws each polyline exactly once at its native
    /// audio time.
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
            // Polylines paint only when the demo is playing AND the
            // current playback time sits inside one of the active
            // phrase ranges. Background, baseline, and playhead
            // always paint so the lane stays present and signals
            // "ready to play" during idle / silence.
            let shouldDrawTrace =
                demoController.demoPlayer.isPlaying
                && ScratchNotationPhraseGate.isInActivePhrase(
                    now, ranges: phraseRanges
                )
            Canvas { ctx, size in
                drawBackground(in: ctx, size: size)
                drawBaseline(in: ctx, size: size)
                if shouldDrawTrace {
                    drawActivePhrasePolylines(in: ctx, size: size, now: now)
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

    /// Paints one continuous polyline per active phrase that overlaps
    /// the visible time window. Each polyline is built once at init
    /// from the trace + phrase ranges (see `phrasePolylines`); here
    /// the only work per frame is the audio-time → canvas-X mapping,
    /// path assembly, and a single stroke call per polyline.
    ///
    /// **No dots.** The reference SXRATCH visualizer paints the upper
    /// lane as one stroked line; dots in the upper lane were the
    /// regression that prompted this replacement.
    ///
    /// **No loop tiling.** The bundled audio plays once through and
    /// does not loop within a playback, so the prior
    /// `[-loopDuration, 0, loopDuration]` tile array would only
    /// inject phantom strokes at audio boundaries.
    private func drawActivePhrasePolylines(
        in ctx: GraphicsContext,
        size: CGSize,
        now: TimeInterval
    ) {
        guard !phrasePolylines.isEmpty else { return }
        let baseline = Self.baselineY(in: size)
        // Vertical headroom above the baseline that maps to position
        // 1.0. Position 0.0 paints at the baseline.
        let positionHeight = size.height * 0.62
        let playheadX = size.width * CGFloat(Self.playheadFraction)
        let pps = size.width / CGFloat(Self.visibleSeconds)
        // Cull polylines whose entire phrase range sits outside the
        // visible window. Visible window in audio-time is
        // `[now - playheadFraction * visibleSeconds, now + (1 -
        // playheadFraction) * visibleSeconds]`.
        let visibleStart = now - Self.playheadFraction * Self.visibleSeconds
        let visibleEnd = now + (1 - Self.playheadFraction) * Self.visibleSeconds
        for polyline in phrasePolylines {
            guard polyline.phraseRange.end >= visibleStart - 0.1,
                  polyline.phraseRange.start <= visibleEnd + 0.1
            else { continue }
            var path = Path()
            for (index, vertex) in polyline.vertices.enumerated() {
                let x = playheadX + CGFloat(vertex.time - now) * pps
                let y = baseline - positionHeight * CGFloat(vertex.position)
                let point = CGPoint(x: x, y: y)
                if index == 0 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }
            ctx.stroke(
                path,
                with: .color(ScratchLabPalette.notationForward.opacity(0.95)),
                style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
            )
        }
    }

    /// Baseline y-coordinate inside the canvas. Sits near the bottom so
    /// the upward stroke geometry has room to peak without colliding
    /// with the header/caption.
    private static func baselineY(in size: CGSize) -> CGFloat {
        size.height * 0.82
    }
}
