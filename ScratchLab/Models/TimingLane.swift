import CoreGraphics
import Foundation

// Shared model for the unified practice timing lane.
//
// ScratchLab's practice surface is one notation-first instrument: a timing
// lane the notation scrolls along, toward a fixed action line that marks
// "now". The lane runs vertically in portrait and horizontally in landscape —
// but it is the SAME lane: same strokes, same action line, same spacing, same
// colours, same Demo/Copy language, same user-overlay model. Only the axis
// differs.
//
// This file is the lane's neutral foundation, decoupled from any one source:
//
//   • `LaneContent` — what the lane renders (strokes, demo/copy segments, a
//     beat tempo, a duration). Adapters build it from a Demo call-and-response
//     `PracticeReelTimeline` or from a scored-mode `ScratchNotation`, so the
//     renderer never needs to know which mode it is drawing.
//   • `LaneViewport` — pure, axis-parametric geometry. It maps timeline
//     seconds to screen coordinates along the scroll axis; every output is a
//     deterministic function of `(now, size, axis)` with no scroll state, so
//     the lane can never drift from its clock.
//
// Scope: pure model + geometry. No SwiftUI, no capture/export/scoring/ML, no
// audio. It reads `PracticeReelTimeline` and `ScratchNotation` but mutates
// neither schema.

// MARK: - Axis

/// Which way the timing lane scrolls. Portrait runs it vertically (time flows
/// top→bottom); landscape runs it horizontally (time flows left→right, future
/// on the right). The renderer and viewport are otherwise identical.
enum LaneAxis: Equatable, Sendable {
    case vertical
    case horizontal
}

// MARK: - Stroke

/// One stroke on the lane's absolute timeline. Field-compatible with both
/// `ReelStroke` and `ScratchNotation.Stroke` — the neutral type the unified
/// renderer draws, whatever the source mode.
struct LaneStroke: Equatable, Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let direction: ScratchNotationDirection
    let speed: ScratchNotationSpeedClassification
    let faderState: ScratchNotationFaderState
    /// True for a derived copy-window target — drawn as an outline "ghost"
    /// rather than a solid reference stroke.
    let isGhost: Bool

    var duration: TimeInterval { max(0, endTime - startTime) }
}

extension LaneStroke {
    /// A solid or ghost stroke adapted from a Demo reel manifest.
    init(reelStroke stroke: ReelStroke, isGhost: Bool) {
        self.init(startTime: stroke.startTime,
                  endTime: stroke.endTime,
                  direction: stroke.direction,
                  speed: stroke.speedClassification,
                  faderState: stroke.faderState,
                  isGhost: isGhost)
    }

    /// A solid reference stroke adapted from a scored-mode `ScratchNotation`.
    init(notationStroke stroke: ScratchNotation.Stroke) {
        self.init(startTime: stroke.startTime,
                  endTime: stroke.endTime,
                  direction: stroke.direction,
                  speed: stroke.speedClassification,
                  faderState: stroke.faderState,
                  isGhost: false)
    }

    /// The stroke with its start/end times shifted by `offset` — used to tile
    /// a looping pattern seamlessly across the lane.
    func shifted(by offset: TimeInterval) -> LaneStroke {
        guard offset != 0 else { return self }
        return LaneStroke(startTime: startTime + offset,
                          endTime: endTime + offset,
                          direction: direction,
                          speed: speed,
                          faderState: faderState,
                          isGhost: isGhost)
    }
}

// MARK: - Segment

/// A typed demo/copy span on the lane timeline. Demo mode's call-and-response
/// reel has these; scored-mode content has none.
struct LaneSegment: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A reference example the app performs — "watch and listen".
        case demo
        /// A copy window the user fills — "your turn".
        case copy
    }

    let kind: Kind
    let startTime: TimeInterval
    let endTime: TimeInterval
    /// Optional display label, e.g. "Demo 1" or "Your turn".
    let label: String?

    var duration: TimeInterval { max(0, endTime - startTime) }

    /// Half-open containment: `[startTime, endTime)`.
    func contains(_ time: TimeInterval) -> Bool {
        time >= startTime && time < endTime
    }
}

extension LaneSegment {
    /// Adapted from a Demo reel manifest segment.
    init(reelSegment segment: ReelSegment) {
        self.init(kind: segment.kind == .copy ? .copy : .demo,
                  startTime: segment.startTime,
                  endTime: segment.endTime,
                  label: segment.label)
    }
}

// MARK: - User-attempt event

