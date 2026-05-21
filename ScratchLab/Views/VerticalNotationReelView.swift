// VerticalNotationReelView.swift
// ScratchLab - Practice Demo Mode
//
// A portrait-first vertical timing reel for the non-scored practice Demo mode.
//
// The reel is a top-down strip of the call-and-response timeline. Upcoming
// notation events sit ABOVE a fixed horizontal "action line" and travel DOWN
// toward it as the demo audio plays; an event reaches the line at the instant
// its sound is heard. The line — not the top or bottom edge — is the reel's
// "now", placed ~72% down so the learner sees several seconds of lookahead.
//
// Timing model
// ------------
// The demo audio is the timing master. This view is a pure follower:
//
//     audio time  ──►  ReelViewport  ──►  every item's screen position
//
// `ReelViewport` is a deterministic value type — `y(for:)` is a function of
// `(now, size)` alone. There is no `ScrollView` and no scroll state, so reel
// position can never feed back into timing or drift from the audio clock. The
// `TimelineView` below is only a render-side ticker; the clock value comes
// from the injected `audioTime` closure (the demo-audio player's smoothed,
// latency-compensated `sampledPlaybackTime()`).
//
// What it renders, all from a `PracticeReelTimeline` manifest:
//   • demo / copy region bands — visually distinct; copy windows carry a tint,
//     hatch and label so they never read as dead space;
//   • a beat grid, when the manifest declares a `bpm` (the interim no-beat
//     asset omits it, so the grid is simply absent — see PHASE 5 notes);
//   • solid reference strokes inside demo segments;
//   • outlined "ghost" target strokes inside copy windows (the demo strokes the
//     copy window answers, echoed — see `derivedCopyGhostStrokes()`);
//   • the action line, segment labels, and a parked "Demo complete" state.
//
// Scope: Demo mode only. This renderer drives no capture, export, scoring or
// ML, takes no live-mic input, and carries no user-attempt overlay yet. It is
// deliberately decoupled from the horizontal `AutoCutTargetChart` used by the
// Guided / Auto-cut modes, which is left untouched.

import SwiftUI

// MARK: - Reel viewport

/// Pure, deterministic mapping from demo-audio time to vertical-reel geometry.
///
/// Every value is a function of `(now, size)` only — no scroll state, no
/// feedback path — so the reel stays locked to the audio clock. `now` is
/// supplied by the demo-audio clock; the view never writes it.
struct ReelViewport: Equatable {
    /// The reel's drawing area.
    let size: CGSize
    /// Current demo-audio time, in seconds — the single source of truth.
    let now: TimeInterval
    /// Action-line position as a fraction of height from the top (0.65–0.75).
    let actionLineFraction: CGFloat
    /// Seconds of upcoming timeline shown between the top edge and the line.
    let secondsAboveLine: TimeInterval

    /// Screen y of the fixed action line.
    var actionLineY: CGFloat { size.height * actionLineFraction }

    /// Vertical scale: points per second of timeline. Derived so exactly
    /// `secondsAboveLine` of lookahead fills the space above the action line,
    /// whatever the panel height — the lookahead window stays constant.
    var pointsPerSecond: CGFloat {
        guard secondsAboveLine > 0, actionLineY > 0 else { return 0 }
        return actionLineY / CGFloat(secondsAboveLine)
    }

    /// Screen y for an absolute audio time. Future (`time > now`) maps above
    /// the action line; past maps below it.
    func y(for time: TimeInterval) -> CGFloat {
        actionLineY - CGFloat(time - now) * pointsPerSecond
    }

    /// Inverse of `y(for:)` — the audio time drawn at a given screen y.
    func time(atY y: CGFloat) -> TimeInterval {
        guard pointsPerSecond > 0 else { return now }
        return now + TimeInterval((actionLineY - y) / pointsPerSecond)
    }

    /// The audio-time span currently on screen.
    var visibleTimeRange: ClosedRange<TimeInterval> {
        let a = time(atY: size.height)
        let b = time(atY: 0)
        return Swift.min(a, b)...Swift.max(a, b)
    }

