// ScratchRawPlatterLaneAdapterTests — unit tests for the DEBUG raw platter
// lane adapter bridge. Tests decode, segmentation, direction detection, edge
// cases, and rejection of wrong format.
//
// Uses embedded JSON strings (no fixture files).

import XCTest
@testable import ScratchLab

final class ScratchRawPlatterLaneAdapterTests: XCTestCase {

    // MARK: - Embedded test JSON

    private var twoStrokeJSON: String {
        """
        {"schemaVersion":"scratchlab_raw_platter_debug_v1","takeID":"t1","takeNumber":1,"source":"liveCapture","sampleCount":5,"startTime":1.0,"endTime":2.0,"sampleRate":5.0,"positionSpan":1.0,"lowDensity":true,"notPromoted":true,"rendererEligibility":"density_below_floor","samples":[{"time":1.0,"normalizedPosition":0.0},{"time":1.2,"normalizedPosition":0.2},{"time":1.4,"normalizedPosition":0.5},{"time":1.6,"normalizedPosition":0.3},{"time":1.8,"normalizedPosition":0.1}]}
        """
    }

    private var oneStrokeJSON: String {
        """
        {"schemaVersion":"scratchlab_raw_platter_debug_v1","takeID":"t2","takeNumber":2,"source":"liveCapture","sampleCount":4,"startTime":0.0,"endTime":1.5,"sampleRate":2.67,"positionSpan":0.8,"lowDensity":true,"notPromoted":true,"rendererEligibility":"density_below_floor","samples":[{"time":0.0,"normalizedPosition":0.1},{"time":0.5,"normalizedPosition":0.3},{"time":1.0,"normalizedPosition":0.6},{"time":1.5,"normalizedPosition":0.9}]}
        """
    }

    private var wrongSchemaJSON: String {
        """
        {"schemaVersion":"scratchlab_detected_notation_v1","takeID":"t1","takeNumber":1,"source":"liveCapture","sampleCount":2,"startTime":0,"endTime":1,"sampleRate":2.0,"positionSpan":1.0,"lowDensity":true,"notPromoted":true,"rendererEligibility":"density_below_floor","samples":[{"time":0,"normalizedPosition":0},{"time":1,"normalizedPosition":1}]}
        """
    }

    private var oneSampleJSON: String {
        """
        {"schemaVersion":"scratchlab_raw_platter_debug_v1","takeID":"t3","takeNumber":3,"source":"liveCapture","sampleCount":1,"startTime":0,"endTime":0,"sampleRate":0,"positionSpan":1.0,"lowDensity":true,"notPromoted":true,"rendererEligibility":"density_below_floor","samples":[{"time":0,"normalizedPosition":0.5}]}
        """
    }

    private var garbageJSON: String { "not json at all" }

    // MARK: - Decode success

    func testDecodesTwoStrokes() throws {
        let data = Data(twoStrokeJSON.utf8)
        let model = try ScratchRawPlatterLaneAdapter.previewModel(from: data)
        XCTAssertEqual(model.strokes.count, 2)
        XCTAssertEqual(model.warnings.count, 0)
        let s1 = model.strokes[0]
        XCTAssertEqual(s1.direction, .forward)
        XCTAssertEqual(s1.startTime, 1.0, accuracy: 1e-9)
        XCTAssertEqual(s1.endTime, 1.4, accuracy: 1e-9)
        XCTAssertEqual(s1.travelPercent, 0.5, accuracy: 1e-9)
        XCTAssertEqual(s1.audibleState, .unknown)
        let s2 = model.strokes[1]
        XCTAssertEqual(s2.direction, .reverse)
        XCTAssertEqual(s2.startTime, 1.4, accuracy: 1e-9)
        XCTAssertEqual(s2.endTime, 1.8, accuracy: 1e-9)
        XCTAssertEqual(s2.travelPercent, 0.4, accuracy: 1e-9)
        XCTAssertEqual(s2.audibleState, .unknown)
    }

    func testDecodesOneStroke() throws {
        let data = Data(oneStrokeJSON.utf8)
        let model = try ScratchRawPlatterLaneAdapter.previewModel(from: data)
        XCTAssertEqual(model.strokes.count, 1)
        let s = model.strokes[0]
        XCTAssertEqual(s.direction, .forward)
        XCTAssertEqual(s.startTime, 0.0, accuracy: 1e-9)
        XCTAssertEqual(s.endTime, 1.5, accuracy: 1e-9)
        XCTAssertEqual(s.travelPercent, 0.8, accuracy: 1e-9)
        XCTAssertEqual(s.audibleState, .unknown)
    }

    // MARK: - Rejection

    func testRejectsWrongSchema() {
        let data = Data(wrongSchemaJSON.utf8)
        XCTAssertThrowsError(try ScratchRawPlatterLaneAdapter.previewModel(from: data)) { error in
            guard case ScratchRawPlatterLaneAdapterError.decodeFailed = error else {
                XCTFail("Expected decodeFailed, got \(error)"); return
            }
        }
    }

    func testRejectsOneSample() {
        let data = Data(oneSampleJSON.utf8)
        XCTAssertThrowsError(try ScratchRawPlatterLaneAdapter.previewModel(from: data)) { error in
            guard case ScratchRawPlatterLaneAdapterError.tooFewSamples = error else {
                XCTFail("Expected tooFewSamples, got \(error)"); return
            }
        }
    }

    func testRejectsGarbage() {
        let data = Data(garbageJSON.utf8)
        XCTAssertThrowsError(try ScratchRawPlatterLaneAdapter.previewModel(from: data)) { error in
            guard case ScratchRawPlatterLaneAdapterError.decodeFailed = error else {
                XCTFail("Expected decodeFailed, got \(error)"); return
            }
        }
    }

    // MARK: - Deterministic / audible

    func testDeterministic() {
        let data = Data(twoStrokeJSON.utf8)
        let a = try! ScratchRawPlatterLaneAdapter.previewModel(from: data)
        let b = try! ScratchRawPlatterLaneAdapter.previewModel(from: data)
        XCTAssertEqual(a, b)
    }

    func testAllStrokesAudibleStateUnknown() throws {
        let data = Data(twoStrokeJSON.utf8)
        let model = try ScratchRawPlatterLaneAdapter.previewModel(from: data)
        for stroke in model.strokes {
            XCTAssertEqual(stroke.audibleState, .unknown)
        }
    }

    func testAdjacentStrokesAlternateDirection() throws {
        let data = Data(twoStrokeJSON.utf8)
        let model = try ScratchRawPlatterLaneAdapter.previewModel(from: data)
        let dirs = model.strokes.map(\.direction)
        for i in 1..<dirs.count {
            XCTAssertNotEqual(dirs[i], dirs[i - 1])
        }
    }

    // MARK: - Integration

    func testIntegrationWithDisplayAdapter() throws {
        let data = Data(twoStrokeJSON.utf8)
        let preview = try ScratchRawPlatterLaneAdapter.previewModel(from: data)
        let display = ScratchNotationLaneDisplayAdapter.displayModel(
            from: preview, fullScaleTravelPercent: 1.0)
        XCTAssertEqual(display.strokes.count, 2)
        XCTAssertTrue(display.scaleIsUsable)
        let stats = display.stats
        XCTAssertEqual(stats.totalStrokes, 2)
        XCTAssertEqual(stats.meaningfulTravelStrokes, 0)
        XCTAssertEqual(stats.microTravelStrokes, 2)
        XCTAssertEqual(stats.zeroDurationStrokes, 0)
    }
}