/// A single user-attempt mark for the timing-comparison overlay.
///
/// SCAFFOLD: empty on every shipping path today. The type exists so the lane
/// renderer and its call sites already carry user attempts; wiring it to a
/// live source — mic analysis, capture, scoring — is out of scope here. The
/// future overlay compares a user event against the target at the action line.
struct LaneUserEvent: Equatable, Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let direction: ScratchNotationDirection
    /// Phase B1 — optional visual judgment for the user-attempt tick.
    /// Renderer consumes this only when
    /// `FeatureFlags.laneJudgmentTintEnabled` is on; nil is the
    /// default so existing call sites compile unchanged and produce
    /// the same neutral tick they always have.
    ///
    /// Presentation-only: deliberately not a `CoachingEventKind`. A
    /// user-attempt tick being "early" or "late" relative to the
    /// action line is a UI signal, not a coaching event — keeping the
    /// types separate prevents the renderer's visual states from
    /// leaking into the coaching value-type contract.
    var judgment: LaneJudgment? = nil
}

// MARK: - LaneJudgment

/// Presentation-only judgment of one user-attempt tick relative to the
/// nearest beat. Pure value type; no clock, no UI, no coaching
/// implication. Renderer maps each case to a `ScratchLabPalette`
/// semantic alias per the Phase B AR-prep contract:
///
/// - `.onBeat` → success
/// - `.early`  → info
/// - `.late`   → warning
/// - `.neutral` → fall back to today's white tint (no usable signal)
enum LaneJudgment: String, Equatable, Sendable, CaseIterable {
    case onBeat
    case early
    case late
    case neutral

    /// Threshold (in milliseconds, signed) above which an attempt
    /// counts as outside the on-beat window. Matches the same 80 ms
    /// boundary the Phase C1 drift summary uses so the lane tick and
    /// the post-session summary read consistent.
    static let outsideWindowThresholdMs: Double = 80

    /// Pure, deterministic mapping from a signed beat offset (in
    /// milliseconds; positive = late, negative = early) plus the
    /// upstream `isOnBeat` verdict.
    ///
    /// `isOnBeat == true` always wins over a marginally-outside-window
    /// numeric offset (mirrors the upstream pipeline's own definition
    /// of "on beat"). Non-finite or NaN offsets collapse to
    /// `.neutral`.
    static func from(
        beatOffsetMilliseconds offset: Double,
        isOnBeat: Bool
    ) -> LaneJudgment {
        guard offset.isFinite else { return .neutral }
        if isOnBeat { return .onBeat }
        if offset > outsideWindowThresholdMs { return .late }
        if offset < -outsideWindowThresholdMs { return .early }
        return .onBeat
    }
}

// MARK: - Content

/// Everything the unified lane renders, decoupled from its source. Built by an
/// adapter from a Demo `PracticeReelTimeline` or a scored `ScratchNotation`.
///
/// Phase 2 adds two **optional** channels — `platterTimeline` (a raw integrated
/// `(t, position)` stream) and `faderEvents` (the captured crossfader event
/// stream). Both default to nil/empty so every existing call site stays
/// behaviourally identical: the renderer's classified-stroke fallback is used
/// whenever the raw timeline is absent or fails `shouldRenderRawTrace(...)`,
/// and the crossfader ribbon is omitted when no events are attached.
struct LaneContent: Equatable, Sendable {
    /// Reference strokes plus any derived copy-window ghosts (`isGhost`).
    let strokes: [LaneStroke]
    /// Demo/copy bands — empty for scored content.
    let segments: [LaneSegment]
    /// Reference-beat tempo for the beat grid. `nil` ⇒ no grid drawn.
    let beatsPerMinute: Double?
    /// Full timeline length, in seconds.
    let duration: TimeInterval
    /// Whether the lane loops the timeline (scored preview modes) or plays it
    /// once through (Demo mode follows the demo audio).
    let loops: Bool
    /// Optional raw platter-position timeline. When present AND dense enough
    /// (see `shouldRenderRawTrace(minimumSampleDensity:)`), the renderer
    /// draws a continuous integrated trace instead of the classified-stroke
    /// `MotionPath`. Nil ⇒ classified fallback always used. Phase 2: there is
    /// no producer yet; this stays nil on every shipping call path until
    /// Phase 3 lands a live producer or Phase 4 ships a bundled fixture.
    let platterTimeline: PlatterPositionTimeline?
    /// Optional captured crossfader event stream. The lane materialises a
    /// `CrossfaderStateTimeline` from this and draws the open/closed ribbon
    /// + cut/pulse/flare ticks along the lane's bottom (portrait) or
    /// trailing (landscape) edge. Empty ⇒ no ribbon drawn.
    let faderEvents: [CaptureCore.DetectedNotationFaderEvent]

