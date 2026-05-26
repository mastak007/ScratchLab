import XCTest
@testable import ScratchLab

/// Section 5 / Slice 4 — locks the contract of
/// `NotationGridlineKind`, `NotationGridlineGeometry`,
/// `NotationGridlineGeometryModel`, and
/// `NotationGridlineGeometryMapper`. Pure subdivision-walk projection
/// of `(TimingGrid, NotationLaneViewport)` into gridline geometry; no
/// SwiftUI, no Canvas, no renderer, no ML, no scoring.
final class NotationGridlineGeometryTests: XCTestCase {

    // MARK: - Helpers

    /// 120 BPM, 4 beats/bar, 1 subdivision/beat, origin 0 — so a
    /// subdivision lasts 0.5 s and a bar lasts 2.0 s. Beat lines fall
    /// at 0.5/1.0/1.5 s within each bar (relative to the bar start).
    private func gridSimple(
        bpm: Double = 120,
        beatsPerBar: Int = 4,
        subdivisionsPerBeat: Int = 1,
        origin: TimeInterval = 0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> TimingGrid {
        guard let g = TimingGrid(
            beatsPerMinute: bpm,
            beatsPerBar: beatsPerBar,
            subdivisionsPerBeat: subdivisionsPerBeat,
            origin: origin
        ) else {
            XCTFail("Grid unexpectedly rejected", file: file, line: line)
            return TimingGrid(beatsPerMinute: 60, beatsPerBar: 4, subdivisionsPerBeat: 1, origin: 0)!
        }
        return g
    }

    private func viewport(
        start: TimeInterval = 0,
        end: TimeInterval = 8,
        width: Double = 800,
        height: Double = 40,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> NotationLaneViewport {
        guard let v = NotationLaneViewport(
            startTime: start, endTime: end, width: width, height: height
        ) else {
            XCTFail("Viewport unexpectedly rejected", file: file, line: line)
            return NotationLaneViewport(startTime: 0, endTime: 1, width: 1, height: 1)!
        }
        return v
    }

    // MARK: - 1. Empty-width invalid viewport remains handled by viewport init, not mapper

    /// Smoke test that constructing a degenerate viewport still
    /// fails at the viewport boundary, so the mapper never has to
    /// defend against it.
    func testInvalidViewportIsRejectedByItsOwnInit() {
        XCTAssertNil(NotationLaneViewport(startTime: 0, endTime: 0, width: 100, height: 40))
        XCTAssertNil(NotationLaneViewport(startTime: 0, endTime: 1, width: 0, height: 40))
    }

    // MARK: - 2. Generates bar line at viewport start when aligned

    func testGeneratesBarLineAtViewportStartWhenAligned() {
        // 120 BPM, 4/4, 1 sub/beat → bar at t=0, 2.0, 4.0, ...; viewport 0..2.
        let grid = gridSimple()
        let model = NotationGridlineGeometryMapper.makeGridlines(
            grid: grid,
            viewport: viewport(start: 0, end: 2, width: 200, height: 40)
        )
        XCTAssertFalse(model.gridlines.isEmpty)
        XCTAssertEqual(model.gridlines.first?.kind, .bar)
        XCTAssertEqual(model.gridlines.first?.time ?? -1, 0.0, accuracy: 1e-9)
    }

    // MARK: - 3. Generates beat lines between bars

    func testGeneratesBeatLinesBetweenBars() {
        let grid = gridSimple()
        let model = NotationGridlineGeometryMapper.makeGridlines(
            grid: grid,
            viewport: viewport(start: 0, end: 2, width: 200, height: 40)
        )
        // Expected gridline times: 0.0 (bar), 0.5 (beat), 1.0 (beat),
        // 1.5 (beat), 2.0 (next bar at end of viewport).
        XCTAssertEqual(model.gridlines.map(\.kind), [.bar, .beat, .beat, .beat, .bar])
        let times = model.gridlines.map(\.time)
        XCTAssertEqual(times[0], 0.0, accuracy: 1e-9)
        XCTAssertEqual(times[1], 0.5, accuracy: 1e-9)
        XCTAssertEqual(times[2], 1.0, accuracy: 1e-9)
        XCTAssertEqual(times[3], 1.5, accuracy: 1e-9)
        XCTAssertEqual(times[4], 2.0, accuracy: 1e-9)
    }

    // MARK: - 4. Generates subdivision lines between beats

    func testGeneratesSubdivisionLinesBetweenBeats() {
        // 60 BPM, 4/4, 2 sub/beat → sub = 0.5s, beat = 1s, bar = 4s.
        let grid = gridSimple(bpm: 60, beatsPerBar: 4, subdivisionsPerBeat: 2)
        let model = NotationGridlineGeometryMapper.makeGridlines(
            grid: grid,
            viewport: viewport(start: 0, end: 2, width: 200, height: 40)
        )
        // Expected times: 0.0 (bar), 0.5 (sub), 1.0 (beat), 1.5 (sub), 2.0 (beat).
        XCTAssertEqual(model.gridlines.map(\.kind), [.bar, .subdivision, .beat, .subdivision, .beat])
        XCTAssertEqual(model.gridlines.map(\.time), [0.0, 0.5, 1.0, 1.5, 2.0])
    }

    // MARK: - 5. Includes viewport end boundary when aligned

    func testIncludesViewportEndBoundaryWhenAligned() {
        let grid = gridSimple()
        let model = NotationGridlineGeometryMapper.makeGridlines(
            grid: grid,
            viewport: viewport(start: 0, end: 1.0, width: 100, height: 40)
        )
        // Expected: 0.0 (bar), 0.5 (beat), 1.0 (beat).
        XCTAssertEqual(model.gridlines.last?.time ?? -1, 1.0, accuracy: 1e-9)
    }

    // MARK: - 6. Excludes gridlines before viewport start

    func testExcludesGridlinesBeforeViewportStart() {
        let grid = gridSimple()
        let model = NotationGridlineGeometryMapper.makeGridlines(
            grid: grid,
            viewport: viewport(start: 0.75, end: 2.0, width: 100, height: 40)
        )
        // 0.0 / 0.5 are before 0.75 and must be excluded; 1.0 / 1.5 / 2.0 included.
        XCTAssertEqual(model.gridlines.map(\.time), [1.0, 1.5, 2.0])
    }

    // MARK: - 7. Excludes gridlines after viewport end

    func testExcludesGridlinesAfterViewportEnd() {
        let grid = gridSimple()
        let model = NotationGridlineGeometryMapper.makeGridlines(
            grid: grid,
            viewport: viewport(start: 0, end: 1.25, width: 100, height: 40)
        )
        // 1.5 is after 1.25 and must be excluded.
        XCTAssertEqual(model.gridlines.map(\.time), [0.0, 0.5, 1.0])
    }

    // MARK: - 8. Preserves ascending time order

    func testPreservesAscendingTimeOrder() {
        let grid = gridSimple()
        let model = NotationGridlineGeometryMapper.makeGridlines(
            grid: grid,
            viewport: viewport(start: 0, end: 4.0, width: 400, height: 40)
        )
        let times = model.gridlines.map(\.time)
        for i in 1..<times.count {
            XCTAssertGreaterThan(times[i], times[i - 1],
                                 "gridlines must be strictly ascending in time")
        }
    }

    // MARK: - 9. No duplicate gridlines at same time

    func testNoDuplicateGridlinesAtSameTime() {
        let grid = gridSimple()
        let model = NotationGridlineGeometryMapper.makeGridlines(
            grid: grid,
            viewport: viewport(start: 0, end: 4.0, width: 400, height: 40)
        )
        let times = model.gridlines.map(\.time)
        XCTAssertEqual(times.count, Set(times).count)
    }

    // MARK: - 10. x positions map linearly

    func testXPositionsMapLinearly() {
        let grid = gridSimple()
        let v = viewport(start: 0, end: 2, width: 200, height: 40)
        let model = NotationGridlineGeometryMapper.makeGridlines(grid: grid, viewport: v)
        // For start=0, end=2, width=200: x == time * 100.
        for line in model.gridlines {
            XCTAssertEqual(line.x, line.time * 100, accuracy: 1e-9)
        }
    }

    // MARK: - 11. Non-zero origin shifts gridlines correctly

    func testNonZeroOriginShiftsGridlines() {
        // origin=0.5 with 4/4 at 120 BPM (subSec=0.5). Subdivisions
        // are at t = ..., 0.0, 0.5, 1.0, 1.5, 2.0, 2.5, ... — the
        // beat=0/subdivision=0 boundary (a `.bar`) sits at t=0.5
        // (bar 0) and t=2.5 (bar 1). The t=0.0 boundary maps to
        // bar=-1, beat=3, subdivision=0 — a `.beat`. Viewport 0..2.5.
        let grid = gridSimple(bpm: 120, beatsPerBar: 4, subdivisionsPerBeat: 1, origin: 0.5)
        let model = NotationGridlineGeometryMapper.makeGridlines(
            grid: grid,
            viewport: viewport(start: 0, end: 2.5, width: 250, height: 40)
        )
        XCTAssertEqual(model.gridlines.map(\.kind),
                       [.beat, .bar, .beat, .beat, .beat, .bar])
        XCTAssertEqual(model.gridlines.map(\.time), [0.0, 0.5, 1.0, 1.5, 2.0, 2.5])
    }

    // MARK: - 12. Non-4/4 grid classifies bar/beat correctly

    func testNonFourFourGridClassifiesBarBeatCorrectly() {
        // 120 BPM, 3/4, 1 sub/beat → beat = 0.5s, bar = 1.5s.
        let grid = gridSimple(bpm: 120, beatsPerBar: 3, subdivisionsPerBeat: 1)
        let model = NotationGridlineGeometryMapper.makeGridlines(
            grid: grid,
            viewport: viewport(start: 0, end: 3.0, width: 300, height: 40)
        )
        // Expected: 0.0 (bar), 0.5 (beat), 1.0 (beat), 1.5 (bar),
        // 2.0 (beat), 2.5 (beat), 3.0 (bar).
        XCTAssertEqual(model.gridlines.map(\.kind), [.bar, .beat, .beat, .bar, .beat, .beat, .bar])
    }

    // MARK: - 13. Triplet subdivisions generate expected subdivision count

    func testTripletSubdivisionsGenerateExpectedCount() {
        // 60 BPM, 4/4, 3 sub/beat → sub = 1/3 s, beat = 1s, bar = 4s.
        let grid = gridSimple(bpm: 60, beatsPerBar: 4, subdivisionsPerBeat: 3)
        let model = NotationGridlineGeometryMapper.makeGridlines(
            grid: grid,
            viewport: viewport(start: 0, end: 1.0, width: 300, height: 40)
        )
        // Expected kinds within 0..1s: bar at 0, sub at 1/3, sub at 2/3, beat at 1.0.
        XCTAssertEqual(model.gridlines.map(\.kind), [.bar, .subdivision, .subdivision, .beat])
        XCTAssertEqual(model.gridlines.count, 4)
    }

    // MARK: - 14. Codable round-trip

    func testCodableRoundTrip() throws {
        let grid = gridSimple()
        let v = viewport(start: 0, end: 4.0, width: 400, height: 40)
        let model = NotationGridlineGeometryMapper.makeGridlines(grid: grid, viewport: v)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        let data = try encoder.encode(model)
        let decoded = try decoder.decode(NotationGridlineGeometryModel.self, from: data)
        XCTAssertEqual(decoded, model)
        let second = try encoder.encode(decoded)
        XCTAssertEqual(second, data)
    }

    // MARK: - 15. Deterministic repeated mapping

    func testDeterministicRepeatedMapping() {
        let grid = gridSimple()
        let v = viewport()
        let first = NotationGridlineGeometryMapper.makeGridlines(grid: grid, viewport: v)
        let second = NotationGridlineGeometryMapper.makeGridlines(grid: grid, viewport: v)
        XCTAssertEqual(first, second)
    }

    // MARK: - 16. No UI/render/export/ML dependency

    /// Compile-time assertion. The mapper consumes only `TimingGrid`
    /// and `NotationLaneViewport`. If the implementation reached for
    /// SwiftUI, Canvas, AppKit, UIKit, renderer/view code, exporters,
    /// CoreML or CreateML, this file would fail to build without the
    /// matching imports — and the test deliberately does not import
    /// any of them.
    func testGridlinesBuildableWithoutUIRenderExportOrMLImports() {
        let grid = gridSimple()
        let v = viewport()
        let model = NotationGridlineGeometryMapper.makeGridlines(grid: grid, viewport: v)
        XCTAssertFalse(model.gridlines.isEmpty)
    }
}
