// Offline notation proof against a CHECKED-IN, repo-contained real-shape fixture.
//
// Loads `scratch_timeline_cc6_baby_fixture.json` (a tiny, privacy-safe ScratchSampleTimeline
// shape) from the test bundle, decodes it through ScratchAnalysisTimelineAdapter, and checks
// the C++ core's stroke output as NOTATION INTENT via an expected-stroke profile helper.
//
// Still offline analysis only: no audio playback, no realtime engine, no ring buffer, no
// RtMidi/CoreMIDI, no hardware. Self-contained: no reference to ScratchPlaybackLabEngine or
// ScratchPlaybackLabModel. Uses cc6Step directly (no raw-CC6 ring-delta).

import XCTest
@testable import ScratchLab

final class ScratchAnalysisCheckedInFixtureTests: XCTestCase {

    private static let fixtureName = "scratch_timeline_cc6_baby_fixture"

    /// RANE-measured CC6 steps-per-revolution (timeline JSON carries no calibration, so it
    /// is supplied explicitly).
    private let rane = ScratchAnalysisCalibration(stepsPerRevolution: 3932, crossfaderCutWidth: 0.05)

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

    // MARK: - Slice 6: expected-stroke profile helper (test-only, no UI)

    /// Expected notation intent for one stroke.
    private struct ExpectedStroke {
        let direction: ScratchStrokeDirection
        let audible: ScratchAudibleState
        /// travelPercent must be strictly greater than this (use 0 to require "non-zero").
        let minTravelPercent: Double
    }

    /// Compares the analysis output to an expected stroke profile: count, per-stroke
    /// direction, audible state, and a travelPercent lower bound.
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

    // 1. Checked-in fixture loads from the test bundle.
    func testFixtureLoadsFromBundle() throws {
        let data = try fixtureData()
        XCTAssertGreaterThan(data.count, 0, "fixture data should be non-empty")
    }

    // 2. Fixture decodes through the timeline adapter into wrapper-ready inputs.
    func testFixtureDecodesThroughAdapter() throws {
        let input = try ScratchAnalysisTimelineAdapter.decodeTimelineInput(
            data: try fixtureData(), calibration: rane)
        XCTAssertEqual(input.platter.count, 6, "6 cc6Step events")
        XCTAssertEqual(input.crossfader.count, 6, "6 crossfader samples")
    }

    // 3-6. Stroke count, direction sequence, audible states, and non-zero travelPercent,
    // expressed as a single notation profile.
    func testFixtureProducesExpectedNotationProfile() throws {
        let out = try ScratchAnalysisTimelineAdapter.analyzeTimeline(
            data: try fixtureData(), calibration: rane)
        assertProfile(out, [
            ExpectedStroke(direction: .forward, audible: .audible, minTravelPercent: 0),
            ExpectedStroke(direction: .reverse, audible: .cut, minTravelPercent: 0),
        ])
        // Exact travel: 3 steps / 3932 per rev * 100 for each stroke.
        XCTAssertEqual(out.strokes.first?.travelPercent ?? -1, 3.0 / 3932.0 * 100.0, accuracy: 1e-9)
        XCTAssertEqual(out.strokes.last?.travelPercent ?? -1, 3.0 / 3932.0 * 100.0, accuracy: 1e-9)
    }

    // 7. Pitch bend / audioRender / zone fields in the fixture do not affect output.
    // Equivalent values WITHOUT any of those fields must produce identical output.
    func testPitchBendAndPlaybackFieldsDoNotAffectOutput() throws {
        let fromFixture = try ScratchAnalysisTimelineAdapter.analyzeTimeline(
            data: try fixtureData(), calibration: rane)
        let cleanJSON = """
        {
          "events": [
            { "timeSeconds": 0.000, "cc6Step": 1, "crossfader": 1.0 },
            { "timeSeconds": 0.012, "cc6Step": 1, "crossfader": 1.0 },
            { "timeSeconds": 0.024, "cc6Step": 1, "crossfader": 1.0 },
            { "timeSeconds": 0.200, "cc6Step": -1, "crossfader": 0.0 },
            { "timeSeconds": 0.212, "cc6Step": -1, "crossfader": 0.0 },
            { "timeSeconds": 0.224, "cc6Step": -1, "crossfader": 0.0 }
          ]
        }
        """
        let fromClean = try ScratchAnalysisTimelineAdapter.analyzeTimeline(
            data: Data(cleanJSON.utf8), calibration: rane)
        XCTAssertEqual(fromFixture, fromClean, "ignored fields must not change the result")
    }

    // 8. Fader behavior stays honest: the fixture's open/cut faders give audible/cut, and a
    // fader-less timeline gives .unknown (no guessing).
    func testFaderBehaviorStaysHonest() throws {
        let out = try ScratchAnalysisTimelineAdapter.analyzeTimeline(
            data: try fixtureData(), calibration: rane)
        XCTAssertEqual(out.strokes.first?.audibleState, .audible, "open fader -> audible")
        XCTAssertEqual(out.strokes.last?.audibleState, .cut, "closed fader -> cut")

        let faderless = """
        {
          "events": [
            { "timeSeconds": 0.0, "cc6Step": 1 },
            { "timeSeconds": 0.1, "cc6Step": 1 }
          ]
        }
        """
        let unknown = try ScratchAnalysisTimelineAdapter.analyzeTimeline(
            data: Data(faderless.utf8), calibration: rane)
        XCTAssertEqual(unknown.strokes.first?.audibleState, .unknown, "absent fader -> unknown")
    }

    // 9. Adapter output equals a direct ScratchAnalysis.analyze for equivalent values.
    func testAdapterMatchesDirectAnalyze() throws {
        let viaAdapter = try ScratchAnalysisTimelineAdapter.analyzeTimeline(
            data: try fixtureData(), calibration: rane)
        let direct = ScratchAnalysis.analyze(
            platter: [
                .init(timeSeconds: 0.000, cc6Step: 1),
                .init(timeSeconds: 0.012, cc6Step: 1),
                .init(timeSeconds: 0.024, cc6Step: 1),
                .init(timeSeconds: 0.200, cc6Step: -1),
                .init(timeSeconds: 0.212, cc6Step: -1),
                .init(timeSeconds: 0.224, cc6Step: -1),
            ],
            crossfader: [
                .init(timeSeconds: 0.000, value: 1.0),
                .init(timeSeconds: 0.012, value: 1.0),
                .init(timeSeconds: 0.024, value: 1.0),
                .init(timeSeconds: 0.200, value: 0.0),
                .init(timeSeconds: 0.212, value: 0.0),
                .init(timeSeconds: 0.224, value: 0.0),
            ],
            calibration: rane
        )
        XCTAssertEqual(viaAdapter, direct)
    }
}
