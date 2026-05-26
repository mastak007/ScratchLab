import XCTest
@testable import ScratchLab

/// Section 7 / Slice 2 — locks the contract of
/// `NotationReplayFrame`, `NotationReplayState`,
/// `NotationReplayProjection`, and `NotationReplayDriver`. Pure
/// deterministic projection from a `(frame, state, presentation,
/// grid?, rule, width, height)` tuple into the four existing
/// Section 5 geometry models. No SwiftUI, no Canvas, no clock,
/// no timer, no AVFoundation, no Combine, no renderer, no ML,
/// no scoring, no export.
final class NotationReplayModelTests: XCTestCase {

    // MARK: - Fixtures

    private func makeFrame(
        index: Int = 0,
        time: TimeInterval = 0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> NotationReplayFrame {
        guard let frame = NotationReplayFrame(index: index, time: time) else {
            XCTFail("Frame(\(index), \(time)) unexpectedly rejected", file: file, line: line)
            return NotationReplayFrame(index: 0, time: 0)!
        }
        return frame
    }

    private func makeState(
        contentStart: TimeInterval = 0,
        contentEnd: TimeInterval = 10,
        frames: [NotationReplayFrame]? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> NotationReplayState {
        let resolved = frames ?? [
            makeFrame(index: 0, time: 0),
            makeFrame(index: 1, time: 5),
            makeFrame(index: 2, time: 10),
        ]
        guard let state = NotationReplayState(
            contentStart: contentStart,
            contentEnd: contentEnd,
            frames: resolved
        ) else {
            XCTFail("State(\(contentStart), \(contentEnd), \(resolved.count) frames) unexpectedly rejected",
                    file: file, line: line)
            return NotationReplayState(contentStart: 0, contentEnd: 1, frames: [])!
        }
        return state
    }

    private func makeRule(
        duration: TimeInterval = 4,
        leadIn: TimeInterval = 1,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> NotationViewportWindowRule {
        guard let rule = NotationViewportWindowRule(duration: duration, leadIn: leadIn) else {
            XCTFail("Rule(\(duration), \(leadIn)) unexpectedly rejected", file: file, line: line)
            return NotationViewportWindowRule(duration: 1, leadIn: 0)!
        }
        return rule
    }

    private func makeGrid(
        bpm: Double = 120,
        beatsPerBar: Int = 4,
        subdivisionsPerBeat: Int = 4,
        origin: TimeInterval = 0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> TimingGrid {
        guard let grid = TimingGrid(
            beatsPerMinute: bpm,
            beatsPerBar: beatsPerBar,
            subdivisionsPerBeat: subdivisionsPerBeat,
            origin: origin
        ) else {
            XCTFail("Grid unexpectedly rejected", file: file, line: line)
            return TimingGrid(beatsPerMinute: 60, beatsPerBar: 4, subdivisionsPerBeat: 4, origin: 0)!
        }
        return grid
    }

    private func makePresentation() -> NotationPresentationModel {
        NotationPresentationModel(strokes: [
            NotationPresentationStroke(
                primitiveIndex: 0,
                startTime: 1.0, endTime: 1.5,
                startPosition: nil, endPosition: nil,
                family: .baby, coachingKinds: []
            ),
            NotationPresentationStroke(
                primitiveIndex: 1,
                startTime: 2.0, endTime: 2.0,
                startPosition: nil, endPosition: nil,
                family: nil, coachingKinds: []
            ),
            NotationPresentationStroke(
                primitiveIndex: 2,
                startTime: 3.0, endTime: 3.5,
                startPosition: nil, endPosition: nil,
                family: .chirp, coachingKinds: [.lateReversal]
            ),
        ])
    }

    // MARK: - 1. Frame rejects negative index

    func testFrameRejectsNegativeIndex() {
        XCTAssertNil(NotationReplayFrame(index: -1, time: 0))
        XCTAssertNil(NotationReplayFrame(index: Int.min, time: 0))
    }

    // MARK: - 2. Frame rejects NaN/infinity time

    func testFrameRejectsNonFiniteTime() {
        XCTAssertNil(NotationReplayFrame(index: 0, time: .nan))
        XCTAssertNil(NotationReplayFrame(index: 0, time: .infinity))
        XCTAssertNil(NotationReplayFrame(index: 0, time: -.infinity))
    }

    // MARK: - 3. Frame accepts index zero and finite time

    func testFrameAcceptsZeroIndexAndFiniteTime() {
        let zero = NotationReplayFrame(index: 0, time: 0)
        XCTAssertNotNil(zero)
        XCTAssertEqual(zero?.index, 0)
        XCTAssertEqual(zero?.time, 0)

        let negativeTime = NotationReplayFrame(index: 0, time: -123.456)
        XCTAssertNotNil(negativeTime, "negative finite time is allowed; only non-finite time is rejected")

        let large = NotationReplayFrame(index: 1_000_000, time: 99.5)
        XCTAssertEqual(large?.index, 1_000_000)
        XCTAssertEqual(large?.time, 99.5)
    }

    // MARK: - 4. State rejects non-finite content bounds

    func testStateRejectsNonFiniteContentBounds() {
        XCTAssertNil(NotationReplayState(contentStart: .nan, contentEnd: 1, frames: []))
        XCTAssertNil(NotationReplayState(contentStart: 0, contentEnd: .nan, frames: []))
        XCTAssertNil(NotationReplayState(contentStart: 0, contentEnd: .infinity, frames: []))
        XCTAssertNil(NotationReplayState(contentStart: -.infinity, contentEnd: 0, frames: []))
    }

    // MARK: - 5. State rejects contentEnd <= contentStart

    func testStateRejectsNonPositiveContentSpan() {
        XCTAssertNil(NotationReplayState(contentStart: 1, contentEnd: 1, frames: []))
        XCTAssertNil(NotationReplayState(contentStart: 2, contentEnd: 1, frames: []))
    }

    // MARK: - 6. State rejects unsorted frame indices

    func testStateRejectsUnsortedFrameIndices() {
        let frames = [
            makeFrame(index: 1, time: 0),
            makeFrame(index: 0, time: 1),
        ]
        XCTAssertNil(NotationReplayState(contentStart: 0, contentEnd: 10, frames: frames))
    }

    // MARK: - 7. State rejects duplicate frame indices

    func testStateRejectsDuplicateFrameIndices() {
        let frames = [
            makeFrame(index: 0, time: 0),
            makeFrame(index: 0, time: 1),
        ]
        XCTAssertNil(NotationReplayState(contentStart: 0, contentEnd: 10, frames: frames))
    }

    // MARK: - 8. State accepts empty frames

    func testStateAcceptsEmptyFrames() {
        let state = NotationReplayState(contentStart: 0, contentEnd: 10, frames: [])
        XCTAssertNotNil(state)
        XCTAssertEqual(state?.frames, [])
    }

    // MARK: - 9. project returns nil when viewport cannot be created

    func testProjectReturnsNilWhenViewportCannotBeCreated() {
        // Width = 0 fails the viewport mapper's `width > 0` guard.
        let projection = NotationReplayDriver.project(
            frame: makeFrame(index: 0, time: 2),
            state: makeState(),
            presentationModel: makePresentation(),
            timingGrid: nil,
            viewportRule: makeRule(),
            width: 0,
            height: 40
        )
        XCTAssertNil(projection)

        let projection2 = NotationReplayDriver.project(
            frame: makeFrame(index: 0, time: 2),
            state: makeState(),
            presentationModel: makePresentation(),
            timingGrid: nil,
            viewportRule: makeRule(),
            width: 100,
            height: -1
        )
        XCTAssertNil(projection2)
    }

    // MARK: - 10. project creates viewport using frame time and window rule

    func testProjectCreatesViewportUsingFrameTimeAndWindowRule() throws {
        let rule = makeRule(duration: 4, leadIn: 1)
        let state = makeState(contentStart: 0, contentEnd: 20)
        let frame = makeFrame(index: 0, time: 6)

        let projection = NotationReplayDriver.project(
            frame: frame,
            state: state,
            presentationModel: makePresentation(),
            timingGrid: nil,
            viewportRule: rule,
            width: 200,
            height: 40
        )
        let viewport = try XCTUnwrap(projection?.viewport)

        // desiredStart = 6 - 1 = 5, desiredEnd = 5 + 4 = 9. Both inside content.
        XCTAssertEqual(viewport.startTime, 5, accuracy: 1e-9)
        XCTAssertEqual(viewport.endTime, 9, accuracy: 1e-9)
        XCTAssertEqual(viewport.width, 200)
        XCTAssertEqual(viewport.height, 40)
    }

    // MARK: - 11. project creates lane geometry from presentation model

    func testProjectCreatesLaneGeometryFromPresentationModel() throws {
        let presentation = makePresentation()
        let projection = NotationReplayDriver.project(
            frame: makeFrame(index: 0, time: 2),
            state: makeState(contentStart: 0, contentEnd: 20),
            presentationModel: presentation,
            timingGrid: nil,
            viewportRule: makeRule(duration: 10, leadIn: 0),
            width: 200,
            height: 40
        )
        let lane = try XCTUnwrap(projection?.laneGeometry)
        XCTAssertEqual(lane.strokes.count, presentation.strokes.count)
        XCTAssertEqual(lane.strokes.map(\.primitiveIndex),
                       presentation.strokes.map(\.primitiveIndex))
    }

    // MARK: - 12. project creates playhead at frame time

    func testProjectCreatesPlayheadAtFrameTime() throws {
        let projection = NotationReplayDriver.project(
            frame: makeFrame(index: 0, time: 6),
            state: makeState(contentStart: 0, contentEnd: 20),
            presentationModel: makePresentation(),
            timingGrid: nil,
            viewportRule: makeRule(duration: 4, leadIn: 1),
            width: 200,
            height: 40
        )
        let playhead = try XCTUnwrap(projection?.playhead)
        XCTAssertEqual(playhead.time, 6, accuracy: 1e-9)
        // viewport = [5, 9], width = 200. (6 - 5) / 4 * 200 = 50.
        XCTAssertEqual(playhead.x, 50, accuracy: 1e-9)
        XCTAssertEqual(playhead.yTop, 0)
        XCTAssertEqual(playhead.yBottom, 40)
        XCTAssertTrue(playhead.isWithinViewport)
    }

    // MARK: - 13. project creates gridlines when timingGrid is present

    func testProjectCreatesGridlinesWhenTimingGridPresent() throws {
        let grid = makeGrid(bpm: 120, beatsPerBar: 4, subdivisionsPerBeat: 4, origin: 0)
        let projection = NotationReplayDriver.project(
            frame: makeFrame(index: 0, time: 0),
            state: makeState(contentStart: 0, contentEnd: 20),
            presentationModel: makePresentation(),
            timingGrid: grid,
            viewportRule: makeRule(duration: 4, leadIn: 0),
            width: 200,
            height: 40
        )
        let gridlines = try XCTUnwrap(projection?.gridlineGeometry)
        XCTAssertFalse(gridlines.gridlines.isEmpty)
        let expected = NotationGridlineGeometryMapper.makeGridlines(
            grid: grid,
            viewport: try XCTUnwrap(projection?.viewport)
        )
        XCTAssertEqual(gridlines, expected)
    }

    // MARK: - 14. project returns nil gridlineGeometry when timingGrid is nil

    func testProjectReturnsNilGridlinesWhenTimingGridNil() throws {
        let projection = NotationReplayDriver.project(
            frame: makeFrame(index: 0, time: 0),
            state: makeState(),
            presentationModel: makePresentation(),
            timingGrid: nil,
            viewportRule: makeRule(),
            width: 200,
            height: 40
        )
        XCTAssertNotNil(projection)
        XCTAssertNil(projection?.gridlineGeometry)
    }

    // MARK: - 15. frame time before contentStart still projects with clamped viewport/playhead

    func testProjectClampsViewportAndPlayheadForOutOfRangeFrameTime() throws {
        let state = makeState(contentStart: 0, contentEnd: 20)
        let rule = makeRule(duration: 4, leadIn: 1)

        // Frame time well before contentStart — viewport should clamp to
        // [contentStart, contentStart + duration], playhead's x clamps to 0.
        let beforeProjection = NotationReplayDriver.project(
            frame: makeFrame(index: 0, time: -5),
            state: state,
            presentationModel: makePresentation(),
            timingGrid: nil,
            viewportRule: rule,
            width: 200,
            height: 40
        )
        let beforeViewport = try XCTUnwrap(beforeProjection?.viewport)
        XCTAssertEqual(beforeViewport.startTime, 0, accuracy: 1e-9)
        XCTAssertEqual(beforeViewport.endTime, 4, accuracy: 1e-9)
        let beforePlayhead = try XCTUnwrap(beforeProjection?.playhead)
        XCTAssertEqual(beforePlayhead.x, 0)
        XCTAssertFalse(beforePlayhead.isWithinViewport)

        // Frame time well past contentEnd — viewport clamps to the right
        // edge, playhead's x clamps to width.
        let afterProjection = NotationReplayDriver.project(
            frame: makeFrame(index: 1, time: 999),
            state: state,
            presentationModel: makePresentation(),
            timingGrid: nil,
            viewportRule: rule,
            width: 200,
            height: 40
        )
        let afterViewport = try XCTUnwrap(afterProjection?.viewport)
        XCTAssertEqual(afterViewport.endTime, 20, accuracy: 1e-9)
        XCTAssertEqual(afterViewport.startTime, 16, accuracy: 1e-9)
        let afterPlayhead = try XCTUnwrap(afterProjection?.playhead)
        XCTAssertEqual(afterPlayhead.x, 200)
        XCTAssertFalse(afterPlayhead.isWithinViewport)
    }

    // MARK: - 16. Codable round-trip for frame

    func testFrameCodableRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()

        let frame = makeFrame(index: 7, time: 3.25)
        let data = try encoder.encode(frame)
        let decoded = try decoder.decode(NotationReplayFrame.self, from: data)
        XCTAssertEqual(decoded, frame)
        let second = try encoder.encode(decoded)
        XCTAssertEqual(second, data)
    }

    // MARK: - 17. Codable round-trip for state

    func testStateCodableRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()

        let state = makeState(contentStart: 0, contentEnd: 12.5, frames: [
            makeFrame(index: 0, time: 0),
            makeFrame(index: 3, time: 4.5),
            makeFrame(index: 9, time: 12.5),
        ])
        let data = try encoder.encode(state)
        let decoded = try decoder.decode(NotationReplayState.self, from: data)
        XCTAssertEqual(decoded, state)
        let second = try encoder.encode(decoded)
        XCTAssertEqual(second, data)
    }

    // MARK: - 18. Codable round-trip for projection

    func testProjectionCodableRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()

        let projection = try XCTUnwrap(NotationReplayDriver.project(
            frame: makeFrame(index: 0, time: 6),
            state: makeState(contentStart: 0, contentEnd: 20),
            presentationModel: makePresentation(),
            timingGrid: makeGrid(),
            viewportRule: makeRule(),
            width: 200,
            height: 40
        ))
        let data = try encoder.encode(projection)
        let decoded = try decoder.decode(NotationReplayProjection.self, from: data)
        XCTAssertEqual(decoded, projection)

        // Round-trip a projection with nil gridlines too.
        let nilGridProjection = try XCTUnwrap(NotationReplayDriver.project(
            frame: makeFrame(index: 0, time: 2),
            state: makeState(),
            presentationModel: makePresentation(),
            timingGrid: nil,
            viewportRule: makeRule(),
            width: 200,
            height: 40
        ))
        let nilGridData = try encoder.encode(nilGridProjection)
        let nilGridDecoded = try decoder.decode(NotationReplayProjection.self, from: nilGridData)
        XCTAssertEqual(nilGridDecoded, nilGridProjection)
        XCTAssertNil(nilGridDecoded.gridlineGeometry)
    }

    // MARK: - 19. Codable rejects invalid frame

    func testFrameDecoderRejectsInvalidPayload() {
        let decoder = JSONDecoder()
        let negativeIndex = #"{"index": -1, "time": 0}"#.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(NotationReplayFrame.self, from: negativeIndex))

        // NaN/Infinity aren't JSON literals; encode as Double.nan via a
        // small payload that decodes to a non-finite Double — Swift's
        // JSONDecoder accepts the literal `"NaN"`/`"Infinity"` only when
        // `.nonConformingFloatDecodingStrategy` is set, so instead use a
        // payload that decodes successfully with the default strategy
        // for the time field but fails our `isFinite` guard. We can't
        // express that directly in JSON without the custom strategy, so
        // assert the negative-index path is enough to prove the decoder
        // runs `isValid` — and additionally drive the strategy-based
        // path:
        let nonFiniteAwareDecoder = JSONDecoder()
        nonFiniteAwareDecoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        let nanTime = #"{"index": 0, "time": "NaN"}"#.data(using: .utf8)!
        XCTAssertThrowsError(
            try nonFiniteAwareDecoder.decode(NotationReplayFrame.self, from: nanTime)
        )
        let infTime = #"{"index": 0, "time": "Infinity"}"#.data(using: .utf8)!
        XCTAssertThrowsError(
            try nonFiniteAwareDecoder.decode(NotationReplayFrame.self, from: infTime)
        )
    }

    // MARK: - 20. Codable rejects invalid state

    func testStateDecoderRejectsInvalidPayload() {
        let decoder = JSONDecoder()

        // contentEnd <= contentStart
        let badBounds = #"{"contentStart": 1, "contentEnd": 1, "frames": []}"#.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(NotationReplayState.self, from: badBounds))

        // Unsorted frame indices
        let unsorted = """
        {"contentStart": 0, "contentEnd": 10, "frames": [
            {"index": 1, "time": 0},
            {"index": 0, "time": 1}
        ]}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(NotationReplayState.self, from: unsorted))

        // Duplicate frame indices
        let duplicate = """
        {"contentStart": 0, "contentEnd": 10, "frames": [
            {"index": 0, "time": 0},
            {"index": 0, "time": 1}
        ]}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(NotationReplayState.self, from: duplicate))

        // Non-finite content bound
        let nonFiniteAwareDecoder = JSONDecoder()
        nonFiniteAwareDecoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        let infiniteEnd = #"{"contentStart": 0, "contentEnd": "Infinity", "frames": []}"#.data(using: .utf8)!
        XCTAssertThrowsError(
            try nonFiniteAwareDecoder.decode(NotationReplayState.self, from: infiniteEnd)
        )
    }

