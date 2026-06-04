// Tests for ScratchAnalysisNotationIntentExportAdapter — the deterministic, lossless Codable
// export of a ScratchNotationIntent.
//
// Verifies stable schema/strings, lossless travelPercent (unclamped) and `.unknown` audible
// preservation, warnings visibility, JSON round-trip, and deterministic output with a fixed
// generatedAtEpochSeconds. End-to-end uses the merged Slice 5 (synthetic) and Slice 8 (real
// fader) fixtures.
//
// Offline only. No SwiftUI import. No ScratchPlaybackLabEngine / ScratchPlaybackLabModel.

import XCTest
@testable import ScratchLab

final class ScratchAnalysisNotationIntentExportTests: XCTestCase {

    private let rane = ScratchAnalysisCalibration(stepsPerRevolution: 3932, crossfaderCutWidth: 0.05)

    // MARK: - Builders / loaders

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

    private func intent(forFixture name: String) throws -> ScratchNotationIntent {
        let out = try ScratchAnalysisTimelineAdapter.analyzeTimeline(
            data: try fixtureData(name), calibration: rane)
        return ScratchAnalysisNotationAdapter.notationIntent(from: out)
    }

    private func deterministicEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }

    // MARK: - Tests

    // 1. JSON encode/decode round-trip.
    func testRoundTrips() throws {
        let export = ScratchAnalysisNotationIntentExportAdapter.export(
            intent: try intent(forFixture: "scratch_timeline_cc6_real_fader_cut_fixture"),
            sourceKind: .realFixture, sourceName: "slice8", generatedAtEpochSeconds: 1234.5)
        let data = try deterministicEncoder().encode(export)
        let decoded = try JSONDecoder().decode(ScratchNotationIntentExport.self, from: data)
        XCTAssertEqual(decoded, export)
    }

    // 2-4. schemaVersion + metadata preserved.
    func testSchemaAndMetadata() throws {
        let export = ScratchAnalysisNotationIntentExportAdapter.export(
            intent: try intent(forFixture: "scratch_timeline_cc6_real_fader_cut_fixture"),
            sourceKind: .realFixture, sourceName: "ScratchTimeline-1780500806", generatedAtEpochSeconds: 42.0)
        XCTAssertEqual(export.schemaVersion, "scratch_notation_intent_export_v1")
        XCTAssertEqual(export.sourceKind, .realFixture)
        XCTAssertEqual(export.sourceName, "ScratchTimeline-1780500806")
        XCTAssertEqual(export.generatedAtEpochSeconds, 42.0)
    }

    // 5. nil generatedAtEpochSeconds round-trips.
    func testNilTimestampRoundTrips() throws {
        let export = ScratchAnalysisNotationIntentExportAdapter.export(
            intent: try intent(forFixture: "scratch_timeline_cc6_real_fader_cut_fixture"),
            sourceKind: .realFixture, sourceName: nil, generatedAtEpochSeconds: nil)
        XCTAssertNil(export.generatedAtEpochSeconds)
        let data = try deterministicEncoder().encode(export)
        let decoded = try JSONDecoder().decode(ScratchNotationIntentExport.self, from: data)
        XCTAssertEqual(decoded, export)
        XCTAssertNil(decoded.sourceName)
    }

    // 6. Slice 8 real fader intent export: forward/audible + reverse/cut, exact travel, nonUnitStep.
    func testRealFaderIntentExport() throws {
        let export = ScratchAnalysisNotationIntentExportAdapter.export(
            intent: try intent(forFixture: "scratch_timeline_cc6_real_fader_cut_fixture"),
            sourceKind: .realFixture, sourceName: nil, generatedAtEpochSeconds: nil)
        XCTAssertEqual(export.strokes.map(\.direction), ["forward", "reverse"])
        XCTAssertEqual(export.strokes.map(\.audibleState), ["audible", "cut"])
        XCTAssertEqual(export.strokes.first?.travelPercent ?? -1, 32.0 / 3932.0 * 100.0, accuracy: 1e-9)
        XCTAssertEqual(export.strokes.last?.travelPercent ?? -1, 11.0 / 3932.0 * 100.0, accuracy: 1e-9)
        XCTAssertTrue(export.warnings.contains("nonUnitStep"))
    }

    // 7. Slice 5 synthetic checked-in fixture export works (forward/audible + reverse/cut).
    func testSyntheticCheckedInIntentExport() throws {
        let export = ScratchAnalysisNotationIntentExportAdapter.export(
            intent: try intent(forFixture: "scratch_timeline_cc6_baby_fixture"),
            sourceKind: .syntheticFixture, sourceName: "slice5", generatedAtEpochSeconds: nil)
        XCTAssertEqual(export.sourceKind, .syntheticFixture)
        XCTAssertEqual(export.strokes.map(\.direction), ["forward", "reverse"])
        XCTAssertEqual(export.strokes.map(\.audibleState), ["audible", "cut"])
    }

    // 8. .unknown audible state serializes as "unknown".
    func testUnknownAudibleSerializesAsUnknown() {
        let intent = ScratchNotationIntent(
            strokes: [stroke(.forward, 0, 1, 1.0, .unknown)], warnings: [])
        let export = ScratchAnalysisNotationIntentExportAdapter.export(
            intent: intent, sourceKind: .manual, sourceName: nil, generatedAtEpochSeconds: nil)
        XCTAssertEqual(export.strokes.first?.audibleState, "unknown")
    }

    // 9. travelPercent > 100 is not clamped.
    func testTravelPercentNotClamped() {
        let intent = ScratchNotationIntent(
            strokes: [stroke(.forward, 0, 1, 250.0, .audible)], warnings: [])
        let export = ScratchAnalysisNotationIntentExportAdapter.export(
            intent: intent, sourceKind: .manual, sourceName: nil, generatedAtEpochSeconds: nil)
        XCTAssertEqual(export.strokes.first?.travelPercent ?? -1, 250.0, accuracy: 1e-9)
    }

    // 10. Deterministic JSON output with fixed timestamp + sortedKeys.
    func testDeterministicJSON() throws {
        let intent = try intent(forFixture: "scratch_timeline_cc6_real_fader_cut_fixture")
        let a = try deterministicEncoder().encode(ScratchAnalysisNotationIntentExportAdapter.export(
            intent: intent, sourceKind: .realFixture, sourceName: "x", generatedAtEpochSeconds: 7.0))
        let b = try deterministicEncoder().encode(ScratchAnalysisNotationIntentExportAdapter.export(
            intent: intent, sourceKind: .realFixture, sourceName: "x", generatedAtEpochSeconds: 7.0))
        XCTAssertEqual(a, b, "same intent + fixed timestamp must encode to identical bytes")
    }

    // 11. Warnings + empty-stroke intent: warnings preserved in order, strokes empty.
    func testWarningsPreservedOrder() {
        let intent = ScratchNotationIntent(
            strokes: [], warnings: [.emptyInput, .invalidCalibration, .nonUnitStep])
        let export = ScratchAnalysisNotationIntentExportAdapter.export(
            intent: intent, sourceKind: .manual, sourceName: nil, generatedAtEpochSeconds: nil)
        XCTAssertEqual(export.warnings, ["emptyInput", "invalidCalibration", "nonUnitStep"])
        XCTAssertTrue(export.strokes.isEmpty)
    }
}
