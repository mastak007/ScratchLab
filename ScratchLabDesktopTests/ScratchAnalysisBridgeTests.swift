// Focused tests for the Swift -> Objective-C++ -> C++ scratch analysis bridge.
//
// These exercise the Swift facade `ScratchAnalysis.analyze`, which routes through the
// SLSScratchAnalyzer Objective-C++ bridge into the pure C++ core, then back to Swift
// value types. They prove the round-trip and that bridged values match the C++ behavior.
//
// Deliberately self-contained: no reference to ScratchPlaybackLabEngine or
// ScratchPlaybackLabModel, no UI, no live MIDI/audio.

import XCTest
@testable import ScratchLab

final class ScratchAnalysisBridgeTests: XCTestCase {

    private let rane = ScratchAnalysisCalibration(stepsPerRevolution: 3932, crossfaderCutWidth: 0.05)

    // 1. Bridge returns one forward stroke for same-direction movement.
    func testForwardStrokeRoundTrips() {
        let out = ScratchAnalysis.analyze(
            platter: [
                .init(timeSeconds: 0.0, cc6Step: 1),
                .init(timeSeconds: 0.1, cc6Step: 1),
                .init(timeSeconds: 0.2, cc6Step: 1),
            ],
            crossfader: [],
            calibration: rane
        )
        XCTAssertEqual(out.strokes.count, 1)
        XCTAssertEqual(out.strokes.first?.direction, .forward)
        XCTAssertEqual(out.strokes.first?.startTime ?? -1, 0.0, accuracy: 1e-9)
        XCTAssertEqual(out.strokes.first?.endTime ?? -1, 0.2, accuracy: 1e-9)
        XCTAssertEqual(out.strokes.first?.travelPercent ?? -1, 3.0 / 3932.0 * 100.0, accuracy: 1e-9)
    }

    // 2. Direction reversal returns two strokes, forward then reverse.
    func testReversalReturnsTwoStrokes() {
        let out = ScratchAnalysis.analyze(
            platter: [
                .init(timeSeconds: 0.0, cc6Step: 1),
                .init(timeSeconds: 0.1, cc6Step: 1),
                .init(timeSeconds: 0.2, cc6Step: -1),
                .init(timeSeconds: 0.3, cc6Step: -1),
            ],
            crossfader: [],
            calibration: rane
        )
        XCTAssertEqual(out.strokes.count, 2)
        XCTAssertEqual(out.strokes.first?.direction, .forward)
        XCTAssertEqual(out.strokes.last?.direction, .reverse)
    }

    // 3. Missing crossfader telemetry returns audibleState unknown.
    func testMissingCrossfaderUnknown() {
        let out = ScratchAnalysis.analyze(
            platter: [.init(timeSeconds: 0.0, cc6Step: 1), .init(timeSeconds: 0.1, cc6Step: 1)],
            crossfader: [],
            calibration: rane
        )
        XCTAssertEqual(out.strokes.first?.audibleState, .unknown)
    }

    // 4. Fader open returns audible.
    func testFaderOpenAudible() {
        let out = ScratchAnalysis.analyze(
            platter: [.init(timeSeconds: 0.0, cc6Step: 1), .init(timeSeconds: 0.2, cc6Step: 1)],
            crossfader: [
                .init(timeSeconds: 0.0, value: 0.0),
                .init(timeSeconds: 0.1, value: 1.0),
                .init(timeSeconds: 0.2, value: 0.0),
            ],
            calibration: rane
        )
        XCTAssertEqual(out.strokes.first?.audibleState, .audible)
    }

    // 5. Fader closed returns cut.
    func testFaderClosedCut() {
        let out = ScratchAnalysis.analyze(
            platter: [.init(timeSeconds: 0.0, cc6Step: 1), .init(timeSeconds: 0.2, cc6Step: 1)],
            crossfader: [
                .init(timeSeconds: 0.0, value: 0.0),
                .init(timeSeconds: 0.1, value: 0.0),
                .init(timeSeconds: 0.2, value: 0.0),
            ],
            calibration: rane
        )
        XCTAssertEqual(out.strokes.first?.audibleState, .cut)
    }

