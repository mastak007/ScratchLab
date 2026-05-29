import Foundation

// Phase 1 controller-input: pure detected-control aggregation.
//
// Scope guardrails (deliberate):
// - Pure value type. No Core MIDI, no device assumptions, no RANE ONE mapping.
// - Aggregates observed MIDI messages into per-control stats for the Inspector's
//   "detected controls" summary: which CC/note numbers are most active, the last
//   value seen per control, and an observed event rate. It interprets nothing
//   about meaning (which CC is the crossfader, etc.) — that is discovery's job.

/// Identity used to group observed messages into a single "control": a
/// (message-type, channel, CC/note-number) tuple. Channel and number are optional
/// because system messages have neither.
struct DetectedControlID: Sendable, Equatable, Hashable {
    let messageType: MIDIMessageType
    let channel: Int?
    let number: Int?

    init(_ parsed: ParsedMIDIMessage) {
        self.messageType = parsed.messageType
        self.channel = parsed.channel
        self.number = parsed.controlOrNoteNumber
    }

    init(messageType: MIDIMessageType, channel: Int?, number: Int?) {
        self.messageType = messageType
        self.channel = channel
        self.number = number
    }

    /// Compact label for the Inspector, e.g. "CC 16 · ch 1" or "Note 60 · ch 2".
    var displayLabel: String {
        var head: String
        switch messageType {
        case .controlChange: head = number.map { "CC \($0)" } ?? "CC"
        case .noteOn, .noteOff: head = number.map { "Note \($0)" } ?? "Note"
        default: head = messageType.displayName
        }
        if let channel { head += " · ch \(channel + 1)" }
        return head
    }
}

/// Per-control running stats accumulated by `DetectedControlSummary`.
struct DetectedControlStat: Sendable, Equatable {
    let id: DetectedControlID
    /// Total messages observed for this control.
    var count: Int
    /// Most recent salient value (see `ParsedMIDIMessage.value`).
    var lastValue: Int?
    /// Timestamp (monotonic seconds) of the first and most recent observation.
    var firstTimestamp: TimeInterval
    var lastTimestamp: TimeInterval

    /// Observed event rate in Hz across the span this control has been seen.
    /// Uses (count - 1) intervals over the elapsed span; 0 until a second event.
    var eventRate: Double {
        let span = lastTimestamp - firstTimestamp
        guard span > 0, count > 1 else { return 0 }
        return Double(count - 1) / span
    }
}

/// Aggregates parsed MIDI messages into per-control stats. Pure and deterministic:
/// timestamps are supplied by the caller, never read from a wall clock here.
struct DetectedControlSummary: Sendable, Equatable {
    private(set) var stats: [DetectedControlID: DetectedControlStat] = [:]
    /// Total messages recorded across all controls.
    private(set) var totalCount: Int = 0

    init() {}

    /// Records one observed message at the given monotonic timestamp.
    mutating func record(_ parsed: ParsedMIDIMessage, at timestamp: TimeInterval) {
        let id = DetectedControlID(parsed)
        totalCount += 1
        if var existing = stats[id] {
            existing.count += 1
            existing.lastValue = parsed.value
            existing.lastTimestamp = timestamp
            stats[id] = existing
        } else {
            stats[id] = DetectedControlStat(
                id: id,
                count: 1,
                lastValue: parsed.value,
                firstTimestamp: timestamp,
                lastTimestamp: timestamp
            )
        }
    }

    /// Controls ordered by activity (most messages first). Ties break by a stable
    /// label so the Inspector list does not jitter between equal-count controls.
    var mostActive: [DetectedControlStat] {
        stats.values.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.id.displayLabel < $1.id.displayLabel
        }
    }

    /// Number of distinct controls seen.
    var distinctControlCount: Int { stats.count }

    /// Resets all accumulated stats.
    mutating func clear() {
        stats.removeAll()
        totalCount = 0
    }
}
