import Foundation

// MARK: - PlatterPositionSample

/// A single timestamped platter-position sample.
///
/// `position` carries **unbounded signed platter-axis displacement
/// units**, produced by integrating normalized tracker deltas. Not
/// calibrated to revolutions yet; calibration is deferred to a future
/// slice. Forward motion is positive, backward is negative. The
/// renderer normalises into the lane's cross-axis 0…1 range at draw
/// time using the timeline-wide min/max envelope
/// (`PlatterPositionTimeline.positionRange`), so the absolute unit
/// does not affect visual output.
///
/// `confidence` is `1.0` when the sample is sourced directly from the
/// hand tracker, and `< 1` when interpolated, hand-authored, or
/// extrapolated. Phase 1 does not interpret the value beyond storing it;
/// future renderer work may use it to draw uncertainty rails.
struct PlatterPositionSample: Equatable, Sendable, Codable {
    let time: TimeInterval
    let position: Double
    let confidence: Double
}

// MARK: - PlatterPositionTimeline

/// A continuous raw platter-position timeline for one take or one demo
/// reel. Samples are sorted by `time`, monotonically non-decreasing, and
/// fall within `[startTime, endTime]`. The timeline carries its own
/// metadata so a renderer can decide whether to use it without
/// consulting the surrounding notation.
///
/// **Not persisted in Phase 1.** The `Codable` conformance exists so
/// future bundled-demo JSONs and in-memory fixtures round-trip cleanly;
/// the session export schema `scratchlab_session_export_v4` is
/// unchanged and does not embed this type.
struct PlatterPositionTimeline: Equatable, Sendable, Codable {
    /// Where the timeline came from. Used by the renderer's
    /// substrate-selection logic and by uncertainty rendering.
    enum Source: String, Equatable, Sendable, Codable {
        /// Produced by the live capture pipeline from the hand tracker.
        case liveCapture
        /// Authored alongside a bundled demo reel.
        case bundledDemo
        /// Hand-authored for a fixture or lesson asset.
        case coachAuthored
    }

    let source: Source
    let startTime: TimeInterval
    let endTime: TimeInterval
    let samples: [PlatterPositionSample]

    // MARK: Failing memberwise initialiser

    /// Builds a timeline if `samples` satisfy the invariants:
    ///
    /// - `endTime >= startTime`
    /// - `samples` are sorted by `time`, non-decreasing
    /// - if `samples` is non-empty: `samples.first!.time >= startTime`
    ///   and `samples.last!.time <= endTime`
    ///
    /// Returns `nil` when any invariant fails. Empty samples are
    /// permitted — interpolation simply returns `nil`.
    init?(source: Source,
          startTime: TimeInterval,
          endTime: TimeInterval,
          samples: [PlatterPositionSample]) {
        guard PlatterPositionTimeline.invariantsHold(
            startTime: startTime, endTime: endTime, samples: samples
        ) else {
            return nil
        }
        self.source = source
        self.startTime = startTime
        self.endTime = endTime
        self.samples = samples
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case source
        case startTime
        case endTime
        case samples
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let source = try container.decode(Source.self, forKey: .source)
        let startTime = try container.decode(TimeInterval.self, forKey: .startTime)
        let endTime = try container.decode(TimeInterval.self, forKey: .endTime)
        let samples = try container.decode([PlatterPositionSample].self, forKey: .samples)
        guard PlatterPositionTimeline.invariantsHold(
            startTime: startTime, endTime: endTime, samples: samples
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .samples,
                in: container,
                debugDescription: "PlatterPositionTimeline invariants failed: endTime must be ≥ startTime, samples must be sorted by time and fall within [startTime, endTime]."
            )
        }
        self.source = source
        self.startTime = startTime
        self.endTime = endTime
        self.samples = samples
    }

    // MARK: Queries

    /// Linearly-interpolated position at `time`.
    ///
    /// Returns `nil` for empty `samples` or for any `time` outside
    /// `[startTime, endTime]`. When `time` falls before the first
    /// sample or after the last sample but still inside the timeline
    /// span, the nearest sample's position is returned (clamped).
    func position(at time: TimeInterval) -> Double? {
        guard !samples.isEmpty else { return nil }
        guard time >= startTime, time <= endTime else { return nil }
        // Clamp to sample range when the query falls in the
        // pre-first / post-last lead-in / lead-out.
        if time <= samples.first!.time { return samples.first!.position }
        if time >= samples.last!.time { return samples.last!.position }
        // Locate the bracketing pair via a linear walk. Sample arrays
        // here are typically a few thousand entries; binary search is
        // not worth the complexity in Phase 1.
        for i in 1..<samples.count {
            let lhs = samples[i - 1]
            let rhs = samples[i]
            if time >= lhs.time && time <= rhs.time {
                let span = rhs.time - lhs.time
                if span <= 0 { return lhs.position }
                let frac = (time - lhs.time) / span
                return lhs.position + (rhs.position - lhs.position) * frac
            }
        }
        return samples.last!.position
    }

    /// Min / max position across the sample span. Nil when samples are
    /// empty. The renderer uses this to map unbounded platter-axis
    /// displacement units onto the lane's cross-axis 0…1.
    var positionRange: ClosedRange<Double>? {
        guard let first = samples.first else { return nil }
        var lo = first.position
        var hi = first.position
        for sample in samples.dropFirst() {
            if sample.position < lo { lo = sample.position }
            if sample.position > hi { hi = sample.position }
        }
        return lo...hi
    }

    // MARK: Invariant check

    private static func invariantsHold(
        startTime: TimeInterval,
        endTime: TimeInterval,
        samples: [PlatterPositionSample]
    ) -> Bool {
        guard endTime >= startTime else { return false }
        guard !samples.isEmpty else { return true }
        guard samples.first!.time >= startTime else { return false }
        guard samples.last!.time <= endTime else { return false }
        for i in 1..<samples.count {
            if samples[i].time < samples[i - 1].time { return false }
        }
        return true
    }
}

