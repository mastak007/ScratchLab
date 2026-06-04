// Offline notation proof against a REAL, trimmed ScratchTimeline export.
//
// Loads `scratch_timeline_cc6_real_trimmed_fixture.json` from the test bundle — a tiny,
// privacy-safe slice (20 contiguous events, source indices 3461-3480) copied verbatim from a
// real exported ScratchTimeline (schemaVersion 1). It straddles a single direction reversal:
// ten cc6Step=+1 then ten cc6Step=-1, with the capture's real (constant 0.551) crossfader and
// real pitch-bend / audio-render fields. Decodes through ScratchAnalysisTimelineAdapter and
// checks the C++ core's stroke output as NOTATION INTENT.
//
// Unlike `ScratchAnalysisCheckedInFixtureTests` (hand-authored synthetic-shape data), every
// value here is REAL captured data — these tests assert that (test 9).
//
// Still offline analysis only: no audio playback, no realtime engine, no ring buffer, no
// RtMidi/CoreMIDI, no hardware. Self-contained: no reference to ScratchPlaybackLabEngine or
// ScratchPlaybackLabModel. Uses cc6Step directly (no raw-CC6 ring-delta).

import XCTest
@testable import ScratchLab

final class ScratchAnalysisTrimmedRealFixtureTests: XCTestCase {

    private static let fixtureName = "scratch_timeline_cc6_real_trimmed_fixture"

    /// RANE-measured CC6 steps-per-revolution. The timeline JSON carries no calibration, so it
    /// is supplied explicitly (no hidden default).
    private let rane = ScratchAnalysisCalibration(stepsPerRevolution: 3932, crossfaderCutWidth: 0.05)

    /// Exact travel for a ten-step run: 10 / 3932 * 100.
    private let tenStepTravel = 10.0 / 3932.0 * 100.0

    // MARK: - Bundle loading

    private func fixtureURL(file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: Self.fixtureName, withExtension: "json") else {
            XCTFail("fixture \(Self.fixtureName).json not found in test bundle \(bundle.bundleURL.path)",
                    file: file, line: line)
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }

    private func fixtureData() throws -> Data { try Data(contentsOf: try fixtureURL()) }

    // MARK: - Expected-stroke profile helper (test-only, no UI)

    private struct ExpectedStroke {
        let direction: ScratchStrokeDirection
        let audible: ScratchAudibleState
        /// travelPercent must be strictly greater than this (use 0 to require "non-zero").
        let minTravelPercent: Double
    }

    private func assertProfile(
        _ output: ScratchAnalysisOutput,
        _ expected: [ExpectedStroke],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(output.strokes.count, expected.count, "stroke count", file: file, line: line)
        guard output.strokes.count == expected.count else { return }
        for (i, pair) in zip(output.strokes, expected).enumerated() {
            let (stroke, want) = pair
            XCTAssertEqual(stroke.direction, want.direction, "stroke \(i) direction", file: file, line: line)
            XCTAssertEqual(stroke.audibleState, want.audible, "stroke \(i) audible", file: file, line: line)
            XCTAssertGreaterThan(stroke.travelPercent, want.minTravelPercent,
                                 "stroke \(i) travelPercent", file: file, line: line)
        }
    }

    // MARK: - Tests

    // 1. Real trimmed fixture loads from the test bundle.
    func testFixtureLoadsFromBundle() throws {
        let data = try fixtureData()
        XCTAssertGreaterThan(data.count, 0, "fixture data should be non-empty")
    }

    // 2. Real trimmed fixture decodes through the timeline adapter into wrapper-ready inputs.
    func testFixtureDecodesThroughAdapter() throws {
        let input = try ScratchAnalysisTimelineAdapter.decodeTimelineInput(
            data: try fixtureData(), calibration: rane)
        XCTAssertEqual(input.platter.count, 20, "20 cc6Step events")
        XCTAssertEqual(input.crossfader.count, 20, "20 crossfader samples (all present in this slice)")
    }

