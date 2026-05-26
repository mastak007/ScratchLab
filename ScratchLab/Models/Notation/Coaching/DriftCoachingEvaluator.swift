import Foundation

// MARK: - DriftCoachingRule

/// A pair of finite, non-negative thresholds that define the "late"
/// and "early" boundaries for converting `TimingDrift` values into
/// `CoachingEvent`s.
///
/// The thresholds are interpreted as **strict** boundaries:
/// `drift > lateThreshold` is late, `drift < -earlyThreshold` is
/// early, and `|drift|` equal to either threshold yields no event.
///
/// **No ML, no scoring, no calibration.** The rule is the entirety
/// of the threshold logic — no decay, no smoothing, no per-primitive
/// adjustment. Callers select the threshold values from their own
/// product or research configuration.
///
/// **Invariants enforced at construction and decode time:**
///
/// - `lateThreshold` is finite and ≥ 0.
/// - `earlyThreshold` is finite and ≥ 0.
struct DriftCoachingRule: Equatable, Sendable, Codable {
    let lateThreshold: TimeInterval
    let earlyThreshold: TimeInterval

    init?(lateThreshold: TimeInterval, earlyThreshold: TimeInterval) {
        guard DriftCoachingRule.isValidThreshold(lateThreshold) else { return nil }
        guard DriftCoachingRule.isValidThreshold(earlyThreshold) else { return nil }
        self.lateThreshold = lateThreshold
        self.earlyThreshold = earlyThreshold
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case lateThreshold, earlyThreshold
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let lateThreshold = try container.decode(TimeInterval.self, forKey: .lateThreshold)
        guard DriftCoachingRule.isValidThreshold(lateThreshold) else {
            throw DecodingError.dataCorruptedError(
                forKey: .lateThreshold,
                in: container,
                debugDescription: "lateThreshold must be finite and ≥ 0, got \(lateThreshold)"
            )
        }
        let earlyThreshold = try container.decode(TimeInterval.self, forKey: .earlyThreshold)
        guard DriftCoachingRule.isValidThreshold(earlyThreshold) else {
            throw DecodingError.dataCorruptedError(
                forKey: .earlyThreshold,
                in: container,
                debugDescription: "earlyThreshold must be finite and ≥ 0, got \(earlyThreshold)"
            )
        }
        self.lateThreshold = lateThreshold
        self.earlyThreshold = earlyThreshold
    }

    private static func isValidThreshold(_ value: TimeInterval) -> Bool {
        value.isFinite && value >= 0
    }
}

// MARK: - DriftCoachingEvaluator

/// Pure, deterministic projection of `[TimingDrift]` to
/// `[CoachingEvent]` via a `DriftCoachingRule`.
///
/// **What it does (and only this):**
///
/// - For each `TimingDrift` whose `drift` value is finite:
///   - If `drift > rule.lateThreshold` → emit a `.lateReversal`.
///   - If `drift < -rule.earlyThreshold` → emit an `.earlyReversal`.
///   - Otherwise emit nothing.
/// - Emitted events use `drift.actualTime` as `time`, the catalog's
///   descriptor severity, and a `nil` message.
/// - Output preserves input order.
///
/// **What it does not do:** no ML, no smoothing, no per-primitive
/// re-thresholding, no UI/export coupling, no consultation of the
/// primitives or grid that produced the drifts. Inputs whose
/// `drift` is non-finite, or whose `actualTime` would fail
/// `CoachingEvent`'s validity check, are silently skipped — the
/// evaluator never throws and never produces a sentinel event.
enum DriftCoachingEvaluator {

    static func events(
        from drifts: [TimingDrift],
        using rule: DriftCoachingRule
    ) -> [CoachingEvent] {
        var output: [CoachingEvent] = []
        output.reserveCapacity(drifts.count)
        for drift in drifts {
            guard drift.drift.isFinite else { continue }
            let kind: CoachingEventKind
            if drift.drift > rule.lateThreshold {
                kind = .lateReversal
            } else if drift.drift < -rule.earlyThreshold {
                kind = .earlyReversal
            } else {
                continue
            }
            let descriptor = CoachingEventCatalog.descriptor(for: kind)
            guard let event = CoachingEvent(
                time: drift.actualTime,
                kind: kind,
                severity: descriptor.severity,
                message: nil
            ) else { continue }
            output.append(event)
        }
        return output
    }
}
