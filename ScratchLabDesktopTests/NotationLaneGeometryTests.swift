import XCTest
@testable import ScratchLab

/// Section 5 / Slice 2 — locks the contract of
/// `NotationLaneViewport`, `NotationLaneStrokeGeometry`,
/// `NotationLaneGeometryModel`, and
/// `NotationLaneGeometryMapper`. Pure geometry projection from a
/// `NotationPresentationModel` plus a viewport; no SwiftUI, no
/// Canvas, no renderer, no ML, no scoring.
final class NotationLaneGeometryTests: XCTestCase {

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
            XCTFail("Viewport(\(start), \(end), \(width), \(height)) unexpectedly rejected",
                    file: file, line: line)
            return NotationLaneViewport(startTime: 0, endTime: 1, width: 1, height: 1)!
        }
        return v
    }

    private func presentationStroke(
        primitiveIndex: Int = 0,
        startTime: TimeInterval,
        endTime: TimeInterval,
        family: ScratchFamily? = nil,
        coachingKinds: [CoachingEventKind] = []
    ) -> NotationPresentationStroke {
        NotationPresentationStroke(
            primitiveIndex: primitiveIndex,
            startTime: startTime,
            endTime: endTime,
            startPosition: nil,
            endPosition: nil,
            family: family,
            coachingKinds: coachingKinds
        )
    }

    // MARK: - 1. Viewport rejects non-finite start/end/width/height

    func testViewportRejectsNonFiniteValues() {
        XCTAssertNil(NotationLaneViewport(startTime: .nan, endTime: 1, width: 1, height: 1))
        XCTAssertNil(NotationLaneViewport(startTime: 0, endTime: .nan, width: 1, height: 1))
        XCTAssertNil(NotationLaneViewport(startTime: 0, endTime: 1, width: .nan, height: 1))
        XCTAssertNil(NotationLaneViewport(startTime: 0, endTime: 1, width: 1, height: .nan))
        XCTAssertNil(NotationLaneViewport(startTime: 0, endTime: .infinity, width: 1, height: 1))
        XCTAssertNil(NotationLaneViewport(startTime: 0, endTime: 1, width: .infinity, height: 1))
    }

    // MARK: - 2. Viewport rejects endTime <= startTime

    func testViewportRejectsNonPositiveTimeSpan() {
        XCTAssertNil(NotationLaneViewport(startTime: 1, endTime: 1, width: 1, height: 1))
        XCTAssertNil(NotationLaneViewport(startTime: 2, endTime: 1, width: 1, height: 1))
    }

    // MARK: - 3. Viewport rejects width <= 0 and height <= 0

    func testViewportRejectsNonPositiveDimensions() {
        XCTAssertNil(NotationLaneViewport(startTime: 0, endTime: 1, width: 0, height: 1))
        XCTAssertNil(NotationLaneViewport(startTime: 0, endTime: 1, width: -1, height: 1))
        XCTAssertNil(NotationLaneViewport(startTime: 0, endTime: 1, width: 1, height: 0))
        XCTAssertNil(NotationLaneViewport(startTime: 0, endTime: 1, width: 1, height: -1))
    }

    // MARK: - 4. Empty presentation model returns empty geometry

    func testEmptyPresentationModelReturnsEmptyGeometry() {
        let model = NotationPresentationModel(strokes: [])
        let geometry = NotationLaneGeometryMapper.makeGeometry(
            presentationModel: model,
            viewport: viewport()
        )
        XCTAssertEqual(geometry.strokes, [])
    }

    // MARK: - 5. One geometry stroke per presentation stroke

    func testOneGeometryStrokePerPresentationStroke() {
        let model = NotationPresentationModel(strokes: [
            presentationStroke(primitiveIndex: 0, startTime: 0, endTime: 1),
            presentationStroke(primitiveIndex: 1, startTime: 1, endTime: 2),
            presentationStroke(primitiveIndex: 2, startTime: 2, endTime: 3),
        ])
        let geometry = NotationLaneGeometryMapper.makeGeometry(
            presentationModel: model,
            viewport: viewport()
        )
        XCTAssertEqual(geometry.strokes.count, model.strokes.count)
    }

    // MARK: - 6. Preserves primitive order

    func testPreservesPrimitiveOrder() {
        let model = NotationPresentationModel(strokes: [
            presentationStroke(primitiveIndex: 5, startTime: 0, endTime: 1),
            presentationStroke(primitiveIndex: 2, startTime: 1, endTime: 2),
            presentationStroke(primitiveIndex: 9, startTime: 2, endTime: 3),
        ])
        let geometry = NotationLaneGeometryMapper.makeGeometry(
            presentationModel: model,
            viewport: viewport()
        )
        XCTAssertEqual(geometry.strokes.map(\.primitiveIndex), [5, 2, 9])
    }

    // MARK: - 7. Maps xStart/xEnd linearly

    func testMapsXLinearly() {
        let v = viewport(start: 0, end: 10, width: 100, height: 40)
        let model = NotationPresentationModel(strokes: [
            presentationStroke(startTime: 0, endTime: 10),
            presentationStroke(startTime: 2.5, endTime: 7.5),
            presentationStroke(startTime: 5, endTime: 5),
        ])
        let geometry = NotationLaneGeometryMapper.makeGeometry(
            presentationModel: model,
            viewport: v
        )
        XCTAssertEqual(geometry.strokes[0].xStart, 0, accuracy: 1e-9)
        XCTAssertEqual(geometry.strokes[0].xEnd, 100, accuracy: 1e-9)
        XCTAssertEqual(geometry.strokes[1].xStart, 25, accuracy: 1e-9)
        XCTAssertEqual(geometry.strokes[1].xEnd, 75, accuracy: 1e-9)
        XCTAssertEqual(geometry.strokes[2].xStart, 50, accuracy: 1e-9)
        XCTAssertEqual(geometry.strokes[2].xEnd, 50, accuracy: 1e-9)
    }

    // MARK: - 8. Clamps x positions before viewport start

    func testClampsXPositionsBeforeViewportStart() {
        let v = viewport(start: 1, end: 2, width: 100, height: 40)
        let model = NotationPresentationModel(strokes: [
            presentationStroke(startTime: -5, endTime: 0),
        ])
        let geometry = NotationLaneGeometryMapper.makeGeometry(
            presentationModel: model,
            viewport: v
        )
        XCTAssertEqual(geometry.strokes[0].xStart, 0)
        XCTAssertEqual(geometry.strokes[0].xEnd, 0)
    }

    // MARK: - 9. Clamps x positions after viewport end

    func testClampsXPositionsAfterViewportEnd() {
        let v = viewport(start: 0, end: 1, width: 100, height: 40)
        let model = NotationPresentationModel(strokes: [
            presentationStroke(startTime: 1.5, endTime: 5),
        ])
        let geometry = NotationLaneGeometryMapper.makeGeometry(
            presentationModel: model,
            viewport: v
        )
        XCTAssertEqual(geometry.strokes[0].xStart, 100)
        XCTAssertEqual(geometry.strokes[0].xEnd, 100)
    }

    // MARK: - 10. Forward-like time span maps to low-to-high rail

    func testForwardLikeTimeSpanMapsToLowToHighRail() {
        let v = viewport(start: 0, end: 10, width: 100, height: 40)
        let model = NotationPresentationModel(strokes: [
            presentationStroke(startTime: 0, endTime: 1),
        ])
        let geometry = NotationLaneGeometryMapper.makeGeometry(
            presentationModel: model,
            viewport: v
        )
        XCTAssertEqual(geometry.strokes[0].yStart, v.height * 0.25, accuracy: 1e-9)
        XCTAssertEqual(geometry.strokes[0].yEnd, v.height * 0.75, accuracy: 1e-9)
    }

    // MARK: - 11. Zero-duration stroke maps to center rail

    func testZeroDurationStrokeMapsToCenterRail() {
        let v = viewport(start: 0, end: 10, width: 100, height: 40)
        let model = NotationPresentationModel(strokes: [
            presentationStroke(startTime: 1, endTime: 1),
        ])
        let geometry = NotationLaneGeometryMapper.makeGeometry(
            presentationModel: model,
            viewport: v
        )
        XCTAssertEqual(geometry.strokes[0].yStart, v.height * 0.5, accuracy: 1e-9)
        XCTAssertEqual(geometry.strokes[0].yEnd, v.height * 0.5, accuracy: 1e-9)
    }

    // MARK: - 12. Preserves family

    func testPreservesFamily() {
        let v = viewport()
        let model = NotationPresentationModel(strokes: [
            presentationStroke(startTime: 0, endTime: 1, family: .baby),
            presentationStroke(startTime: 1, endTime: 2, family: nil),
            presentationStroke(startTime: 2, endTime: 3, family: .scribble),
        ])
        let geometry = NotationLaneGeometryMapper.makeGeometry(
            presentationModel: model,
            viewport: v
        )
        XCTAssertEqual(geometry.strokes.map(\.family), [.baby, nil, .scribble])
    }

    // MARK: - 13. Preserves coachingKinds

    func testPreservesCoachingKinds() {
        let v = viewport()
        let model = NotationPresentationModel(strokes: [
            presentationStroke(startTime: 0, endTime: 1, coachingKinds: [.lateReversal, .unstableTiming]),
            presentationStroke(startTime: 1, endTime: 2, coachingKinds: []),
        ])
        let geometry = NotationLaneGeometryMapper.makeGeometry(
            presentationModel: model,
            viewport: v
        )
        XCTAssertEqual(geometry.strokes[0].coachingKinds, [.lateReversal, .unstableTiming])
        XCTAssertEqual(geometry.strokes[1].coachingKinds, [])
    }

    // MARK: - 14. Codable round-trip

    func testCodableRoundTrip() throws {
        let v = viewport(start: 0, end: 10, width: 200, height: 50)
        let model = NotationPresentationModel(strokes: [
            presentationStroke(primitiveIndex: 0, startTime: 0, endTime: 1, family: .baby, coachingKinds: [.lateReversal]),
            presentationStroke(primitiveIndex: 1, startTime: 1, endTime: 1),
            presentationStroke(primitiveIndex: 2, startTime: 2, endTime: 5, family: .scribble),
        ])
        let geometry = NotationLaneGeometryMapper.makeGeometry(
            presentationModel: model,
            viewport: v
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()

        let geomData = try encoder.encode(geometry)
        let decodedGeom = try decoder.decode(NotationLaneGeometryModel.self, from: geomData)
        XCTAssertEqual(decodedGeom, geometry)
        let secondGeom = try encoder.encode(decodedGeom)
        XCTAssertEqual(secondGeom, geomData)

        let vpData = try encoder.encode(v)
        let decodedVp = try decoder.decode(NotationLaneViewport.self, from: vpData)
        XCTAssertEqual(decodedVp, v)

        // Viewport decoder must reject invalid payload.
        let bad = """
        {"startTime": 1, "endTime": 1, "width": 100, "height": 40}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(NotationLaneViewport.self, from: bad))
    }

    // MARK: - 15. Deterministic repeated mapping

    func testDeterministicRepeatedMapping() {
        let v = viewport()
        let model = NotationPresentationModel(strokes: [
            presentationStroke(primitiveIndex: 0, startTime: 0, endTime: 1, family: .baby),
            presentationStroke(primitiveIndex: 1, startTime: 1, endTime: 2, coachingKinds: [.lateReversal]),
        ])
        let first = NotationLaneGeometryMapper.makeGeometry(presentationModel: model, viewport: v)
        let second = NotationLaneGeometryMapper.makeGeometry(presentationModel: model, viewport: v)
        XCTAssertEqual(first, second)
    }

    // MARK: - 16. No UI/render/export/ML dependency

    /// Compile-time assertion. Building geometry uses only the
    /// presentation model, viewport, family, and coaching kind
    /// surfaces. If the implementation reached for SwiftUI, Canvas,
    /// AppKit, UIKit, renderer/view code, exporters, CoreML or
    /// CreateML, the file would fail to build without the matching
    /// imports — and this test deliberately does not import any of
    /// them.
    func testGeometryBuildableWithoutUIRenderExportOrMLImports() {
        let v = viewport()
        let model = NotationPresentationModel(strokes: [
            presentationStroke(startTime: 0, endTime: 1, family: .baby),
        ])
        let geometry = NotationLaneGeometryMapper.makeGeometry(presentationModel: model, viewport: v)
        XCTAssertEqual(geometry.strokes.count, 1)
    }
}
