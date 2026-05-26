import Foundation

/// Deterministic, host-time-driven replay controller for the Slice 4.3
/// Overlay Review cursor.
///
/// Owns a `SessionReplayClock` and a virtual playback anchor so the
/// macOS Overlay Review card can scrub a visual cursor across the
/// captured `SessionReplayTimeline` without an audio player attached.
/// Every state transition is a pure function of `(prior state, hostTime,
/// caller action)` — there is no `Date()`, no global timer, no random
/// component — so a deterministic input stream yields a byte-identical
/// output stream of `currentTime` values and fired event sequences.
///
/// Scope (read-only, additive):
///   - drives a visual cursor only
///   - does **not** mutate notation, sidecars, exports, or scoring
///   - does **not** speak to AVAudioPlayer or any audio engine
///   - reuses `SessionReplayClock` exactly as shipped — no
///     `SessionReplayTimeline` schema or `SessionReplayClock` API
///     changes
///
/// Anchor model:
///   - `anchorHostTime` and `anchorPlayerTime` are reset on every
///     `play`, `pause`, `restart`, and on auto-stop-at-end.
///   - While `isPlaying`, the externally visible `currentTime`
///     equals `min(duration, anchorPlayerTime + (hostTime - anchorHostTime))`.
///   - While paused, `currentTime` is the value the cursor was at the
///     moment of the most recent `pause` / `restart`.
///
/// Determinism invariants enforced by the tests:
///   - **starts at zero**: a freshly initialised controller reports
///     `currentTime == 0`, `isPlaying == false`.
///   - **monotonic**: for any monotonic non-decreasing host-time
///     sequence, `currentTime` is non-decreasing.
///   - **clamps to duration**: `currentTime` never exceeds
///     `timeline.takeDurationSeconds`.
///   - **stops at end**: `tick(hostTime:)` auto-clears `isPlaying`
///     when the cursor reaches `duration`.
///   - **restart rewinds cursor**: after `restart(hostTime:)`,
///     `currentTime == 0` and the wrapped `SessionReplayClock` cursor
///     is at event 0.
///   - **no double-fire across pause/play or seek**: events that
///     already fired never refire — the wrapped clock owns this
///     invariant, the controller preserves it by only re-ingesting
///     the audio clock on explicit state transitions and never
///     rewinding the cursor outside `restart`.
///   - **empty timeline is safe**: `hasTimeline == false` short-
///     circuits every mutating method; `tick` returns `[]`.
struct OverlayReplayController: Equatable, Sendable {

    let timeline: SessionReplayTimeline
    private(set) var clock: SessionReplayClock
    private(set) var isPlaying: Bool = false
    private(set) var currentTime: TimeInterval = 0

    private var anchorHostTime: TimeInterval = 0
    private var anchorPlayerTime: TimeInterval = 0

    init(timeline: SessionReplayTimeline) {
        self.timeline = timeline
        self.clock = SessionReplayClock(timeline: timeline)
    }

    /// The replay axis span. Zero when the timeline carries no events
    /// or was constructed with a non-positive duration.
    var duration: TimeInterval { max(0, timeline.takeDurationSeconds) }

    /// `true` when the underlying timeline has a playable duration.
    /// `false` short-circuits every mutating method.
    var hasTimeline: Bool { duration > 0 }

    /// Begin playback at `hostTime`. No-op when `hasTimeline == false`
    /// or playback is already active. When the cursor is already at
    /// (or beyond) `duration`, the controller rewinds first so a
    /// second Play after auto-stop replays from the beginning.
    mutating func play(hostTime: TimeInterval) {
        guard hasTimeline else { return }
        if isPlaying { return }
        if currentTime >= duration {
            currentTime = 0
            clock.reset()
        }
        anchorHostTime = hostTime
        anchorPlayerTime = currentTime
        isPlaying = true
        clock.ingest(playerTime: currentTime, isPlaying: true, hostTime: hostTime)
    }

    /// Pause playback at `hostTime`. The cursor freezes at the value
    /// it had advanced to by this host moment. No-op when not playing.
    mutating func pause(hostTime: TimeInterval) {
        guard isPlaying else { return }
        currentTime = computeAdvanced(hostTime: hostTime)
        anchorHostTime = hostTime
        anchorPlayerTime = currentTime
        isPlaying = false
        clock.ingest(playerTime: currentTime, isPlaying: false, hostTime: hostTime)
    }

    /// Rewind the cursor and the wrapped clock to zero. Preserves
    /// `isPlaying` so a Restart while playing continues forward from
    /// `0` without requiring an additional Play tap.
    mutating func restart(hostTime: TimeInterval) {
        guard hasTimeline else { return }
        currentTime = 0
        anchorHostTime = hostTime
        anchorPlayerTime = 0
        clock.reset()
        clock.ingest(playerTime: 0, isPlaying: isPlaying, hostTime: hostTime)
    }

    /// Advance the controller to `hostTime` and fire any events whose
    /// `startTime` is now at or below `currentTime`. Auto-stops at
    /// `duration`. Returns the events that fired this tick, in the
    /// timeline's deterministic sort order.
    @discardableResult
    mutating func tick(hostTime: TimeInterval) -> [SessionReplayEvent] {
        guard hasTimeline else { return [] }
        if isPlaying {
            currentTime = computeAdvanced(hostTime: hostTime)
        }
        clock.ingest(playerTime: currentTime, isPlaying: isPlaying, hostTime: hostTime)
        let fired = clock.tick(hostTime: hostTime)
        if isPlaying && currentTime >= duration {
            currentTime = duration
            anchorHostTime = hostTime
            anchorPlayerTime = duration
            isPlaying = false
            clock.ingest(playerTime: duration, isPlaying: false, hostTime: hostTime)
        }
        return fired
    }

    /// Pure derivation of the current player position for `hostTime`,
    /// clamped to `[0, duration]`. Used both internally and by the
    /// view's `TimelineView` per-frame closure so it can render the
    /// cursor without mutating controller state.
    func currentTime(at hostTime: TimeInterval) -> TimeInterval {
        guard hasTimeline else { return 0 }
        if !isPlaying { return currentTime }
        return computeAdvanced(hostTime: hostTime)
    }

    private func computeAdvanced(hostTime: TimeInterval) -> TimeInterval {
        let elapsed = hostTime - anchorHostTime
        let raw = anchorPlayerTime + elapsed
        if raw <= 0 { return 0 }
        if raw >= duration { return duration }
        return raw
    }
}
