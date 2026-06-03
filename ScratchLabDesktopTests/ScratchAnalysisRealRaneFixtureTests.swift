// Offline proof against the REAL RANE scratch-sample timeline shape.
//
// Inline JSON uses the exact ScratchSampleTimelineEvent field names (timeSeconds, position,
// velocity, crossfader, muted, cc6Step, rawPitchBend, zone*, audioRender*, ...) so it
// exercises ScratchAnalysisTimelineAdapter against the real capture shape. The adapter reads
// only timeSeconds/cc6Step/crossfader and ignores the rest. Routes through
// ScratchAnalysis.analyze (Swift wrapper -> Obj-C++ bridge -> C++ core).
//
// Self-contained: no reference to ScratchPlaybackLabEngine or ScratchPlaybackLabModel, no
// hardware, no audio, no external files.

import XCTest
@testable import ScratchLab

final class ScratchAnalysisRealRaneFixtureTests: XCTestCase {

    private func data(_ json: String) -> Data { Data(json.utf8) }

    /// RANE-measured CC6 steps-per-revolution (documented on the rane mapper). Calibration
    /// is supplied explicitly because the timeline JSON carries none.
    private let rane = ScratchAnalysisCalibration(stepsPerRevolution: 3932, crossfaderCutWidth: 0.05)

    // A same-direction run of cc6Step = +1 with full pitch-bend/zone/playback noise present.
    private let sameDirectionTimeline = """
    {
      "muteCrossfaderBelow": 0.05,
      "didReachCapacity": false,
      "events": [
        { "timeSeconds": 0.00, "position": 0.50, "velocity": 0.1, "crossfader": 1.0, "muted": false, "cc6Step": 1, "rawPitchBend": 8192, "pitchBendDelta": 0, "zoneAudioMode": "velocity", "audioRenderSeconds": 0.0 },
        { "timeSeconds": 0.01, "position": 0.51, "velocity": 0.1, "crossfader": 1.0, "muted": false, "cc6Step": 1, "rawPitchBend": 8260, "pitchBendDelta": 68, "zoneTargetSeconds": 1.2, "zoneScrubRate": 0.9 },
        { "timeSeconds": 0.02, "position": 0.52, "velocity": 0.1, "crossfader": 1.0, "muted": false, "cc6Step": 1, "rawPitchBend": 8328, "pitchBendDelta": 68, "mapperSampleSeconds": 0.02, "audioMapperDriftSeconds": 0.0 }
      ]
    }
    """

    // 1. Real-shape timeline JSON decodes into wrapper-ready inputs.
    func testTimelineDecodes() throws {
        let input = try ScratchAnalysisTimelineAdapter.decodeTimelineInput(
            data: data(sameDirectionTimeline), calibration: rane)
        XCTAssertEqual(input.platter.count, 3)
        XCTAssertEqual(input.crossfader.count, 3)
        XCTAssertEqual(input.calibration.stepsPerRevolution, 3932, accuracy: 1e-9)
    }

    // 2. cc6Step maps directly (no ring-delta); position-only samples (nil cc6Step) are skipped.
    func testCc6StepMapsDirectlyAndSkipsNilSteps() throws {
        let json = """
        {
          "events": [
            { "timeSeconds": 0.00, "position": 0.50, "velocity": 0.0, "muted": false, "cc6Step": 1 },
            { "timeSeconds": 0.01, "position": 0.50, "velocity": 0.0, "muted": false },
            { "timeSeconds": 0.02, "position": 0.51, "velocity": 0.1, "muted": false, "cc6Step": 1 }
          ]
        }
        """
        let input = try ScratchAnalysisTimelineAdapter.decodeTimelineInput(data: data(json), calibration: rane)
        XCTAssertEqual(input.platter.count, 2, "the nil-cc6Step sample is skipped")
        XCTAssertEqual(input.platter.map(\.cc6Step), [1, 1])
        XCTAssertEqual(input.platter.map(\.timeSeconds), [0.0, 0.02])
    }

