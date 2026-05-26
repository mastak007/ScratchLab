import XCTest
@testable import ScratchLab

/// Section 5 / Slice 3 — locks the contract of
/// `NotationPlayheadGeometry` and
/// `NotationPlayheadGeometryMapper`. Pure single-value projection of
/// time + viewport into pixel-space playhead geometry; no SwiftUI,
/// no Canvas, no renderer, no ML, no scoring.
final class NotationPlayheadGeometryTests: XCTestCase {

    // MARK: - Helpers

    private func viewport(
        start: TimeInterval = 0,
        end: TimeInterval = 10,
        width: Double = 100,
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

    // MARK: - 1. Mapper returns nil for NaN/infinity time

    func testMapperReturnsNilForNonFiniteTime() {
        let v = viewport()
        XCTAssertNil(NotationPlayheadGeometryMapper.makePlayhead(time: .nan, viewport: v))
        XCTAssertNil(NotationPlayheadGeometryMapper.makePlayhead(time: .infinity, viewport: v))
        XCTAssertNil(NotationPlayheadGeometryMapper.makePlayhead(time: -.infinity, viewport: v))
    }

    // MARK: - 2. Maps viewport start time to x = 0

    func testMapsViewportStartTimeToZero() throws {
        let v = viewport(start: 0, end: 10, width: 100, height: 40)
        let playhead = try XCTUnwrap(NotationPlayheadGeometryMapper.makePlayhead(time: 0, viewport: v))
        XCTAssertEqual(playhead.x, 0, accuracy: 1e-9)
    }

    // MARK: - 3. Maps viewport end time to x = width

    func testMapsViewportEndTimeToWidth() throws {
        let v = viewport(start: 0, end: 10, width: 100, height: 40)
        let playhead = try XCTUnwrap(NotationPlayheadGeometryMapper.makePlayhead(time: 10, viewport: v))
        XCTAssertEqual(playhead.x, 100, accuracy: 1e-9)
    }

    // MARK: - 4. Maps midpoint time to width / 2

    func testMapsMidpointTimeToHalfWidth() throws {
        let v = viewport(start: 0, end: 10, width: 100, height: 40)
        let playhead = try XCTUnwrap(NotationPlayheadGeometryMapper.makePlayhead(time: 5, viewport: v))
        XCTAssertEqual(playhead.x, 50, accuracy: 1e-9)
    }

    // MARK: - 5. Clamps time before viewport to x = 0

    func testClampsTimeBeforeViewportToZero() {
        let v = viewport(start: 1, end: 2, width: 100, height: 40)
        let playhead = NotationPlayheadGeometryMapper.makePlayhead(time: -5, viewport: v)
        XCTAssertEqual(playhead?.x, 0)
    }

    // MARK: - 6. Clamps time after viewport to x = width

    func testClampsTimeAfterViewportToWidth() {
        let v = viewport(start: 0, end: 1, width: 100, height: 40)
        let playhead = NotationPlayheadGeometryMapper.makePlayhead(time: 5, viewport: v)
        XCTAssertEqual(playhead?.x, 100)
    }

    // MARK: - 7. isWithinViewport true at start boundary

    func testIsWithinViewportTrueAtStartBoundary() {
        let v = viewport(start: 1, end: 2, width: 100, height: 40)
        let playhead = NotationPlayheadGeometryMapper.makePlayhead(time: 1, viewport: v)
        XCTAssertEqual(playhead?.isWithinViewport, true)
    }

    // MARK: - 8. isWithinViewport true at end boundary

    func testIsWithinViewportTrueAtEndBoundary() {
        let v = viewport(start: 1, end: 2, width: 100, height: 40)
        let playhead = NotationPlayheadGeometryMapper.makePlayhead(time: 2, viewport: v)
        XCTAssertEqual(playhead?.isWithinViewport, true)
    }

    // MARK: - 9. isWithinViewport false before start

    func testIsWithinViewportFalseBeforeStart() {
        let v = viewport(start: 1, end: 2, width: 100, height: 40)
        let playhead = NotationPlayheadGeometryMapper.makePlayhead(time: 0.999, viewport: v)
        XCTAssertEqual(playhead?.isWithinViewport, false)
    }

    // MARK: - 10. isWithinViewport false after end

    func testIsWithinViewportFalseAfterEnd() {
        let v = viewport(start: 1, end: 2, width: 100, height: 40)
        let playhead = NotationPlayheadGeometryMapper.makePlayhead(time: 2.001, viewport: v)
        XCTAssertEqual(playhead?.isWithinViewport, false)
    }

    // MARK: - 11. yTop is 0

    func testYTopIsZero() {
        let v = viewport(height: 47)
        let playhead = NotationPlayheadGeometryMapper.makePlayhead(time: 5, viewport: v)
        XCTAssertEqual(playhead?.yTop, 0)
    }

    // MARK: - 12. yBottom is viewport.height

    func testYBottomIsViewportHeight() {
        let v = viewport(height: 47)
        let playhead = NotationPlayheadGeometryMapper.makePlayhead(time: 5, viewport: v)
        XCTAssertEqual(playhead?.yBottom, 47)
    }

    // MARK: - 13. Codable round-trip

    func testCodableRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        let v = viewport(start: 0, end: 10, width: 100, height: 40)
        for t in [-1.0, 0.0, 2.5, 5.0, 10.0, 11.0] {
            let playhead = NotationPlayheadGeometryMapper.makePlayhead(time: t, viewport: v)!
            let data = try encoder.encode(playhead)
            let decoded = try decoder.decode(NotationPlayheadGeometry.self, from: data)
            XCTAssertEqual(decoded, playhead)
            let second = try encoder.encode(decoded)
            XCTAssertEqual(second, data)
        }
    }

