// Tests for ScratchNotationLaneDisplayAdapter — the UI-free travel-display projection that adds
// a display-only normalizedTravel against a caller-supplied fullScaleTravelPercent.
//
// Verifies lossless passthrough of preview fields, correct normalization/clamping, honest
// handling of invalid scales (no crash, normalizedTravel = 0, raw preserved), and a
// source-dependency guard enforcing the no-lane/no-UI/no-geometry boundary.
//
// Offline only. No SwiftUI import. No ScratchPlaybackLabEngine / ScratchPlaybackLabModel.

import XCTest
@testable import ScratchLab

final class ScratchNotationLaneDisplayModelTests: XCTestCase {

    private let rane = ScratchAnalysisCalibration(stepsPerRevolution: 3932, crossfaderCutWidth: 0.05)

    // MARK: - Builders / loaders

    private func previewStroke(_ dir: ScratchStrokeDirection, _ start: Double, _ end: Double,
                               _ travel: Double, _ audible: ScratchAudibleState)
        -> ScratchNotationLanePreviewModel.Stroke {
        .init(direction: dir, startTime: start, endTime: end, travelPercent: travel, audibleState: audible)
    }

    private func preview(_ strokes: [ScratchNotationLanePreviewModel.Stroke],
                         warnings: [ScratchAnalysisWarning] = []) -> ScratchNotationLanePreviewModel {
        ScratchNotationLanePreviewModel(strokes: strokes, warnings: warnings)
    }

