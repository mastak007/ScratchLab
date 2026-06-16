#if DEBUG

import Foundation

// MARK: - TimecodePrototypeRecordingState

/// Recording state for the Batch 5 prototype take recorder.
public enum TimecodePrototypeRecordingState: String, Equatable, Sendable {
    case idle
    case recording
    case stopped

    public var label: String {
        switch self {
        case .idle:      return "Idle"
        case .recording: return "Recording"
        case .stopped:   return "Stopped"
        }
    }
}

// MARK: - TimecodePrototypeRecorder

/// DEBUG-only in-memory recorder for trusted `timecode_live` adapted output.
///
/// Collects `PlatterPositionTimeline` samples produced by
/// `TimecodeControlPipeline.flushDecode()` in `.controlPrototype` mode,
/// behind an explicit `startRecording()` / `stopRecording()` gate.
///
/// ## Guarantees
///
/// - Defaults idle / empty.
/// - Only accumulates when `state == .recording`.
/// - Only accepts timelines whose `source == .timecodeLive`.
/// - Maintains position continuity across successive flushes by offsetting
///   each incoming timeline's positions by the last recorded sample's position.
/// - Enforces monotonically non-decreasing sample time; backwards-time flushes
///   are dropped and counted.
/// - Does NOT persist to disk.
/// - Does NOT call notation, HandDirectionTracker, Review, or any production
///   recording path.
/// - Does NOT affect replay trust or RANE source labels.
///
/// **Batch 5:** Prototype take-path only. Not wired to production take
/// recording, notation classification, or export schema.
public final class TimecodePrototypeRecorder: ObservableObject, @unchecked Sendable {

    // MARK: - Published state

    @Published public private(set) var state: TimecodePrototypeRecordingState = .idle

    /// Number of motion samples accepted into the current (or last) take.
    @Published public private(set) var acceptedSampleCount: Int = 0

    /// Number of flush windows dropped (bad signal, wrong source, time fault).
    @Published public private(set) var droppedSampleCount: Int = 0

    /// Human-readable reason for the most recent drop. Empty when no drop
    /// has occurred.
    @Published public private(set) var lastDropReason: String = ""

    /// The recorded `PlatterPositionTimeline`, populated on `stopRecording()`.
    /// `nil` when no samples were accepted or before stop.
    @Published public private(set) var recordedTimeline: PlatterPositionTimeline? = nil

    // MARK: - Metadata

    /// Source label for the prototype pipeline output.
    public let sourceLabel: String = "timecode_live"

    /// Duration of the recorded take in seconds. `0` when no timeline.
    public var recordedDuration: TimeInterval {
        guard let t = recordedTimeline else { return 0 }
        return t.endTime - t.startTime
    }

    // MARK: - Private state

    private var buffer: [PlatterPositionSample] = []
    private var recordingStartTime: TimeInterval?
    private var recordingEndTime: TimeInterval = 0

    // MARK: - Init

    public init() {}

    // MARK: - Lifecycle

    /// Begin a new take. Resets all accumulated state. Safe to call after a
    /// previous stop or clear, or to restart a recording in progress.
    public func startRecording() {
        buffer.removeAll(keepingCapacity: true)
        recordingStartTime = nil
        recordingEndTime = 0
        acceptedSampleCount = 0
        droppedSampleCount = 0
        lastDropReason = ""
        recordedTimeline = nil
        state = .recording
    }

    /// End the current take and build the recorded timeline from accumulated
    /// samples. Has no effect if not currently recording.
    public func stopRecording() {
        guard state == .recording else { return }
        buildTimeline()
        state = .stopped
    }

    /// Reset to idle, discarding all accumulated samples and the recorded timeline.
    public func clearTake() {
        buffer.removeAll(keepingCapacity: true)
        recordingStartTime = nil
        recordingEndTime = 0
        acceptedSampleCount = 0
        droppedSampleCount = 0
        lastDropReason = ""
        recordedTimeline = nil
        state = .idle
    }

    // MARK: - Pipeline bridge (internal — called only by TimecodeControlPipeline)

    /// Accept a trusted `.timecodeLive` timeline produced by `flushDecode()`.
    ///
    /// Silently ignored when `state != .recording`. Timelines with wrong
    /// source are dropped and counted. Backwards-time flushes are dropped
    /// and counted. Positions are offset by the last recorded position to
    /// maintain global continuity across successive flush windows.
    func accept(timeline: PlatterPositionTimeline) {
        guard state == .recording else { return }

        guard timeline.source == .timecodeLive else {
            droppedSampleCount += max(1, timeline.samples.count)
            lastDropReason = "wrong_source"
            return
        }

        guard !timeline.samples.isEmpty else { return }

        // Enforce monotonically non-decreasing time across flush boundaries.
        if let lastRecordedTime = buffer.last?.time,
           let firstNewTime = timeline.samples.first?.time,
           firstNewTime < lastRecordedTime {
            droppedSampleCount += timeline.samples.count
            lastDropReason = "non_monotonic_time"
            return
        }

        // Offset positions so the recorded trace is globally continuous.
        let positionOffset = buffer.last?.position ?? 0

        for sample in timeline.samples {
            if recordingStartTime == nil { recordingStartTime = sample.time }
            let adjusted = PlatterPositionSample(
                time: sample.time,
                position: sample.position + positionOffset,
                confidence: sample.confidence
            )
            buffer.append(adjusted)
            if sample.time > recordingEndTime { recordingEndTime = sample.time }
        }
        acceptedSampleCount += timeline.samples.count
    }

    /// Record a signal dropout or decode failure from the pipeline.
    /// Increments `droppedSampleCount` and sets `lastDropReason`.
    /// Silently ignored when `state != .recording`.
    func recordDrop(reason: String, count: Int = 1) {
        guard state == .recording else { return }
        droppedSampleCount += max(1, count)
        if !reason.isEmpty { lastDropReason = reason }
    }

    // MARK: - Private

    private func buildTimeline() {
        guard !buffer.isEmpty, let start = recordingStartTime else {
            recordedTimeline = nil
            return
        }
        let end = max(recordingEndTime, start)
        recordedTimeline = PlatterPositionTimeline(
            source: .timecodeLive,
            startTime: start,
            endTime: end,
            samples: buffer
        )
    }
}

#endif // DEBUG
