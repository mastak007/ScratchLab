// Tests for ScratchAnalysisNotationComparison — the UI-free diagnostic comparison between the
// C++ notation intent and the app's renderer-neutral `LaneStroke` shape.
//
// Verifies honest, non-lossy behaviour: travelPercent is always reported unsupported (LaneStroke
// has no such field), `.unknown` audible state is reported unsupported rather than guessed, and
// direction/timing/audible are compared only where representable. End-to-end test uses the
// Slice 8 real fader fixture (forward/audible + reverse/cut).
//
// Offline only: no audio, no realtime engine, no MIDI, no hardware. No SwiftUI import. No
// reference to ScratchPlaybackLabEngine or ScratchPlaybackLabModel.

import XCTest
@testable import ScratchLab

final class ScratchAnalysisNotationComparisonTests: XCTestCase {

    private let rane = ScratchAnalysisCalibration(stepsPerRevolution: 3932, crossfaderCutWidth: 0.05)
    private let tol = 0.001

    // MARK: - Builders

    private func intent(_ strokes: [ScratchNotationIntentStroke],
                        warnings: [ScratchAnalysisWarning] = []) -> ScratchNotationIntent {
        ScratchNotationIntent(strokes: strokes, warnings: warnings)
    }

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

    // MARK: - Tests

    // 1. travelPercent is always reported unsupported.
    func testTravelPercentAlwaysUnsupported() {
        let report = ScratchAnalysisNotationComparison.compare(
            intent: intent([stroke(.forward, 0, 1, 5.0, .audible)]),
            reference: [lane(.forward, 0, 1, .open)],
            timingToleranceSeconds: tol)
        XCTAssertTrue(report.unsupportedFields.contains(.travelPercent))
    }

    // 2. .unknown audible is reported unsupported, not mismatched.
    func testUnknownAudibleReportedUnsupportedNotMismatched() {
        let report = ScratchAnalysisNotationComparison.compare(
            intent: intent([stroke(.forward, 0, 1, 5.0, .unknown)]),
            reference: [lane(.forward, 0, 1, .open)],
            timingToleranceSeconds: tol)
        XCTAssertTrue(report.unsupportedFields.contains(.audibleStateUnknown))
        XCTAssertTrue(report.audibleMismatches.isEmpty, "unknown must not create an audible mismatch")
    }

    // 3. Direction matches for forward/reverse vs forward/backward.
    func testDirectionMatches() {
        let report = ScratchAnalysisNotationComparison.compare(
            intent: intent([stroke(.forward, 0, 1, 1, .audible), stroke(.reverse, 1, 2, 1, .cut)]),
            reference: [lane(.forward, 0, 1, .open), lane(.backward, 1, 2, .closed)],
            timingToleranceSeconds: tol)
        XCTAssertTrue(report.directionMismatches.isEmpty)
        XCTAssertTrue(report.audibleMismatches.isEmpty)
    }

    // 4. Direction mismatch reported when reference disagrees.
    func testDirectionMismatchReported() {
        let report = ScratchAnalysisNotationComparison.compare(
            intent: intent([stroke(.forward, 0, 1, 1, .audible)]),
            reference: [lane(.backward, 0, 1, .open)],
            timingToleranceSeconds: tol)
        XCTAssertEqual(report.directionMismatches, [.init(index: 0, kind: .direction)])
    }

    // 5. Timing match within tolerance.
    func testTimingMatchWithinTolerance() {
        let report = ScratchAnalysisNotationComparison.compare(
            intent: intent([stroke(.forward, 0.0, 1.0, 1, .audible)]),
            reference: [lane(.forward, 0.0005, 1.0005, .open)],
            timingToleranceSeconds: tol)
        XCTAssertTrue(report.timingMismatches.isEmpty)
    }

    // 6. Timing mismatch reported outside tolerance.
    func testTimingMismatchOutsideTolerance() {
        let report = ScratchAnalysisNotationComparison.compare(
            intent: intent([stroke(.forward, 0.0, 1.0, 1, .audible)]),
            reference: [lane(.forward, 0.0, 1.5, .open)],
            timingToleranceSeconds: tol)
        XCTAssertEqual(report.timingMismatches, [.init(index: 0, kind: .timing)])
    }

