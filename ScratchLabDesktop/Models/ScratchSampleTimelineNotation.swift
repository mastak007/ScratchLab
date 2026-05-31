#if os(macOS)
import CoreGraphics
import Foundation

// Scratch Playback Lab: pure adapter from a captured `ScratchSampleTimeline` to
// notation geometry — a `MotionPath` the existing `ScratchMotionRenderer.draw`
// already consumes. No UI, no PNG, no view wiring lives here; this file only
// shapes the geometry.
//
// The whole reason this adapter exists is to PRESERVE ABSOLUTE SAMPLE TRAVEL.
//   `ScratchStrokeGeometry.motionPath(for:)` deliberately min/max-NORMALISES its
//   raw curve into 0...1, so a partial scratch is stretched to fill the lane.
//   That is exactly what must NOT happen here: the captured sample position is
//   already a truthful normalised 0...1 figure (0 = sample start / rest edge,
//   1 = sample end / full-travel edge), so it is mapped STRAIGHT through to the
//   notation cross-axis with no renormalisation. A scratch that only reaches
//   0.4 sits at 0.4; a 0.4...0.6 nudge stays mid-lane; a reversal at 0.55 turns
//   around at 0.55. The renderer's `draw(_:in:viewport:style:)` maps position 0
//   to the lane's low edge and 1 to its high edge directly, so feeding it the
//   raw sample positions yields height that is faithful to real travel.
//
// Crossfader-closed (muted) capture is preserved, never deleted: the muted
// samples keep their real timing and position inside `path`, and their time
// spans are surfaced separately in `mutedSpans` so a later slice can dim / mark
// them without the geometry having to encode a "muted" flag the shared
// `MotionSegment` type does not carry.

/// Pure, derived notation geometry for one captured `ScratchSampleTimeline`.
/// Holds the renderer-ready `MotionPath` (absolute sample position preserved)
/// plus the time spans that were captured with the crossfader closed. Never
/// persisted — adds no field to any export schema.
struct ScratchSampleTimelineNotation: Equatable, Sendable {

    /// The platter-position curve, directly consumable by
    /// `ScratchMotionRenderer.draw`. Each segment's `startPosition` /
    /// `endPosition` ARE the captured absolute sample positions (0...1) — there
    /// is NO min/max renormalisation, so partial travel stays partial height.
    let path: MotionPath

    /// Time spans captured while the crossfader was in the closed (muted) zone.
    /// Markable as muted / gap / dim by a later UI slice; the timing is
    /// preserved (the spans are real), and the matching travel still lives in
    /// `path`. Empty when nothing was muted. One span per maximal run of
    /// consecutive muted samples.
    let mutedSpans: [ClosedRange<TimeInterval>]

    /// True when there is no drawable geometry (an empty source timeline).
    var isEmpty: Bool { path.isEmpty }

    /// Builds notation geometry from a captured timeline. Pure and
    /// deterministic — reads only the timeline's events.
    ///
    /// - Empty timeline → an empty path (`isEmpty == true`) and no muted spans.
    /// - Single-event timeline → one safe flat hold at the captured position
    ///   (a zero-length span), so a lone sample never crashes or invents travel.
    /// - Otherwise → one segment per consecutive event pair: a rising stroke
    ///   when the sample position increased, a falling stroke when it decreased,
    ///   and a flat hold when it did not move (within `positionEpsilon`). A
    ///   direction reversal therefore produces a vertex at the EXACT sample
    ///   position the platter turned around.
    init(timeline: ScratchSampleTimeline) {
        let events = timeline.events

        guard let first = events.first else {
            // Empty capture — nothing to draw, nothing muted.
            path = MotionPath(segments: [], timeRange: 0...0)
            mutedSpans = []
            return
        }

        guard events.count >= 2 else {
            // A single sample has no travel and no time span: hold flat at the
            // captured position so the lane shows a truthful rest, not a stroke.
            let time = first.timeSeconds
            let position = CGFloat(first.position)
            path = MotionPath(
                segments: [MotionSegment(kind: .hold,
                                         startTime: time, endTime: time,
                                         startPosition: position, endPosition: position,
                                         speed: .medium, isGhost: false)],
                timeRange: time...time)
            mutedSpans = first.muted ? [time...time] : []
            return
        }

        // One segment per consecutive event pair. Sample positions pass straight
        // through (CGFloat cast only) — the absolute-travel contract. Speed is a
        // neutral `.medium`: this slice is about position fidelity, so line
        // weight is left flat rather than inventing a speed classification.
        var segments: [MotionSegment] = []
        segments.reserveCapacity(events.count - 1)
        for index in 1..<events.count {
            let previous = events[index - 1]
            let current = events[index]
            let delta = current.position - previous.position
            let kind: MotionSegmentKind
            if abs(delta) <= ScratchSampleTimeline.positionEpsilon {
                kind = .hold
            } else {
                kind = .stroke(delta > 0 ? .forward : .backward)
            }
            segments.append(MotionSegment(
                kind: kind,
                startTime: previous.timeSeconds,
                endTime: current.timeSeconds,
                startPosition: CGFloat(previous.position),
                endPosition: CGFloat(current.position),
                speed: .medium,
                isGhost: false))
        }
        path = MotionPath(segments: segments,
                          timeRange: first.timeSeconds...events[events.count - 1].timeSeconds)

        // Collapse consecutive muted samples into spans, preserving their real
        // start→end timing. A lone muted sample becomes a zero-length span.
        var spans: [ClosedRange<TimeInterval>] = []
        var runStart: TimeInterval?
        var runEnd: TimeInterval = first.timeSeconds
        for event in events {
            if event.muted {
                if runStart == nil { runStart = event.timeSeconds }
                runEnd = event.timeSeconds
            } else if let start = runStart {
                spans.append(start...runEnd)
                runStart = nil
            }
        }
        if let start = runStart { spans.append(start...runEnd) }
        mutedSpans = spans
    }
}
#endif
