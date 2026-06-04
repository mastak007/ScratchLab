// Tests for ScratchNotationIntentDebugFormatter — a UI-free, deterministic text readout for
// ScratchNotationIntent.
//
// Offline only. No SwiftUI import. No ScratchPlaybackLabEngine / ScratchPlaybackLabModel.
// Uses existing checked-in fixtures; adds no resources.

import XCTest
@testable import ScratchLab

final class ScratchNotationIntentDebugFormatterTests: XCTestCase {

    private let rane = ScratchAnalysisCalibration(stepsPerRevolution: 3932, crossfaderCutWidth: 0.05)

    // MARK: - Builders / loaders

    private func stroke(
        _ direction: ScratchStrokeDirection,
        _ startTime: Double,
        _ endTime: Double,
        _ travelPercent: Double,
        _ audibleState: ScratchAudibleState
    ) -> ScratchNotationIntentStroke {
        ScratchNotationIntentStroke(
            direction: direction,
            startTime: startTime,
            endTime: endTime,
            travelPercent: travelPercent,
            audibleState: audibleState
        )
    }

    private func fixtureData(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            XCTFail("fixture \(name).json not found in \(bundle.bundleURL.path)", file: file, line: line)
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    private func intent(forFixture name: String) throws -> ScratchNotationIntent {
        let output = try ScratchAnalysisTimelineAdapter.analyzeTimeline(
            data: try fixtureData(name),
            calibration: rane
        )
        return ScratchAnalysisNotationAdapter.notationIntent(from: output)
    }

    private func formatterSource(file: StaticString = #filePath) throws -> String {
        let testURL = URL(fileURLWithPath: "\(file)")
        let sourceURL = testURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ScratchLab/Analysis/ScratchNotationIntentDebugFormatter.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    // MARK: - Tests

    func testEmptyIntentReadout() {
        let intent = ScratchNotationIntent(strokes: [], warnings: [])
        let lines = ScratchNotationIntentDebugFormatter.lines(for: intent)

        XCTAssertEqual(lines, [
            "Scratch notation intent",
            "strokes: 0",
            "warnings: none",
        ])
    }

    func testOneForwardAudibleStroke() {
        let intent = ScratchNotationIntent(
            strokes: [stroke(.forward, 168719.47666, 168719.81234, 0.8142, .audible)],
            warnings: []
        )

        XCTAssertEqual(ScratchNotationIntentDebugFormatter.lines(for: intent), [
            "Scratch notation intent",
            "strokes: 1",
            "1. forward · audible · travel 0.814% · 168719.4767s → 168719.8123s",
            "warnings: none",
        ])
    }

    func testRealFaderFixtureReadout() throws {
        let intent = try intent(forFixture: "scratch_timeline_cc6_real_fader_cut_fixture")
        let lines = ScratchNotationIntentDebugFormatter.lines(for: intent)

        XCTAssertEqual(lines[0], "Scratch notation intent")
        XCTAssertEqual(lines[1], "strokes: 2")
        XCTAssertTrue(lines[2].contains("1. forward · audible"))
        XCTAssertTrue(lines[2].contains("travel 0.814%"))
        XCTAssertTrue(lines[3].contains("2. reverse · cut"))
        XCTAssertTrue(lines[3].contains("travel 0.280%"))
        XCTAssertEqual(lines[4], "warnings: nonUnitStep")
    }

    func testCheckedInFixtureReadout() throws {
        let intent = try intent(forFixture: "scratch_timeline_cc6_baby_fixture")
        let lines = ScratchNotationIntentDebugFormatter.lines(for: intent)

        XCTAssertEqual(lines[1], "strokes: 2")
        XCTAssertTrue(lines[2].contains("forward · audible"))
        XCTAssertTrue(lines[3].contains("reverse · cut"))
        XCTAssertEqual(lines[4], "warnings: none")
    }

    func testUnknownAudibleStateAppearsAsUnknown() {
        let intent = ScratchNotationIntent(
            strokes: [stroke(.forward, 0, 1, 1.0, .unknown)],
            warnings: []
        )

        XCTAssertTrue(ScratchNotationIntentDebugFormatter.text(for: intent).contains("forward · unknown"))
    }

    func testTravelPercentOver100IsNotClamped() {
        let intent = ScratchNotationIntent(
            strokes: [stroke(.forward, 0, 1, 250.0, .audible)],
            warnings: []
        )

        XCTAssertTrue(ScratchNotationIntentDebugFormatter.text(for: intent).contains("travel 250.000%"))
    }

    func testMultipleWarningsAreCommaSeparatedInOrder() {
        let intent = ScratchNotationIntent(
            strokes: [],
            warnings: [.emptyInput, .invalidCalibration, .nonUnitStep]
        )

        XCTAssertEqual(
            ScratchNotationIntentDebugFormatter.lines(for: intent).last,
            "warnings: emptyInput, invalidCalibration, nonUnitStep"
        )
    }

    func testTextEqualsJoinedLines() {
        let intent = ScratchNotationIntent(
            strokes: [stroke(.reverse, 1.23456, 2.34567, 3.45678, .cut)],
            warnings: [.nonUnitStep]
        )

        XCTAssertEqual(
            ScratchNotationIntentDebugFormatter.text(for: intent),
            ScratchNotationIntentDebugFormatter.lines(for: intent).joined(separator: "\n")
        )
    }

    func testDeterministicOutput() throws {
        let intent = try intent(forFixture: "scratch_timeline_cc6_real_fader_cut_fixture")

        let a = ScratchNotationIntentDebugFormatter.lines(for: intent)
        let b = ScratchNotationIntentDebugFormatter.lines(for: intent)

        XCTAssertEqual(a, b)
    }

    func testFormatterHasNoUIPlaybackOrExportDependency() throws {
        let source = try formatterSource()

        XCTAssertFalse(source.contains("SwiftUI"))
        XCTAssertFalse(source.contains("View"))
        XCTAssertFalse(source.contains("Renderer"))
        XCTAssertFalse(source.contains("Playback"))
        XCTAssertFalse(source.contains("ScratchPlaybackLabEngine"))
        XCTAssertFalse(source.contains("ScratchPlaybackLabModel"))
        XCTAssertFalse(source.contains("ScratchNotationIntentExport"))
        XCTAssertFalse(source.contains("ScratchNotationComparisonExport"))
        XCTAssertFalse(source.contains("FileManager"))
        XCTAssertFalse(source.contains("Date("))
    }
}
