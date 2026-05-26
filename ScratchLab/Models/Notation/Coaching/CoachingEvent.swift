import Foundation

// MARK: - CoachingEvent

/// A sidecar binding between a `CoachingEventKind` / `severity` /
/// optional human-readable `message` and a time on the take.
///
/// **Manual metadata only.** A coaching event says nothing more than
/// "the caller has declared that this kind of coaching event applies
/// at this time." It performs **no inference, no thresholding, no
/// scoring**, and consults no primitives, timing grid, family
/// annotations, or classifier output. Future inference layers may
/// construct events through the same surface, but that work is
/// explicitly out of scope here.
///
/// **Invariants enforced at construction and decode time:**
///
/// - `time` is finite (not NaN, not infinite).
/// - `time` is greater than or equal to zero.
///
/// `message` may be `nil` or empty; no trimming or canonicalisation
/// is performed — what the caller stores is what comes back.
struct CoachingEvent: Equatable, Sendable, Codable {
    let time: TimeInterval
    let kind: CoachingEventKind
    let severity: CoachingEventSeverity
    let message: String?

    init?(
        time: TimeInterval,
        kind: CoachingEventKind,
        severity: CoachingEventSeverity,
        message: String?
    ) {
        guard CoachingEvent.isValidTime(time) else { return nil }
        self.time = time
        self.kind = kind
        self.severity = severity
        self.message = message
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case time, kind, severity, message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let time = try container.decode(TimeInterval.self, forKey: .time)
        guard CoachingEvent.isValidTime(time) else {
            throw DecodingError.dataCorruptedError(
                forKey: .time,
                in: container,
                debugDescription: "time must be finite and ≥ 0, got \(time)"
            )
        }
        self.time = time
        self.kind = try container.decode(CoachingEventKind.self, forKey: .kind)
        self.severity = try container.decode(CoachingEventSeverity.self, forKey: .severity)
        self.message = try container.decodeIfPresent(String.self, forKey: .message)
    }

    // MARK: Invariant check

    private static func isValidTime(_ time: TimeInterval) -> Bool {
        time.isFinite && time >= 0
    }
}

// MARK: - CoachingEventSet

/// A validated, ordered collection of `CoachingEvent` sidecars.
/// Represents the manual coaching-event surface for a captured take
/// or fixture: zero or more events on a shared timeline.
///
/// **Invariants enforced at construction and decode time:**
///
/// - Events are sorted by `time` ascending (non-strict).
/// - Duplicate event times are allowed — two events may share a `time`.
/// - The empty set is valid.
/// - Duplicate `CoachingEventKind`s and `CoachingEventSeverity`s are
///   allowed across the set.
///
/// **Manual metadata only.** No classifier or detector produces
/// these events. The set carries no reference back to primitives,
/// timing grid, family annotations, or capture state.
struct CoachingEventSet: Equatable, Sendable, Codable {
    let events: [CoachingEvent]

    init?(events: [CoachingEvent]) {
        guard CoachingEventSet.invariantsHold(events) else { return nil }
        self.events = events
    }

    /// All events whose `kind` matches the given kind, in stored order.
    func events(of kind: CoachingEventKind) -> [CoachingEvent] {
        events.filter { $0.kind == kind }
    }

    /// All events whose `time` is greater than or equal to the given
    /// time, in stored order. Equality is included — an event at
    /// exactly `time` is returned.
    func events(atOrAfter time: TimeInterval) -> [CoachingEvent] {
        events.filter { $0.time >= time }
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case events
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let events = try container.decode([CoachingEvent].self, forKey: .events)
        guard CoachingEventSet.invariantsHold(events) else {
            throw DecodingError.dataCorruptedError(
                forKey: .events,
                in: container,
                debugDescription: "events must be sorted ascending by time; duplicate times are allowed"
            )
        }
        self.events = events
    }

    // MARK: Invariant check

    private static func invariantsHold(_ events: [CoachingEvent]) -> Bool {
        guard events.count > 1 else { return true }
        for i in 1..<events.count where events[i].time < events[i - 1].time {
            return false
        }
        return true
    }
}
