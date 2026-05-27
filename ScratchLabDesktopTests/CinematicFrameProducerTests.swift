import XCTest
@testable import ScratchLab

/// Phase D-X0 — locks the contract of `CinematicFrameProducer`: pure,
/// deterministic projection from `NotationReplayState` to a
/// `[CinematicFrame]` stream. No UI, no AVFoundation, no clock.
final class CinematicFrameProducerTests: XCTestCase {

    // MARK: - Helpers

    private func makeState(frames: [(Int, TimeInterval)]) -> NotationReplayState {
        let replayFrames: [NotationReplayFrame] = frames.compactMap { entry in
            NotationReplayFrame(index: entry.0, time: entry.1)
        }
        guard let state = NotationReplayState(
            contentStart: 0,
            contentEnd: 8,
            frames: replayFrames
        ) else {
            XCTFail("NotationReplayState init unexpectedly rejected")
            return NotationReplayState(contentStart: 0, contentEnd: 8, frames: [])!
        }
        return state
    }

    private func makeModel() -> NotationPresentationModel {
        NotationPresentationModel(strokes: [
            NotationPresentationStroke(
                primitiveIndex: 0, startTime: 0.5, endTime: 1.0,
                startPosition: nil, endPosition: nil,
                family: .baby, coachingKinds: []
            ),
            NotationPresentationStroke(
                primitiveIndex: 1, startTime: 2.0, endTime: 2.5,
                startPosition: nil, endPosition: nil,
                family: .chirp, coachingKinds: [.lateReversal]
            ),
        ])
    }

    private func makeGrid() -> TimingGrid {
        TimingGrid(beatsPerMinute: 120, beatsPerBar: 4,
                   subdivisionsPerBeat: 4, origin: 0)!
    }

    private func makeRule() -> NotationViewportWindowRule {
        NotationViewportWindowRule(duration: 4, leadIn: 1)!
    }

    // MARK: - Empty input

    func testEmptyStateProducesNoFrames() {
        let state = makeState(frames: [])
        let frames = CinematicFrameProducer.makeFrames(
            state: state,
            presentationModel: makeModel(),
            timingGrid: makeGrid(),
            viewportRule: makeRule(),
            width: 400,
            height: 200
        )
        XCTAssertEqual(frames, [])
    }

    // MARK: - One-to-one mapping

    func testFrameCountMatchesStateFrames() {
        let entries = (0..<5).map { ($0, Double($0) * 1.0) }
        let state = makeState(frames: entries)
        let frames = CinematicFrameProducer.makeFrames(
            state: state,
            presentationModel: makeModel(),
            timingGrid: makeGrid(),
            viewportRule: makeRule(),
            width: 400,
            height: 200
        )
        XCTAssertEqual(frames.count, entries.count)
        for (index, frame) in frames.enumerated() {
            XCTAssertEqual(frame.frame.index, entries[index].0)
            XCTAssertEqual(frame.frame.time, entries[index].1, accuracy: 1e-9)
        }
    }

    func testEachFrameMatchesDriverProjection() {
        let entries = (0..<3).map { ($0, Double($0) * 1.5) }
        let state = makeState(frames: entries)
        let model = makeModel()
        let grid = makeGrid()
        let rule = makeRule()
        let frames = CinematicFrameProducer.makeFrames(
            state: state,
            presentationModel: model,
            timingGrid: grid,
            viewportRule: rule,
            width: 400,
            height: 200
        )
        for (index, cinematic) in frames.enumerated() {
            let expected = NotationReplayDriver.project(
                frame: state.frames[index],
                state: state,
                presentationModel: model,
                timingGrid: grid,
                viewportRule: rule,
                width: 400,
                height: 200
            )
            XCTAssertEqual(cinematic.viewport, expected?.viewport)
            XCTAssertEqual(cinematic.laneGeometry, expected?.laneGeometry)
            XCTAssertEqual(cinematic.gridlineGeometry, expected?.gridlineGeometry)
            XCTAssertEqual(cinematic.playhead, expected?.playhead)
        }
    }

    // MARK: - Optional grid

    func testNilGridDropsGridlineGeometry() {
        let state = makeState(frames: [(0, 0.0), (1, 1.0)])
        let frames = CinematicFrameProducer.makeFrames(
            state: state,
            presentationModel: makeModel(),
            timingGrid: nil,
            viewportRule: makeRule(),
            width: 400,
            height: 200
        )
        XCTAssertTrue(frames.allSatisfy { $0.gridlineGeometry == nil })
    }

    // MARK: - Determinism

    func testDeterministicAcrossReruns() {
        let state = makeState(frames: (0..<7).map { ($0, Double($0) * 0.5) })
        let model = makeModel()
        let rule = makeRule()
        let first = CinematicFrameProducer.makeFrames(
            state: state, presentationModel: model,
            timingGrid: makeGrid(), viewportRule: rule,
            width: 400, height: 200
        )
        for _ in 0..<49 {
            let next = CinematicFrameProducer.makeFrames(
                state: state, presentationModel: model,
                timingGrid: makeGrid(), viewportRule: rule,
                width: 400, height: 200
            )
            XCTAssertEqual(next, first)
        }
    }

    // MARK: - Order preservation

    func testFrameOrderPreserved() {
        let entries = (0..<10).map { ($0, Double($0) * 0.6) }
        let state = makeState(frames: entries)
        let frames = CinematicFrameProducer.makeFrames(
            state: state,
            presentationModel: makeModel(),
            timingGrid: makeGrid(),
            viewportRule: makeRule(),
            width: 400,
            height: 200
        )
        let indices = frames.map { $0.frame.index }
        XCTAssertEqual(indices, indices.sorted())
    }
}
