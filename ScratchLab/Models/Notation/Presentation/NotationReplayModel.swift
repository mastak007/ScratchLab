import Foundation

// MARK: - NotationReplayFrame

/// A single deterministic position on a `NotationReplayState`.
///
/// **Pure value type.** A frame carries no clock, no timer, no
/// playback state — it is the `(index, time)` pair a future stepper
/// (or a deterministic test) hands to `NotationReplayDriver` to
/// project Section 5 geometry.
///
/// `index` is the frame's position within the enclosing
/// `NotationReplayState.frames` array. It is the deterministic
/// identity used by tie-breaking, sort ordering, and persistence —
/// not a derived value.
///
/// `time` is the absolute take time the frame represents. It may
/// fall outside `[contentStart, contentEnd]`; downstream mappers
/// (viewport / playhead) clamp visually so an out-of-range frame
/// still projects to a valid `NotationReplayProjection`.
///
/// **Invariants enforced at construction and decode time:**
///
/// - `index >= 0`.
/// - `time` is finite.
struct NotationReplayFrame: Equatable, Sendable, Codable {
    let index: Int
    let time: TimeInterval

    init?(index: Int, time: TimeInterval) {
        guard NotationReplayFrame.isValid(index: index, time: time) else {
            return nil
        }
        self.index = index
        self.time = time
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case index, time
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let index = try container.decode(Int.self, forKey: .index)
        let time = try container.decode(TimeInterval.self, forKey: .time)
        guard NotationReplayFrame.isValid(index: index, time: time) else {
            throw DecodingError.dataCorruptedError(
                forKey: .index,
                in: container,
                debugDescription: "frame requires index ≥ 0 and finite time, got index=\(index), time=\(time)"
            )
        }
        self.index = index
        self.time = time
    }

    private static func isValid(index: Int, time: TimeInterval) -> Bool {
        guard index >= 0 else { return false }
        guard time.isFinite else { return false }
        return true
    }
}

// MARK: - NotationReplayState

/// Immutable description of a notation replay timeline.
///
/// **Pure value type.** A state carries the absolute content bounds
/// of the take plus a strictly-ordered, deduplicated list of
/// `NotationReplayFrame`s. It does not own a playhead, a cursor, or
/// any mutable position.
///
/// **Invariants enforced at construction and decode time:**
///
/// - `contentStart` and `contentEnd` are finite.
/// - `contentEnd > contentStart`.
/// - `frames.map(\.index)` is strictly ascending (sorted, no duplicates).
///
/// An empty `frames` array is allowed — a state with no frames is a
/// valid container; callers that try to project a frame against it
/// must already have a `NotationReplayFrame` from elsewhere.
struct NotationReplayState: Equatable, Sendable, Codable {
    let contentStart: TimeInterval
    let contentEnd: TimeInterval
    let frames: [NotationReplayFrame]

    init?(contentStart: TimeInterval,
          contentEnd: TimeInterval,
          frames: [NotationReplayFrame]) {
        guard NotationReplayState.isValid(
            contentStart: contentStart,
            contentEnd: contentEnd,
            frames: frames
        ) else { return nil }
        self.contentStart = contentStart
        self.contentEnd = contentEnd
        self.frames = frames
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case contentStart, contentEnd, frames
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let contentStart = try container.decode(TimeInterval.self, forKey: .contentStart)
        let contentEnd = try container.decode(TimeInterval.self, forKey: .contentEnd)
        let frames = try container.decode([NotationReplayFrame].self, forKey: .frames)
        guard NotationReplayState.isValid(
            contentStart: contentStart,
            contentEnd: contentEnd,
            frames: frames
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .contentStart,
                in: container,
                debugDescription: "state requires finite content bounds with contentEnd > contentStart and strictly ascending frame indices"
            )
        }
        self.contentStart = contentStart
        self.contentEnd = contentEnd
        self.frames = frames
    }

    private static func isValid(
        contentStart: TimeInterval,
        contentEnd: TimeInterval,
        frames: [NotationReplayFrame]
    ) -> Bool {
        guard contentStart.isFinite, contentEnd.isFinite else { return false }
        guard contentEnd > contentStart else { return false }
        var previous: Int?
        for frame in frames {
            if let previous, frame.index <= previous { return false }
            previous = frame.index
        }
        return true
    }
}

