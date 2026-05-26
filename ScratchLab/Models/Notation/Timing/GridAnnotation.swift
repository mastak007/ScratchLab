import Foundation

// MARK: - GridAnnotation

/// A sidecar binding between a `NotationPrimitive` (by index) and the
/// pair of `GridPosition`s that bracket its time span on a `TimingGrid`.
///
/// The annotation is **external**: it carries a `primitiveIndex`
/// reference rather than mutating or extending the primitive. The
/// grammar layer stays BPM-agnostic; the `TimingGrid` layer stays
/// playback-agnostic; their composition lives here, as data.
///
/// `start` and `end` correspond to the primitive's time span:
///
/// - `DirectionSegment` and `IdleHold` use their full `[startTime, endTime]`.
/// - `Reversal` is a point event, so `start == end` (both projected
///   from `Reversal.time`).
///
/// No filtering, no merging, no nearest-beat snapping, no tolerance
/// banding. Those are layers above this sidecar and intentionally
/// outside this slice's scope.
struct GridAnnotation: Equatable, Sendable, Codable {
    let primitiveIndex: Int
    let start: GridPosition
    let end: GridPosition

    init(primitiveIndex: Int, start: GridPosition, end: GridPosition) {
        self.primitiveIndex = primitiveIndex
        self.start = start
        self.end = end
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case primitiveIndex, start, end
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
        let start = try container.decode(GridPosition.self, forKey: .start)
        let end = try container.decode(GridPosition.self, forKey: .end)
        self.primitiveIndex = primitiveIndex
        self.start = start
        self.end = end
    }
}

// MARK: - GridAnnotationMapper

/// Pure, deterministic projection of a primitive stream onto a
/// `TimingGrid`, producing one `GridAnnotation` per primitive in input
/// order.
///
/// The mapper does not touch the primitives: input is read-only and
/// the output's `primitiveIndex` matches each annotation's position in
/// the input array (annotations[i].primitiveIndex == i). Reordering or
/// filtering, if ever needed, is a separate concern handled by other
/// callers — never by this mapper.
enum GridAnnotationMapper {

    /// Annotate every primitive with its grid-projected start/end span.
    /// Same input + same grid → byte-identical output across calls.
    static func annotate(
        primitives: [NotationPrimitive],
        using grid: TimingGrid
    ) -> [GridAnnotation] {
        var output: [GridAnnotation] = []
        output.reserveCapacity(primitives.count)
        for (index, primitive) in primitives.enumerated() {
            let span = timeSpan(of: primitive)
            output.append(
                GridAnnotation(
                    primitiveIndex: index,
                    start: grid.position(at: span.start),
                    end: grid.position(at: span.end)
                )
            )
        }
        return output
    }

    // MARK: Primitive time-span extraction

    /// Extracts the `(start, end)` time pair for any
    /// `NotationPrimitive` variant.
    ///
    /// - `DirectionSegment` / `IdleHold`: their own `startTime`/`endTime`.
    /// - `Reversal`: point event — `start == end == reversal.time`.
    ///
    /// Implemented as a private switch (rather than as a computed
    /// property on the primitive types) so this slice stays purely
    /// additive — Section 1 outputs remain byte-identical.
    private static func timeSpan(
        of primitive: NotationPrimitive
    ) -> (start: TimeInterval, end: TimeInterval) {
        switch primitive {
        case .directionSegment(let segment):
            return (segment.startTime, segment.endTime)
        case .reversal(let reversal):
            return (reversal.time, reversal.time)
        case .idleHold(let hold):
            return (hold.startTime, hold.endTime)
        }
    }
}