    /// Whether `[startTime, endTime]` overlaps the visible window at all.
    func isVisible(startTime: TimeInterval, endTime: TimeInterval) -> Bool {
        let window = visibleTimeRange
        return endTime >= window.lowerBound && startTime <= window.upperBound
    }
}

// MARK: - VerticalNotationReelView

struct VerticalNotationReelView: View {

    /// The call-and-response manifest driving the reel.
    let timeline: PracticeReelTimeline
    /// The demo-audio clock — the sole source of timing truth. Sampled once
    /// per render tick; never written back to.
    let audioTime: () -> TimeInterval

    /// Echoed copy-window targets, derived once from the manifest.
    private let ghostStrokes: [ReelStroke]

    init(timeline: PracticeReelTimeline, audioTime: @escaping () -> TimeInterval) {
        self.timeline = timeline
        self.audioTime = audioTime
        self.ghostStrokes = timeline.derivedCopyGhostStrokes()
    }

    // MARK: Layout tuning

    /// Action line ~72% down — inside the 65–75% design band.
    private static let actionLineFraction: CGFloat = 0.72
    /// Lookahead window above the action line.
    private static let secondsAboveLine: TimeInterval = 5.5
    /// Render cadence — matches the demo-audio chart so the smoothed,
    /// latency-compensated playhead reads true.
    private static let tickInterval: TimeInterval = 1.0 / 60.0
    /// How close to the audio's end counts as "demo complete".
    private static let completionEpsilon: TimeInterval = 0.06
    /// Horizontal inset of the stroke lane from the reel edges.
    private static let laneInset: CGFloat = 24
    /// Smallest drawn stroke-bar height, so a brief stroke stays legible.
    private static let minBarHeight: CGFloat = 16
    private static let barCornerRadius: CGFloat = 7

    // MARK: Palette — calm, high-contrast, notation-like (no casino theming)

    private static let backgroundTop = Color(red: 0.06, green: 0.07, blue: 0.10)
    private static let backgroundBottom = Color(red: 0.03, green: 0.035, blue: 0.05)
    /// Demo segments read cool; copy windows read warm/active.
    private static let demoAccent = Color(red: 0.23, green: 0.51, blue: 0.96)   // blue
    private static let copyAccent = Color(red: 0.96, green: 0.62, blue: 0.07)   // amber
    /// Stroke direction colors — two harmonious cool hues, not a rainbow.
    private static let backwardColor = Color(red: 0.22, green: 0.74, blue: 0.97) // sky
    private static let forwardColor = Color(red: 0.75, green: 0.52, blue: 0.99)  // violet
    private static let beatLineColor = Color.white.opacity(0.05)
    private static let downbeatLineColor = Color.white.opacity(0.11)

    // MARK: Body