    // 3-5. Stroke count, real forward-then-reverse direction sequence, plausible non-zero travel.
    // 6. Crossfader honesty: the real constant 0.551 fader (>= 0.05 cut width) reads .audible.
    func testFixtureProducesExpectedNotationProfile() throws {
        let out = try ScratchAnalysisTimelineAdapter.analyzeTimeline(
            data: try fixtureData(), calibration: rane)
        assertProfile(out, [
            ExpectedStroke(direction: .forward, audible: .audible, minTravelPercent: 0),
            ExpectedStroke(direction: .reverse, audible: .audible, minTravelPercent: 0),
        ])
        // Exact travel: each run is ten unit steps.
        XCTAssertEqual(out.strokes.first?.travelPercent ?? -1, tenStepTravel, accuracy: 1e-9)
        XCTAssertEqual(out.strokes.last?.travelPercent ?? -1, tenStepTravel, accuracy: 1e-9)
        // Plausibility: a ~0.25% sliver of a revolution, well under a full turn.
        XCTAssertLessThan(out.strokes.first?.travelPercent ?? 999, 1.0)
    }

    // 7. Real pitch-bend / audio-render fields in the fixture do not affect output. The same
    // events carrying ONLY timeSeconds/cc6Step/crossfader must produce identical output.
    func testIgnoredFieldsDoNotAffectOutput() throws {
        let fromFixture = try ScratchAnalysisTimelineAdapter.analyzeTimeline(
            data: try fixtureData(), calibration: rane)

        // Re-decode the fixture, strip everything the adapter ignores, re-encode, re-analyze.
        let raw = try JSONSerialization.jsonObject(with: try fixtureData()) as? [String: Any]
        let rawEvents = (raw?["events"] as? [[String: Any]]) ?? []
        XCTAssertEqual(rawEvents.count, 20)
        let cleanEvents: [[String: Any]] = rawEvents.map { e in
            [
                "timeSeconds": e["timeSeconds"] as Any,
                "cc6Step": e["cc6Step"] as Any,
                "crossfader": e["crossfader"] as Any,
            ]
        }
        let cleanData = try JSONSerialization.data(withJSONObject: ["events": cleanEvents])
        let fromClean = try ScratchAnalysisTimelineAdapter.analyzeTimeline(
            data: cleanData, calibration: rane)
        XCTAssertEqual(fromFixture, fromClean, "ignored pitch-bend / audio-render fields must not change output")
    }

    // 8. Adapter output equals a direct ScratchAnalysis.analyze for the equivalent values.
    func testAdapterMatchesDirectAnalyze() throws {
        let input = try ScratchAnalysisTimelineAdapter.decodeTimelineInput(
            data: try fixtureData(), calibration: rane)
        let viaAdapter = try ScratchAnalysisTimelineAdapter.analyzeTimeline(
            data: try fixtureData(), calibration: rane)
        let direct = ScratchAnalysis.analyze(
            platter: input.platter,
            crossfader: input.crossfader,
            calibration: rane)
        XCTAssertEqual(viaAdapter, direct)
    }

    // 9. The fixture carries ACTUAL copied values from the real export, not synthetic ones.
    // These are the verbatim timeSeconds/cc6Step (and crossfader) of source events 3461-3480.
    func testFixtureCarriesRealCopiedValues() throws {
        let input = try ScratchAnalysisTimelineAdapter.decodeTimelineInput(
            data: try fixtureData(), calibration: rane)
        // Real export host-clock timestamps (large, monotonic) — not tidy synthetic 0.0/0.01 values.
        XCTAssertEqual(input.platter.first?.timeSeconds ?? -1, 168719.47665162498, accuracy: 1e-6)
        XCTAssertEqual(input.platter.last?.timeSeconds ?? -1, 168720.0, accuracy: 1.0)
        XCTAssertGreaterThan(input.platter.last?.timeSeconds ?? 0, input.platter.first?.timeSeconds ?? 0)
        // Real signed step sequence: ten +1 then ten -1.
        XCTAssertEqual(input.platter.map(\.cc6Step), Array(repeating: 1, count: 10) + Array(repeating: -1, count: 10))
        // Real crossfader value from the capture (70/127 of a 7-bit fader).
        XCTAssertEqual(input.crossfader.first?.value ?? -1, 0.5511811023622047, accuracy: 1e-12)
    }
}