// MARK: - NotationReplayProjection

/// Renderer-ready bundle of the four Section 5 geometry models for a
/// single replay frame.
///
/// **Pure value type.** No view, no rendering, no animation state.
/// A future debug host or scrubber consumes this bundle and hands it
/// straight to `NotationLaneGeometryView`.
///
/// - `viewport` is the `NotationLaneViewport` derived by the window
///   mapper for this frame's time.
/// - `laneGeometry` is the lane geometry projected from the supplied
///   presentation model into `viewport`.
/// - `gridlineGeometry` is `nil` when no `TimingGrid` was supplied
///   to the driver, otherwise the gridline geometry for `viewport`.
/// - `playhead` is the playhead geometry for the frame's time inside
///   `viewport`. May be `nil` only if `NotationPlayheadGeometryMapper`
///   rejects the inputs — which today happens only for non-finite
///   time, and `NotationReplayFrame` already guards that.
struct NotationReplayProjection: Equatable, Sendable, Codable {
    let viewport: NotationLaneViewport
    let laneGeometry: NotationLaneGeometryModel
    let gridlineGeometry: NotationGridlineGeometryModel?
    let playhead: NotationPlayheadGeometry?
}

// MARK: - NotationReplayDriver

/// Pure, deterministic projection of
/// `(frame, state, presentationModel, timingGrid?, viewportRule,
/// width, height)` to a `NotationReplayProjection`.
///
/// **What the driver does (and only this):**
///
/// - Calls `NotationViewportWindowMapper.viewport(around:...)` with
///   `frame.time` and the state's content bounds. Returns `nil` if
///   that mapper returns `nil` (the only failure path).
/// - Calls `NotationLaneGeometryMapper.makeGeometry(...)` with the
///   supplied presentation model and resolved viewport.
/// - Calls `NotationGridlineGeometryMapper.makeGridlines(...)` only
///   when `timingGrid != nil`; otherwise leaves `gridlineGeometry`
///   `nil`.
/// - Calls `NotationPlayheadGeometryMapper.makePlayhead(time:viewport:)`
///   with `frame.time` and the resolved viewport.
///
/// **What the driver does not do:** no UI / Canvas / renderer call,
/// no clock, no timer, no AVFoundation, no Combine, no I/O, no ML,
/// no scoring, no mutation of inputs. Frames whose `time` falls
/// outside `[contentStart, contentEnd]` are not rejected — the
/// downstream mappers clamp the viewport to content and clamp the
/// playhead's `x` to `[0, viewport.width]`.
enum NotationReplayDriver {

    static func project(
        frame: NotationReplayFrame,
        state: NotationReplayState,
        presentationModel: NotationPresentationModel,
        timingGrid: TimingGrid?,
        viewportRule: NotationViewportWindowRule,
        width: Double,
        height: Double
    ) -> NotationReplayProjection? {
        guard let viewport = NotationViewportWindowMapper.viewport(
            around: frame.time,
            contentStart: state.contentStart,
            contentEnd: state.contentEnd,
            width: width,
            height: height,
            rule: viewportRule
        ) else {
            return nil
        }
        let laneGeometry = NotationLaneGeometryMapper.makeGeometry(
            presentationModel: presentationModel,
            viewport: viewport
        )
        let gridlineGeometry: NotationGridlineGeometryModel?
        if let timingGrid {
            gridlineGeometry = NotationGridlineGeometryMapper.makeGridlines(
                grid: timingGrid,
                viewport: viewport
            )
        } else {
            gridlineGeometry = nil
        }
        let playhead = NotationPlayheadGeometryMapper.makePlayhead(
            time: frame.time,
            viewport: viewport
        )
        return NotationReplayProjection(
            viewport: viewport,
            laneGeometry: laneGeometry,
            gridlineGeometry: gridlineGeometry,
            playhead: playhead
        )
    }
}
