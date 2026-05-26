import Foundation

// MARK: - CoachingEventSummary

/// A per-kind count of `CoachingEvent`s observed in a
/// `CoachingEventSet`.
///
/// The struct is pure metadata: it pairs a `CoachingEventKind` with
/// the catalog's `CoachingEventSeverity` and a non-negative `count`.
/// No scoring percentage is computed — that's a higher-layer
/// concern.
///
/// **Invariants enforced at decode time:**
///
/// - `count >= 0`.
struct CoachingEventSummary: Equatable, Sendable, Codable {
    let kind: CoachingEventKind
    let severity: CoachingEventSeverity
    let count: Int

    init(kind: CoachingEventKind, severity: CoachingEventSeverity, count: Int) {
        self.kind = kind
        self.severity = severity
        self.count = count
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case kind, severity, count
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try container.decode(CoachingEventKind.self, forKey: .kind)
        self.severity = try container.decode(CoachingEventSeverity.self, forKey: .severity)
        let count = try container.decode(Int.self, forKey: .count)
        guard count >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .count,
                in: container,
                debugDescription: "count must be ≥ 0, got \(count)"
            )
        }
        self.count = count
    }
}

// MARK: - CoachingEventMerger

/// Pure, deterministic merge of multiple `[CoachingEvent]` groups
/// into a single time-sorted `CoachingEventSet`.
///
/// **Merge contract:**
///
/// - All groups are flattened into one stream.
/// - The stream is sorted by `event.time` ascending.
/// - For events that share a `time`, the original group order is
///   preserved first; within a group, the original element order is
///   preserved.
/// - The resulting `CoachingEventSet` carries the standard
///   sorted-by-time invariant established in Slice 2.
///
/// **No inference, no de-duplication, no scoring.** The merger
/// neither inspects nor mutates event payloads beyond reading
/// `event.time` for ordering. Duplicate events at the same `time`
/// are passed through.
enum CoachingEventMerger {

    static func merge(_ eventGroups: [[CoachingEvent]]) -> CoachingEventSet? {
        // Tag each event with (time, groupIndex, intraIndex) so the
        // sort tiebreaker is explicit and stability is independent
        // of the host sorting algorithm's stability guarantees.
        var tagged: [(time: TimeInterval, groupIndex: Int, intraIndex: Int, event: CoachingEvent)] = []
        for (groupIndex, group) in eventGroups.enumerated() {
            tagged.reserveCapacity(tagged.count + group.count)
            for (intraIndex, event) in group.enumerated() {
                tagged.append((event.time, groupIndex, intraIndex, event))
            }
        }
        tagged.sort { lhs, rhs in
            if lhs.time != rhs.time { return lhs.time < rhs.time }
            if lhs.groupIndex != rhs.groupIndex { return lhs.groupIndex < rhs.groupIndex }
            return lhs.intraIndex < rhs.intraIndex
        }
        return CoachingEventSet(events: tagged.map(\.event))
    }
}

// MARK: - CoachingEventSummaryEvaluator

/// Pure, deterministic projection of a `CoachingEventSet` to one
/// `CoachingEventSummary` per `CoachingEventKind`.
///
/// **Summary contract:**
///
/// - The output contains exactly one row per
///   `CoachingEventKind.allCases` entry, in that same order.
/// - Kinds that do not appear in the input set are still represented
///   with `count == 0`.
/// - Each row's `severity` comes from
///   `CoachingEventCatalog.descriptor(for: kind).severity`.
///
/// **No percentages, no thresholds, no UI coupling.** This is a
/// count-bucket only.
enum CoachingEventSummaryEvaluator {

    static func summarize(_ eventSet: CoachingEventSet) -> [CoachingEventSummary] {
        var counts: [CoachingEventKind: Int] = [:]
        counts.reserveCapacity(CoachingEventKind.allCases.count)
        for event in eventSet.events {
            counts[event.kind, default: 0] += 1
        }
        return CoachingEventKind.allCases.map { kind in
            CoachingEventSummary(
                kind: kind,
                severity: CoachingEventCatalog.descriptor(for: kind).severity,
                count: counts[kind, default: 0]
            )
        }
    }
}