    /// Designated initialiser. The two Phase 2 fields default to nil/empty so
    /// every existing call site (including `init(reel:)` and `init(notation:)`)
    /// continues to behave identically without modification.
    init(strokes: [LaneStroke],
         segments: [LaneSegment],
         beatsPerMinute: Double?,
         duration: TimeInterval,
         loops: Bool,
         platterTimeline: PlatterPositionTimeline? = nil,
         faderEvents: [CaptureCore.DetectedNotationFaderEvent] = []) {
        self.strokes = strokes
        self.segments = segments
        self.beatsPerMinute = beatsPerMinute
        self.duration = duration
        self.loops = loops
        self.platterTimeline = platterTimeline
        self.faderEvents = faderEvents
    }

    /// The segment active at `time`, if any.
    func segment(at time: TimeInterval) -> LaneSegment? {
        segments.first { $0.contains(time) }
    }
}

extension LaneContent {
    /// Default minimum sample density (samples/second) below which the
    /// renderer falls back to the classified-stroke `MotionPath`. Karl's
    /// Phase 2 decision: 10 samples/sec — matches the live hand-tracker's
    /// idle-throttled rate (~30 Hz active, ~4 Hz idle).
    static let defaultMinimumSampleDensity: Double = 10.0

    /// Minimum fraction of `duration` the raw timeline must cover before
    /// the renderer prefers it over the classified fallback.
    static let minimumRawTraceCoverageFraction: Double = 0.8

    /// Whether the renderer should prefer the raw integrated trace over the
    /// classified-stroke `MotionPath` fallback. Returns `true` when **all**
    /// gates pass:
    ///
    /// 1. `platterTimeline` is non-nil.
    /// 2. Timeline span is positive.
    /// 3. Sample density ≥ `minimumSampleDensity` samples/second.
    /// 4. `duration` is positive (a degenerate content has no fallback to
    ///    measure against either, so this gate is mostly defensive).
    /// 5. Timeline span ≥ `duration * minimumRawTraceCoverageFraction`.
    ///
    /// The Phase 1 placeholder threshold is `10` samples/sec; Phase 3 may
    /// tune this once real live capture exists.
    func shouldRenderRawTrace(
        minimumSampleDensity: Double = LaneContent.defaultMinimumSampleDensity
    ) -> Bool {
        guard let timeline = platterTimeline else { return false }
        let span = timeline.endTime - timeline.startTime
        guard span > 0 else { return false }
        let density = Double(timeline.samples.count) / span
        guard density >= minimumSampleDensity else { return false }
        guard duration > 0 else { return false }
        guard span >= duration * LaneContent.minimumRawTraceCoverageFraction else {
            return false
        }
        return true
    }
}

extension LaneContent {
    /// Builds lane content from a Demo call-and-response reel manifest. Demo
    /// segments carry solid reference strokes; copy windows carry derived
    /// ghost targets. Demo plays once — it does not loop.
    init(reel: PracticeReelTimeline) {
        // Copy windows render as truly empty space — the warm copy band, the
        // boundary line, and the "Your Turn" label tell the user it's their
        // turn. Ghosts are intentionally omitted until the renderer can draw
        // them as faint outlines distinct from solid reference strokes;
        // `PracticeReelTimeline.derivedCopyGhostStrokes()` stays defined for
        // that future surface.
        let references = reel.strokes.map { LaneStroke(reelStroke: $0, isGhost: false) }
        self.init(strokes: references,
                  segments: reel.segments.map(LaneSegment.init(reelSegment:)),
                  beatsPerMinute: reel.bpm,
                  duration: reel.audioDuration,
                  loops: false)
    }

    /// Builds lane content from a scored-mode target pattern. There are no
    /// demo/copy segments and no ghosts; the pattern loops so the learner can
    /// practise it against the action line repeatedly.
    init(notation: ScratchNotation, beatsPerMinute: Double? = nil) {
        self.init(strokes: notation.strokes.map(LaneStroke.init(notationStroke:)),
                  segments: [],
                  beatsPerMinute: beatsPerMinute,
                  duration: max(notation.timelineDuration, 0.1),
                  loops: true)
    }
}

// MARK: - Viewport

/// Pure, axis-parametric geometry for the timing lane.
///
/// The lane has two axes: the **scroll axis** carries time (vertical = the
/// view's height, horizontal = its width) and the **cross axis** is the lane's
/// width. `pos(for:)` maps a timeline second onto the scroll axis; `rect` and
/// `point` turn scroll/cross coordinates into screen geometry for the active
/// axis. Every value is a function of `(now, size, axis)` alone — no scroll
/// state, no feedback path — so the lane stays locked to its clock.
struct LaneViewport: Equatable, Sendable {
    /// The lane's drawing area.
    let size: CGSize
    /// Current timeline position, in seconds — the single source of truth.
    let now: TimeInterval
    let axis: LaneAxis
    /// Action-line position as a fraction along the scroll axis, from its
    /// start (top for vertical, leading edge for horizontal).
    let actionLineFraction: CGFloat
    /// Seconds of lookahead shown between the action line and the far edge.
    let secondsAhead: TimeInterval

