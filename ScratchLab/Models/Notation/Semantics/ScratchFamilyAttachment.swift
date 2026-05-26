import Foundation

// MARK: - PrimitiveIndexRange

/// An inclusive, non-empty range of `NotationPrimitive` indices.
///
/// `lowerBound` and `upperBound` are both included; for a range that
/// addresses a single primitive, `lowerBound == upperBound`. The
/// failable initialiser enforces:
///
/// - `lowerBound >= 0` (primitive indices are 0-based)
/// - `upperBound >= lowerBound` (range is non-empty)
///
/// The type carries **no reference** to a primitive array. It is
/// purely an interval over Int. Validation that the addressed indices
/// exist within a specific `[NotationPrimitive]` is the caller's
/// concern, not this type's.
struct PrimitiveIndexRange: Equatable, Sendable, Codable {
    let lowerBound: Int
    let upperBound: Int

    init?(lowerBound: Int, upperBound: Int) {
        guard lowerBound >= 0 else { return nil }
        guard upperBound >= lowerBound else { return nil }
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    /// Inclusive cardinality: `upperBound - lowerBound + 1`.
    var count: Int {
        upperBound - lowerBound + 1
    }

    /// Inclusive containment on both bounds.
    func contains(_ index: Int) -> Bool {
        index >= lowerBound && index <= upperBound
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case lowerBound, upperBound
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let lowerBound = try container.decode(Int.self, forKey: .lowerBound)
        guard lowerBound >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .lowerBound,
                in: container,
                debugDescription: "lowerBound must be ≥ 0, got \(lowerBound)"
            )
        }
        let upperBound = try container.decode(Int.self, forKey: .upperBound)
        guard upperBound >= lowerBound else {
            throw DecodingError.dataCorruptedError(
                forKey: .upperBound,
                in: container,
                debugDescription: "upperBound \(upperBound) must be ≥ lowerBound \(lowerBound)"
            )
        }
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }
}

// MARK: - ScratchFamilyAttachment

/// A sidecar binding between a `ScratchFamilyLabel` and a
/// `PrimitiveIndexRange`. Attaches semantic meaning to a span of
/// notation primitives **by reference** (index range), never by
/// mutating the primitives themselves.
///
/// **No claim about correctness.** An attachment says only "the caller
/// (manual, future classifier, etc.) has declared that this range
/// carries this label." It does not validate that the primitives at
/// those indices actually exhibit the family's motion / fader pattern
/// — that belongs to future inference layers and stays out of scope
/// here. Per `PROFILE.md`, classifier-produced labels remain
/// research-only; the sidecar still accepts them, but consumers must
/// honour `label.isResearchOnly` before surfacing them.
struct ScratchFamilyAttachment: Equatable, Sendable, Codable {
    let primitiveRange: PrimitiveIndexRange
    let label: ScratchFamilyLabel

    init(primitiveRange: PrimitiveIndexRange, label: ScratchFamilyLabel) {
        self.primitiveRange = primitiveRange
        self.label = label
    }
}

// MARK: - ScratchFamilyAttachmentMapper

/// Pure, deterministic factory for `ScratchFamilyAttachment`.
///
/// The mapper is intentionally trivial — it neither inspects nor
/// modifies any primitive array. Its purpose is to provide a single,
/// named construction site so future inference layers can call into
/// the same surface as manual attachers without diverging on shape.
enum ScratchFamilyAttachmentMapper {

    static func attach(
        label: ScratchFamilyLabel,
        to primitiveRange: PrimitiveIndexRange
    ) -> ScratchFamilyAttachment {
        ScratchFamilyAttachment(primitiveRange: primitiveRange, label: label)
    }
}