    // 4. Same-direction run returns one stroke.
    func testSameDirectionOneStroke() throws {
        let out = try ScratchAnalysisTimelineAdapter.analyzeTimeline(
            data: data(sameDirectionTimeline), calibration: rane)
        XCTAssertEqual(out.strokes.count, 1)
        XCTAssertEqual(out.strokes.first?.direction, .forward)
        XCTAssertEqual(out.strokes.first?.travelPercent ?? -1, 3.0 / 3932.0 * 100.0, accuracy: 1e-9)
    }

    // 5. Reversal returns two strokes (forward then reverse).
    func testReversalTwoStrokes() throws {
        let json = """
        {
          "events": [
            { "timeSeconds": 0.00, "position": 0.50, "velocity": 0.1, "muted": false, "cc6Step": 1 },
            { "timeSeconds": 0.01, "position": 0.51, "velocity": 0.1, "muted": false, "cc6Step": 1 },
            { "timeSeconds": 0.02, "position": 0.50, "velocity": -0.1, "muted": false, "cc6Step": -1 },
            { "timeSeconds": 0.03, "position": 0.49, "velocity": -0.1, "muted": false, "cc6Step": -1 }
          ]
        }
        """
        let out = try ScratchAnalysisTimelineAdapter.analyzeTimeline(data: data(json), calibration: rane)
        XCTAssertEqual(out.strokes.count, 2)
        XCTAssertEqual(out.strokes.first?.direction, .forward)
        XCTAssertEqual(out.strokes.last?.direction, .reverse)
    }

    // 6. All-nil / missing crossfader -> audibleState .unknown.
    func testMissingCrossfaderUnknown() throws {
        let json = """
        {
          "events": [
            { "timeSeconds": 0.00, "position": 0.50, "velocity": 0.1, "muted": false, "cc6Step": 1 },
            { "timeSeconds": 0.01, "position": 0.51, "velocity": 0.1, "muted": false, "cc6Step": 1 }
          ]
        }
        """
        let out = try ScratchAnalysisTimelineAdapter.analyzeTimeline(data: data(json), calibration: rane)
        XCTAssertEqual(out.strokes.first?.audibleState, .unknown)
    }

    // 7. Crossfader open -> .audible.
    func testCrossfaderOpenAudible() throws {
        let json = """
        {
          "events": [
            { "timeSeconds": 0.00, "position": 0.50, "velocity": 0.1, "crossfader": 0.0, "muted": true, "cc6Step": 1 },
            { "timeSeconds": 0.01, "position": 0.51, "velocity": 0.1, "crossfader": 1.0, "muted": false, "cc6Step": 1 },
            { "timeSeconds": 0.02, "position": 0.52, "velocity": 0.1, "crossfader": 0.0, "muted": true, "cc6Step": 1 }
          ]
        }
        """
        let out = try ScratchAnalysisTimelineAdapter.analyzeTimeline(data: data(json), calibration: rane)
        XCTAssertEqual(out.strokes.first?.audibleState, .audible)
    }

    // 8. Crossfader closed -> .cut.
    func testCrossfaderClosedCut() throws {
        let json = """
        {
          "events": [
            { "timeSeconds": 0.00, "position": 0.50, "velocity": 0.1, "crossfader": 0.0, "muted": true, "cc6Step": 1 },
            { "timeSeconds": 0.01, "position": 0.51, "velocity": 0.1, "crossfader": 0.0, "muted": true, "cc6Step": 1 },
            { "timeSeconds": 0.02, "position": 0.52, "velocity": 0.1, "crossfader": 0.0, "muted": true, "cc6Step": 1 }
          ]
        }
        """
        let out = try ScratchAnalysisTimelineAdapter.analyzeTimeline(data: data(json), calibration: rane)
        XCTAssertEqual(out.strokes.first?.audibleState, .cut)
    }