// MARK: - CrossfaderStateTimeline

/// A renderer-side materialisation of crossfader open/closed state over
/// time, derived from a `CaptureCore.DetectedNotationFaderEvent` stream.
///
/// **Not persisted.** This is a hybrid view-type: the underlying events
/// already live in `DetectedNotationSnapshot.faderEvents` and survive
/// to the v4 session export. This timeline is computed on demand by
/// the lane renderer and never written to disk.
///
/// State semantics:
/// - `.open` / `.closed` segments are static.
/// - `.transitioning(progress: target)` segments encode a ramp from
///   `progress = 0` at `startTime` to `progress = target` at `endTime`.
///   `state(at:)` lerps the progress for query times inside the
///   segment. Phase 1 assumes start progress = 0 for every transition
///   (i.e. event `fromValue` is treated as 0); a future enhancement
///   will carry an explicit from-value when the renderer fork lands.
struct CrossfaderStateTimeline: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case open
        case closed
        case transitioning(progress: Double)   // 0 = closed, 1 = open
    }

    struct Segment: Equatable, Sendable {
        let startTime: TimeInterval
        let endTime: TimeInterval
        let state: State
    }

    let segments: [Segment]
    let coverage: ClosedRange<TimeInterval>?

    /// Build from a fader-event stream (typically
    /// `DetectedNotationSnapshot.faderEvents`). Each event becomes one
    /// segment spanning its `[startTime, endTime]`. Event `.eventKind`
    /// maps to `State`:
    /// - `.open` → `.open`
    /// - `.closed` → `.closed`
    /// - `.cut`, `.pulse`, `.transformPulse`, `.flareClick` →
    ///   `.transitioning(progress: event.toValue)`
    /// - `.unknown` → `.closed` (safe default — closed is silent)
    init(from events: [CaptureCore.DetectedNotationFaderEvent],
         coverage: ClosedRange<TimeInterval>?) {
        self.segments = events.map { event in
            Segment(
                startTime: event.startTime,
                endTime: event.endTime,
                state: CrossfaderStateTimeline.state(for: event)
            )
        }
        self.coverage = coverage
    }

    /// State at `time`. Returns `.closed` outside `coverage` (safe
    /// default — a closed crossfader is silent). For a transitioning
    /// segment, interpolates `progress` linearly from `0` at
    /// `segment.startTime` to the stored target at `segment.endTime`.
    func state(at time: TimeInterval) -> State {
        if let coverage, !coverage.contains(time) {
            return .closed
        }
        guard let segment = segments.first(where: { $0.contains(time) }) else {
            return .closed
        }
        switch segment.state {
        case .open, .closed:
            return segment.state
        case .transitioning(let target):
            let span = segment.endTime - segment.startTime
            guard span > 0 else { return .transitioning(progress: target) }
            let frac = (time - segment.startTime) / span
            return .transitioning(progress: frac * target)
        }
    }

    // MARK: Internal mapping

    private static func state(
        for event: CaptureCore.DetectedNotationFaderEvent
    ) -> State {
        switch event.eventKind {
        case .open:
            return .open
        case .closed:
            return .closed
        case .cut, .pulse, .transformPulse, .flareClick:
            return .transitioning(progress: event.toValue)
        case .unknown:
            return .closed
        }
    }
}

extension CrossfaderStateTimeline.Segment {
    fileprivate func contains(_ time: TimeInterval) -> Bool {
        time >= startTime && time <= endTime
    }
}