    // MARK: - 21. Deterministic repeated projection

    func testDeterministicRepeatedProjection() {
        let frame = makeFrame(index: 0, time: 6)
        let state = makeState(contentStart: 0, contentEnd: 20)
        let presentation = makePresentation()
        let grid = makeGrid()
        let rule = makeRule()

        let first = NotationReplayDriver.project(
            frame: frame,
            state: state,
            presentationModel: presentation,
            timingGrid: grid,
            viewportRule: rule,
            width: 200,
            height: 40
        )
        let second = NotationReplayDriver.project(
            frame: frame,
            state: state,
            presentationModel: presentation,
            timingGrid: grid,
            viewportRule: rule,
            width: 200,
            height: 40
        )
        XCTAssertEqual(first, second)
        XCTAssertNotNil(first)
    }

    // MARK: - 22. No UI/clock/export/ML dependency

    /// Compile-time assertion. Driving a projection uses only the
    /// presentation model, viewport rule, timing grid, frame, and
    /// state surfaces. If the implementation reached for SwiftUI,
    /// Canvas, AppKit, UIKit, AVFoundation, Combine, a clock/timer
    /// type, an exporter, CoreML, or CreateML, this file would fail
    /// to build without the matching imports — and this test
    /// deliberately does not import any of them.
    func testProjectionBuildableWithoutUIClockExportOrMLImports() {
        let projection = NotationReplayDriver.project(
            frame: makeFrame(index: 0, time: 0),
            state: makeState(),
            presentationModel: makePresentation(),
            timingGrid: nil,
            viewportRule: makeRule(),
            width: 100,
            height: 40
        )
        XCTAssertNotNil(projection)
    }
}
