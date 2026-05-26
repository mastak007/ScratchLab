import Foundation

// MARK: - ScratchFamilyAnnotationSet

/// A validated, ordered collection of `ScratchFamilyAttachment`
/// sidecars. Represents the manual family-annotation surface for a
/// captured take or fixture: zero or more attachments, each pointing
/// at a `PrimitiveIndexRange` and a `ScratchFamilyLabel`.
///
/// **Invariants enforced at construction and decode time:**
///
/// - Attachments are sorted **strictly ascending** by
///   `primitiveRange.lowerBound`.
/// - No two attachments' ranges overlap. Adjacent (touching) ranges
///   are allowed — e.g. one ending at index 7 next to one starting at
///   index 8.
/// - The empty set is valid.
/// - Duplicate `ScratchFamilyLabel`s are allowed across the set, as
///   long as the ranges remain non-overlapping.
///
/// **Manual metadata only.** No classifier produces these
/// attachments. No `NotationPrimitive` array is consulted to build the
/// set, and the set carries no reference back to primitives, timing,
/// or capture state.
struct ScratchFamilyAnnotationSet: Equatable, Sendable, Codable {
    let attachments: [ScratchFamilyAttachment]

    init?(attachments: [ScratchFamilyAttachment]) {
        guard ScratchFamilyAnnotationSet.invariantsHold(attachments) else { return nil }
        self.attachments = attachments
    }

    /// Returns the (at most one) attachment whose range contains the
    /// given primitive index. Returns `nil` for negative indices and
    /// for indices outside every stored range. Because overlapping
    /// ranges are forbidden by construction, at most one attachment
    /// can match — the first match found is returned.
    func attachment(containing primitiveIndex: Int) -> ScratchFamilyAttachment? {
        guard primitiveIndex >= 0 else { return nil }
        return attachments.first { $0.primitiveRange.contains(primitiveIndex) }
    }

    /// Returns all attachments whose label belongs to the given
    /// family, preserving stored order.
    func attachments(for family: ScratchFamily) -> [ScratchFamilyAttachment] {
        attachments.filter { $0.label.family == family }
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case attachments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let attachments = try container.decode([ScratchFamilyAttachment].self,
                                                forKey: .attachments)
        guard ScratchFamilyAnnotationSet.invariantsHold(attachments) else {
            throw DecodingError.dataCorruptedError(
                forKey: .attachments,
                in: container,
                debugDescription: "attachments must be sorted ascending by primitiveRange.lowerBound and non-overlapping; adjacent ranges are allowed"
            )
        }
        self.attachments = attachments
    }

    // MARK: Invariant check

    private static func invariantsHold(_ attachments: [ScratchFamilyAttachment]) -> Bool {
        // Empty set is valid.
        guard attachments.count > 1 else { return true }
        for i in 1..<attachments.count {
            let prev = attachments[i - 1].primitiveRange
            let curr = attachments[i].primitiveRange
            // Strict ascending by lowerBound implies non-overlapping
            // when combined with `prev.upperBound < curr.lowerBound`.
            // The single condition `prev.upperBound < curr.lowerBound`
            // covers both rules: if `curr.lowerBound <= prev.lowerBound`
            // then the ranges would overlap (since prev.upperBound ≥
            // prev.lowerBound ≥ curr.lowerBound), so the same check
            // also rejects unsorted input.
            if prev.upperBound >= curr.lowerBound { return false }
        }
        return true
    }
}
