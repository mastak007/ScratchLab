#if DEBUG
import XCTest
@testable import ScratchLab

/// Section 8 / Slice 2 — locks the contract of the DEBUG-only
/// `DebugReviewNotationCard` synthetic data. The view itself is a
/// SwiftUI surface and is not exercised here; only the synthetic
/// target/captured presentation models, the shared replay state,
/// the rule, and the grid are asserted, plus the deterministic
/// projection of every frame against both lanes through
/// `NotationReplayDriver`. No SwiftUI hosting, no clock, no timer,
/// no AVFoundation, no Combine, no ML, no export.
final class DebugReviewNotationCardTests: XCTestCase {

    private static let laneWidth: Double = 400
    private static let laneHeight: Double = 80

    // MARK: - Synthetic data shape

    func testReplayStateHasStrictlyAscendingFramesWithinContentBounds() {
        let state = DebugReviewNotationCard.replayState
        XCTAssertEqual(state.contentStart, 0)
        XCTAssertEqual(state.contentEnd, 8)
        XCTAssertFalse(state.frames.isEmpty)

        var previousIndex: Int?
        for frame in state.frames {
            if let previousIndex {
                XCTAssertGreaterThan(frame.index, previousIndex,
                                     "frames must be strictly ascending by index")
            }
            previousIndex = frame.index
            XCTAssertTrue(frame.time.isFinite)
            XCTAssertGreaterThanOrEqual(frame.time, state.contentStart)
            XCTAssertLessThanOrEqual(frame.time, state.contentEnd)
        }
    }

    func testTargetAndCapturedPresentationsHaveMatchingStrokeCounts() {
        let target = DebugReviewNotationCard.targetPresentation
        let captured = DebugReviewNotationCard.capturedPresentation
        XCTAssertFalse(target.strokes.isEmpty)
        XCTAssertEqual(target.strokes.count, captured.strokes.count,
                       "synthetic Review preview pairs target/captured 1:1")
    }

    func testCapturedStrokesCarrySyntheticDriftRelativeToTarget() {
        let target = DebugReviewNotationCard.targetPresentation
        let captured = DebugReviewNotationCard.capturedPresentation
        var sawDrift = false
        for (t, c) in zip(target.strokes, captured.strokes) {
            XCTAssertEqual(t.primitiveIndex, c.primitiveIndex)
            if t.startTime != c.startTime { sawDrift = true }
        }
        XCTAssertTrue(sawDrift,
                      "captured lane must visibly drift against target to be useful as a preview")
    }

    func testReplayRuleAndGridAreWellFormed() {
        let rule = DebugReviewNotationCard.replayRule
        XCTAssertGreaterThan(rule.duration, 0)
        XCTAssertGreaterThanOrEqual(rule.leadIn, 0)

        let grid = DebugReviewNotationCard.replayGrid
        XCTAssertGreaterThan(grid.beatsPerMinute, 0)
        XCTAssertGreaterThan(grid.beatsPerBar, 0)
        XCTAssertGreaterThan(grid.subdivisionsPerBeat, 0)
        XCTAssertTrue(grid.origin.isFinite)
    }

    // MARK: - Projection determinism

    func testEveryFrameProjectsAgainstBothLanes() throws {
        let state = DebugReviewNotationCard.replayState
        for presentation in [
            DebugReviewNotationCard.targetPresentation,
            DebugReviewNotationCard.capturedPresentation,
        ] {
            for frame in state.frames {
                let projection = NotationReplayDriver.project(
                    frame: frame,
                    state: state,
                    presentationModel: presentation,
                    timingGrid: DebugReviewNotationCard.replayGrid,
                    viewportRule: DebugReviewNotationCard.replayRule,
                    width: Self.laneWidth,
                    height: Self.laneHeight
                )
                let unwrapped = try XCTUnwrap(projection,
                                              "frame \(frame.index) at t=\(frame.time) failed to project")
                XCTAssertEqual(unwrapped.viewport.width, Self.laneWidth)
                XCTAssertEqual(unwrapped.viewport.height, Self.laneHeight)
                XCTAssertNotNil(unwrapped.gridlineGeometry)
                XCTAssertNotNil(unwrapped.playhead)
                XCTAssertEqual(unwrapped.playhead?.time, frame.time)
            }
        }
    }

    func testRepeatedProjectionIsByteIdenticalAcrossBothLanes() {
        let state = DebugReviewNotationCard.replayState
        let frame = state.frames[state.frames.count / 2]
        for presentation in [
            DebugReviewNotationCard.targetPresentation,
            DebugReviewNotationCard.capturedPresentation,
        ] {
            let first = NotationReplayDriver.project(
                frame: frame,
                state: state,
                presentationModel: presentation,
                timingGrid: DebugReviewNotationCard.replayGrid,
                viewportRule: DebugReviewNotationCard.replayRule,
                width: Self.laneWidth,
                height: Self.laneHeight
            )
            let second = NotationReplayDriver.project(
                frame: frame,
                state: state,
                presentationModel: presentation,
                timingGrid: DebugReviewNotationCard.replayGrid,
                viewportRule: DebugReviewNotationCard.replayRule,
                width: Self.laneWidth,
                height: Self.laneHeight
            )
            XCTAssertEqual(first, second)
        }
    }

    func testTargetAndCapturedProjectionsDifferAtAnyFrameWhereDriftLandsInsideViewport() throws {
        // The captured lane has alternating early/late drift relative
        // to target, so at least one frame's lane geometry must differ
        // between the two presentations once the strokes are mapped
        // into the same viewport.
        let state = DebugReviewNotationCard.replayState
        var sawDifference = false
        for frame in state.frames {
            let targetProj = NotationReplayDriver.project(
                frame: frame,
                state: state,
                presentationModel: DebugReviewNotationCard.targetPresentation,
                timingGrid: DebugReviewNotationCard.replayGrid,
                viewportRule: DebugReviewNotationCard.replayRule,
                width: Self.laneWidth,
                height: Self.laneHeight
            )
            let capturedProj = NotationReplayDriver.project(
                frame: frame,
                state: state,
                presentationModel: DebugReviewNotationCard.capturedPresentation,
                timingGrid: DebugReviewNotationCard.replayGrid,
                viewportRule: DebugReviewNotationCard.replayRule,
                width: Self.laneWidth,
                height: Self.laneHeight
            )
            if targetProj?.laneGeometry != capturedProj?.laneGeometry {
                sawDifference = true
                break
            }
        }
        XCTAssertTrue(sawDifference,
                      "synthetic drift must produce at least one differing lane projection across the frame sweep")
    }
}
#endif
