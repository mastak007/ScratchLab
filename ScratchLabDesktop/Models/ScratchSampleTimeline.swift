#if os(macOS)
import Foundation

// Scratch Playback Lab: live sample-position timeline (capture model).
//
// Scope guardrails (deliberate):
// - Pure value types + Foundation only. No Core MIDI, no AVFoundation, no device I/O,
//   and NOTHING from notation / replay / beat engine / capture / scoring / ML / export /
//   app navigation. The lab model feeds it parsed scrub samples; rendering lives
//   elsewhere (the notation renderer wiring is a later slice).
//
// Why this exists (the conceptual fix):
//   The old notation could draw a full 100% stroke even when the scratch only travelled
//   partway through the sample. The truth is "how far did the playhead actually move
//   through the sample, over time" — so capture the real, normalised sample position at
//   each platter step and let height/length be DERIVED from that travel, never inferred
//   from "a note happened". A partial scratch spans a partial slice of 0...1; a reversal
//   at mid-sample turns the travel around at ~0.5; a closed crossfader silences a segment
//   without erasing its timing or position.
//
// Timestamps are host-supplied seconds (TimeInterval). Append enforces two invariants so
// downstream geometry can trust the data without re-validating:
//   - time is non-decreasing (a late/out-of-order sample is pinned to the previous time),
//   - position is clamped to 0...1.

/// One captured point of live scratch travel: where the playhead is in the sample, when,
/// and which way / how fast it is moving. Pure value type, fully deterministic. Codable
/// so a captured timeline can be exported to JSON and reloaded to regenerate notation.
struct ScratchSampleTimelineEvent: Equatable, Codable {
    /// Travel direction at this sample, derived from the signed scrub velocity.
    enum Direction: Equatable {
        case forward   // velocity > 0: moving toward the end of the sample
        case reverse   // velocity < 0: moving back toward the start
        case idle      // effectively stationary (within the velocity deadband)
    }

    /// Host-derived seconds (monotonic across a capture; set by the appender).
    let timeSeconds: TimeInterval
    /// Normalised sample position, clamped to `0...1` (0 = sample start, 1 = sample end).
    let position: Double
    /// Signed scrub velocity in sample-position units per second (the engine's smoothed
    /// estimate). Sign is the direction of travel; magnitude is how fast.
    let velocity: Double
    /// Normalised crossfader position `0...1`, or nil if no valid crossfader value yet.
    let crossfader: Double?
    /// True when the crossfader is in the hard-cut (closed) zone: the segment is silenced
    /// for sound but its timing and position are still real and kept.
    let muted: Bool
    /// Optional source diagnostic: the signed CC6 step (±1) that produced this sample.
    let cc6Step: Int?

    /// Velocities with magnitude at or below this are treated as stationary (`.idle`),
    /// so float dither around zero doesn't read as motion.
    static let velocityDeadband = 1.0e-9

    /// Travel direction implied by the signed velocity.
    var direction: Direction {
        if velocity > Self.velocityDeadband { return .forward }
        if velocity < -Self.velocityDeadband { return .reverse }
        return .idle
    }
}

/// Pure, ordered capture of live scratch travel through the sample. The host (the lab
/// model) appends one event per platter step; the timeline clamps/orders the data and
/// exposes travel geometry (span, reversals) that notation can be derived from. No file
/// or device I/O lives here.
struct ScratchSampleTimeline: Equatable, Codable {
    /// Hard ceiling on captured events. At ~935 platter events/sec this is a few minutes
    /// of continuous scrub, bounding memory so a forgotten capture can't grow without
    /// limit. Appending stops (and `didReachCapacity` is set) once the cap is reached.
    static let maxEvents = 250_000

    /// Position deltas with magnitude at or below this are treated as no travel, so float
    /// dither doesn't register as a direction reversal.
    static let positionEpsilon = 1.0e-9

    /// Crossfader fraction below which a segment is considered closed/muted. Defaults to
    /// the playback engine's hard-cut width so "muted here" matches "silenced there".
    let muteCrossfaderBelow: Double

    private(set) var events: [ScratchSampleTimelineEvent] = []
    /// Set when an append was dropped because `maxEvents` was already reached.
    private(set) var didReachCapacity = false

    init(muteCrossfaderBelow: Double = ScratchPlatterPlayheadMapper.crossfaderCutWidth) {
        self.muteCrossfaderBelow = muteCrossfaderBelow
    }

    // MARK: - Capture

    /// Appends one captured scrub sample, enforcing the timeline invariants:
    /// - `position` is clamped to `0...1`,
    /// - `timeSeconds` is pinned to be non-decreasing (a late sample inherits the last
    ///   sample's time rather than going backwards),
    /// - `muted` is derived from the crossfader (closed when below `muteCrossfaderBelow`).
    /// A no-op once `maxEvents` is reached. Returns the stored event (nil if dropped).
    @discardableResult
    mutating func append(
        timeSeconds: TimeInterval,
        position: Double,
        velocity: Double,
        crossfader: Double? = nil,
        cc6Step: Int? = nil
    ) -> ScratchSampleTimelineEvent? {
        guard events.count < Self.maxEvents else {
            didReachCapacity = true
            return nil
        }
        let clampedPosition = Swift.min(Swift.max(position, 0), 1)
        let monotonicTime = Swift.max(timeSeconds, events.last?.timeSeconds ?? timeSeconds)
        let muted = crossfader.map { $0 < muteCrossfaderBelow } ?? false
        let event = ScratchSampleTimelineEvent(
            timeSeconds: monotonicTime,
            position: clampedPosition,
            velocity: velocity,
            crossfader: crossfader,
            muted: muted,
            cc6Step: cc6Step
        )
        events.append(event)
        return event
    }

