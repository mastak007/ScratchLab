import Foundation

// MARK: - PhraseTimingSummary

/// Aggregate timing-drift statistics for a single `Phrase`.
///
/// The summary is intentionally minimal:
///
/// - `primitiveCount` is the number of `TimingDrift` records whose
///   matching `GridAnnotation.start` was contained by the phrase.
/// - `withinWindowCount` is how many of those drifts had
///   `isWithinWindow == true`.
/// - `meanAbsoluteDrift` and `maxAbsoluteDrift` are computed over
///   `abs(drift.drift)` of the matched drifts.
///
/// For a phrase with no matched drifts, all four numeric fields are
/// zero. No "drift score percentage" is computed — that's a coaching
/// layer concern, separate from this slice.
///
/// The decoder enforces:
///
/// - `phraseIndex >= 0`
/// - `primitiveCount >= 0`
/// - `withinWindowCount >= 0`
/// - `withinWindowCount <= primitiveCount`
/// - `meanAbsoluteDrift` and `maxAbsoluteDrift` finite and `>= 0`
///
/// The in-memory constructor does not validate these invariants — the
/// evaluator is the only producer, and it satisfies them by construction.
struct PhraseTimingSummary: Equatable, Sendable, Codable {
    let phraseIndex: Int
    let primitiveCount: Int
    let withinWindowCount: Int
    let meanAbsoluteDrift: TimeInterval
    let maxAbsoluteDrift: TimeInterval

    init(phraseIndex: Int,
         primitiveCount: Int,
         withinWindowCount: Int,
         meanAbsoluteDrift: TimeInterval,
         maxAbsoluteDrift: TimeInterval) {
        self.phraseIndex = phraseIndex
        self.primitiveCount = primitiveCount
        self.withinWindowCount = withinWindowCount
        self.meanAbsoluteDrift = meanAbsoluteDrift
        self.maxAbsoluteDrift = maxAbsoluteDrift
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case phraseIndex
        case primitiveCount
        case withinWindowCount
        case meanAbsoluteDrift
        case maxAbsoluteDrift
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let phraseIndex = try container.decode(Int.self, forKey: .phraseIndex)
        guard phraseIndex >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .phraseIndex,
                in: container,
                debugDescription: "phraseIndex must be ≥ 0, got \(phraseIndex)"
            )
        }
        let primitiveCount = try container.decode(Int.self, forKey: .primitiveCount)
        guard primitiveCount >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .primitiveCount,
                in: container,
                debugDescription: "primitiveCount must be ≥ 0, got \(primitiveCount)"
            )
        }
        let withinWindowCount = try container.decode(Int.self, forKey: .withinWindowCount)
        guard withinWindowCount >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .withinWindowCount,
                in: container,
                debugDescription: "withinWindowCount must be ≥ 0, got \(withinWindowCount)"
            )
        }
        guard withinWindowCount <= primitiveCount else {
            throw DecodingError.dataCorruptedError(
                forKey: .withinWindowCount,
                in: container,
                debugDescription: "withinWindowCount \(withinWindowCount) exceeds primitiveCount \(primitiveCount)"
            )
        }
        let meanAbsoluteDrift = try container.decode(TimeInterval.self, forKey: .meanAbsoluteDrift)
        guard meanAbsoluteDrift.isFinite, meanAbsoluteDrift >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .meanAbsoluteDrift,
                in: container,
                debugDescription: "meanAbsoluteDrift must be finite and ≥ 0, got \(meanAbsoluteDrift)"
            )
        }
        let maxAbsoluteDrift = try container.decode(TimeInterval.self, forKey: .maxAbsoluteDrift)
        guard maxAbsoluteDrift.isFinite, maxAbsoluteDrift >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .maxAbsoluteDrift,
                in: container,
                debugDescription: "maxAbsoluteDrift must be finite and ≥ 0, got \(maxAbsoluteDrift)"
            )
        }
        self.phraseIndex = phraseIndex
        self.primitiveCount = primitiveCount
        self.withinWindowCount = withinWindowCount
        self.meanAbsoluteDrift = meanAbsoluteDrift
        self.maxAbsoluteDrift = maxAbsoluteDrift
    }
}

// MARK: - PhraseTimingSummaryEvaluator

/// Pure, deterministic projection of `(drifts, annotations, phrases)`
/// onto a `[PhraseTimingSummary]` stream.
///
/// One summary is emitted per input phrase, in the same order as
/// `phrases`. Phrases with zero matched drifts produce all-zero
/// summaries — there is no notion of "phrase doesn't exist in the
/// output."
///
/// A drift is matched to a phrase when:
///
///   1. There is an annotation whose `primitiveIndex` equals the
///      drift's `primitiveIndex`. If multiple annotations share the
///      same `primitiveIndex`, the **first** one in input order wins.
///   2. That annotation's `start` `GridPosition` is `contains`-ed by
///      the phrase (bar-only check inherited from `Phrase.contains`).
///
/// Drifts without a matching annotation are silently ignored. The
/// evaluator does not touch primitives, the grid, or any clock.
enum PhraseTimingSummaryEvaluator {

    static func summarize(
        drifts: [TimingDrift],
        annotations: [GridAnnotation],
        phrases: [Phrase]
    ) -> [PhraseTimingSummary] {
        // First-wins lookup: primitiveIndex → GridPosition (annotation.start).
        var annotationStartByIndex: [Int: GridPosition] = [:]
        annotationStartByIndex.reserveCapacity(annotations.count)
        for annotation in annotations {
            // Dictionary subscript assignment overwrites; explicit
            // first-wins check preserves the contract regardless of
            // input ordering.
            if annotationStartByIndex[annotation.primitiveIndex] == nil {
                annotationStartByIndex[annotation.primitiveIndex] = annotation.start
            }
        }

        var output: [PhraseTimingSummary] = []
        output.reserveCapacity(phrases.count)

        for (phraseIndex, phrase) in phrases.enumerated() {
            var primitiveCount = 0
            var withinWindowCount = 0
            var sumAbs: Double = 0
            var maxAbs: Double = 0
            for drift in drifts {
                guard let start = annotationStartByIndex[drift.primitiveIndex] else {
                    continue
                }
                guard phrase.contains(start) else {
                    continue
                }
                primitiveCount += 1
                if drift.isWithinWindow { withinWindowCount += 1 }
                let absoluteDrift = abs(drift.drift)
                sumAbs += absoluteDrift
                if absoluteDrift > maxAbs { maxAbs = absoluteDrift }
            }
            let mean: Double = primitiveCount > 0
                ? sumAbs / Double(primitiveCount)
                : 0
            output.append(
                PhraseTimingSummary(
                    phraseIndex: phraseIndex,
                    primitiveCount: primitiveCount,
                    withinWindowCount: withinWindowCount,
                    meanAbsoluteDrift: mean,
                    maxAbsoluteDrift: primitiveCount > 0 ? maxAbs : 0
                )
            )
        }
        return output
    }
}