    private func fixtureData(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            XCTFail("fixture \(name).json not found in \(bundle.bundleURL.path)", file: file, line: line)
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    private func realFaderPreview() throws -> ScratchNotationLanePreviewModel {
        let out = try ScratchAnalysisTimelineAdapter.analyzeTimeline(
            data: try fixtureData("scratch_timeline_cc6_real_fader_cut_fixture"), calibration: rane)
        let intent = ScratchAnalysisNotationAdapter.notationIntent(from: out)
        return ScratchNotationLanePreviewAdapter.preview(from: intent)
    }

    // MARK: - Mapping tests

    // 1. Empty preview → empty strokes; warnings + scale echoed.
    func testEmptyPreview() {
        let m = ScratchNotationLaneDisplayAdapter.displayModel(
            from: preview([], warnings: [.emptyInput]), fullScaleTravelPercent: 1.0)
        XCTAssertTrue(m.strokes.isEmpty)
        XCTAssertEqual(m.warnings, [.emptyInput])
        XCTAssertEqual(m.fullScaleTravelPercent, 1.0)
        XCTAssertTrue(m.scaleIsUsable)
    }

    // 2. One stroke maps losslessly with a usable scale.
    func testOneStrokeLossless() {
        let m = ScratchNotationLaneDisplayAdapter.displayModel(
            from: preview([previewStroke(.forward, 0.0, 0.25, 0.5, .audible)]), fullScaleTravelPercent: 1.0)
        let s = m.strokes.first
        XCTAssertEqual(s?.direction, .forward)
        XCTAssertEqual(s?.startTime, 0.0)
        XCTAssertEqual(s?.endTime, 0.25)
        XCTAssertEqual(s?.travelPercent, 0.5)
        XCTAssertEqual(s?.audibleState, .audible)
    }

    // 3. Short travel → small normalizedTravel.
    func testShortTravelNormalizesSmall() {
        let m = ScratchNotationLaneDisplayAdapter.displayModel(
            from: preview([previewStroke(.forward, 0, 1, 0.2, .audible)]), fullScaleTravelPercent: 2.0)
        XCTAssertEqual(m.strokes.first?.normalizedTravel ?? -1, 0.1, accuracy: 1e-12)
    }

    // 4. travel == fullScale → normalizedTravel == 1.
    func testTravelEqualsFullScale() {
        let m = ScratchNotationLaneDisplayAdapter.displayModel(
            from: preview([previewStroke(.forward, 0, 1, 2.0, .audible)]), fullScaleTravelPercent: 2.0)
        XCTAssertEqual(m.strokes.first?.normalizedTravel ?? -1, 1.0, accuracy: 1e-12)
    }

    // 5. Over-full travel → normalizedTravel == 1 while raw is preserved unclamped.
    func testOverFullTravelClampsButRawPreserved() {
        let m = ScratchNotationLaneDisplayAdapter.displayModel(
            from: preview([previewStroke(.forward, 0, 1, 250.0, .audible)]), fullScaleTravelPercent: 1.0)
        XCTAssertEqual(m.strokes.first?.normalizedTravel ?? -1, 1.0, accuracy: 1e-12)
        XCTAssertEqual(m.strokes.first?.travelPercent ?? -1, 250.0, accuracy: 1e-9)
    }

    // 6. Negative travelPercent → normalizedTravel == 0 while raw preserved.
    func testNegativeTravelNormalizesZeroRawPreserved() {
        let m = ScratchNotationLaneDisplayAdapter.displayModel(
            from: preview([previewStroke(.reverse, 0, 1, -5.0, .cut)]), fullScaleTravelPercent: 1.0)
        XCTAssertEqual(m.strokes.first?.normalizedTravel ?? -1, 0.0, accuracy: 1e-12)
        XCTAssertEqual(m.strokes.first?.travelPercent ?? 999, -5.0, accuracy: 1e-9)
    }

    // 7-9. Invalid scales → scaleIsUsable false, all normalizedTravel == 0, raw preserved, no crash.
    func testInvalidScales() {
        for scale in [0.0, -1.0, Double.nan, Double.infinity, -Double.infinity] {
            let m = ScratchNotationLaneDisplayAdapter.displayModel(
                from: preview([previewStroke(.forward, 0, 1, 3.0, .audible),
                               previewStroke(.reverse, 1, 2, 7.0, .cut)]),
                fullScaleTravelPercent: scale)
            XCTAssertFalse(m.scaleIsUsable, "scale \(scale) must be unusable")
            XCTAssertEqual(m.strokes.map(\.normalizedTravel), [0.0, 0.0], "scale \(scale)")
            XCTAssertEqual(m.strokes.map(\.travelPercent), [3.0, 7.0], "raw preserved for scale \(scale)")
        }
    }

    // 10. Real fader fixture with explicit fullScale 1.0.
    func testRealFaderFixtureExplicitScale() throws {
        let m = ScratchNotationLaneDisplayAdapter.displayModel(
            from: try realFaderPreview(), fullScaleTravelPercent: 1.0)
        let fwd = 32.0 / 3932.0 * 100.0
        let rev = 11.0 / 3932.0 * 100.0
        XCTAssertEqual(m.strokes.map(\.direction), [.forward, .reverse])
        XCTAssertEqual(m.strokes.map(\.audibleState), [.audible, .cut])
        XCTAssertEqual(m.strokes.first?.travelPercent ?? -1, fwd, accuracy: 1e-9)
        XCTAssertEqual(m.strokes.last?.travelPercent ?? -1, rev, accuracy: 1e-9)
        // fullScale 1.0 and both travels < 1.0 → normalized == raw (unclamped here).
        XCTAssertEqual(m.strokes.first?.normalizedTravel ?? -1, fwd, accuracy: 1e-9)
        XCTAssertEqual(m.strokes.last?.normalizedTravel ?? -1, rev, accuracy: 1e-9)
        XCTAssertTrue(m.warnings.contains(.nonUnitStep))
    }

    // 11. .unknown audibleState preserved.
    func testUnknownPreserved() {
        let m = ScratchNotationLaneDisplayAdapter.displayModel(
            from: preview([previewStroke(.forward, 0, 1, 1, .unknown)]), fullScaleTravelPercent: 1.0)
        XCTAssertEqual(m.strokes.first?.audibleState, .unknown)
    }

    // 12. Warnings preserve order.
    func testWarningsOrder() {
        let m = ScratchNotationLaneDisplayAdapter.displayModel(
            from: preview([], warnings: [.nonUnitStep, .emptyInput, .invalidCalibration]),
            fullScaleTravelPercent: 1.0)
        XCTAssertEqual(m.warnings, [.nonUnitStep, .emptyInput, .invalidCalibration])
    }

    // 13. Stroke order preserved.
    func testStrokeOrderPreserved() {
        let m = ScratchNotationLaneDisplayAdapter.displayModel(
            from: preview([previewStroke(.forward, 0, 1, 1, .audible),
                           previewStroke(.reverse, 1, 2, 2, .cut),
                           previewStroke(.forward, 2, 3, 3, .unknown)]),
            fullScaleTravelPercent: 10.0)
        XCTAssertEqual(m.strokes.map(\.direction), [.forward, .reverse, .forward])
        XCTAssertEqual(m.strokes.map(\.startTime), [0, 1, 2])
    }

    // 14. durationSeconds = end - start.
    func testDurationSeconds() {
        let m = ScratchNotationLaneDisplayAdapter.displayModel(
            from: preview([previewStroke(.forward, 10.0, 12.5, 1, .audible)]), fullScaleTravelPercent: 1.0)
        XCTAssertEqual(m.strokes.first?.durationSeconds ?? -1, 2.5, accuracy: 1e-9)
    }

    // 15. durationSeconds floors at 0 for out-of-order endpoints.
    func testDurationSecondsNonNegative() {
        let m = ScratchNotationLaneDisplayAdapter.displayModel(
            from: preview([previewStroke(.reverse, 5.0, 4.0, 1, .cut)]), fullScaleTravelPercent: 1.0)
        XCTAssertEqual(m.strokes.first?.durationSeconds ?? -1, 0.0, accuracy: 1e-12)
    }

    // 16. Deterministic output.
    func testDeterministic() throws {
        let p = try realFaderPreview()
        let a = ScratchNotationLaneDisplayAdapter.displayModel(from: p, fullScaleTravelPercent: 1.5)
        let b = ScratchNotationLaneDisplayAdapter.displayModel(from: p, fullScaleTravelPercent: 1.5)
        XCTAssertEqual(a, b)
    }

    // MARK: - 17. Source-dependency guard for the production file

    private func displayModelCodeWithoutComments(
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> String {
        let url = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // ScratchLabDesktopTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("ScratchLab/Analysis/ScratchNotationLaneDisplayModel.swift")
        let raw = try String(contentsOf: url, encoding: .utf8)

        var noBlocks = ""
        var index = raw.startIndex
        var inBlock = false
        while index < raw.endIndex {
            let rest = raw[index...]
            if inBlock {
                if rest.hasPrefix("*/") { inBlock = false; index = raw.index(index, offsetBy: 2) }
                else { index = raw.index(after: index) }
            } else if rest.hasPrefix("/*") {
                inBlock = true; index = raw.index(index, offsetBy: 2)
            } else {
                noBlocks.append(raw[index]); index = raw.index(after: index)
            }
        }
        let codeLines = noBlocks.split(separator: "\n", omittingEmptySubsequences: false).map { lineText -> Substring in
            if let r = lineText.range(of: "//") { return lineText[lineText.startIndex..<r.lowerBound] }
            return lineText
        }
        return codeLines.joined(separator: "\n")
    }

    func testProductionFileDoesNotReferenceForbiddenTypes() throws {
        let code = try displayModelCodeWithoutComments()
        let forbidden = [
            "import SwiftUI",
            "LaneStroke", "TimingLane",
            "NotationPresentation", "NotationLaneGeometry", "NotationPrimitive",
            "ScratchStrokeGeometry", "ScratchMotionRenderer", "ScratchMotionLane",
            "ScratchPlaybackLabEngine", "ScratchPlaybackLabModel",
            "CoreMIDI", "RtMidi", "AVAudio", "AudioToolbox",
        ]
        for token in forbidden {
            XCTAssertFalse(code.contains(token),
                           "Display model production code must not reference \(token)")
        }
    }

    func testProductionFileImportsOnlyFoundation() throws {
        let code = try displayModelCodeWithoutComments()
        let imports = code
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("import ") }
        XCTAssertEqual(imports, ["import Foundation"], "display model must import only Foundation")
    }
}
