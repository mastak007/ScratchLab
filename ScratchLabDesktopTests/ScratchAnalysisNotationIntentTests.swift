// Tests for ScratchAnalysisNotationAdapter — the UI-free notation-intent projection of the
// C++ analysis output.
//
// Unit tests (1-7) build ScratchAnalysisOutput directly and assert a lossless 1:1 mapping.
// End-to-end tests (8-9) run the real path: timeline fixture -> ScratchAnalysisTimelineAdapter
// -> ScratchAnalysis (Swift wrapper -> Obj-C++ bridge -> C++ core) -> notation intent.
//
// Offline only: no audio, no realtime engine, no ring buffer, no RtMidi/CoreMIDI, no hardware.
// No reference to ScratchPlaybackLabEngine or ScratchPlaybackLabModel. No UI / SwiftUI import.

import XCTest
@testable import ScratchLab

final class ScratchAnalysisNotationIntentTests: XCTestCase {

    private let rane = ScratchAnalysisCalibration(stepsPerRevolution: 3932, crossfaderCutWidth: 0.05)
    private let tenStepTravel = 10.0 / 3932.0 * 100.0

    // MARK: - Bundle fixture loading (shared with Slice 5 / Slice 6 fixtures)

    private func fixtureData(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            XCTFail("fixture \(name).json not found in test bundle \(bundle.bundleURL.path)", file: file, line: line)
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    // MARK: - Unit tests (direct ScratchAnalysisOutput)

    // 1. Converts one forward stroke.
    func testConvertsOneForwardStroke() {
        let output = ScratchAnalysisOutput(
            strokes: [.init(direction: .forward, startTime: 0.0, endTime: 0.2,
                            travelPercent: 1.5, audibleState: .audible)],
            warnings: [])
        let intent = ScratchAnalysisNotationAdapter.notationIntent(from: output)
        XCTAssertEqual(intent.strokes.count, 1)
        XCTAssertEqual(intent.strokes.first?.direction, .forward)
        XCTAssertEqual(intent.strokes.first?.audibleState, .audible)
    }

    // 2. Converts forward then reverse sequence in order.
    func testConvertsForwardThenReverseInOrder() {
        let output = ScratchAnalysisOutput(
            strokes: [
                .init(direction: .forward, startTime: 0.0, endTime: 0.1, travelPercent: 1.0, audibleState: .audible),
                .init(direction: .reverse, startTime: 0.2, endTime: 0.3, travelPercent: 2.0, audibleState: .cut),
            ],
            warnings: [])
        let intent = ScratchAnalysisNotationAdapter.notationIntent(from: output)
        XCTAssertEqual(intent.strokes.map(\.direction), [.forward, .reverse])
    }

    // 3. Preserves travelPercent exactly.
    func testPreservesTravelPercentExactly() {
        let value = 0.2543219876543
        let output = ScratchAnalysisOutput(
            strokes: [.init(direction: .forward, startTime: 0, endTime: 1, travelPercent: value, audibleState: .unknown)],
            warnings: [])
        let intent = ScratchAnalysisNotationAdapter.notationIntent(from: output)
        XCTAssertEqual(intent.strokes.first?.travelPercent ?? -1, value, accuracy: 1e-12)
    }

    // 4. Preserves audible, cut, and unknown states.
    func testPreservesAllAudibleStates() {
        let output = ScratchAnalysisOutput(
            strokes: [
                .init(direction: .forward, startTime: 0, endTime: 1, travelPercent: 1, audibleState: .audible),
                .init(direction: .reverse, startTime: 1, endTime: 2, travelPercent: 1, audibleState: .cut),
                .init(direction: .forward, startTime: 2, endTime: 3, travelPercent: 1, audibleState: .unknown),
            ],
            warnings: [])
        let intent = ScratchAnalysisNotationAdapter.notationIntent(from: output)
        XCTAssertEqual(intent.strokes.map(\.audibleState), [.audible, .cut, .unknown])
    }

    // 5. Preserves startTime/endTime exactly.
    func testPreservesStartEndTimesExactly() {
        let output = ScratchAnalysisOutput(
            strokes: [.init(direction: .reverse, startTime: 168525.1903115, endTime: 168526.01948145832,
                            travelPercent: 1, audibleState: .audible)],
            warnings: [])
        let intent = ScratchAnalysisNotationAdapter.notationIntent(from: output)
        XCTAssertEqual(intent.strokes.first?.startTime ?? -1, 168525.1903115, accuracy: 1e-9)
        XCTAssertEqual(intent.strokes.first?.endTime ?? -1, 168526.01948145832, accuracy: 1e-9)
    }

    // 6. Preserves warnings in order.
    func testPreservesWarningsInOrder() {
        let output = ScratchAnalysisOutput(
            strokes: [],
            warnings: [.emptyInput, .invalidCalibration, .nonUnitStep])
        let intent = ScratchAnalysisNotationAdapter.notationIntent(from: output)
        XCTAssertEqual(intent.warnings, [.emptyInput, .invalidCalibration, .nonUnitStep])
        XCTAssertTrue(intent.strokes.isEmpty)
    }

    // 7. Does not clamp travelPercent over 100.
    func testDoesNotClampTravelPercentOver100() {
        let output = ScratchAnalysisOutput(
            strokes: [.init(direction: .forward, startTime: 0, endTime: 1, travelPercent: 250.0, audibleState: .audible)],
            warnings: [])
        let intent = ScratchAnalysisNotationAdapter.notationIntent(from: output)
        XCTAssertEqual(intent.strokes.first?.travelPercent ?? -1, 250.0, accuracy: 1e-9)
    }

    // MARK: - End-to-end through the real analysis path

    // 8. Slice 5 synthetic checked-in fixture: forward/audible then reverse/cut.
    func testEndToEndSyntheticCheckedInFixture() throws {
        let output = try ScratchAnalysisTimelineAdapter.analyzeTimeline(
            data: try fixtureData("scratch_timeline_cc6_baby_fixture"), calibration: rane)
        let intent = ScratchAnalysisNotationAdapter.notationIntent(from: output)
        XCTAssertEqual(intent.strokes.map(\.direction), [.forward, .reverse])
        XCTAssertEqual(intent.strokes.map(\.audibleState), [.audible, .cut])
        // Intent is a faithful mirror of the analysis output.
        XCTAssertEqual(intent.strokes.map(\.travelPercent), output.strokes.map(\.travelPercent))
    }

    // 9. Slice 6 real trimmed fixture: forward then reverse, both audible, travel = 10/3932*100.
    func testEndToEndRealTrimmedFixture() throws {
        let output = try ScratchAnalysisTimelineAdapter.analyzeTimeline(
            data: try fixtureData("scratch_timeline_cc6_real_trimmed_fixture"), calibration: rane)
        let intent = ScratchAnalysisNotationAdapter.notationIntent(from: output)
        XCTAssertEqual(intent.strokes.map(\.direction), [.forward, .reverse])
        XCTAssertEqual(intent.strokes.map(\.audibleState), [.audible, .audible])
        XCTAssertEqual(intent.strokes.first?.travelPercent ?? -1, tenStepTravel, accuracy: 1e-9)
        XCTAssertEqual(intent.strokes.last?.travelPercent ?? -1, tenStepTravel, accuracy: 1e-9)
    }

    // 10. The whole intent equals a verbatim rebuild of the analysis output (lossless check).
    func testIntentIsLosslessMirrorOfOutput() throws {
        let output = try ScratchAnalysisTimelineAdapter.analyzeTimeline(
            data: try fixtureData("scratch_timeline_cc6_real_trimmed_fixture"), calibration: rane)
        let intent = ScratchAnalysisNotationAdapter.notationIntent(from: output)
        let rebuilt = ScratchNotationIntent(
            strokes: output.strokes.map {
                ScratchNotationIntentStroke(direction: $0.direction, startTime: $0.startTime,
                                            endTime: $0.endTime, travelPercent: $0.travelPercent,
                                            audibleState: $0.audibleState)
            },
            warnings: output.warnings)
        XCTAssertEqual(intent, rebuilt)
    }
}
