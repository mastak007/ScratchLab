import Foundation

/// A single firing event in a deterministic replay timeline.
///
/// Projected from `CaptureCore.DetectedNotationSnapshot` lanes. The
/// source snapshot remains the canonical record; this type is a
/// reorderable, single-stream view of the same data for replay
/// consumers.
///
/// `sourceIndex` is the event's position within its original lane
/// array on the source snapshot. It is used solely as a deterministic
/// tie-breaker when two events in the same lane share an identical
/// `startTime`.
///
/// `tag` carries the source lane's most discriminating string label
/// (e.g. `eventKind` for audio onsets, `direction` for movements,
/// `control` for faders, `mappedControl` for mixer MIDI). It is
/// optional and informational; replay correctness does not depend on
/// its value.
struct SessionReplayEvent: Codable, Equatable, Sendable {

    /// Lane the event originated from. The raw-value strings are
    /// part of the persisted contract and must not change without a
    /// schemaVersion bump on `SessionReplayTimeline`. `Comparable` is
    /// implemented explicitly via lane priority and is the second
    /// sort key after `startTime` (see `SessionReplayTimeline.build`).
    enum Kind: String, Codable, Sendable, Comparable {
        case audioOnset      = "audio_onset"
        case recordMovement  = "record_movement"
        case fader           = "fader"
        case mixerMidi       = "mixer_midi"

        /// Lane-priority ordinal. Lower = fires first when two events
        /// across lanes share an identical `startTime`. Order is:
        /// audio (master) → movement (next-most-trusted live signal)
        /// → fader → mixer MIDI (auxiliary / derived).
        var laneOrder: Int {
            switch self {
            case .audioOnset:     return 0
            case .recordMovement: return 1
            case .fader:          return 2
            case .mixerMidi:      return 3
            }
        }

        static func < (lhs: Kind, rhs: Kind) -> Bool {
            lhs.laneOrder < rhs.laneOrder
        }
    }

    let startTime: Double
    let endTime: Double?
    let kind: Kind
    let sourceIndex: Int
    let tag: String?
}

/// In-memory deterministic event stream for replaying one captured
/// take. Pre-sorted by the rules documented on `build(from:takeDuration:)`.
///
/// Not written to disk in Slice 3.1 — the `schemaVersion` field
/// reserves the contract for a future additive sibling manifest
/// (`manifests/session_replay.json`) gated on a real consumer. The
/// v4 session export schema string (`scratchlab_session_export_v4`)
/// is unrelated to this timeline and stays byte-identical.
struct SessionReplayTimeline: Codable, Equatable, Sendable {
    static let currentSchemaVersion = "scratchlab_session_replay_v1"

    let schemaVersion: String
    let takeDurationSeconds: Double
    let events: [SessionReplayEvent]

    init(
        schemaVersion: String = SessionReplayTimeline.currentSchemaVersion,
        takeDurationSeconds: Double,
        events: [SessionReplayEvent]
    ) {
        self.schemaVersion = schemaVersion
        self.takeDurationSeconds = takeDurationSeconds
        self.events = events
    }

    /// Builds a deterministic timeline from a `DetectedNotationSnapshot`.
    ///
    /// The four source lanes are concatenated into a single
    /// `SessionReplayEvent` stream and sorted with three keys:
    ///
    /// 1. `startTime` ascending.
    /// 2. `Kind` ascending by `laneOrder` (audioOnset < recordMovement
    ///    < fader < mixerMidi).
    /// 3. `sourceIndex` ascending (lane-array position).
    ///
    /// Per-lane projection rules:
    ///
    /// - `audioEvents`: kind `.audioOnset`, tag = `eventKind`.
    /// - `recordMovementEvents`: kind `.recordMovement`, tag =
    ///   `direction`.
    /// - `faderEvents`: kind `.fader`, tag = `control`. **Consumed
    ///   from `snapshot.faderEvents` as-stored — never re-derived
    ///   from `mixerMidiEvents`. ** Re-deriving would break
    ///   determinism if `CaptureCore.deriveDetectedNotationFaderEvents`
    ///   evolves.
    /// - `mixerMidiEvents`: kind `.mixerMidi`, tag =
    ///   `mappedControl ?? "midi_cc_<controller>"`. `startTime` is
    ///   sourced from `takeRelativeTime` (the take-relative origin),
    ///   **not** `timestamp` (wall-clock-style host time). `endTime`
    ///   is `nil` — mixer MIDI events are point-in-time samples.
    static func build(
        from snapshot: CaptureCore.DetectedNotationSnapshot,
        takeDuration: Double
    ) -> SessionReplayTimeline {
        var events: [SessionReplayEvent] = []
        events.reserveCapacity(
            snapshot.audioEvents.count
            + snapshot.recordMovementEvents.count
            + snapshot.faderEvents.count
            + snapshot.mixerMidiEvents.count
        )

        for (index, event) in snapshot.audioEvents.enumerated() {
            events.append(SessionReplayEvent(
                startTime: event.startTime,
                endTime: event.endTime,
                kind: .audioOnset,
                sourceIndex: index,
                tag: event.eventKind
            ))
        }
        for (index, event) in snapshot.recordMovementEvents.enumerated() {
            events.append(SessionReplayEvent(
                startTime: event.startTime,
                endTime: event.endTime,
                kind: .recordMovement,
                sourceIndex: index,
                tag: event.direction
            ))
        }
        for (index, event) in snapshot.faderEvents.enumerated() {
            events.append(SessionReplayEvent(
                startTime: event.startTime,
                endTime: event.endTime,
                kind: .fader,
                sourceIndex: index,
                tag: event.control
            ))
        }
        for (index, event) in snapshot.mixerMidiEvents.enumerated() {
            events.append(SessionReplayEvent(
                startTime: event.takeRelativeTime,
                endTime: nil,
                kind: .mixerMidi,
                sourceIndex: index,
                tag: event.mappedControl ?? "midi_cc_\(event.controller)"
            ))
        }

        events.sort { lhs, rhs in
            if lhs.startTime != rhs.startTime {
                return lhs.startTime < rhs.startTime
            }
            if lhs.kind != rhs.kind {
                return lhs.kind < rhs.kind
            }
            return lhs.sourceIndex < rhs.sourceIndex
        }

        return SessionReplayTimeline(
            takeDurationSeconds: takeDuration,
            events: events
        )
    }
}
