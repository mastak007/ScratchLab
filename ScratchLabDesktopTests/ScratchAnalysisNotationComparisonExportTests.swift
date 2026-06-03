// Tests for ScratchAnalysisNotationComparisonExportAdapter — the deterministic Codable export
// DTO for a ScratchNotationComparisonReport.
//
// Verifies stable schema/strings, that countMismatches and unsupported fields and warnings are
// visible, JSON round-trips, and output is deterministic with a fixed generatedAtEpochSeconds.
// End-to-end uses the Slice 8 real fader fixture.
//
// Offline only. No SwiftUI import. No ScratchPlaybackLabEngine / ScratchPlaybackLabModel.

import XCTest
@testable import ScratchLab

final class ScratchAnalysisNotationComparisonExportTests: XCTestCase {

    private let rane = ScratchAnalysisCalibration(stepsPerRevolution: 3932, crossfaderCutWidth: 0.05)
    private let tol = 0.001

    // MARK: - Builders

    private func stroke(_ dir: ScratchStrokeDirection, _ start: Double, _ end: Double,
                        _ travel: Double, _ audible: ScratchAudibleState) -> ScratchNotationIntentStroke {
        ScratchNotationIntentStroke(direction: dir, startTime: start, endTime: end,
                                    travelPercent: travel, audibleState: audible)
    }

    private func lane(_ dir: ScratchNotationDirection, _ start: Double, _ end: Double,
                      _ fader: ScratchNotationFaderState) -> LaneStroke {
        LaneStroke(startTime: start, endTime: end, direction: dir,
                   speed: .medium, faderState: fader, isGhost: false)
    }

    private func fixtureData(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            XCTFail("fixture \(name).json not found in \(bundle.bundleURL.path)", file: file, line: line)
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    private func deterministicEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }

    /// The Slice 8 real fader comparison report (forward/audible + reverse/cut).
    private func realFaderReport() throws -> ScratchNotationComparisonReport {
        let out = try ScratchAnalysisTimelineAdapter.analyzeTimeline(
            data: try fixtureData("scratch_timeline_cc6_real_fader_cut_fixture"), calibration: rane)
        let intent = ScratchAnalysisNotationAdapter.notationIntent(from: out)
        let reference = [
            lane(.forward, intent.strokes[0].startTime, intent.strokes[0].endTime, .open),
            lane(.backward, intent.strokes[1].startTime, intent.strokes[1].endTime, .closed),
        ]
        return ScratchAnalysisNotationComparison.compare(
            intent: intent, reference: reference, timingToleranceSeconds: tol)
    }

    // MARK: - Tests

    // 1. JSON encode/decode round-trip.
    func testRoundTrips() throws {
        let export = ScratchAnalysisNotationComparisonExportAdapter.export(
            report: try realFaderReport(), sourceKind: .realFixture,
            sourceName: "slice8", generatedAtEpochSeconds: 1234.5)
        let data = try deterministicEncoder().encode(export)
        let decoded = try JSONDecoder().decode(ScratchNotationComparisonExport.self, from: data)
        XCTAssertEqual(decoded, export)
    }

    // 2-3-4. Slice 8 real fader export: sourceKind/sourceName/timestamp preserved; schema versioned.
    func testRealFaderExportMetadata() throws {
        let export = ScratchAnalysisNotationComparisonExportAdapter.export(
            report: try realFaderReport(), sourceKind: .realFixture,
            sourceName: "ScratchTimeline-1780500806", generatedAtEpochSeconds: 42.0)
        XCTAssertEqual(export.schemaVersion, "scratch_notation_comparison_export_v1")
        XCTAssertEqual(export.sourceKind, .realFixture)
        XCTAssertEqual(export.sourceName, "ScratchTimeline-1780500806")
        XCTAssertEqual(export.generatedAtEpochSeconds, 42.0)
        XCTAssertEqual(export.intentStrokeCount, 2)
        XCTAssertEqual(export.referenceStrokeCount, 2)
    }

    // 5. unsupportedFields contains "travelPercent".
    func testTravelPercentVisible() throws {
        let export = ScratchAnalysisNotationComparisonExportAdapter.export(
            report: try realFaderReport(), sourceKind: .realFixture,
            sourceName: nil, generatedAtEpochSeconds: nil)
        XCTAssertTrue(export.unsupportedFields.contains("travelPercent"))
    }

    // 6. "audibleStateUnknown" appears when the report includes a .unknown stroke.
    func testAudibleStateUnknownVisible() {
        let intent = ScratchNotationIntent(
            strokes: [stroke(.forward, 0, 1, 1, .unknown)], warnings: [])
        let report = ScratchAnalysisNotationComparison.compare(
            intent: intent, reference: [lane(.forward, 0, 1, .open)], timingToleranceSeconds: tol)
        let export = ScratchAnalysisNotationComparisonExportAdapter.export(
            report: report, sourceKind: .manual, sourceName: nil, generatedAtEpochSeconds: nil)
        XCTAssertTrue(export.unsupportedFields.contains("audibleStateUnknown"))
        XCTAssertTrue(export.unsupportedFields.contains("travelPercent"))
    }

    // 7. warnings include "nonUnitStep" (from the real fader fixture's +2/+3/-2 steps).
    func testWarningsVisible() throws {
        let export = ScratchAnalysisNotationComparisonExportAdapter.export(
            report: try realFaderReport(), sourceKind: .realFixture,
            sourceName: nil, generatedAtEpochSeconds: nil)
        XCTAssertTrue(export.warnings.contains("nonUnitStep"))
    }

    // 8. countMismatches export as a stable "count" mismatch.
    func testCountMismatchExportsStableString() {
        let intent = ScratchNotationIntent(
            strokes: [stroke(.forward, 0, 1, 1, .audible), stroke(.reverse, 1, 2, 1, .cut)], warnings: [])
        let report = ScratchAnalysisNotationComparison.compare(
            intent: intent, reference: [lane(.forward, 0, 1, .open)], timingToleranceSeconds: tol)
        let export = ScratchAnalysisNotationComparisonExportAdapter.export(
            report: report, sourceKind: .manual, sourceName: nil, generatedAtEpochSeconds: nil)
        XCTAssertEqual(export.countMismatches, [.init(index: 1, kind: "count")])
    }

    // 9. JSON output is deterministic with a fixed generatedAtEpochSeconds.
    func testDeterministicJSON() throws {
        let report = try realFaderReport()
        let a = try deterministicEncoder().encode(ScratchAnalysisNotationComparisonExportAdapter.export(
            report: report, sourceKind: .realFixture, sourceName: "x", generatedAtEpochSeconds: 7.0))
        let b = try deterministicEncoder().encode(ScratchAnalysisNotationComparisonExportAdapter.export(
            report: report, sourceKind: .realFixture, sourceName: "x", generatedAtEpochSeconds: 7.0))
        XCTAssertEqual(a, b, "same report + fixed timestamp must encode to identical bytes")
    }

    // 10. nil generatedAtEpochSeconds is allowed and round-trips.
    func testNilTimestampRoundTrips() throws {
        let export = ScratchAnalysisNotationComparisonExportAdapter.export(
            report: try realFaderReport(), sourceKind: .realFixture,
            sourceName: nil, generatedAtEpochSeconds: nil)
        XCTAssertNil(export.generatedAtEpochSeconds)
        let data = try deterministicEncoder().encode(export)
        let decoded = try JSONDecoder().decode(ScratchNotationComparisonExport.self, from: data)
        XCTAssertEqual(decoded, export)
        XCTAssertNil(decoded.sourceName)
    }
}
