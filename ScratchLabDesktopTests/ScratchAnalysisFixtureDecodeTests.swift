// Offline proof: scratchlab_analysis_fixture_v1 JSON -> Swift -> Obj-C++ -> C++ core.
//
// Inline synthetic fixtures only (no external files, no hardware, no audio, no UI).
// Exercises ScratchAnalysisFixtureAdapter, which decodes the fixture and routes it through
// ScratchAnalysis.analyze. Self-contained: no reference to ScratchPlaybackLabEngine or
// ScratchPlaybackLabModel.

import XCTest
@testable import ScratchLab

final class ScratchAnalysisFixtureDecodeTests: XCTestCase {

    private func data(_ json: String) -> Data { Data(json.utf8) }

    // 1. Decodes a valid scratchlab_analysis_fixture_v1 into wrapper-ready inputs.
    func testDecodesValidFixture() throws {
        let json = """
        {
          "schemaVersion": "scratchlab_analysis_fixture_v1",
          "calibration": { "stepsPerRevolution": 3932.0, "crossfaderCutWidth": 0.05 },
          "platterEvents": [
            { "timeSeconds": 0.000, "cc6Step": 1 },
            { "timeSeconds": 0.010, "cc6Step": 1 }
          ],
          "crossfaderEvents": [
            { "timeSeconds": 0.000, "value": 1.0 }
          ]
        }
        """
        let input = try ScratchAnalysisFixtureAdapter.decodeFixtureInput(data: data(json))
        XCTAssertEqual(input.calibration.stepsPerRevolution, 3932.0, accuracy: 1e-9)
        XCTAssertEqual(input.calibration.crossfaderCutWidth, 0.05, accuracy: 1e-9)
        XCTAssertEqual(input.platter.count, 2)
        XCTAssertEqual(input.platter.first?.cc6Step, 1)
        XCTAssertEqual(input.platter.last?.timeSeconds ?? -1, 0.010, accuracy: 1e-9)
        XCTAssertEqual(input.crossfader.count, 1)
        XCTAssertEqual(input.crossfader.first?.value ?? -1, 1.0, accuracy: 1e-9)
    }

    // 2. Same-direction CC6 fixture returns one stroke.
    func testSameDirectionOneStroke() throws {
        let json = """
        {
          "schemaVersion": "scratchlab_analysis_fixture_v1",
          "calibration": { "stepsPerRevolution": 3932.0, "crossfaderCutWidth": 0.05 },
          "platterEvents": [
            { "timeSeconds": 0.0, "cc6Step": 1 },
            { "timeSeconds": 0.1, "cc6Step": 1 },
            { "timeSeconds": 0.2, "cc6Step": 1 }
          ]
        }
        """
        let out = try ScratchAnalysisFixtureAdapter.analyzeFixture(data: data(json))
        XCTAssertEqual(out.strokes.count, 1)
        XCTAssertEqual(out.strokes.first?.direction, .forward)
        XCTAssertEqual(out.strokes.first?.travelPercent ?? -1, 3.0 / 3932.0 * 100.0, accuracy: 1e-9)
    }

    // 3. Direction reversal fixture returns two strokes (forward then reverse).
    func testReversalTwoStrokes() throws {
        let json = """
        {
          "schemaVersion": "scratchlab_analysis_fixture_v1",
          "calibration": { "stepsPerRevolution": 3932.0, "crossfaderCutWidth": 0.05 },
          "platterEvents": [
            { "timeSeconds": 0.0, "cc6Step": 1 },
            { "timeSeconds": 0.1, "cc6Step": 1 },
            { "timeSeconds": 0.2, "cc6Step": -1 },
            { "timeSeconds": 0.3, "cc6Step": -1 }
          ]
        }
        """
        let out = try ScratchAnalysisFixtureAdapter.analyzeFixture(data: data(json))
        XCTAssertEqual(out.strokes.count, 2)
        XCTAssertEqual(out.strokes.first?.direction, .forward)
        XCTAssertEqual(out.strokes.last?.direction, .reverse)
    }

