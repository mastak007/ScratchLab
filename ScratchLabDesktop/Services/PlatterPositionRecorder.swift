import Foundation
import CoreGraphics
import QuartzCore

// Phase 3 — Live platter-position producer.
//
// A sibling consumer of the same `(rawPoint, time)` samples that
// `HandDirectionTracker.recordObservation(rawPoint:at:)` receives during a
// recording. The tracker keeps doing what it does (4-sample rolling history,
// signed-velocity hysteresis, Direction emission) — this recorder runs
// alongside it and accumulates an unbounded `[PlatterPositionSample]` buffer
// drained at end-of-take into a `PlatterPositionTimeline`.
//
// Karl's Phase 3 decisions (2026-05-24):
//   • Tracker-native sample rate — whatever `activeHandPoseInterval` delivers
//     (~30 Hz active, ~4 Hz idle). No resampling, no clock drift.
//   • Unbounded buffer with end-of-take drain. Memory cost at 30 Hz ≈
//     720 B/s ≈ 2.6 MB/hour. Negligible for typical takes.
//   • `position` is integrated normalised image-space x-deltas — "unbounded
//     signed platter-axis displacement units" per the Phase-1 docstring on
//     `PlatterPositionSample`. NOT calibrated to revolutions yet.
//
// Constraints:
//   • Does NOT modify `HandDirectionTracker` in any way.
//   • Does NOT mutate `CaptureCore.DetectedNotationSnapshot` or any of its
//     Codable members.
//   • Does NOT persist anything. The drained timeline is in-memory only;
//     the v4 session export schema stays byte-stable.
//   • The recorder is NOT wired into the live capture pipeline yet —
//     `MacCaptureEngine` will be the future call site. Phase 3 ships the
//     recorder + its tests in isolation.

/// Accumulates a raw platter-position timeline from upstream hand-tracker
/// samples during a recording session.
///
/// Usage shape (mirrors what `MacCaptureEngine` will eventually do):
///
/// ```swift
/// let recorder = PlatterPositionRecorder()
/// recorder.startRecording(at: 0)
/// // …for each tracker frame…
/// recorder.observe(point: rawPoint, at: takeRelativeTime)
/// // …at end of take…
/// let timeline = recorder.finishRecording(at: takeEndTime)
/// // Hand `timeline` to the in-memory diagnostics holder. Do NOT write
/// // it into `DetectedNotationSnapshot` — schema stays unchanged.
/// ```
///
/// This is a reference type so a single recorder instance can be held by
/// the capture engine and observed by tests. State is local to the
/// instance; concurrent observers should serialise calls externally
/// (Phase 3 ships single-threaded usage only).
final class PlatterPositionRecorder {

    /// The source label stamped onto the drained timeline. Defaults to
    /// `.liveCapture`; tests can override to `.coachAuthored` or
    /// `.bundledDemo` when injecting synthetic samples for verification.
    let source: PlatterPositionTimeline.Source

    init(source: PlatterPositionTimeline.Source = .liveCapture) {
        self.source = source
    }

    // MARK: - State

    /// Whether a recording is currently in progress.
    private(set) var isRecording: Bool = false

    /// Number of samples observed during the current (or most-recently-
    /// drained) recording. Useful for tests to assert state was reset.
    var sampleCount: Int { buffer.count }

    /// Take-relative start time of the current recording.
    private var startTime: TimeInterval = 0

    /// Take-relative end time. Updated on each `observe(...)` call so the
    /// drained timeline covers the actual sample span even when
    /// `finishRecording(at:)` is called with a smaller value.
    private var endTime: TimeInterval = 0

    /// The accumulated samples. Unbounded — Karl's Phase 3 decision.
    private var buffer: [PlatterPositionSample] = []

    /// Running integration accumulator. Starts at zero at `startRecording`
    /// and tracks the signed sum of `point.x` deltas across the take.
    private var runningPosition: Double = 0

    /// Last observed raw point. `nil` between `startRecording` and the
    /// first `observe` call; reset on `finishRecording`.
    private var lastPoint: CGPoint?

    // MARK: - Lifecycle

    /// Begin a fresh recording. Resets all state; safe to call after a
    /// previous `finishRecording` or to abandon an in-progress recording
    /// and start over.
    ///
    /// `at` is the take-relative start time in seconds. The first
    /// `observe(...)` sample is appended with `position = 0`; subsequent
    /// samples carry the signed integrated delta.
    func startRecording(at startTime: TimeInterval) {
        self.isRecording = true
        self.startTime = startTime
        self.endTime = startTime
        self.runningPosition = 0
        self.lastPoint = nil
        self.buffer.removeAll(keepingCapacity: true)
    }

    /// Append one sample from the upstream tracker.
    ///
    /// `point` is the normalised image-space coordinate as delivered to
    /// `HandDirectionTracker.recordObservation(rawPoint:at:)` — `x ∈ [0,1]`
    /// with rightward motion increasing. `time` is take-relative seconds
    /// (matching the tracker's `CFTimeInterval` argument). The recorder
    /// integrates `Δx = point.x - lastPoint.x` into `runningPosition`
    /// and appends a `PlatterPositionSample` with `confidence = 1.0`.
    ///
    /// Calls outside an active recording are silently ignored — the
    /// expected wiring is "capture-engine starts recording before
    /// streaming samples", so a stray pre-start sample is a wiring bug,
    /// not a data condition the recorder should fail on.
    func observe(point: CGPoint, at time: TimeInterval) {
        guard isRecording else { return }
        if let previous = lastPoint {
            runningPosition += Double(point.x - previous.x)
        }
        // Clamp the sample time into `[startTime, +∞)` so the Phase 1
        // timeline invariant (`samples.first.time >= startTime`) always
        // holds even when a tracker frame arrives slightly before the
        // recorder's nominal start.
        let clampedTime = max(time, startTime)
        buffer.append(PlatterPositionSample(
            time: clampedTime,
            position: runningPosition,
            confidence: 1.0
        ))
        if clampedTime > endTime { endTime = clampedTime }
        lastPoint = point
    }

    /// End the current recording and return the drained timeline.
    /// Returns `nil` when no samples were observed.
    ///
    /// `at` is the take-relative end time the caller wishes to assert.
    /// If the last observed sample lands after `at`, the timeline's
    /// `endTime` is widened to the sample time so the Phase 1 invariant
    /// (`samples.last.time <= endTime`) stays satisfied.
    ///
    /// State is fully reset after the drain — the same recorder can be
    /// reused for a subsequent take.
    func finishRecording(at endTime: TimeInterval) -> PlatterPositionTimeline? {
        let wasRecording = isRecording
        self.isRecording = false
        defer {
            buffer.removeAll(keepingCapacity: true)
            runningPosition = 0
            lastPoint = nil
            startTime = 0
            self.endTime = 0
        }
        guard wasRecording, !buffer.isEmpty else { return nil }
        let resolvedEnd = max(endTime, self.endTime)
        return PlatterPositionTimeline(
            source: source,
            startTime: startTime,
            endTime: resolvedEnd,
            samples: buffer
        )
    }
}
