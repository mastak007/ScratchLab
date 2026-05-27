import Foundation

// MARK: - CinematicFrame

/// One frame of the cinematic-export / spatial-replay pipeline.
///
/// Carries the same projected geometry the on-screen replay
/// already uses (lane, gridlines, playhead, viewport) plus the source
/// `NotationReplayFrame` so consumers can correlate exported frames
/// back to the deterministic frame model. Pure value type — no UI,
/// no AVFoundation, no RealityKit, no clock.
struct CinematicFrame: Equatable, Sendable {
    let frame: NotationReplayFrame
    let viewport: NotationLaneViewport
    let laneGeometry: NotationLaneGeometryModel
    let gridlineGeometry: NotationGridlineGeometryModel?
    let playhead: NotationPlayheadGeometry?
}

// MARK: - CinematicFrameProducer

/// Pure, deterministic producer of a frame stream from a notation
/// replay session. Composes `NotationReplayDriver.project(...)` over
/// every `NotationReplayFrame` in the supplied `NotationReplayState`
/// to yield a `[CinematicFrame]` consumable by either:
///
/// - a macOS video encoder (D-X1 notation overlay export, D-X2 phrase
///   comparison, D-X3 cinematic replay), or
/// - a 3D renderer (Phase D-S spatial replay).
///
/// **What the producer does (and only this):**
///
/// - Iterates frames in `state.frames` order.
/// - For each frame, calls `NotationReplayDriver.project(...)` with the
///   supplied `presentationModel`, optional `timingGrid`,
///   `viewportRule`, and pixel `(width, height)`.
/// - Drops any frame whose projection returns `nil` (matches the
///   driver's existing contract: same input → same drop set).
/// - Preserves frame index order in the output.
///
/// **What the producer does not do:** no UI, no AVFoundation, no
/// `RealityKit`, no `ARKit`, no `Combine`, no clock, no I/O, no
/// mutation of inputs. Forbidden imports are absent at module level
/// per the Phase D-X verification gate.
///
/// Same inputs → byte-identical output across calls — the determinism
/// gate that D-X1's deterministic re-export test ultimately rests on.
enum CinematicFrameProducer {

    static func makeFrames(
        state: NotationReplayState,
        presentationModel: NotationPresentationModel,
        timingGrid: TimingGrid?,
        viewportRule: NotationViewportWindowRule,
        width: Double,
        height: Double
    ) -> [CinematicFrame] {
        var output: [CinematicFrame] = []
        output.reserveCapacity(state.frames.count)
        for frame in state.frames {
            guard let projection = NotationReplayDriver.project(
                frame: frame,
                state: state,
                presentationModel: presentationModel,
                timingGrid: timingGrid,
                viewportRule: viewportRule,
                width: width,
                height: height
            ) else {
                continue
            }
            output.append(
                CinematicFrame(
                    frame: frame,
                    viewport: projection.viewport,
                    laneGeometry: projection.laneGeometry,
                    gridlineGeometry: projection.gridlineGeometry,
                    playhead: projection.playhead
                )
            )
        }
        return output
    }
}
