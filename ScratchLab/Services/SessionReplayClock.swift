import Foundation

/// Deterministic event-firing cursor over a `SessionReplayTimeline`.
///
/// `SessionReplayClock` is a value type that composes the existing
/// `DemoAudioClock` (latency-compensated, anchor-based, monotonic
/// playhead — `ScratchLab/Models/DemoAudioClock.swift`) with a forward-
/// only event cursor. There is no global state, no `Date()` source,
/// no random component. Given an identical `(playerTime, isPlaying,
/// hostTime)` sample stream, two clocks produce byte-identical fired
/// event sequences.
///
/// Firing window is **open-left / closed-right**: an event whose
/// `startTime` equals `currentTime(hostTime:)` fires once, and an
/// event already fired in a previous tick does not fire again. The
/// cursor never rewinds without an explicit `seek(to:)`, so audio-
/// clock re-anchors caused by player-time drift past
/// `DemoAudioClock.resyncThreshold` cannot double-fire events.
///
/// Time is clamped to `[0, timeline.takeDurationSeconds]`: events
/// whose `startTime` exceeds the take's recorded duration never fire,
/// even if `hostTime` continues to advance.
struct SessionReplayClock: Equatable, Sendable {

    let timeline: SessionReplayTimeline
    private(set) var audioClock: DemoAudioClock
    private(set) var cursor: Int

    init(
        timeline: SessionReplayTimeline,
        audioClock: DemoAudioClock = DemoAudioClock()
    ) {
        self.timeline = timeline
        self.audioClock = audioClock
        self.cursor = 0
    }

    /// Latency-compensated replay position for `hostTime`, clamped to
    /// `[0, timeline.takeDurationSeconds]`. The clamp guarantees the
    /// cursor cannot drift past the timeline's recorded duration even
    /// when the underlying audio player overruns.
    func currentTime(hostTime: TimeInterval) -> TimeInterval {
        let raw = audioClock.currentTime(hostTime: hostTime)
        let bounded = min(raw, timeline.takeDurationSeconds)
        return max(0, bounded)
    }

    /// Feeds a raw audio-player sample into the wrapped
    /// `DemoAudioClock`. See `DemoAudioClock.ingest(...)` for the
    /// re-anchor semantics — buffer-plateau no-ops, play/pause hard
    /// anchors, and `resyncThreshold`-gated jumps.
    mutating func ingest(
        playerTime: TimeInterval,
        isPlaying: Bool,
        hostTime: TimeInterval
    ) {
        audioClock.ingest(
            playerTime: playerTime,
            isPlaying: isPlaying,
            hostTime: hostTime
        )
    }

    /// Fires every pending event whose `startTime` is at or below the
    /// current replay time. The cursor advances past each fired event
    /// and never rewinds without `seek(to:)`, so:
    ///
    /// - A second `tick(hostTime:)` at the same `hostTime` returns
    ///   `[]` (idempotence on repeated ticks).
    /// - An audio-clock re-anchor that pulls `currentTime` backward
    ///   cannot replay events the cursor has already consumed.
    ///
    /// Returned events preserve the timeline's deterministic sort
    /// order (`startTime` → lane priority → source index).
    mutating func tick(hostTime: TimeInterval) -> [SessionReplayEvent] {
        let now = currentTime(hostTime: hostTime)
        var fired: [SessionReplayEvent] = []
        while cursor < timeline.events.count
            && timeline.events[cursor].startTime <= now {
            fired.append(timeline.events[cursor])
            cursor += 1
        }
        return fired
    }

    /// Sets the cursor to the first event whose `startTime >= time`,
    /// or one past the end if no such event exists. Subsequent
    /// `tick(hostTime:)` calls fire that event (and later ones) as
    /// the replay clock crosses their start times.
    ///
    /// Does **not** modify the wrapped `audioClock`. Pair with a
    /// player-side seek if the audio source should also rewind —
    /// the next `ingest(...)` will re-anchor the audio clock against
    /// the new player position.
    mutating func seek(to time: TimeInterval) {
        let clamped = max(0, min(time, timeline.takeDurationSeconds))
        if let nextIndex = timeline.events.firstIndex(where: { $0.startTime >= clamped }) {
            cursor = nextIndex
        } else {
            cursor = timeline.events.count
        }
    }

    /// Returns the clock to its initial state: cursor at 0, audio
    /// clock anchor cleared. The next `ingest(...)` hard-anchors.
    mutating func reset() {
        cursor = 0
        audioClock.reset()
    }
}