    /// Discards captured events and clears the capacity flag.
    mutating func clear() {
        events.removeAll(keepingCapacity: true)
        didReachCapacity = false
    }

    var isEmpty: Bool { events.isEmpty }
    var count: Int { events.count }

    // MARK: - Travel geometry (what notation is derived from)

    /// Lowest sample position visited, or nil if empty.
    var minPosition: Double? { events.map(\.position).min() }
    /// Highest sample position visited, or nil if empty.
    var maxPosition: Double? { events.map(\.position).max() }

    /// The span of sample actually travelled, `max - min`, in normalised `0...1` units.
    /// This is the truthful "stroke height/length": a scratch that only reaches 0.4
    /// spans 0.4, NOT a full 1.0. Zero for an empty timeline.
    var positionSpan: Double {
        guard let lo = minPosition, let hi = maxPosition else { return 0 }
        return hi - lo
    }

    /// Events at which travel direction reversed — i.e. the sign of position change
    /// flipped between forward and reverse (idle/no-travel samples are skipped, so a
    /// pause mid-stroke is not a reversal). These are the turn points of the stroke; the
    /// `position` of each is where in the sample the platter turned around.
    var reversalEvents: [ScratchSampleTimelineEvent] {
        var result: [ScratchSampleTimelineEvent] = []
        var lastTravelSign = 0
        var previousPosition: Double?
        for event in events {
            defer { previousPosition = event.position }
            guard let previous = previousPosition else { continue }
            let delta = event.position - previous
            guard abs(delta) > Self.positionEpsilon else { continue } // no travel: ignore
            let sign = delta > 0 ? 1 : -1
            if lastTravelSign != 0, sign != lastTravelSign {
                result.append(event)
            }
            lastTravelSign = sign
        }
        return result
    }

    /// True when every captured time is non-decreasing (the monotonic invariant holds).
    var isTimeMonotonic: Bool {
        for index in 1..<Swift.max(events.count, 1) where events[index].timeSeconds < events[index - 1].timeSeconds {
            return false
        }
        return true
    }

    /// True when every captured position is within `0...1` (the clamp invariant holds).
    var isPositionClamped: Bool {
        events.allSatisfy { $0.position >= 0 && $0.position <= 1 }
    }
}

/// Pure summary of a captured timeline, derived entirely from its events. Encodable so it
/// travels inside the exported JSON alongside the raw travel. All figures are read from
/// the timeline's existing (tested) geometry — nothing is invented.
struct ScratchSampleTimelineSummary: Equatable, Codable {
    let eventCount: Int
    /// Seconds from the first to the last captured sample (0 for fewer than two events).
    let durationSeconds: TimeInterval
    /// Lowest / highest normalised sample position visited (nil when empty).
    let minPosition: Double?
    let maxPosition: Double?
    /// Span of sample actually travelled (`max - min`), the truthful stroke height.
    let positionSpan: Double
    /// Number of forward↔reverse turn points in the captured travel.
    let reversalCount: Int
    /// Samples captured while the crossfader was closed (the muted segments).
    let mutedEventCount: Int

    init(timeline: ScratchSampleTimeline) {
        let events = timeline.events
        eventCount = events.count
        if let first = events.first, let last = events.last {
            durationSeconds = Swift.max(0, last.timeSeconds - first.timeSeconds)
        } else {
            durationSeconds = 0
        }
        minPosition = timeline.minPosition
        maxPosition = timeline.maxPosition
        positionSpan = timeline.positionSpan
        reversalCount = timeline.reversalEvents.count
        mutedEventCount = events.filter { $0.muted }.count
    }
}

/// Codable export envelope: a schema-versioned header, a derived summary, and the full
/// captured event list. Encoded as deterministic pretty JSON for offline, diffable
/// exports. The raw per-event travel preserves enough to regenerate notation later —
/// notation strokes are NOT synthesised here.
struct ScratchSampleTimelineExport: Equatable, Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    /// Wall-clock export time (epoch seconds), supplied by the host. Optional so the
    /// envelope stays deterministic in tests.
    let exportedAtEpochSeconds: TimeInterval?
    let summary: ScratchSampleTimelineSummary
    let events: [ScratchSampleTimelineEvent]

    init(timeline: ScratchSampleTimeline, exportedAtEpochSeconds: TimeInterval? = nil) {
        self.schemaVersion = Self.currentSchemaVersion
        self.exportedAtEpochSeconds = exportedAtEpochSeconds
        self.summary = ScratchSampleTimelineSummary(timeline: timeline)
        self.events = timeline.events
    }

    /// Encodes to deterministic pretty-printed JSON (sorted keys) so exports diff cleanly.
    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
#endif