    /// Length of the scroll (time) axis.
    var scrollLength: CGFloat { axis == .vertical ? size.height : size.width }
    /// Length of the cross (lane-width) axis.
    var crossLength: CGFloat { axis == .vertical ? size.width : size.height }

    /// Position of the action line along the scroll axis.
    var actionLinePos: CGFloat { scrollLength * actionLineFraction }

    /// Length of the lookahead region — action line to the far (future) edge.
    private var lookaheadLength: CGFloat {
        axis == .vertical ? actionLinePos : scrollLength - actionLinePos
    }

    /// Points per second of timeline — derived so exactly `secondsAhead` of
    /// lookahead fills the region ahead of the action line, whatever the size.
    var pointsPerSecond: CGFloat {
        guard secondsAhead > 0, lookaheadLength > 0 else { return 0 }
        return lookaheadLength / CGFloat(secondsAhead)
    }

    /// Direction of the time→scroll mapping. Vertical future is *before* the
    /// action line (smaller y); horizontal future is *after* it (larger x).
    private var timeSign: CGFloat { axis == .vertical ? -1 : 1 }

    /// Scroll-axis position for an absolute timeline time. `time == now` maps
    /// to the action line; the future maps toward the far edge.
    func pos(for time: TimeInterval) -> CGFloat {
        actionLinePos + timeSign * CGFloat(time - now) * pointsPerSecond
    }

    /// Inverse of `pos(for:)` — the timeline time drawn at a scroll position.
    func time(atPos pos: CGFloat) -> TimeInterval {
        guard pointsPerSecond > 0 else { return now }
        return now + TimeInterval((pos - actionLinePos) / (timeSign * pointsPerSecond))
    }

    /// The timeline span currently on screen.
    var visibleTimeRange: ClosedRange<TimeInterval> {
        let a = time(atPos: 0)
        let b = time(atPos: scrollLength)
        return Swift.min(a, b)...Swift.max(a, b)
    }

    /// Whether `[start, end]` overlaps the visible window at all.
    func isVisible(from start: TimeInterval, to end: TimeInterval) -> Bool {
        let window = visibleTimeRange
        return end >= window.lowerBound && start <= window.upperBound
    }

    /// A screen rect spanning `[scroll0, scroll1]` along the time axis and
    /// `[cross0, cross1]` across the lane width — mapped for the active axis.
    func rect(scroll0: CGFloat, scroll1: CGFloat,
              cross0: CGFloat, cross1: CGFloat) -> CGRect {
        let s0 = Swift.min(scroll0, scroll1), s1 = Swift.max(scroll0, scroll1)
        let c0 = Swift.min(cross0, cross1), c1 = Swift.max(cross0, cross1)
        switch axis {
        case .vertical:   return CGRect(x: c0, y: s0, width: c1 - c0, height: s1 - s0)
        case .horizontal: return CGRect(x: s0, y: c0, width: s1 - s0, height: c1 - c0)
        }
    }

    /// A screen point at scroll-axis `scroll` and cross-axis `cross`.
    func point(scroll: CGFloat, cross: CGFloat) -> CGPoint {
        switch axis {
        case .vertical:   return CGPoint(x: cross, y: scroll)
        case .horizontal: return CGPoint(x: scroll, y: cross)
        }
    }
}

// MARK: - Lane clock

/// The timing source driving the lane. The single shared clock abstraction —
/// Demo mode locks to the demo-audio position, the scored preview modes run a
/// free-running loop over the pattern, and the manual modes hold it parked.
/// Audio playback is always the master clock.
enum LaneClock {
    /// Locked to an external audio position, in seconds (Demo mode).
    case audioTime(() -> TimeInterval)
    /// Free-running loop over `duration` seconds from `start` (the scored
    /// preview modes — Auto-cut, Guided).
    case looping(start: Date, duration: TimeInterval)
    /// Parked at a fixed position — the lane holds still (Coached, Open).
    case fixed(TimeInterval)

    /// Resolves the current timeline position for a render tick at `date`.
    func now(at date: Date) -> TimeInterval {
        switch self {
        case .audioTime(let provider):
            return max(0, provider())
        case .looping(let start, let duration):
            let span = max(duration, 0.0001)
            return date.timeIntervalSince(start).truncatingRemainder(dividingBy: span)
        case .fixed(let time):
            return max(0, time)
        }
    }
}