    // 4. Missing crossfaderEvents -> audibleState .unknown.
    func testMissingCrossfaderUnknown() throws {
        let json = """
        {
          "schemaVersion": "scratchlab_analysis_fixture_v1",
          "calibration": { "stepsPerRevolution": 3932.0, "crossfaderCutWidth": 0.05 },
          "platterEvents": [
            { "timeSeconds": 0.0, "cc6Step": 1 },
            { "timeSeconds": 0.1, "cc6Step": 1 }
          ]
        }
        """
        let out = try ScratchAnalysisFixtureAdapter.analyzeFixture(data: data(json))
        XCTAssertEqual(out.strokes.first?.audibleState, .unknown)
    }

    // 5. Crossfader open -> .audible.
    func testCrossfaderOpenAudible() throws {
        let json = """
        {
          "schemaVersion": "scratchlab_analysis_fixture_v1",
          "calibration": { "stepsPerRevolution": 3932.0, "crossfaderCutWidth": 0.05 },
          "platterEvents": [
            { "timeSeconds": 0.0, "cc6Step": 1 },
            { "timeSeconds": 0.2, "cc6Step": 1 }
          ],
          "crossfaderEvents": [
            { "timeSeconds": 0.0, "value": 0.0 },
            { "timeSeconds": 0.1, "value": 1.0 },
            { "timeSeconds": 0.2, "value": 0.0 }
          ]
        }
        """
        let out = try ScratchAnalysisFixtureAdapter.analyzeFixture(data: data(json))
        XCTAssertEqual(out.strokes.first?.audibleState, .audible)
    }

    // 6. Crossfader closed -> .cut.
    func testCrossfaderClosedCut() throws {
        let json = """
        {
          "schemaVersion": "scratchlab_analysis_fixture_v1",
          "calibration": { "stepsPerRevolution": 3932.0, "crossfaderCutWidth": 0.05 },
          "platterEvents": [
            { "timeSeconds": 0.0, "cc6Step": 1 },
            { "timeSeconds": 0.2, "cc6Step": 1 }
          ],
          "crossfaderEvents": [
            { "timeSeconds": 0.0, "value": 0.0 },
            { "timeSeconds": 0.1, "value": 0.0 },
            { "timeSeconds": 0.2, "value": 0.0 }
          ]
        }
        """
        let out = try ScratchAnalysisFixtureAdapter.analyzeFixture(data: data(json))
        XCTAssertEqual(out.strokes.first?.audibleState, .cut)
    }

    // 7. Pitch bend-like and other unknown fields are ignored by the decoder.
    func testIgnoresPitchBendAndUnknownFields() throws {
        let json = """
        {
          "schemaVersion": "scratchlab_analysis_fixture_v1",
          "pitchBend": [ { "timeSeconds": 0.0, "rawPitchBend": 8192 } ],
          "audioRenderSeconds": 1.23,
          "zoneScrub": { "enabled": true },
          "calibration": { "stepsPerRevolution": 3932.0, "crossfaderCutWidth": 0.05, "ticksPerRevolution": 16384 },
          "platterEvents": [
            { "timeSeconds": 0.0, "cc6Step": 1, "rawPitchBend": 8192 },
            { "timeSeconds": 0.1, "cc6Step": 1, "rawPitchBend": 8200 }
          ]
        }
        """
        let out = try ScratchAnalysisFixtureAdapter.analyzeFixture(data: data(json))
        XCTAssertEqual(out.strokes.count, 1)
        XCTAssertEqual(out.strokes.first?.direction, .forward)
        XCTAssertEqual(out.strokes.first?.travelPercent ?? -1, 2.0 / 3932.0 * 100.0, accuracy: 1e-9)
    }

