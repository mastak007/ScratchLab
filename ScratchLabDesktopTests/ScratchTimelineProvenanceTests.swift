// Headless tests for ScratchTimelineProvenance — the Data → analyze → intent → display chain that
// the DEBUG macOS file-load surface uses. Proves a recorded ScratchTimeline payload becomes a
// travel-display model and a travel MotionPath, using existing checked-in fixtures (no real export
// file, no file I/O here — the helper takes Data). The file picker itself is not unit-tested.

import CoreGraphics
import XCTest
@testable import ScratchLab

final class ScratchTimelineProvenanceTests: XCTestCase {

    private let rane = ScratchAnalysisCalibration(stepsPerRevolution: 3932, crossfaderCutWidth: 0.05)

    private func fixtureData(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            XCTFail("fixture \(name).json not found in \(bundle.bundleURL.path)", file: file, line: line)
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    // 1. Real fader fixture payload → display model: forward/audible + reverse/cut, exact travel,
    //    nonUnitStep, usable scale.
    func testRealFaderPayloadProducesDisplayModel() throws {
        let model = try ScratchTimelineProvenance.displayModel(
            from: try fixtureData("scratch_timeline_cc6_real_fader_cut_fixture"),
            calibration: rane, fullScaleTravelPercent: 1.0)
        XCTAssertEqual(model.strokes.map(\.direction), [.forward, .reverse])
        XCTAssertEqual(model.strokes.map(\.audibleState), [.audible, .cut])
        XCTAssertEqual(model.strokes.first?.travelPercent ?? -1, 32.0 / 3932.0 * 100.0, accuracy: 1e-9)
        XCTAssertEqual(model.strokes.last?.travelPercent ?? -1, 11.0 / 3932.0 * 100.0, accuracy: 1e-9)
        XCTAssertTrue(model.warnings.contains(.nonUnitStep))
        XCTAssertTrue(model.scaleIsUsable)
    }

    // 2. End-to-end: payload → display model → travel MotionPath; forward deflects more than reverse.
    func testPayloadEndToEndTravelMotionPath() throws {
        let model = try ScratchTimelineProvenance.displayModel(
            from: try fixtureData("scratch_timeline_cc6_real_fader_cut_fixture"),
            calibration: rane, fullScaleTravelPercent: 1.0)
        let duration = (model.strokes.map(\.endTime).max() ?? 0) + 0.5
        let path = ScratchNotationTravelMotionPath.motionPath(for: model, duration: duration)
        let centre = path.segments.first { $0.isHold }?.startPosition ?? 0.5
        let strokeSegs = path.segments.filter { if case .stroke = $0.kind { return true }; return false }
        XCTAssertGreaterThanOrEqual(strokeSegs.count, 4)
        XCTAssertEqual(strokeSegs[0].isRising, true)
        XCTAssertEqual(strokeSegs[2].isRising, false)
        XCTAssertGreaterThan(abs(strokeSegs[0].endPosition - centre), abs(strokeSegs[2].endPosition - centre))
    }

    // 3. Malformed JSON → throws decodeFailed (no crash).
    func testMalformedPayloadThrows() {
        let bad = Data(#"{ "muteCrossfaderBelow": 0.05 }"#.utf8)  // missing `events`
        XCTAssertThrowsError(
            try ScratchTimelineProvenance.displayModel(from: bad, calibration: rane, fullScaleTravelPercent: 1.0)
        ) { error in
            guard case ScratchAnalysisTimelineError.decodeFailed = error else {
                return XCTFail("expected .decodeFailed, got \(error)")
            }
        }
    }

    // 4. Calibration is honoured: coarser stepsPerRevolution yields larger travelPercent.
    func testCalibrationIsHonoured() throws {
        let data = try fixtureData("scratch_timeline_cc6_real_fader_cut_fixture")
        let fine = try ScratchTimelineProvenance.displayModel(
            from: data, calibration: .init(stepsPerRevolution: 3932, crossfaderCutWidth: 0.05),
            fullScaleTravelPercent: 1.0)
        let coarse = try ScratchTimelineProvenance.displayModel(
            from: data, calibration: .init(stepsPerRevolution: 1000, crossfaderCutWidth: 0.05),
            fullScaleTravelPercent: 1.0)
        XCTAssertGreaterThan(coarse.strokes.first?.travelPercent ?? 0, fine.strokes.first?.travelPercent ?? 0)
    }

    // 5. fullScale is honoured: unusable scale → all normalizedTravel 0, raw preserved.
    func testUnusableFullScale() throws {
        let model = try ScratchTimelineProvenance.displayModel(
            from: try fixtureData("scratch_timeline_cc6_real_fader_cut_fixture"),
            calibration: rane, fullScaleTravelPercent: 0.0)
        XCTAssertFalse(model.scaleIsUsable)
        XCTAssertEqual(model.strokes.map(\.normalizedTravel), [0.0, 0.0])
        XCTAssertGreaterThan(model.strokes.first?.travelPercent ?? 0, 0)
    }

    // 6. Deterministic.
    func testDeterministic() throws {
        let data = try fixtureData("scratch_timeline_cc6_real_fader_cut_fixture")
        let a = try ScratchTimelineProvenance.displayModel(from: data, calibration: rane, fullScaleTravelPercent: 1.5)
        let b = try ScratchTimelineProvenance.displayModel(from: data, calibration: rane, fullScaleTravelPercent: 1.5)
        XCTAssertEqual(a, b)
    }
}
