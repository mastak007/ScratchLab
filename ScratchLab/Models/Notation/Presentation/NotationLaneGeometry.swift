import Foundation

// MARK: - NotationLaneViewport

/// A finite, validated window onto a notation lane in absolute time
/// and pixel-space units.
///
/// **Pure value type.** A viewport carries no view, no scaling
/// transform, no drawing intent — it's the parameter bundle a future
/// renderer would consume to lay out a `NotationLaneGeometryModel`.
///
/// **Invariants enforced at construction and decode time:**
///
/// - `startTime`, `endTime`, `width`, `height` are finite.
/// - `endTime > startTime`.
/// - `width > 0` and `height > 0`.
struct NotationLaneViewport: Equatable, Sendable, Codable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let width: Double
    let height: Double

    init?(startTime: TimeInterval, endTime: TimeInterval, width: Double, height: Double) {
        guard NotationLaneViewport.isValid(
            startTime: startTime,
            endTime: endTime,
            width: width,
            height: height
        ) else { return nil }
        self.startTime = startTime
        self.endTime = endTime
        self.width = width
        self.height = height
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case startTime, endTime, width, height
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let startTime = try container.decode(TimeInterval.self, forKey: .startTime)
        let endTime = try container.decode(TimeInterval.self, forKey: .endTime)
        let width = try container.decode(Double.self, forKey: .width)
        let height = try container.decode(Double.self, forKey: .height)
        guard NotationLaneViewport.isValid(
            startTime: startTime,
            endTime: endTime,
            width: width,
            height: height
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .startTime,
                in: container,
                debugDescription: "viewport requires finite startTime/endTime/width/height, endTime > startTime, width > 0, height > 0"
            )
        }
        self.startTime = startTime
        self.endTime = endTime
        self.width = width
        self.height = height
    }

    // MARK: Invariant check

    private static func isValid(
        startTime: TimeInterval,
        endTime: TimeInterval,
        width: Double,
        height: Double
    ) -> Bool {
        guard startTime.isFinite, endTime.isFinite,
              width.isFinite, height.isFinite else { return false }
        guard endTime > startTime else { return false }
        guard width > 0, height > 0 else { return false }
        return true
    }
}

// MARK: - NotationLaneStrokeGeometry

/// Renderer-ready geometry for a single presentation stroke. All
/// coordinates are in viewport pixel space.
///
/// - `xStart` / `xEnd` are the linear projection of the stroke's
///   start/end times onto `[0, viewport.width]`, clamped to that
///   range.
/// - `yStart` / `yEnd` select between two lane rails (low/high) based
///   on the stroke's time direction. Zero-duration or
///   direction-unknown strokes use the center rail for both.
/// - `family` and `coachingKinds` are passed through from the
///   presentation stroke without transformation.
struct NotationLaneStrokeGeometry: Equatable, Sendable, Codable {
    let primitiveIndex: Int
    let xStart: Double
    let xEnd: Double
    let yStart: Double
    let yEnd: Double
    let family: ScratchFamily?
    let coachingKinds: [CoachingEventKind]
}

// MARK: - NotationLaneGeometryModel

/// A renderer-ready geometry snapshot for an entire take, in
/// presentation-stroke order.
struct NotationLaneGeometryModel: Equatable, Sendable, Codable {
    let strokes: [NotationLaneStrokeGeometry]
}

// MARK: - NotationLaneGeometryMapper

/// Pure, deterministic projection of
/// `(NotationPresentationModel, NotationLaneViewport)` to a
/// `NotationLaneGeometryModel`.
///
/// **What the mapper does (and only this):**
///
/// - Emits one `NotationLaneStrokeGeometry` per input presentation
///   stroke, in input order.
/// - Maps stroke start/end times linearly into `[0, viewport.width]`
///   and clamps the result to that interval.
/// - Selects a y-pair from the viewport's three rails by the stroke's
///   time direction:
///   - `endTime > startTime` → `(0.25*h, 0.75*h)`
///   - `endTime < startTime` → `(0.75*h, 0.25*h)`
///   - `endTime == startTime` → `(0.5*h, 0.5*h)`
/// - Passes `family` and `coachingKinds` through unchanged.
///
/// **What the mapper does not do:** no UI / Canvas / renderer call,
/// no ML, no scoring, no clock, no I/O, no mutation of inputs.
enum NotationLaneGeometryMapper {

    static func makeGeometry(
        presentationModel: NotationPresentationModel,
        viewport: NotationLaneViewport
    ) -> NotationLaneGeometryModel {
        let span = viewport.endTime - viewport.startTime
        var strokes: [NotationLaneStrokeGeometry] = []
        strokes.reserveCapacity(presentationModel.strokes.count)
        for stroke in presentationModel.strokes {
            let xStart = mapX(time: stroke.startTime, viewport: viewport, span: span)
            let xEnd = mapX(time: stroke.endTime, viewport: viewport, span: span)
            let (yStart, yEnd) = rails(
                startTime: stroke.startTime,
                endTime: stroke.endTime,
                height: viewport.height
            )
            strokes.append(
                NotationLaneStrokeGeometry(
                    primitiveIndex: stroke.primitiveIndex,
                    xStart: xStart,
                    xEnd: xEnd,
                    yStart: yStart,
                    yEnd: yEnd,
                    family: stroke.family,
                    coachingKinds: stroke.coachingKinds
                )
            )
        }
        return NotationLaneGeometryModel(strokes: strokes)
    }

    // MARK: Helpers

    private static func mapX(
        time: TimeInterval,
        viewport: NotationLaneViewport,
        span: TimeInterval
    ) -> Double {
        let normalized = (time - viewport.startTime) / span
        let x = normalized * viewport.width
        return min(max(x, 0), viewport.width)
    }

    private static func rails(
        startTime: TimeInterval,
        endTime: TimeInterval,
        height: Double
    ) -> (Double, Double) {
        if endTime > startTime {
            return (height * 0.25, height * 0.75)
        } else if endTime < startTime {
            return (height * 0.75, height * 0.25)
        } else {
            let center = height * 0.5
            return (center, center)
        }
    }
}
