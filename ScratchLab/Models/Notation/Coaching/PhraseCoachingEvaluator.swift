import Foundation

// MARK: - PhraseCoachingRule

/// Threshold configuration for converting `PhraseTimingSummary`
/// values into `CoachingEvent`s.
///
/// The rule carries three independent dials:
///
/// - `unstableMeanAbsoluteDriftThreshold` — strict upper bound on the
///   phrase's mean absolute drift. A summary whose
///   `meanAbsoluteDrift` exceeds this value emits an `unstableTiming`
///   event.
/// - `unstableMaxAbsoluteDriftThreshold` — strict upper bound on the
///   phrase's max absolute drift. A summary whose `maxAbsoluteDrift`
///   exceeds this value emits an `unstableTiming` event. The two
///   thresholds are OR-combined — exceeding either is sufficient for
///   one (and only one) `unstableTiming` event per phrase.
/// - `incompleteMinimumPrimitiveCount` — the minimum primitive count
///   that counts as a "complete" phrase. A summary whose
///   `primitiveCount` is strictly less than this value emits an
///   `incompletePhrase` event.
///
/// **No ML, no scoring, no calibration.** The rule is the entirety
/// of the threshold logic — no decay, no smoothing, no per-phrase
/// adjustment.
///
/// **Invariants enforced at construction and decode time:**
///
/// - Both drift thresholds are finite and ≥ 0.
/// - `incompleteMinimumPrimitiveCount` is ≥ 0.
struct PhraseCoachingRule: Equatable, Sendable, Codable {
    let unstableMeanAbsoluteDriftThreshold: TimeInterval
    let unstableMaxAbsoluteDriftThreshold: TimeInterval
    let incompleteMinimumPrimitiveCount: Int

    init?(
        unstableMeanAbsoluteDriftThreshold: TimeInterval,
        unstableMaxAbsoluteDriftThreshold: TimeInterval,
        incompleteMinimumPrimitiveCount: Int
    ) {
        guard PhraseCoachingRule.isValidThreshold(unstableMeanAbsoluteDriftThreshold) else { return nil }
        guard PhraseCoachingRule.isValidThreshold(unstableMaxAbsoluteDriftThreshold) else { return nil }
        guard incompleteMinimumPrimitiveCount >= 0 else { return nil }
        self.unstableMeanAbsoluteDriftThreshold = unstableMeanAbsoluteDriftThreshold
        self.unstableMaxAbsoluteDriftThreshold = unstableMaxAbsoluteDriftThreshold
        self.incompleteMinimumPrimitiveCount = incompleteMinimumPrimitiveCount
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case unstableMeanAbsoluteDriftThreshold
        case unstableMaxAbsoluteDriftThreshold
        case incompleteMinimumPrimitiveCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let mean = try container.decode(TimeInterval.self, forKey: .unstableMeanAbsoluteDriftThreshold)
        guard PhraseCoachingRule.isValidThreshold(mean) else {
            throw DecodingError.dataCorruptedError(
                forKey: .unstableMeanAbsoluteDriftThreshold,
                in: container,
                debugDescription: "unstableMeanAbsoluteDriftThreshold must be finite and ≥ 0, got \(mean)"
            )
        }
        let max = try container.decode(TimeInterval.self, forKey: .unstableMaxAbsoluteDriftThreshold)
        guard PhraseCoachingRule.isValidThreshold(max) else {
            throw DecodingError.dataCorruptedError(
                forKey: .unstableMaxAbsoluteDriftThreshold,
                in: container,
                debugDescription: "unstableMaxAbsoluteDriftThreshold must be finite and ≥ 0, got \(max)"
            )
        }
        let minCount = try container.decode(Int.self, forKey: .incompleteMinimumPrimitiveCount)
        guard minCount >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .incompleteMinimumPrimitiveCount,
                in: container,
                debugDescription: "incompleteMinimumPrimitiveCount must be ≥ 0, got \(minCount)"
            )
        }
        self.unstableMeanAbsoluteDriftThreshold = mean
        self.unstableMaxAbsoluteDriftThreshold = max
        self.incompleteMinimumPrimitiveCount = minCount
    }

    private static func isValidThreshold(_ value: TimeInterval) -> Bool {
        value.isFinite && value >= 0
    }
}

// MARK: - PhraseCoachingEvaluator

/// Pure, deterministic projection of `[PhraseTimingSummary]` to
/// `[CoachingEvent]` via a `PhraseCoachingRule` and a per-phrase
/// start-time map.
///
/// **What it does (and only this):**
///
/// - For each input `summary` in order:
///   - Resolve `time = phraseStartTimes[summary.phraseIndex]`. If the
///     map has no entry, the summary is silently skipped.
///   - If `summary.primitiveCount < rule.incompleteMinimumPrimitiveCount`,
///     emit an `incompletePhrase` event.
///   - If `summary.meanAbsoluteDrift > rule.unstableMeanAbsoluteDriftThreshold`
///     **or** `summary.maxAbsoluteDrift > rule.unstableMaxAbsoluteDriftThreshold`,
///     emit a single `unstableTiming` event. Non-finite drift values
///     are treated defensively as "doesn't exceed" — no
///     `unstableTiming` is emitted from a non-finite input.
///   - When both kinds fire for the same phrase, `incompletePhrase`
///     is emitted **before** `unstableTiming`.
/// - Emitted events use the resolved `time`, the catalog's descriptor
///   severity, and a `nil` message.
/// - Output preserves input summary order; within a single summary
///   the documented incompletePhrase-then-unstableTiming order holds.
///
/// **What it does not do:** no ML, no smoothing, no consultation of
/// primitives, grids, drifts, or annotations beyond the summaries
/// the caller has already aggregated. The evaluator never throws and
/// never produces a sentinel event — invalid inputs (e.g. a resolved
/// `time` that fails `CoachingEvent`'s validity check) are silently
/// skipped.
enum PhraseCoachingEvaluator {

    static func events(
        from summaries: [PhraseTimingSummary],
        phraseStartTimes: [Int: TimeInterval],
        using rule: PhraseCoachingRule
    ) -> [CoachingEvent] {
        var output: [CoachingEvent] = []
        output.reserveCapacity(summaries.count)
        for summary in summaries {
            guard let time = phraseStartTimes[summary.phraseIndex] else { continue }

            if summary.primitiveCount < rule.incompleteMinimumPrimitiveCount {
                if let event = makeEvent(kind: .incompletePhrase, at: time) {
                    output.append(event)
                }
            }

            let meanExceeds = summary.meanAbsoluteDrift.isFinite
                && summary.meanAbsoluteDrift > rule.unstableMeanAbsoluteDriftThreshold
            let maxExceeds = summary.maxAbsoluteDrift.isFinite
                && summary.maxAbsoluteDrift > rule.unstableMaxAbsoluteDriftThreshold
            if meanExceeds || maxExceeds {
                if let event = makeEvent(kind: .unstableTiming, at: time) {
                    output.append(event)
                }
            }
        }
        return output
    }

    private static func makeEvent(kind: CoachingEventKind, at time: TimeInterval) -> CoachingEvent? {
        let descriptor = CoachingEventCatalog.descriptor(for: kind)
        return CoachingEvent(
            time: time,
            kind: kind,
            severity: descriptor.severity,
            message: nil
        )
    }
}
