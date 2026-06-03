// Offline notation proof against a REAL trimmed ScratchTimeline export that contains an actual
// crossfader open -> cut transition.
//
// Loads `scratch_timeline_cc6_real_fader_cut_fixture.json` (31 contiguous events, source indices
// 920-950, copied verbatim from a real export) and runs it through the full path:
// timeline fixture -> ScratchAnalysisTimelineAdapter -> ScratchAnalysis (Swift wrapper ->
// Obj-C++ bridge -> C++ core) -> stroke output, and on to the notation-intent adapter.
//
// The capture tells a real story: a forward scratch with the crossfader OPEN that the DJ then
// pulls CLOSED, followed by a reverse stroke performed fully CUT. So unlike Slice 6 (constant
// fader, everything audible), this fixture exercises BOTH .audible and .cut on real data.
//
// NOTE on the forward travel value: the real signed CC6 sum over the forward run (indices
// 920-940) is 32 (the run contains non-unit +2/+3 steps from fast scratching), so the forward
// travel is 32/3932*100 -- not 31. The reverse run sums to -11 -> 11/3932*100.
//
// Offline only: no audio, no realtime engine, no ring buffer, no RtMidi/CoreMIDI, no hardware.
// No reference to ScratchPlaybackLabEngine or ScratchPlaybackLabModel. No UI / SwiftUI import.
// Uses cc6Step directly (no raw-CC6 ring-delta).

import XCTest
@testable import ScratchLab

final class ScratchAnalysisRealFaderFixtureTests: XCTestCase {

    private static let fixtureName = "scratch_timeline_cc6_real_fader_cut_fixture"

    /// RANE-measured CC6 steps-per-revolution. The timeline JSON carries no calibration, so it
    /// is supplied explicitly (no hidden default).
    private let rane = ScratchAnalysisCalibration(stepsPerRevolution: 3932, crossfaderCutWidth: 0.05)

    private let forwardTravel = 32.0 / 3932.0 * 100.0
    private let reverseTravel = 11.0 / 3932.0 * 100.0

    // MARK: - Bundle loading

    private func fixtureData(file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: Self.fixtureName, withExtension: "json") else {
            XCTFail("fixture \(Self.fixtureName).json not found in test bundle \(bundle.bundleURL.path)",
                    file: file, line: line)
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    // MARK: - Tests

    // 1. Real fader-cut fixture loads from the test bundle.
    func testFixtureLoadsFromBundle() throws {
        XCTAssertGreaterThan(try fixtureData().count, 0, "fixture data should be non-empty")
    }

    // 2. Fixture decodes through the timeline adapter into wrapper-ready inputs.
    func testFixtureDecodesThroughAdapter() throws {
        let input = try ScratchAnalysisTimelineAdapter.decodeTimelineInput(
            data: try fixtureData(), calibration: rane)
        XCTAssertEqual(input.platter.count, 31, "31 cc6Step events")
        XCTAssertEqual(input.crossfader.count, 31, "31 crossfader samples")
    }

    // 3-5. Exactly two strokes; direction [.forward, .reverse]; audible [.audible, .cut].
    func testProducesAudibleThenCutStrokes() throws {
        let out = try ScratchAnalysisTimelineAdapter.analyzeTimeline(
            data: try fixtureData(), calibration: rane)
        XCTAssertEqual(out.strokes.count, 2)
        XCTAssertEqual(out.strokes.map(\.direction), [.forward, .reverse])
        XCTAssertEqual(out.strokes.map(\.audibleState), [.audible, .cut])
    }

    // 6-7. Travel matches the real signed-step sums (forward 32, reverse 11).
    func testTravelMatchesRealStepSums() throws {
        let out = try ScratchAnalysisTimelineAdapter.analyzeTimeline(
            data: try fixtureData(), calibration: rane)
        XCTAssertEqual(out.strokes.first?.travelPercent ?? -1, forwardTravel, accuracy: 1e-9)
        XCTAssertEqual(out.strokes.last?.travelPercent ?? -1, reverseTravel, accuracy: 1e-9)
        XCTAssertGreaterThan(out.strokes.first?.travelPercent ?? 0, 0)
        XCTAssertLessThan(out.strokes.first?.travelPercent ?? 999, 5.0) // plausible: a small fraction of a turn
    }

    // 8. The non-unit (+2/+3/-2) steps raise the nonUnitStep warning.
    func testNonUnitStepWarningSurfaces() throws {
        let out = try ScratchAnalysisTimelineAdapter.analyzeTimeline(
            data: try fixtureData(), calibration: rane)
        XCTAssertTrue(out.warnings.contains(.nonUnitStep), "non-unit cc6 steps should raise nonUnitStep")
    }

    // 9. Ignored rawPitchBend / pitchBendDelta / audioRenderSeconds do not affect output.
    func testIgnoredFieldsDoNotAffectOutput() throws {
        let fromFixture = try ScratchAnalysisTimelineAdapter.analyzeTimeline(
            data: try fixtureData(), calibration: rane)
        let raw = try JSONSerialization.jsonObject(with: try fixtureData()) as? [String: Any]
        let rawEvents = (raw?["events"] as? [[String: Any]]) ?? []
        XCTAssertEqual(rawEvents.count, 31)
        let cleanEvents: [[String: Any]] = rawEvents.map {
            ["timeSeconds": $0["timeSeconds"] as Any, "cc6Step": $0["cc6Step"] as Any,
             "crossfader": $0["crossfader"] as Any]
        }
        let cleanData = try JSONSerialization.data(withJSONObject: ["events": cleanEvents])
        let fromClean = try ScratchAnalysisTimelineAdapter.analyzeTimeline(data: cleanData, calibration: rane)
        XCTAssertEqual(fromFixture, fromClean, "ignored pitch-bend / audio-render fields must not change output")
    }

    // 10. Adapter output equals a direct ScratchAnalysis.analyze for the equivalent values.
    func testAdapterMatchesDirectAnalyze() throws {
        let input = try ScratchAnalysisTimelineAdapter.decodeTimelineInput(
            data: try fixtureData(), calibration: rane)
        let viaAdapter = try ScratchAnalysisTimelineAdapter.analyzeTimeline(
            data: try fixtureData(), calibration: rane)
        let direct = ScratchAnalysis.analyze(
            platter: input.platter, crossfader: input.crossfader, calibration: rane)
        XCTAssertEqual(viaAdapter, direct)
    }

    // 11. Notation intent preserves the real [.audible, .cut] states (and the warning).
    func testNotationIntentPreservesAudibleAndCut() throws {
        let out = try ScratchAnalysisTimelineAdapter.analyzeTimeline(
            data: try fixtureData(), calibration: rane)
        let intent = ScratchAnalysisNotationAdapter.notationIntent(from: out)
        XCTAssertEqual(intent.strokes.map(\.direction), [.forward, .reverse])
        XCTAssertEqual(intent.strokes.map(\.audibleState), [.audible, .cut])
        XCTAssertTrue(intent.warnings.contains(.nonUnitStep))
    }
}