    // 7. Count mismatch is reported deterministically via the count fields AND a single
    //    `.count` mismatch at the boundary index min(intent, reference); per-axis arrays only
    //    cover the overlap.
    func testCountMismatchReported() {
        let report = ScratchAnalysisNotationComparison.compare(
            intent: intent([stroke(.forward, 0, 1, 1, .audible), stroke(.reverse, 1, 2, 1, .cut)]),
            reference: [lane(.forward, 0, 1, .open)],
            timingToleranceSeconds: tol)
        XCTAssertEqual(report.intentStrokeCount, 2)
        XCTAssertEqual(report.referenceStrokeCount, 1)
        XCTAssertNotEqual(report.intentStrokeCount, report.referenceStrokeCount)
        // Exactly one .count mismatch at the boundary index min(2, 1) == 1.
        XCTAssertEqual(report.countMismatches, [.init(index: 1, kind: .count)])
        // Overlap of 1 compared cleanly; no fabricated verdict for the extra intent stroke.
        XCTAssertTrue(report.directionMismatches.isEmpty)
        XCTAssertTrue(report.audibleMismatches.isEmpty)
    }

    // 7b. Equal counts -> no count mismatch.
    func testNoCountMismatchWhenCountsEqual() {
        let report = ScratchAnalysisNotationComparison.compare(
            intent: intent([stroke(.forward, 0, 1, 1, .audible)]),
            reference: [lane(.forward, 0, 1, .open)],
            timingToleranceSeconds: tol)
        XCTAssertEqual(report.intentStrokeCount, report.referenceStrokeCount)
        XCTAssertTrue(report.countMismatches.isEmpty)
    }

    // 8. Same inputs produce an identical report (determinism).
    func testDeterministic() {
        let i = intent([stroke(.forward, 0, 1, 7, .audible), stroke(.reverse, 1, 2, 3, .unknown)],
                       warnings: [.nonUnitStep])
        let r = [lane(.forward, 0, 1, .open), lane(.backward, 1, 2, .closed)]
        let a = ScratchAnalysisNotationComparison.compare(intent: i, reference: r, timingToleranceSeconds: tol)
        let b = ScratchAnalysisNotationComparison.compare(intent: i, reference: r, timingToleranceSeconds: tol)
        XCTAssertEqual(a, b)
    }

    // 9. Slice 8 real fader fixture: forward/audible + reverse/cut vs a matching LaneStroke
    //    reference. Direction + audible axes match; travelPercent stays unsupported.
    func testRealFaderFixtureComparison() throws {
        let out = try ScratchAnalysisTimelineAdapter.analyzeTimeline(
            data: try fixtureData("scratch_timeline_cc6_real_fader_cut_fixture"), calibration: rane)
        let intentValue = ScratchAnalysisNotationAdapter.notationIntent(from: out)
        XCTAssertEqual(intentValue.strokes.map(\.audibleState), [.audible, .cut], "precondition")

        // Hand-built reference matching the real strokes' direction/fader and timing.
        let s0 = intentValue.strokes[0], s1 = intentValue.strokes[1]
        let reference = [
            lane(.forward, s0.startTime, s0.endTime, .open),
            lane(.backward, s1.startTime, s1.endTime, .closed),
        ]
        let report = ScratchAnalysisNotationComparison.compare(
            intent: intentValue, reference: reference, timingToleranceSeconds: tol)

        XCTAssertEqual(report.intentStrokeCount, 2)
        XCTAssertEqual(report.referenceStrokeCount, 2)
        XCTAssertTrue(report.directionMismatches.isEmpty, "forward/reverse must match forward/backward")
        XCTAssertTrue(report.timingMismatches.isEmpty, "timing within tolerance")
        XCTAssertTrue(report.audibleMismatches.isEmpty, "audible/cut must match open/closed")
        XCTAssertTrue(report.unsupportedFields.contains(.travelPercent), "travel still unsupported")
        XCTAssertFalse(report.unsupportedFields.contains(.audibleStateUnknown), "no unknown strokes here")
    }

    // 10. Warnings pass through, including nonUnitStep (from the real fader fixture).
    func testWarningsPassThrough() throws {
        let out = try ScratchAnalysisTimelineAdapter.analyzeTimeline(
            data: try fixtureData("scratch_timeline_cc6_real_fader_cut_fixture"), calibration: rane)
        let intentValue = ScratchAnalysisNotationAdapter.notationIntent(from: out)
        let report = ScratchAnalysisNotationComparison.compare(
            intent: intentValue,
            reference: [lane(.forward, 0, 1, .open), lane(.backward, 1, 2, .closed)],
            timingToleranceSeconds: 1e9) // huge tolerance: isolate warning passthrough from timing
        XCTAssertTrue(report.warnings.contains(.nonUnitStep))
    }
}
