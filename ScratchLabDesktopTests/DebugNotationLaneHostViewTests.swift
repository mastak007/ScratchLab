#if DEBUG
import XCTest
@testable import ScratchLab

/// Section 7 / Slice 3 — locks the contract of the DEBUG-only
/// replay-stepper data on `DebugNotationLaneHostView`. The view
/// itself is a SwiftUI surface and is not exercised here; only the
/// synthetic replay state, presentation, grid, and rule are
/// asserted, plus the deterministic projection of every frame
/// through `NotationReplayDriver`. No SwiftUI hosting, no clock,
/// no timer, no AVFoundation, no Combine, no ML, no export.
final class DebugNotationLaneHostViewTests: XCTestCase {

    private static let laneWidth: Double = 400
    private static let laneHeight: Double = 200

    // MARK: - Synthetic state shape

    func testReplayStateHasStrictlyAscendingFramesWithinContentBounds() {
        let state = DebugNotationLaneHostView.replayState
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

    func testReplayPresentationHasNonEmptyDeterministicStrokeSet() {
        let model = DebugNotationLaneHostView.replayPresentation
        XCTAssertFalse(model.strokes.isEmpty)
        XCTAssertEqual(model.strokes.map(\.primitiveIndex),
                       model.strokes.map(\.primitiveIndex).sorted())
        for stroke in model.strokes {
            XCTAssertTrue(stroke.startTime.isFinite)
            XCTAssertTrue(stroke.endTime.isFinite)
        }
    }

    func testReplayRuleAndGridAreWellFormed() {
        let rule = DebugNotationLaneHostView.replayRule
        XCTAssertGreaterThan(rule.duration, 0)
        XCTAssertGreaterThanOrEqual(rule.leadIn, 0)

        let grid = DebugNotationLaneHostView.replayGrid
        XCTAssertGreaterThan(grid.beatsPerMinute, 0)
        XCTAssertGreaterThan(grid.beatsPerBar, 0)
        XCTAssertGreaterThan(grid.subdivisionsPerBeat, 0)
        XCTAssertTrue(grid.origin.isFinite)
    }

    // MARK: - Projection determinism

    func testEveryFrameProjectsSuccessfully() throws {
        let state = DebugNotationLaneHostView.replayState
        for frame in state.frames {
            let projection = NotationReplayDriver.project(
                frame: frame,
                state: state,
                presentationModel: DebugNotationLaneHostView.replayPresentation,
                timingGrid: DebugNotationLaneHostView.replayGrid,
                viewportRule: DebugNotationLaneHostView.replayRule,
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

    func testRepeatedProjectionIsByteIdentical() {
        let state = DebugNotationLaneHostView.replayState
        let frame = state.frames[state.frames.count / 2]
        let first = NotationReplayDriver.project(
            frame: frame,
            state: state,
            presentationModel: DebugNotationLaneHostView.replayPresentation,
            timingGrid: DebugNotationLaneHostView.replayGrid,
            viewportRule: DebugNotationLaneHostView.replayRule,
            width: Self.laneWidth,
            height: Self.laneHeight
        )
        let second = NotationReplayDriver.project(
            frame: frame,
            state: state,
            presentationModel: DebugNotationLaneHostView.replayPresentation,
            timingGrid: DebugNotationLaneHostView.replayGrid,
            viewportRule: DebugNotationLaneHostView.replayRule,
            width: Self.laneWidth,
            height: Self.laneHeight
        )
        XCTAssertEqual(first, second)
    }

    // MARK: - Preset enumeration

    func testReplayIsAvailableAsAPreset() {
        let names = DebugNotationLaneHostView.Preset.allCases.map(\.rawValue)
        XCTAssertTrue(names.contains("replay"),
                      "`.replay` preset must remain advertised by the host's segmented picker")
        // Empty/simple/dense remain alongside the new replay preset.
        XCTAssertTrue(names.contains("empty"))
        XCTAssertTrue(names.contains("simple"))
        XCTAssertTrue(names.contains("dense"))
    }

    // MARK: - Adapter-backed replay sources

    func testReplaySourceEnumeratesHandBuiltAndBothAdapters() {
        let names = DebugNotationLaneHostView.ReplaySource.allCases.map(\.rawValue)
        XCTAssertEqual(Set(names),
                       Set(["handBuilt", "scratchNotation", "sessionReplay"]),
                       "replay source toggle must advertise the hand-built default plus both adapter-backed feeds")
    }

    func testScratchNotationAdapterPresentationMatchesFixtureShape() {
        let fixture = DebugNotationLaneHostView.scratchNotationFixture
        let model = DebugNotationLaneHostView.scratchNotationReplayPresentation
        XCTAssertEqual(model.strokes.count, fixture.strokes.count)
        XCTAssertEqual(model.strokes.map(\.primitiveIndex),
                       Array(0..<fixture.strokes.count))
        XCTAssertEqual(model.strokes.map(\.startTime),
                       fixture.strokes.map(\.startTime))
        XCTAssertEqual(model.strokes.map(\.endTime),
                       fixture.strokes.map(\.endTime))
        XCTAssertTrue(model.strokes.allSatisfy { $0.startPosition == nil })
        XCTAssertTrue(model.strokes.allSatisfy { $0.endPosition == nil })
        XCTAssertTrue(model.strokes.allSatisfy { $0.family == nil })
        XCTAssertTrue(model.strokes.allSatisfy { $0.coachingKinds.isEmpty })
    }

    func testSessionReplayAdapterPresentationMatchesFixtureShape() {
        let fixture = DebugNotationLaneHostView.sessionReplayFixture
        let model = DebugNotationLaneHostView.sessionReplayPresentation
        XCTAssertEqual(model.strokes.count, fixture.events.count)
        XCTAssertEqual(model.strokes.map(\.primitiveIndex),
                       Array(0..<fixture.events.count))
        XCTAssertEqual(model.strokes.map(\.startTime),
                       fixture.events.map(\.startTime))
        XCTAssertEqual(model.strokes.map(\.endTime),
                       fixture.events.map { $0.endTime ?? $0.startTime })
        XCTAssertTrue(model.strokes.allSatisfy { $0.startPosition == nil })
        XCTAssertTrue(model.strokes.allSatisfy { $0.endPosition == nil })
        XCTAssertTrue(model.strokes.allSatisfy { $0.family == nil })
        XCTAssertTrue(model.strokes.allSatisfy { $0.coachingKinds.isEmpty })
    }

    func testAdapterBackedPresentationsAreDeterministicAcrossRebuilds() {
        let scratchA = ScratchNotationPresentationAdapter.makeModel(
            from: DebugNotationLaneHostView.scratchNotationFixture
        )
        let scratchB = ScratchNotationPresentationAdapter.makeModel(
            from: DebugNotationLaneHostView.scratchNotationFixture
        )
        XCTAssertEqual(scratchA, DebugNotationLaneHostView.scratchNotationReplayPresentation)
        XCTAssertEqual(scratchA, scratchB)

        let sessionA = SessionReplayPresentationAdapter.makeModel(
            from: DebugNotationLaneHostView.sessionReplayFixture
        )
        let sessionB = SessionReplayPresentationAdapter.makeModel(
            from: DebugNotationLaneHostView.sessionReplayFixture
        )
        XCTAssertEqual(sessionA, DebugNotationLaneHostView.sessionReplayPresentation)
        XCTAssertEqual(sessionA, sessionB)
    }

    func testEveryFrameProjectsForEachAdapterBackedSource() throws {
        let state = DebugNotationLaneHostView.replayState
        for source in [
            DebugNotationLaneHostView.scratchNotationReplayPresentation,
            DebugNotationLaneHostView.sessionReplayPresentation,
        ] {
            for frame in state.frames {
                let projection = NotationReplayDriver.project(
                    frame: frame,
                    state: state,
                    presentationModel: source,
                    timingGrid: DebugNotationLaneHostView.replayGrid,
                    viewportRule: DebugNotationLaneHostView.replayRule,
                    width: Self.laneWidth,
                    height: Self.laneHeight
                )
                let unwrapped = try XCTUnwrap(projection,
                                              "frame \(frame.index) at t=\(frame.time) failed to project for adapter-backed source")
                XCTAssertEqual(unwrapped.viewport.width, Self.laneWidth)
                XCTAssertEqual(unwrapped.viewport.height, Self.laneHeight)
                XCTAssertNotNil(unwrapped.gridlineGeometry)
                XCTAssertNotNil(unwrapped.playhead)
                XCTAssertEqual(unwrapped.playhead?.time, frame.time)
            }
        }
    }
}
#endif
