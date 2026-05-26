import Foundation

/// Aligned target + captured replay timelines for the Review surface.
///
/// `ReviewOverlayTimeline` is the read-only data substrate for the
/// Slice 4.1 overlay diff viewer. It pairs an authored target
/// `SessionReplayTimeline` against the captured `SessionReplayTimeline`
/// for visual comparison. The model is purely derivative — it owns no
/// playback state, mutates neither source timeline, and introduces no
/// new event format. Playback timing is driven by an external
/// `SessionReplayClock` (typically anchored to the captured stream);
/// this type only describes what gets drawn.
///
/// `displayDurationSeconds` is the joint axis span the overlay lane
/// view scales to: the larger of the two recorded durations, clamped
/// to non-negative. When both timelines are empty the value is `0`.
///
/// Determinism: given identical inputs, two `ReviewOverlayTimeline`
/// values compare equal and serialize identically — there is no
/// time-of-construction state.
struct ReviewOverlayTimeline: Equatable, Sendable {

    /// Authored notation the performer was meant to play. Rendered as
    /// the dimmed "ghost" lane in the overlay view.
    let target: SessionReplayTimeline

    /// Notation the system actually detected from the take. Rendered
    /// as the primary lane in the overlay view.
    let captured: SessionReplayTimeline

    /// Joint axis span used by the overlay view. Equal to
    /// `max(target.takeDurationSeconds, captured.takeDurationSeconds)`,
    /// clamped to `0` when both timelines are empty or negative.
    let displayDurationSeconds: Double

    init(target: SessionReplayTimeline, captured: SessionReplayTimeline) {
        self.target = target
        self.captured = captured
        let joint = max(target.takeDurationSeconds, captured.takeDurationSeconds)
        self.displayDurationSeconds = max(0, joint)
    }

    /// Builds an overlay from a target/captured snapshot pair. Each
    /// snapshot is projected through `SessionReplayTimeline.build` —
    /// no parallel event format is introduced. Negative durations are
    /// clamped to `0` before projection so the overlay never reports
    /// a span the underlying timeline cannot also report.
    static func build(
        targetSnapshot: CaptureCore.DetectedNotationSnapshot,
        targetDuration: Double,
        capturedSnapshot: CaptureCore.DetectedNotationSnapshot,
        capturedDuration: Double
    ) -> ReviewOverlayTimeline {
        ReviewOverlayTimeline(
            target: SessionReplayTimeline.build(
                from: targetSnapshot,
                takeDuration: max(0, targetDuration)
            ),
            captured: SessionReplayTimeline.build(
                from: capturedSnapshot,
                takeDuration: max(0, capturedDuration)
            )
        )
    }

    /// True when neither timeline carries any events to render. The
    /// overlay view is still safe to instantiate in this state — the
    /// lane simply renders empty with the cursor pinned at `0`.
    var isEmpty: Bool {
        target.events.isEmpty && captured.events.isEmpty
    }

    /// Clamps an arbitrary playhead time into the overlay's drawable
    /// range. Used by the lane view so a `SessionReplayClock` whose
    /// `takeDurationSeconds` exceeds either source timeline (or whose
    /// host-time overshoots) cannot push the cursor past the joint
    /// `displayDurationSeconds`. Monotonic: for any pair of inputs
    /// `a <= b`, `clamp(time: a) <= clamp(time: b)`.
    func clamp(time: TimeInterval) -> TimeInterval {
        if time <= 0 { return 0 }
        if time >= displayDurationSeconds { return displayDurationSeconds }
        return time
    }
}
