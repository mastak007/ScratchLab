import Foundation

// A smoothing, latency-compensated clock for the practice Demo-mode notation
// playhead.
//
// The Demo-mode playhead must track what the listener actually HEARS, not the
// raw `AVAudioPlayer.currentTime` sampled at the view's render tick. Reading
// `currentTime` directly has three problems:
//
//   1. It is sampled only at the render cadence, so the playhead steps coarsely.
//   2. It advances in audio buffer-sized plateaus, so successive reads jitter.
//   3. It is the player's *render* position, which leads audible sound by the
//      audio output latency.
//
// `DemoAudioClock` fixes all three. It anchors a raw `(playerTime, hostTime)`
// sample, then interpolates forward against the monotonic host clock so the
// output is continuous at any query rate (1). It re-anchors only when a fresh
// raw value jumps away from the interpolated estimate — a seek, a replay, or a
// loop wrap — so ordinary buffer-plateau jitter never freezes or stutters the
// clock (2). Finally it subtracts the output latency so a notation event
// reaches the action line exactly when its sound is heard (3).
//
// The type is pure: every method is a deterministic function of its inputs —
// no `Date()`, no `AVFoundation` — so it is trivially unit-testable. The caller
// supplies both the raw player sample and the host time.
//
// Scope: Demo-mode timing only. It drives no capture, export, scoring, or ML,
// and is isolated from the looping clock used by the scored-practice preview
// modes.

struct DemoAudioClock: Equatable, Sendable {

    /// Output latency (seconds) between the player's reported position and the
    /// moment its audio is audible. Subtracted from every reported time so the
    /// notation playhead aligns with what the listener hears. Typically sourced
    /// from `AVAudioSession.outputLatency`; `0` disables compensation.
    var outputLatency: TimeInterval {
        didSet { outputLatency = max(0, outputLatency) }
    }

    /// How far a fresh raw player time may diverge from the interpolated
    /// estimate before the clock re-anchors. Set above ordinary buffer-plateau
    /// jitter plus a render interval of extrapolation, and below a real seek or
    /// loop wrap.
    var resyncThreshold: TimeInterval

    private var anchorHostTime: TimeInterval = 0
    private var anchorPlayerTime: TimeInterval = 0
    private var lastRawPlayerTime: TimeInterval = 0
    private var hasAnchor = false
    private var isAdvancing = false

    init(outputLatency: TimeInterval = 0, resyncThreshold: TimeInterval = 0.12) {
        self.outputLatency = max(0, outputLatency)
        self.resyncThreshold = max(0, resyncThreshold)
    }

    /// Whether the clock has received at least one sample.
    var hasSample: Bool { hasAnchor }

    /// Feeds a raw sample from the audio player. Re-anchors on the first
    /// sample, on a play/pause transition, and whenever a *fresh* raw value has
    /// drifted past `resyncThreshold` from the interpolated estimate (a seek, a
    /// replay, or a loop wrap). A repeated raw value — an audio buffer plateau —
    /// does not re-anchor, so the clock keeps interpolating smoothly.
    mutating func ingest(
        playerTime rawPlayerTime: TimeInterval,
        isPlaying: Bool,
        hostTime: TimeInterval
    ) {
        let playerTime = max(0, rawPlayerTime)
        let stateChanged = isPlaying != isAdvancing
        let rawAdvanced = playerTime != lastRawPlayerTime
        lastRawPlayerTime = playerTime

        defer { isAdvancing = isPlaying }

        // Hard anchor: the first sample, or a play/pause transition.
        guard hasAnchor, !stateChanged else {
            anchorHostTime = hostTime
            anchorPlayerTime = playerTime
            hasAnchor = true
            return
        }

        // While advancing, re-anchor only when a fresh raw value has drifted
        // past the threshold — a seek, a replay, or a loop wrap. A repeated
        // value (a buffer plateau) is ignored so interpolation stays smooth.
        guard isPlaying, rawAdvanced else { return }
        let estimate = anchorPlayerTime + (hostTime - anchorHostTime)
        if abs(playerTime - estimate) > resyncThreshold {
            anchorHostTime = hostTime
            anchorPlayerTime = playerTime
        }
    }

    /// The smoothed, latency-compensated playback time for `hostTime`.
    /// Interpolates forward from the anchor while advancing; holds the anchor
    /// while paused or stopped. Never negative.
    func currentTime(hostTime: TimeInterval) -> TimeInterval {
        guard hasAnchor else { return 0 }
        let interpolated = isAdvancing
            ? anchorPlayerTime + (hostTime - anchorHostTime)
            : anchorPlayerTime
        return max(0, interpolated - outputLatency)
    }

    /// Drops all state. The next `ingest` hard-anchors.
    mutating func reset() {
        anchorHostTime = 0
        anchorPlayerTime = 0
        lastRawPlayerTime = 0
        hasAnchor = false
        isAdvancing = false
    }
}
