import Foundation

// MARK: - NotationGridlineKind

/// The three classes of gridline a notation lane can render.
///
/// Raw values are stable, lowercase identifiers safe for persistence.
/// Strict decoding: an unknown raw value throws a `DecodingError`.
enum NotationGridlineKind: String, Equatable, Sendable, Codable {
    case bar
    case beat
    case subdivision
}

// MARK: - NotationGridlineGeometry

/// Renderer-ready position of a single gridline inside a
/// `NotationLaneViewport`.
///
/// - `kind` selects between `.bar`, `.beat`, and `.subdivision`.
/// - `time` is the absolute take time the gridline represents.
/// - `x` is the linear projection of `time` onto
///   `[0, viewport.width]`. Because the mapper only emits gridlines
///   for times within the viewport's `[startTime, endTime]`, `x` is
///   already in `[0, viewport.width]` without clamping.
struct NotationGridlineGeometry: Equatable, Sendable, Codable {
    let kind: NotationGridlineKind
    let time: TimeInterval
    let x: Double
}

// MARK: - NotationGridlineGeometryModel

/// Renderer-ready geometry for every visible gridline in a viewport,
/// in ascending time order.
struct NotationGridlineGeometryModel: Equatable, Sendable, Codable {
    let gridlines: [NotationGridlineGeometry]
}

// MARK: - NotationGridlineGeometryMapper

/// Pure, deterministic projection of `(TimingGrid, NotationLaneViewport)`
/// to a `NotationGridlineGeometryModel`.
///
/// **What the mapper does (and only this):**
///
/// - Walks the grid one subdivision at a time, starting at the
///   first subdivision boundary at or after `viewport.startTime`.
/// - Emits one `NotationGridlineGeometry` for each subdivision
///   boundary whose absolute `time` falls within
///   `[viewport.startTime, viewport.endTime]` (inclusive on both
///   ends).
/// - Classifies each boundary using its `GridPosition`:
///   - `beat == 0` and `subdivision == 0` → `.bar`
///   - `subdivision == 0` (but not bar) → `.beat`
///   - otherwise → `.subdivision`
/// - Maps `time` linearly onto `[0, viewport.width]`.
///
/// **What the mapper does not do:** no UI / Canvas / renderer call,
/// no ML, no scoring, no clock, no I/O, no mutation of inputs.
/// Phase / intermediate / fractional gridlines are intentionally
/// out of scope; only on-subdivision boundaries are emitted.
enum NotationGridlineGeometryMapper {

    static func makeGridlines(
        grid: TimingGrid,
        viewport: NotationLaneViewport
    ) -> NotationGridlineGeometryModel {
        let subSec = grid.secondsPerSubdivision
        let span = viewport.endTime - viewport.startTime

        // Find the smallest integer subdivision index whose absolute
        // time is ≥ viewport.startTime.
        let relative = (viewport.startTime - grid.origin) / subSec
        var subIndex = Int(ceil(relative))
        // Defensive: if floating-point rounding put the resolved time
        // a hair before viewport.startTime, bump until it isn't.
        while grid.origin + Double(subIndex) * subSec < viewport.startTime {
            subIndex += 1
        }

        var output: [NotationGridlineGeometry] = []
        while true {
            let time = grid.origin + Double(subIndex) * subSec
            if time > viewport.endTime { break }
            let position = grid.position(at: time)
            let kind: NotationGridlineKind
            if position.beat == 0 && position.subdivision == 0 {
                kind = .bar
            } else if position.subdivision == 0 {
                kind = .beat
            } else {
                kind = .subdivision
            }
            let normalized = (time - viewport.startTime) / span
            let x = normalized * viewport.width
            output.append(
                NotationGridlineGeometry(kind: kind, time: time, x: x)
            )
            subIndex += 1
        }
        return NotationGridlineGeometryModel(gridlines: output)
    }
}