    var body: some View {
        GeometryReader { geo in
            // TimelineView is purely a render-side ticker. `audioTime()` — the
            // demo-audio clock — is the only timing input, sampled once here,
            // so no layout or scroll state can feed back into timing.
            TimelineView(.periodic(from: .now, by: Self.tickInterval)) { _ in
                let viewport = ReelViewport(
                    size: geo.size,
                    now: max(0, audioTime()),
                    actionLineFraction: Self.actionLineFraction,
                    secondsAboveLine: Self.secondsAboveLine)
                reelContent(viewport)
            }
        }
        .background(
            LinearGradient(colors: [Self.backgroundTop, Self.backgroundBottom],
                           startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    /// One render frame — a pure function of `viewport`. The `Canvas` paints
    /// the dense graphics; the overlays carry crisp text. Nothing here writes
    /// view state.
    private func reelContent(_ viewport: ReelViewport) -> some View {
        let currentSegment = timeline.segment(at: viewport.now)
        let isComplete = viewport.now >= timeline.audioDuration - Self.completionEpsilon

        return ZStack {
            Canvas { context, _ in
                drawRegionBands(in: context, viewport: viewport)
                drawBeatGrid(in: context, viewport: viewport)
                drawGhostStrokes(in: context, viewport: viewport)
                drawTargetStrokes(in: context, viewport: viewport)
                drawActionLine(in: context, viewport: viewport, segment: currentSegment)
            }

            segmentLabelOverlay(viewport)
            actionLineChip(viewport: viewport, segment: currentSegment)

            if isComplete {
                completionCard
            }
        }
    }

    // MARK: - Canvas: region bands

    /// Full-width demo / copy bands. Demo bands are a cool tint; copy windows
    /// get a warm tint plus a diagonal hatch and accent edge so they read as
    /// "your turn" rather than empty space.
    private func drawRegionBands(in context: GraphicsContext, viewport: ReelViewport) {
        for segment in timeline.segments
        where viewport.isVisible(startTime: segment.startTime, endTime: segment.endTime) {
            let topY = viewport.y(for: segment.endTime)
            let bottomY = viewport.y(for: segment.startTime)
            let rect = CGRect(x: 0, y: topY,
                              width: viewport.size.width, height: bottomY - topY)
            let isCopy = segment.kind == .copy
            let accent = isCopy ? Self.copyAccent : Self.demoAccent

            context.fill(Path(rect), with: .color(accent.opacity(isCopy ? 0.13 : 0.09)))

            // A diagonal hatch fills the copy window so it never looks blank.
            if isCopy {
                drawHatch(in: rect, context: context, color: accent.opacity(0.16))
            }

            // Accent edge stripe down the leading side.
            context.fill(Path(CGRect(x: 0, y: topY, width: 3, height: rect.height)),
                         with: .color(accent.opacity(0.85)))

            // Thin boundary line at the segment start.
            var boundary = Path()
            boundary.move(to: CGPoint(x: 0, y: bottomY))
            boundary.addLine(to: CGPoint(x: viewport.size.width, y: bottomY))
            context.stroke(boundary, with: .color(.white.opacity(0.07)), lineWidth: 1)
        }
    }

    /// Diagonal hatch clipped to `rect`. A scoped copy of the context carries
    /// the clip so the rest of the canvas is unaffected.
    private func drawHatch(in rect: CGRect, context: GraphicsContext, color: Color) {
        var clipped = context
        clipped.clip(to: Path(rect))
        let spacing: CGFloat = 16
        var x = rect.minX - rect.height
        while x < rect.maxX {
            var line = Path()
            line.move(to: CGPoint(x: x, y: rect.maxY))
            line.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            clipped.stroke(line, with: .color(color), lineWidth: 1)
            x += spacing
        }
    }

    // MARK: - Canvas: beat grid

    /// Horizontal beat lines, drawn only when the manifest declares a tempo.
    /// The interim no-beat asset has no `bpm`, so the grid is simply absent;
    /// the over-beat asset (PHASE 5) will light it up with no code change.
    private func drawBeatGrid(in context: GraphicsContext, viewport: ReelViewport) {
        guard let bpm = timeline.bpm, bpm > 0 else { return }
        let beatInterval = 60.0 / bpm
        guard beatInterval > 0 else { return }

        let window = viewport.visibleTimeRange
        var index = max(0, Int(window.lowerBound / beatInterval))
        while true {
            let beatTime = Double(index) * beatInterval
            if beatTime > window.upperBound { break }
            if beatTime > timeline.audioDuration { break }
            let y = viewport.y(for: beatTime)
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: viewport.size.width, y: y))
            let isDownbeat = index % 4 == 0
            context.stroke(line,
                           with: .color(isDownbeat ? Self.downbeatLineColor : Self.beatLineColor),
                           lineWidth: isDownbeat ? 1.5 : 1)
            index += 1
        }
    }

    // MARK: - Canvas: strokes

    /// Solid reference strokes — the example to watch and listen to.
    private func drawTargetStrokes(in context: GraphicsContext, viewport: ReelViewport) {
        for stroke in timeline.strokes
        where viewport.isVisible(startTime: stroke.startTime, endTime: stroke.endTime) {
            drawStroke(stroke, in: context, viewport: viewport, isGhost: false)
        }
    }

    /// Outlined ghost strokes — the copy-window targets the user reproduces.
    private func drawGhostStrokes(in context: GraphicsContext, viewport: ReelViewport) {
        for stroke in ghostStrokes
        where viewport.isVisible(startTime: stroke.startTime, endTime: stroke.endTime) {
            drawStroke(stroke, in: context, viewport: viewport, isGhost: true)
        }
    }

    /// Draws one stroke bar in the centered stroke lane. Solid for reference
    /// strokes; translucent + outlined for copy-window ghosts. A bar whose
    /// span currently straddles the action line is "sounding now" and is
    /// haloed. Direction is shown by both color and a chevron.
    private func drawStroke(_ stroke: ReelStroke,
                            in context: GraphicsContext,
                            viewport: ReelViewport,
                            isGhost: Bool) {
        let topY = viewport.y(for: stroke.endTime)
        let bottomY = viewport.y(for: stroke.startTime)
        let centerY = (topY + bottomY) / 2
        let height = max(bottomY - topY, Self.minBarHeight)
        let laneWidth = viewport.size.width - Self.laneInset * 2
        guard laneWidth > 0 else { return }

        let barRect = CGRect(x: Self.laneInset, y: centerY - height / 2,
                             width: laneWidth, height: height)
        let bar = Path(roundedRect: barRect, cornerRadius: Self.barCornerRadius,
                       style: .continuous)
        let color = stroke.direction == .forward ? Self.forwardColor : Self.backwardColor
        let isSounding = viewport.now >= stroke.startTime && viewport.now < stroke.endTime

        if isGhost {
            context.fill(bar, with: .color(color.opacity(0.16)))
            context.stroke(bar, with: .color(color.opacity(0.65)),
                           style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        } else {
            // Fast strokes read a touch more vivid than slow ones.
            let topOpacity = stroke.speedClassification == .fast ? 1.0 : 0.9
            context.fill(bar, with: .linearGradient(
                Gradient(colors: [color.opacity(topOpacity), color.opacity(0.7)]),
                startPoint: CGPoint(x: barRect.midX, y: barRect.minY),
                endPoint: CGPoint(x: barRect.midX, y: barRect.maxY)))
            if isSounding {
                context.stroke(bar, with: .color(.white.opacity(0.95)), lineWidth: 2.5)
            }
        }

        // Direction chevron, centered on the bar: › forward (push),
        // ‹ backward (pull). Skipped when the bar is too short to carry it.
        if height >= Self.minBarHeight {
            drawDirectionChevron(stroke.direction,
                                 center: CGPoint(x: barRect.midX, y: centerY),
                                 in: context,
                                 color: .white.opacity(isGhost ? 0.55 : 0.95))
        }
    }

    /// A clean two-segment chevron — `›` for forward, `‹` for backward.
    private func drawDirectionChevron(_ direction: ScratchNotationDirection,
                                      center: CGPoint,
                                      in context: GraphicsContext,
                                      color: Color) {
        let s: CGFloat = 5
        let dx: CGFloat = direction == .forward ? s : -s
        var chevron = Path()
        chevron.move(to: CGPoint(x: center.x - dx, y: center.y - s))
        chevron.addLine(to: CGPoint(x: center.x + dx, y: center.y))
        chevron.addLine(to: CGPoint(x: center.x - dx, y: center.y + s))
        context.stroke(chevron, with: .color(color),
                       style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
    }

    // MARK: - Canvas: action line

    /// The fixed "now" line. It picks up the active segment's accent — amber
    /// while the user is copying, blue while watching the demo.
    private func drawActionLine(in context: GraphicsContext,
                                viewport: ReelViewport,
                                segment: ReelSegment?) {
        let y = viewport.actionLineY
        let width = viewport.size.width
        let tint = (segment?.kind == .copy) ? Self.copyAccent : Self.demoAccent

        // Soft glow band behind the line.
        context.fill(
            Path(CGRect(x: 0, y: y - 7, width: width, height: 14)),
            with: .linearGradient(
                Gradient(colors: [tint.opacity(0), tint.opacity(0.30), tint.opacity(0)]),
                startPoint: CGPoint(x: 0, y: y),
                endPoint: CGPoint(x: width, y: y)))

        var line = Path()
        line.move(to: CGPoint(x: 0, y: y))
        line.addLine(to: CGPoint(x: width, y: y))
        context.stroke(line, with: .color(.white.opacity(0.9)), lineWidth: 2)

        // End caps anchor the line.
        for capX in [CGFloat(0), width] {
            context.fill(
                Path(ellipseIn: CGRect(x: capX - 4, y: y - 4, width: 8, height: 8)),
                with: .color(tint))
        }
    }

    // MARK: - Overlays: segment labels

    /// Per-segment labels — `DEMO 1`, `YOUR TURN` — riding each band's leading
    /// edge so an upcoming segment announces itself as it scrolls in. Clamped
    /// to stay on screen while any of the band is visible.
    @ViewBuilder
    private func segmentLabelOverlay(_ viewport: ReelViewport) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(timeline.segments.enumerated()), id: \.offset) { _, segment in
                if viewport.isVisible(startTime: segment.startTime, endTime: segment.endTime) {
                    let rawY = viewport.y(for: segment.startTime) + 18
                    let clampedY = min(max(rawY, 20), viewport.size.height - 20)
                    segmentLabelChip(segment)
                        .offset(x: 16, y: clampedY - 11)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func segmentLabelChip(_ segment: ReelSegment) -> some View {
        let isCopy = segment.kind == .copy
        let accent = isCopy ? Color(red: 0.96, green: 0.62, blue: 0.07)
                            : Color(red: 0.23, green: 0.51, blue: 0.96)
        return Text(reelLabel(for: segment).uppercased())
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(accent.opacity(0.9))
            .clipShape(Capsule())
    }

    // MARK: - Overlays: action-line status chip

    /// The pinned chip at the action line — the reel's most prominent label.
    /// Names what is happening *now*: `DEMO n — Watch & listen`, or an emphatic
    /// `YOUR TURN — Copy what you heard` during a copy window.
    @ViewBuilder
    private func actionLineChip(viewport: ReelViewport, segment: ReelSegment?) -> some View {
        let isCopy = segment?.kind == .copy
        let accent = isCopy ? Color(red: 0.96, green: 0.62, blue: 0.07)
                            : Color(red: 0.23, green: 0.51, blue: 0.96)
        let title = segment.map { isCopy ? "YOUR TURN" : reelLabel(for: $0).uppercased() }
            ?? "GET READY"
        let subtitle = isCopy ? "Copy what you heard"
                              : (segment == nil ? "Demo starting" : "Watch & listen")

        VStack(spacing: 1) {
            Text(title)
                .font(.system(size: 15, weight: .heavy))
                .foregroundColor(.white)
            Text(subtitle)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.8))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(accent.opacity(0.92))
                .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1)))
        .shadow(color: .black.opacity(0.4), radius: 5, y: 2)
        .position(x: viewport.size.width / 2,
                  y: max(28, viewport.actionLineY - 30))
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(subtitle)")
    }

    // MARK: - Overlays: completion

    /// Parked state once the demo audio reaches its end. Derived purely from
    /// the audio clock crossing `audioDuration` — no audio-player delegate
    /// callback is involved, so it carries no lifecycle risk.
    private var completionCard: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundColor(Color(red: 0.20, green: 0.80, blue: 0.45))
            Text("Demo complete")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
            Text("You ran the full call-and-response.")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.75))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(Color.white.opacity(0.12), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Demo complete")
    }

    // MARK: - Labels

    /// A practical label for a segment: the manifest's own label when present,
    /// otherwise a plain `Demo` / `Your turn` fallback.
    private func reelLabel(for segment: ReelSegment) -> String {
        if let label = segment.label,
           !label.trimmingCharacters(in: .whitespaces).isEmpty {
            return label
        }
        return segment.kind == .copy ? "Your turn" : "Demo"
    }
}
