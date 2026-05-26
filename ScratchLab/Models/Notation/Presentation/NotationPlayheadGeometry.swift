import Foundation

// MARK: - NotationPlayheadGeometry

/// Renderer-ready geometry for a single playhead within a
/// `NotationLaneViewport`.
///
/// **Pure value type.** No view, no rendering geometry beyond
/// pixel-space coordinates, no animation state.
///
/// - `time` is the absolute take time the playhead represents.
/// - `x` is the linear projection of `time` onto `[0, viewport.width]`,
///   clamped to that interval.
/// - `yTop` / `yBottom` span the full viewport height: `yTop == 0`,
///   `yBottom == viewport.height`. A future renderer can draw a
///   vertical line from `(x, yTop)` to `(x, yBottom)`.
/// - `isWithinViewport` is `true` when
///   `viewport.startTime <= time <= viewport.endTime` and `false`
///   otherwise. Allows a renderer to grey-out / hide a playhead that
///   has been clamped to an edge.
///
/// **Invariants enforced at decode time:** all four numeric fields
/// are finite.
struct NotationPlayheadGeometry: Equatable, Sendable, Codable {
    let time: TimeInterval
    let x: Double
    let yTop: Double
    let yBottom: Double
    let isWithinViewport: Bool

    init(
        time: TimeInterval,
        x: Double,
        yTop: Double,
        yBottom: Double,
        isWithinViewport: Bool
    ) {
        self.time = time
        self.x = x
        self.yTop = yTop
        self.yBottom = yBottom
        self.isWithinViewport = isWithinViewport
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case time, x, yTop, yBottom, isWithinViewport
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let time = try container.decode(TimeInterval.self, forKey: .time)
        guard time.isFinite else {
            throw DecodingError.dataCorruptedError(
                forKey: .time,
                in: container,
                debugDescription: "time must be finite, got \(time)"
            )
        }
        let x = try container.decode(Double.self, forKey: .x)
        guard x.isFinite else {
            throw DecodingError.dataCorruptedError(
                forKey: .x,
                in: container,
                debugDescription: "x must be finite, got \(x)"
            )
        }
        let yTop = try container.decode(Double.self, forKey: .yTop)
        guard yTop.isFinite else {
            throw DecodingError.dataCorruptedError(
                forKey: .yTop,
                in: container,
                debugDescription: "yTop must be finite, got \(yTop)"
            )
        }
        let yBottom = try container.decode(Double.self, forKey: .yBottom)
        guard yBottom.isFinite else {
            throw DecodingError.dataCorruptedError(
                forKey: .yBottom,
                in: container,
                debugDescription: "yBottom must be finite, got \(yBottom)"
            )
        }
        self.time = time
        self.x = x
        self.yTop = yTop
        self.yBottom = yBottom
        self.isWithinViewport = try container.decode(Bool.self, forKey: .isWithinViewport)
    }
}

// MARK: - NotationPlayheadGeometryMapper

/// Pure, deterministic projection of `(time, viewport)` to a
/// `NotationPlayheadGeometry`.
///
/// Returns `nil` when `time` is non-finite. The viewport itself is
/// already validated at construction time (finite values, positive
/// span/width/height), so no further input validation is required.
///
/// **What the mapper does (and only this):**
///
/// - Maps `time` linearly onto `[0, viewport.width]` and clamps the
///   result.
/// - Sets `yTop = 0` and `yBottom = viewport.height`.
/// - Sets `isWithinViewport` to the inclusive
///   `[viewport.startTime, viewport.endTime]` check.
///
/// **What the mapper does not do:** no UI / Canvas / renderer call,
/// no ML, no scoring, no clock, no I/O, no mutation of inputs.
enum NotationPlayheadGeometryMapper {

    static func makePlayhead(
        time: TimeInterval,
        viewport: NotationLaneViewport
    ) -> NotationPlayheadGeometry? {
        guard time.isFinite else { return nil }
        let span = viewport.endTime - viewport.startTime
        let normalized = (time - viewport.startTime) / span
        let x = min(max(normalized * viewport.width, 0), viewport.width)
        let isWithin = time >= viewport.startTime && time <= viewport.endTime
        return NotationPlayheadGeometry(
            time: time,
            x: x,
            yTop: 0,
            yBottom: viewport.height,
            isWithinViewport: isWithin
        )
    }
}
