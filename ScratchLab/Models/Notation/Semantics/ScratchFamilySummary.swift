import Foundation

// MARK: - ScratchFamilySummary

/// Per-family aggregate counts derived from a
/// `ScratchFamilyAnnotationSet`.
///
/// Both counts are non-negative by construction:
///
/// - `attachmentCount` is the number of `ScratchFamilyAttachment`
///   entries in the source set whose label matches `family`.
/// - `primitiveCount` is the sum of inclusive
///   `PrimitiveIndexRange.count` across those attachments — i.e. the
///   total number of primitive indices labelled with this family in
///   the source set. Because the source set forbids overlapping
///   ranges, this is also the literal count of distinct primitive
///   indices addressed.
///
/// **Manual metadata only.** Counts reflect what a human (or some
/// future inference layer) has labelled; the summary makes no claim
/// about what the underlying primitives *are*. Per `PROFILE.md`,
/// surfaces consulting this type still need to honour each label's
/// `isResearchOnly` flag before showing the family name to a user.
struct ScratchFamilySummary: Equatable, Sendable, Codable {
    let family: ScratchFamily
    let attachmentCount: Int
    let primitiveCount: Int

    init(family: ScratchFamily, attachmentCount: Int, primitiveCount: Int) {
        self.family = family
        self.attachmentCount = attachmentCount
        self.primitiveCount = primitiveCount
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case family, attachmentCount, primitiveCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let family = try container.decode(ScratchFamily.self, forKey: .family)
        let attachmentCount = try container.decode(Int.self, forKey: .attachmentCount)
        guard attachmentCount >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .attachmentCount,
                in: container,
                debugDescription: "attachmentCount must be ≥ 0, got \(attachmentCount)"
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
        self.family = family
        self.attachmentCount = attachmentCount
        self.primitiveCount = primitiveCount
    }
}

// MARK: - ScratchFamilySummaryEvaluator

/// Pure, deterministic projection of a `ScratchFamilyAnnotationSet`
/// onto a `[ScratchFamilySummary]` stream.
///
/// One summary is emitted per `ScratchFamily.allCases` entry, in the
/// same order as the enum's declared cases. Families that the
/// annotation set never references appear with `attachmentCount = 0`
/// and `primitiveCount = 0`. `.unknown` is treated like any other
/// family — no special-case suppression, no merging with other
/// families.
///
/// The evaluator does not touch primitives, the grid, or any clock.
/// Same input → byte-identical output across calls.
enum ScratchFamilySummaryEvaluator {

    static func summarize(
        annotationSet: ScratchFamilyAnnotationSet
    ) -> [ScratchFamilySummary] {
        // Pre-zero a per-family bucket so families with no attachments
        // are still represented in the output. Dictionary keys aren't
        // ordered, so we re-emit in `allCases` order at the end.
        var counts: [ScratchFamily: (attachments: Int, primitives: Int)] = [:]
        counts.reserveCapacity(ScratchFamily.allCases.count)
        for family in ScratchFamily.allCases {
            counts[family] = (0, 0)
        }
        for attachment in annotationSet.attachments {
            let family = attachment.label.family
            // Force-unwrap is safe: every ScratchFamily case is keyed
            // above before this loop runs.
            var bucket = counts[family]!
            bucket.attachments += 1
            bucket.primitives += attachment.primitiveRange.count
            counts[family] = bucket
        }
        return ScratchFamily.allCases.map { family in
            let bucket = counts[family]!
            return ScratchFamilySummary(
                family: family,
                attachmentCount: bucket.attachments,
                primitiveCount: bucket.primitives
            )
        }
    }
}
