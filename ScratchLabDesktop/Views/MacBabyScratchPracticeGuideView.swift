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
    /// The trace is built from the raw JSON `startProgress` /
    /// `endProgress` values (`ScratchNotationRawTrace.build`), not
    /// from the duration-proxy derivation. Baby Scratch's JSON
    /// already encodes every stroke as a full-sample sweep
    /// (forward 0 → 1, backward 1 → 0); the duration proxy
    /// compressed that into a narrow band and produced a shallow
    /// waveform-like trace (forensic on `sl notation review 3.mp4`).
    /// Raw progress restores full lane amplitude.
    ///
    /// Hold gaps between strokes inside the same phrase fold into
    /// the same polyline as flat horizontal vertices. Non-carry-
    /// forward transitions (e.g., two consecutive backward strokes
    /// both encoded as 1 → 0) emit an additional vertical-jump
    /// vertex so the silent platter-reset moment reads cleanly
    /// without drawing a fake diagonal scratch. Inter-phrase
    /// silences split into separate polylines and Stage 0's phrase
    /// gate keeps them from drawing at all when the playhead is
    /// inside a silence.
    private let phrasePolylines: [ScratchNotationPhrasePolyline] =
        ScratchNotationPhrasePolyline.build(
            from: ScratchNotationRawTrace.build(
                from: BabyScratchReferenceMotionTimeline.strokeSegments
            ),
            phraseRanges: ScratchNotationPhraseGate.activePhraseRanges(
                from: BabyScratchReferenceMotionTimeline.strokeSegments
            )
        )

    /// Discrete audible-attack onset markers — one per non-neutral
    /// stroke whose onset falls inside an active phrase. Drawn on a
    /// separate low marker row beneath the trace lane (never on the
    /// trace line itself) so the repeated scratch hits read as a
    /// rhythm row. The motion trace stays the primary, honest layer;
    /// this layer only makes the onsets the ear tracks visible.
    ///
    /// Built from the same stroke segments and phrase gate the trace
    /// uses, so the markers share the trace's timing mapping and
    /// phrase gating exactly.
    private let attackMarkers: [ScratchNotationAttackMarker] =
        ScratchNotationAttackMarkers.build(
            from: BabyScratchReferenceMotionTimeline.strokeSegments,
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

    /// Reference tempo for the bundled Baby Scratch demo. Matches
    /// `BabyScratchReferenceAsset.babyScratch79BPM.bpm`. Drives the
    /// beat-grid spacing only — the trace itself is timed from the
    /// JSON stroke times, not from this BPM.
    private static let babyScratchBPM: Double = 79.0

    /// Anchor for the beat grid in audio-time seconds. Set to the
    /// first audible attack in the bundled Baby Scratch demo
    /// (JSON stroke #1 startTime) so beat 0 / bar 1 sits on the
    /// first scratch instead of on `t = 0`. The phrase 1 strokes
    /// then land within ±90 ms of beats at 79 BPM, giving a
    /// readable rhythmic scaffold.
    private static let babyScratchBeatAnchor: TimeInterval = 0.27

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
                // The beat grid paints **independently** of the
                // phrase / play-state gate. The trace is gated
                // (idle / silence / paused → no strokes), but the
                // rhythmic scaffold remains visible so the lane
                // reads as "ready to play in time" even during
                // idle. Painted between baseline and trace so the
                // trace overlays the grid when it appears.
                drawBeatGrid(in: ctx, size: size, now: now)
                if shouldDrawTrace {
                    drawActivePhrasePolylines(in: ctx, size: size, now: now)
                    // Attack markers share the trace's gate: they paint
                    // only while a phrase is active/replaying, so idle /
                    // silence / post-end stay empty. Drawn after the
                    // trace and before the playhead.
                    drawAttackMarkers(in: ctx, size: size, now: now)
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

    /// Paints the beat / bar grid behind the trace. Beat lines are
    /// dim (α = 0.08), bar lines slightly stronger (α = 0.18,
    /// matching the baseline's intensity) so the grid reads as
    /// timing reference rather than as scratch content. Two stroke
    /// calls — one per kind — share a single 0.5 pt line width and
    /// never interact with the trace's colour palette.
    ///
    /// Independent of phrase / polyline / trace data: lines are
    /// computed entirely from the visible window + BPM + anchor.
    /// Always paints regardless of the demo's play state.
    private func drawBeatGrid(
        in ctx: GraphicsContext,
        size: CGSize,
        now: TimeInterval
    ) {
        let playheadX = size.width * CGFloat(Self.playheadFraction)
        let pps = size.width / CGFloat(Self.visibleSeconds)
        let visibleStart = now - Self.playheadFraction * Self.visibleSeconds
        let visibleEnd = now + (1 - Self.playheadFraction) * Self.visibleSeconds
        let lines = ScratchNotationBeatGrid.gridLines(
            visibleStart: visibleStart,
            visibleEnd: visibleEnd,
            bpm: Self.babyScratchBPM,
            anchorTime: Self.babyScratchBeatAnchor
        )
        guard !lines.isEmpty else { return }
        var beatPath = Path()
        var barPath = Path()
        for line in lines {
            let x = playheadX + CGFloat(line.time - now) * pps
            switch line.kind {
            case .beat:
                beatPath.move(to: CGPoint(x: x, y: 0))
                beatPath.addLine(to: CGPoint(x: x, y: size.height))
            case .bar:
                barPath.move(to: CGPoint(x: x, y: 0))
                barPath.addLine(to: CGPoint(x: x, y: size.height))
            }
        }
        ctx.stroke(
            beatPath,
            with: .color(.white.opacity(0.08)),
            style: StrokeStyle(lineWidth: 0.5)
        )
        ctx.stroke(
            barPath,
            with: .color(.white.opacity(0.18)),
            style: StrokeStyle(lineWidth: 0.5)
        )
    }

    /// Paints one polyline group per active phrase that overlaps
    /// the visible time window. Each polyline group is a list of
    /// **sub-paths**; sub-paths within a phrase share no geometry.
    /// Non-carry-forward transitions (silent platter resets)
    /// produce a break between sub-paths — the renderer paints
    /// nothing across the break interval, so silent resets read as
    /// visual gaps instead of vertical lines.
    ///
    /// **No dots.** The reference SXRATCH visualizer paints the upper
    /// lane as one stroked line; dots in the upper lane were the
    /// regression that prompted this replacement.
    ///
    /// **No loop tiling.** The bundled audio plays once through and
    /// does not loop within a playback.
    ///
    /// One `Path` per phrase, one `ctx.stroke(...)` call per phrase
    /// — sub-paths sit inside the same `Path` via `move(to:)` /
    /// `addLine(to:)` and stroke together with a uniform line style.
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
            for subPath in polyline.subPaths {
                for (index, vertex) in subPath.enumerated() {
                    let x = playheadX + CGFloat(vertex.time - now) * pps
                    let y = baseline - positionHeight * CGFloat(vertex.position)
                    let point = CGPoint(x: x, y: y)
                    if index == 0 {
                        path.move(to: point)
                    } else {
                        path.addLine(to: point)
                    }
                }
            }
            ctx.stroke(
                path,
                with: .color(ScratchLabPalette.notationForward.opacity(0.95)),
                style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
            )
        }
    }

    /// Paints the audible-attack onset markers on a dedicated low
    /// marker row beneath the trace lane. Each marker is a short,
    /// uniform vertical tick — deliberately **not** a dot on the trace
    /// line (dots on the upper trace were a prior regression that read
    /// as extra phantom notes). The ticks share the trace's x mapping
    /// (`playheadX + (time - now) * pps`) but sit on a fixed y row, so
    /// they read as rhythm / onset scaffolding rather than as part of
    /// the motion curve.
    ///
    /// Neutral colour, low alpha: the motion trace stays primary. Only
    /// markers inside the visible window are drawn. Phrase gating is
    /// handled by the caller (same `shouldDrawTrace` condition as the
    /// trace), so idle / silence / post-end paint nothing here.
    private func drawAttackMarkers(
        in ctx: GraphicsContext,
        size: CGSize,
        now: TimeInterval
    ) {
        guard !attackMarkers.isEmpty else { return }
        let playheadX = size.width * CGFloat(Self.playheadFraction)
        let pps = size.width / CGFloat(Self.visibleSeconds)
        let visibleStart = now - Self.playheadFraction * Self.visibleSeconds
        let visibleEnd = now + (1 - Self.playheadFraction) * Self.visibleSeconds
        // Marker row sits below the baseline (0.82) so it never
        // overlaps the upward stroke geometry. Ticks are centred on
        // the row.
        let rowY = size.height * 0.93
        let halfTick: CGFloat = 5
        var path = Path()
        for marker in attackMarkers {
            guard marker.time >= visibleStart - 0.1,
                  marker.time <= visibleEnd + 0.1
            else { continue }
            let x = playheadX + CGFloat(marker.time - now) * pps
            path.move(to: CGPoint(x: x, y: rowY - halfTick))
            path.addLine(to: CGPoint(x: x, y: rowY + halfTick))
        }
        ctx.stroke(
            path,
            with: .color(.white.opacity(0.32)),
            style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
        )
    }

    /// Baseline y-coordinate inside the canvas. Sits near the bottom so
    /// the upward stroke geometry has room to peak without colliding
    /// with the header/caption.
    private static func baselineY(in size: CGSize) -> CGFloat {
        size.height * 0.82
    }
}