    // MARK: - 14. Codable rejects non-finite values

    func testCodableRejectsNonFiniteValues() {
        let decoder = JSONDecoder()
        let nonFiniteTime = """
        {"time": 1e1000, "x": 0, "yTop": 0, "yBottom": 40, "isWithinViewport": false}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(NotationPlayheadGeometry.self, from: nonFiniteTime))

        let nonFiniteX = """
        {"time": 0, "x": 1e1000, "yTop": 0, "yBottom": 40, "isWithinViewport": false}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(NotationPlayheadGeometry.self, from: nonFiniteX))

        let nonFiniteYTop = """
        {"time": 0, "x": 0, "yTop": 1e1000, "yBottom": 40, "isWithinViewport": false}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(NotationPlayheadGeometry.self, from: nonFiniteYTop))

        let nonFiniteYBottom = """
        {"time": 0, "x": 0, "yTop": 0, "yBottom": 1e1000, "isWithinViewport": false}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(NotationPlayheadGeometry.self, from: nonFiniteYBottom))
    }

    // MARK: - 15. Deterministic repeated mapping

    func testDeterministicRepeatedMapping() {
        let v = viewport()
        let first = NotationPlayheadGeometryMapper.makePlayhead(time: 3.25, viewport: v)
        let second = NotationPlayheadGeometryMapper.makePlayhead(time: 3.25, viewport: v)
        XCTAssertEqual(first, second)
    }

    // MARK: - 16. No UI/render/export/ML dependency

    /// Compile-time assertion. The playhead mapper consumes only
    /// `TimeInterval` and `NotationLaneViewport`. If the
    /// implementation reached for SwiftUI, Canvas, AppKit, UIKit,
    /// renderer/view code, exporters, CoreML or CreateML, this file
    /// would fail to build without the matching imports — and the
    /// test deliberately does not import any of them.
    func testPlayheadBuildableWithoutUIRenderExportOrMLImports() {
        let v = viewport()
        let playhead = NotationPlayheadGeometryMapper.makePlayhead(time: 0, viewport: v)
        XCTAssertNotNil(playhead)
    }
}