    // 8. Calibration 3574 vs 3932 changes travelPercent (smaller divisor -> larger percent).
    func testCalibrationChangesTravelPercent() throws {
        func fixture(steps: Double) -> Data {
            data("""
            {
              "schemaVersion": "scratchlab_analysis_fixture_v1",
              "calibration": { "stepsPerRevolution": \(steps), "crossfaderCutWidth": 0.05 },
              "platterEvents": [
                { "timeSeconds": 0.0, "cc6Step": 1 },
                { "timeSeconds": 0.1, "cc6Step": 1 },
                { "timeSeconds": 0.2, "cc6Step": 1 },
                { "timeSeconds": 0.3, "cc6Step": 1 }
              ]
            }
            """)
        }
        let coarse = try ScratchAnalysisFixtureAdapter.analyzeFixture(data: fixture(steps: 3574))
        let fine = try ScratchAnalysisFixtureAdapter.analyzeFixture(data: fixture(steps: 3932))
        XCTAssertEqual(coarse.strokes.first?.travelPercent ?? -1, 4.0 / 3574.0 * 100.0, accuracy: 1e-9)
        XCTAssertEqual(fine.strokes.first?.travelPercent ?? -1, 4.0 / 3932.0 * 100.0, accuracy: 1e-9)
        XCTAssertGreaterThan(
            coarse.strokes.first?.travelPercent ?? 0,
            fine.strokes.first?.travelPercent ?? 0)
    }

    // 9. Unsupported schemaVersion -> clear .unsupportedSchema error.
    func testUnsupportedSchemaThrows() {
        let json = """
        {
          "schemaVersion": "scratchlab_analysis_fixture_v2",
          "calibration": { "stepsPerRevolution": 3932.0, "crossfaderCutWidth": 0.05 },
          "platterEvents": [ { "timeSeconds": 0.0, "cc6Step": 1 } ]
        }
        """
        XCTAssertThrowsError(try ScratchAnalysisFixtureAdapter.analyzeFixture(data: data(json))) { error in
            guard case ScratchAnalysisFixtureError.unsupportedSchema(let version) = error else {
                return XCTFail("expected .unsupportedSchema, got \(error)")
            }
            XCTAssertEqual(version, "scratchlab_analysis_fixture_v2")
        }
    }

    // 10. Adapter output equals a direct ScratchAnalysis.analyze(...) for the same values.
    func testAdapterMatchesDirectAnalyze() throws {
        let json = """
        {
          "schemaVersion": "scratchlab_analysis_fixture_v1",
          "calibration": { "stepsPerRevolution": 3932.0, "crossfaderCutWidth": 0.05 },
          "platterEvents": [
            { "timeSeconds": 0.0, "cc6Step": 1 },
            { "timeSeconds": 0.1, "cc6Step": 1 },
            { "timeSeconds": 0.2, "cc6Step": -1 },
            { "timeSeconds": 0.3, "cc6Step": -1 }
          ],
          "crossfaderEvents": [
            { "timeSeconds": 0.0, "value": 1.0 },
            { "timeSeconds": 0.1, "value": 1.0 },
            { "timeSeconds": 0.2, "value": 0.0 },
            { "timeSeconds": 0.3, "value": 0.0 }
          ]
        }
        """
        let viaAdapter = try ScratchAnalysisFixtureAdapter.analyzeFixture(data: data(json))
        let direct = ScratchAnalysis.analyze(
            platter: [
                .init(timeSeconds: 0.0, cc6Step: 1),
                .init(timeSeconds: 0.1, cc6Step: 1),
                .init(timeSeconds: 0.2, cc6Step: -1),
                .init(timeSeconds: 0.3, cc6Step: -1),
            ],
            crossfader: [
                .init(timeSeconds: 0.0, value: 1.0),
                .init(timeSeconds: 0.1, value: 1.0),
                .init(timeSeconds: 0.2, value: 0.0),
                .init(timeSeconds: 0.3, value: 0.0),
            ],
            calibration: .init(stepsPerRevolution: 3932.0, crossfaderCutWidth: 0.05)
        )
        XCTAssertEqual(viaAdapter, direct)
    }
}
