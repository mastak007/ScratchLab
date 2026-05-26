import Foundation

// MARK: - ExpectedTiming

/// A primitive's grid-projected expected start time.
///
/// `expectedStartTime` is the absolute `TimeInterval` produced by
/// `TimingGrid.time(of: annotation.start)`. The mapping is the inverse
/// of the grid-position lookup that `GridAnnotationMapper` performed
/// — it converts a musical position back into the seconds-domain
/// expected time that drift evaluation operates on.
///
/// **No primitive coupling.** The type carries only `primitiveIndex`
/// and the projected time; the underlying `NotationPrimitive` is never
/// inspected by this layer.
///
/// The decoder enforces non-negative `primitiveIndex` and finite
/// `expectedStartTime`. The mapper does not throw, so non-finite
/// values cannot enter via the mapper — only via a hand-crafted JSON,
/// which the decoder rejects.
struct ExpectedTiming: Equatable, Sendable, Codable {
    let primitiveIndex: Int
    let expectedStartTime: TimeInterval

    init(primitiveIndex: Int, expectedStartTime: TimeInterval) {
        self.primitiveIndex = primitiveIndex
        self.expectedStartTime = expectedStartTime
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case primitiveIndex, expectedStartTime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let primitiveIndex = try container.decode(Int.self, forKey: .primitiveIndex)
        guard primitiveIndex >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .primitiveIndex,
                in: container,
                debugDescription: "primitiveIndex must be ≥ 0, got \(primitiveIndex)"
            )
        }
        let expectedStartTime = try container.decode(TimeInterval.self, forKey: .expectedStartTime)
        guard expectedStartTime.isFinite else {
            throw DecodingError.dataCorruptedError(
                forKey: .expectedStartTime,
                in: container,
                debugDescription: "expectedStartTime must be finite, got \(expectedStartTime)"
            )
        }
        self.primitiveIndex = primitiveIndex
        self.expectedStartTime = expectedStartTime
    }
}

// MARK: - ExpectedTimingMapper

/// Pure, deterministic projection from `[GridAnnotation]` back into
/// absolute expected start times.
///
/// Two output shapes are offered:
///
/// - `expectedStartTimes(for:using:)` — `[ExpectedTiming]` array that
///   preserves annotation input order. One entry per annotation,
///   `primitiveIndex` matching `annotation.primitiveIndex`.
///
/// - `expectedStartTimeMap(for:using:)` — `[Int: TimeInterval]`
///   dictionary keyed by `primitiveIndex`. Suitable for feeding
///   directly into `TimingWindowEvaluator.evaluate(...)` as the
///   `expectedStartTimes` argument. When two annotations share the
///   same `primitiveIndex`, the later annotation's expected time
///   wins — consistent with standard dictionary upsert semantics.
///
/// Same input + same grid → byte-identical output. No primitive
/// access, no snapping, no tolerance, no scoring. Mapper does not
/// throw.
enum ExpectedTimingMapper {

    static func expectedStartTimes(
        for annotations: [GridAnnotation],
        using grid: TimingGrid
    ) -> [ExpectedTiming] {
        var output: [ExpectedTiming] = []
        output.reserveCapacity(annotations.count)
        for annotation in annotations {
            output.append(
                ExpectedTiming(
                    primitiveIndex: annotation.primitiveIndex,
                    expectedStartTime: grid.time(of: annotation.start)
                )
            )
        }
        return output
    }

    static func expectedStartTimeMap(
        for annotations: [GridAnnotation],
        using grid: TimingGrid
    ) -> [Int: TimeInterval] {
        var map: [Int: TimeInterval] = [:]
        map.reserveCapacity(annotations.count)
        for annotation in annotations {
            // Plain subscript assignment naturally upserts; later
            // annotations with a duplicate `primitiveIndex` overwrite
            // earlier ones, matching the contract.
            map[annotation.primitiveIndex] = grid.time(of: annotation.start)
        }
        return map
    }
}