    // 9. Pitch-bend / zone / position / velocity fields are ignored (analysis uses only cc6Step).
    func testIgnoresPitchBendAndPlaybackFields() throws {
        // Two events with WILDLY different rawPitchBend / position / velocity but cc6Step = +1
        // both: travel must still be exactly 2 steps, one forward stroke.
        let json = """
        {
          "events": [
            { "timeSeconds": 0.00, "position": 0.10, "velocity": 9.9, "muted": false, "cc6Step": 1, "rawPitchBend": 16383, "pitchBendDelta": -9000, "zoneAudioMode": "positionFollow", "zoneTargetSeconds": 99.0, "audioRenderSeconds": 5.0 },
            { "timeSeconds": 0.01, "position": 0.99, "velocity": -9.9, "muted": false, "cc6Step": 1, "rawPitchBend": 1, "pitchBendDelta": 9000, "zoneScrubRate": -42.0, "audioMapperDriftSeconds": 3.3 }
          ]
        }
        """
        let out = try ScratchAnalysisTimelineAdapter.analyzeTimeline(data: data(json), calibration: rane)
        XCTAssertEqual(out.strokes.count, 1)
        XCTAssertEqual(out.strokes.first?.direction, .forward)
        XCTAssertEqual(out.strokes.first?.travelPercent ?? -1, 2.0 / 3932.0 * 100.0, accuracy: 1e-9)
    }

    // 10. Calibration 3574 vs 3932 changes travelPercent (smaller divisor -> larger percent).
    func testCalibrationChangesTravelPercent() throws {
        let coarse = try ScratchAnalysisTimelineAdapter.analyzeTimeline(
            data: data(sameDirectionTimeline),
            calibration: .init(stepsPerRevolution: 3574, crossfaderCutWidth: 0.05))
        let fine = try ScratchAnalysisTimelineAdapter.analyzeTimeline(
            data: data(sameDirectionTimeline),
            calibration: .init(stepsPerRevolution: 3932, crossfaderCutWidth: 0.05))
        XCTAssertEqual(coarse.strokes.first?.travelPercent ?? -1, 3.0 / 3574.0 * 100.0, accuracy: 1e-9)
        XCTAssertEqual(fine.strokes.first?.travelPercent ?? -1, 3.0 / 3932.0 * 100.0, accuracy: 1e-9)
        XCTAssertGreaterThan(
            coarse.strokes.first?.travelPercent ?? 0,
            fine.strokes.first?.travelPercent ?? 0)
    }

    // 11. Adapter output equals a direct ScratchAnalysis.analyze(...) for equivalent values.
    func testAdapterMatchesDirectAnalyze() throws {
        let json = """
        {
          "events": [
            { "timeSeconds": 0.00, "position": 0.50, "velocity": 0.1, "crossfader": 1.0, "muted": false, "cc6Step": 1, "rawPitchBend": 8192 },
            { "timeSeconds": 0.01, "position": 0.51, "velocity": 0.1, "crossfader": 1.0, "muted": false, "cc6Step": 1, "rawPitchBend": 8260 },
            { "timeSeconds": 0.02, "position": 0.50, "velocity": -0.1, "crossfader": 0.0, "muted": true, "cc6Step": -1, "rawPitchBend": 8100 },
            { "timeSeconds": 0.03, "position": 0.49, "velocity": -0.1, "crossfader": 0.0, "muted": true, "cc6Step": -1, "rawPitchBend": 8000 }
          ]
        }
        """
        let viaAdapter = try ScratchAnalysisTimelineAdapter.analyzeTimeline(data: data(json), calibration: rane)
        let direct = ScratchAnalysis.analyze(
            platter: [
                .init(timeSeconds: 0.00, cc6Step: 1),
                .init(timeSeconds: 0.01, cc6Step: 1),
                .init(timeSeconds: 0.02, cc6Step: -1),
                .init(timeSeconds: 0.03, cc6Step: -1),
            ],
            crossfader: [
                .init(timeSeconds: 0.00, value: 1.0),
                .init(timeSeconds: 0.01, value: 1.0),
                .init(timeSeconds: 0.02, value: 0.0),
                .init(timeSeconds: 0.03, value: 0.0),
            ],
            calibration: rane
        )
        XCTAssertEqual(viaAdapter, direct)
    }

    // 12. Malformed timeline (missing required `events`) -> clear .decodeFailed.
    func testMalformedTimelineThrows() {
        let json = """
        { "muteCrossfaderBelow": 0.05, "didReachCapacity": false }
        """
        XCTAssertThrowsError(
            try ScratchAnalysisTimelineAdapter.analyzeTimeline(data: data(json), calibration: rane)
        ) { error in
            guard case ScratchAnalysisTimelineError.decodeFailed = error else {
                return XCTFail("expected .decodeFailed, got \(error)")
            }
        }
    }
}
