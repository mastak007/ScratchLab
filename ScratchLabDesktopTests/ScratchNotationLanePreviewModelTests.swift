// Tests for ScratchNotationLanePreviewAdapter — the lossless lane-preview re-projection of
// ScratchNotationIntent.
//
// Verifies the model preserves direction, times, travelPercent (unclamped), audibleState
// (including .unknown), warnings, and order — and derives durationSeconds honestly. End-to-end
// uses the merged Slice 8 real fader fixture.
//
// Offline only. No SwiftUI import. No ScratchPlaybackLabEngine / ScratchPlaybackLabModel.
// No reference to LaneStroke / TimingLane / NotationPresentation / NotationLaneGeometry.

import XCTest
@testable import ScratchLab

final class ScratchNotationLanePreviewModelTests: XCTestCase {

    private let rane = ScratchAnalysisCalibration(stepsPerRevolution: 3932, crossfaderCutWidth: 0.05)

    private func stroke(_ dir: ScratchStrokeDirection, _ start: Double, _ end: Double,
                        _ travel: Double, _ audible: ScratchAudibleState) -> ScratchNotationIntentStroke {
        ScratchNotationIntentStroke(direction: dir, startTime: start, endTime: end,
                                    travelPercent: travel, audibleState: audible)
    }

    private func fixtureData(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            XCTFail("fixture \(name).json not found in \(bundle.bundleURL.path)", file: file, line: line)
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    private func realFaderIntent() throws -> ScratchNotationIntent {
        let out = try ScratchAnalysisTimelineAdapter.analyzeTimeline(
            data: try fixtureData("scratch_timeline_cc6_real_fader_cut_fixture"), calibration: rane)
        return ScratchAnalysisNotationAdapter.notationIntent(from: out)
    }

    // 1. Empty intent → empty strokes; warnings preserved.
    func testEmptyIntent() {
        let preview = ScratchNotationLanePreviewAdapter.preview(
            from: ScratchNotationIntent(strokes: [], warnings: [.emptyInput]))
        XCTAssertTrue(preview.strokes.isEmpty)
        XCTAssertEqual(preview.warnings, [.emptyInput])
    }

    // 2. One forward/audible stroke maps losslessly.
    func testOneForwardAudible() {
        let intent = ScratchNotationIntent(
            strokes: [stroke(.forward, 0.0, 0.25, 1.5, .audible)], warnings: [])
        let s = ScratchNotationLanePreviewAdapter.preview(from: intent).strokes.first
        XCTAssertEqual(s?.direction, .forward)
        XCTAssertEqual(s?.startTime, 0.0)
        XCTAssertEqual(s?.endTime, 0.25)
        XCTAssertEqual(s?.travelPercent, 1.5)
        XCTAssertEqual(s?.audibleState, .audible)
    }

    // 3. Real fader fixture: forward/audible + reverse/cut, exact travel, nonUnitStep.
    func testRealFaderFixture() throws {
        let preview = ScratchNotationLanePreviewAdapter.preview(from: try realFaderIntent())
        XCTAssertEqual(preview.strokes.map(\.direction), [.forward, .reverse])
        XCTAssertEqual(preview.strokes.map(\.audibleState), [.audible, .cut])
        XCTAssertEqual(preview.strokes.first?.travelPercent ?? -1, 32.0 / 3932.0 * 100.0, accuracy: 1e-9)
        XCTAssertEqual(preview.strokes.last?.travelPercent ?? -1, 11.0 / 3932.0 * 100.0, accuracy: 1e-9)
        XCTAssertTrue(preview.warnings.contains(.nonUnitStep))
    }

    // 4. .unknown audible state is preserved, not collapsed.
    func testUnknownPreserved() {
        let intent = ScratchNotationIntent(
            strokes: [stroke(.forward, 0, 1, 1, .unknown)], warnings: [])
        XCTAssertEqual(ScratchNotationLanePreviewAdapter.preview(from: intent).strokes.first?.audibleState, .unknown)
    }

    // 5. travelPercent > 100 preserved/unclamped.
    func testTravelNotClamped() {
        let intent = ScratchNotationIntent(
            strokes: [stroke(.forward, 0, 1, 250.0, .audible)], warnings: [])
        XCTAssertEqual(ScratchNotationLanePreviewAdapter.preview(from: intent).strokes.first?.travelPercent ?? -1,
                       250.0, accuracy: 1e-9)
    }

    // 6. Warnings preserve order.
    func testWarningsOrder() {
        let intent = ScratchNotationIntent(
            strokes: [], warnings: [.nonUnitStep, .emptyInput, .invalidCalibration])
        XCTAssertEqual(ScratchNotationLanePreviewAdapter.preview(from: intent).warnings,
                       [.nonUnitStep, .emptyInput, .invalidCalibration])
    }

    // 7. Stroke order preserved.
    func testStrokeOrderPreserved() {
        let intent = ScratchNotationIntent(strokes: [
            stroke(.forward, 0, 1, 1, .audible),
            stroke(.reverse, 1, 2, 2, .cut),
            stroke(.forward, 2, 3, 3, .unknown),
        ], warnings: [])
        let p = ScratchNotationLanePreviewAdapter.preview(from: intent)
        XCTAssertEqual(p.strokes.map(\.direction), [.forward, .reverse, .forward])
        XCTAssertEqual(p.strokes.map(\.startTime), [0, 1, 2])
    }

    // 8. durationSeconds = end - start.
    func testDurationSeconds() {
        let intent = ScratchNotationIntent(
            strokes: [stroke(.forward, 10.0, 12.5, 1, .audible)], warnings: [])
        XCTAssertEqual(ScratchNotationLanePreviewAdapter.preview(from: intent).strokes.first?.durationSeconds ?? -1,
                       2.5, accuracy: 1e-9)
    }

    // 9. durationSeconds floors at 0 for out-of-order endpoints.
    func testDurationSecondsNonNegative() {
        let intent = ScratchNotationIntent(
            strokes: [stroke(.reverse, 5.0, 4.0, 1, .cut)], warnings: [])
        XCTAssertEqual(ScratchNotationLanePreviewAdapter.preview(from: intent).strokes.first?.durationSeconds ?? -1,
                       0.0, accuracy: 1e-12)
    }

    // 10. Whole preview equals a verbatim rebuild from the intent (lossless mirror).
    func testLosslessMirror() throws {
        let intent = try realFaderIntent()
        let preview = ScratchNotationLanePreviewAdapter.preview(from: intent)
        let rebuilt = ScratchNotationLanePreviewModel(
            strokes: intent.strokes.map {
                .init(direction: $0.direction, startTime: $0.startTime, endTime: $0.endTime,
                      travelPercent: $0.travelPercent, audibleState: $0.audibleState)
            },
            warnings: intent.warnings)
        XCTAssertEqual(preview, rebuilt)
    }
}
