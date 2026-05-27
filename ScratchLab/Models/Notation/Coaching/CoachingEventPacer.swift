import Foundation

// MARK: - CoachingEventPacingRule

/// Configuration for `CoachingEventPacer`. Two non-negative
/// `TimeInterval` thresholds:
///
/// - `minimumInterEventSpacing` is the **global** minimum time between
///   consecutive emitted events, regardless of kind. Suppresses bursts
///   that would overwhelm any user surface.
/// - `sameKindSuppressionWindow` is the **per-kind** minimum time
///   between consecutive emitted events of the same
///   `CoachingEventKind`. Suppresses repeated drift / phrase events
///   in tight succession even when the global spacing would allow
///   them.
///
/// Boundary semantics: both rules use a strict less-than comparison —
/// an event whose `time` lands exactly at `lastEmittedTime + threshold`
/// is **allowed** through. Thresholds equal to zero disable that
/// rule.
///
/// **Invariants enforced at construction and decode time:**
///
/// - `minimumInterEventSpacing` is finite and ≥ 0.
/// - `sameKindSuppressionWindow` is finite and ≥ 0.
struct CoachingEventPacingRule: Equatable, Sendable, Codable {
    let minimumInterEventSpacing: TimeInterval
    let sameKindSuppressionWindow: TimeInterval

    init?(minimumInterEventSpacing: TimeInterval, sameKindSuppressionWindow: TimeInterval) {
        guard CoachingEventPacingRule.isValid(minimumInterEventSpacing) else { return nil }
        guard CoachingEventPacingRule.isValid(sameKindSuppressionWindow) else { return nil }
        self.minimumInterEventSpacing = minimumInterEventSpacing
        self.sameKindSuppressionWindow = sameKindSuppressionWindow
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case minimumInterEventSpacing, sameKindSuppressionWindow
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let global = try container.decode(TimeInterval.self, forKey: .minimumInterEventSpacing)
        guard CoachingEventPacingRule.isValid(global) else {
            throw DecodingError.dataCorruptedError(
                forKey: .minimumInterEventSpacing,
                in: container,
                debugDescription: "minimumInterEventSpacing must be finite and ≥ 0, got \(global)"
            )
        }
        let perKind = try container.decode(TimeInterval.self, forKey: .sameKindSuppressionWindow)
        guard CoachingEventPacingRule.isValid(perKind) else {
            throw DecodingError.dataCorruptedError(
                forKey: .sameKindSuppressionWindow,
                in: container,
                debugDescription: "sameKindSuppressionWindow must be finite and ≥ 0, got \(perKind)"
            )
        }
        self.minimumInterEventSpacing = global
        self.sameKindSuppressionWindow = perKind
    }

    private static func isValid(_ value: TimeInterval) -> Bool {
        value.isFinite && value >= 0
    }
}

// MARK: - CoachingEventPacer

/// Pure, deterministic throttle that filters a `CoachingEventSet` down
/// to a paced `[CoachingEvent]` according to a `CoachingEventPacingRule`.
///
/// **What it does (and only this):**
///
/// - Walks the set's events in stored (time-ascending) order.
/// - Emits an event only when both:
///   - Global spacing satisfied: no prior emit within
///     `rule.minimumInterEventSpacing` seconds.
///   - Same-kind suppression satisfied: no prior emit of the same
///     `CoachingEventKind` within `rule.sameKindSuppressionWindow`
///     seconds.
/// - Preserves input order in the output — events are never reordered.
///
/// **What it does not do:** no ML, no scoring, no UI, no clock, no
/// I/O, no mutation of inputs, no consultation of severity / message
/// fields. Silence is a valid output — an empty result is the honest
/// answer when the rule suppresses everything.
///
/// Same input + same rule → byte-identical output across calls.
enum CoachingEventPacer {

    static func pace(
        _ set: CoachingEventSet,
        using rule: CoachingEventPacingRule
    ) -> [CoachingEvent] {
        var output: [CoachingEvent] = []
        output.reserveCapacity(set.events.count)
        var lastEmittedTime: TimeInterval? = nil
        var lastEmittedByKind: [CoachingEventKind: TimeInterval] = [:]
        for event in set.events {
            if let last = lastEmittedTime,
               event.time - last < rule.minimumInterEventSpacing {
                continue
            }
            if let lastSame = lastEmittedByKind[event.kind],
               event.time - lastSame < rule.sameKindSuppressionWindow {
                continue
            }
            output.append(event)
            lastEmittedTime = event.time
            lastEmittedByKind[event.kind] = event.time
        }
        return output
    }
}