    // 6. 3574 vs 3932 changes travelPercent correctly (smaller divisor -> larger percent).
    func testCalibrationChangesTravelPercent() {
        let platter: [ScratchAnalysisPlatterEvent] = [
            .init(timeSeconds: 0.0, cc6Step: 1),
            .init(timeSeconds: 0.1, cc6Step: 1),
            .init(timeSeconds: 0.2, cc6Step: 1),
            .init(timeSeconds: 0.3, cc6Step: 1),
        ]
        let coarse = ScratchAnalysis.analyze(
            platter: platter, crossfader: [],
            calibration: .init(stepsPerRevolution: 3574, crossfaderCutWidth: 0.05))
        let fine = ScratchAnalysis.analyze(
            platter: platter, crossfader: [],
            calibration: .init(stepsPerRevolution: 3932, crossfaderCutWidth: 0.05))
        XCTAssertEqual(coarse.strokes.first?.travelPercent ?? -1, 4.0 / 3574.0 * 100.0, accuracy: 1e-9)
        XCTAssertEqual(fine.strokes.first?.travelPercent ?? -1, 4.0 / 3932.0 * 100.0, accuracy: 1e-9)
        XCTAssertGreaterThan(
            coarse.strokes.first?.travelPercent ?? 0,
            fine.strokes.first?.travelPercent ?? 0)
    }

    // 7. Non-unit step warning round-trips.
    func testNonUnitStepWarningRoundTrips() {
        let out = ScratchAnalysis.analyze(
            platter: [.init(timeSeconds: 0.0, cc6Step: 2), .init(timeSeconds: 0.1, cc6Step: 2)],
            crossfader: [],
            calibration: rane
        )
        XCTAssertTrue(out.warnings.contains(.nonUnitStep))
        XCTAssertEqual(out.strokes.count, 1)
        XCTAssertEqual(out.strokes.first?.travelPercent ?? -1, 4.0 / 3932.0 * 100.0, accuracy: 1e-9)
    }

    // 8. Invalid calibration warning round-trips (and produces no strokes).
    func testInvalidCalibrationWarningRoundTrips() {
        let out = ScratchAnalysis.analyze(
            platter: [.init(timeSeconds: 0.0, cc6Step: 1), .init(timeSeconds: 0.1, cc6Step: 1)],
            crossfader: [],
            calibration: .init(stepsPerRevolution: 0, crossfaderCutWidth: 0.05)
        )
        XCTAssertTrue(out.warnings.contains(.invalidCalibration))
        XCTAssertTrue(out.strokes.isEmpty)
    }

    // 9. Empty input warning round-trips.
    func testEmptyInputWarningRoundTrips() {
        let out = ScratchAnalysis.analyze(platter: [], crossfader: [], calibration: rane)
        XCTAssertTrue(out.warnings.contains(.emptyInput))
        XCTAssertTrue(out.strokes.isEmpty)
    }

    // 10. Swift wrapper output matches the C++ behavior on a known mixed case.
    func testWrapperOutputMatchesCoreBehavior() {
        // Forward run (open fader) then reverse run (closed fader).
        let out = ScratchAnalysis.analyze(
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
            calibration: rane
        )
        let expected = ScratchAnalysisOutput(
            strokes: [
                ScratchAnalyzedStroke(direction: .forward, startTime: 0.0, endTime: 0.1,
                                      travelPercent: 2.0 / 3932.0 * 100.0, audibleState: .audible),
                ScratchAnalyzedStroke(direction: .reverse, startTime: 0.2, endTime: 0.3,
                                      travelPercent: 2.0 / 3932.0 * 100.0, audibleState: .cut),
            ],
            warnings: []
        )
        XCTAssertEqual(out, expected)
    }
}
