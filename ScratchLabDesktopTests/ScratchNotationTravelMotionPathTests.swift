// Tests for ScratchNotationTravelMotionPath — the Stage A additive travel→MotionPath builder.
//
// Verifies the path mirrors the existing motion geometry (centre-rest, out/return halves, holds,
// 0...1 normalization) while driving stroke excursion from normalizedTravel instead of a speed
// bucket: short travel reads short, full travel approaches the rail, unusable scale renders flat.
//
// Offline only. No SwiftUI import. No ScratchPlaybackLabEngine / ScratchPlaybackLabModel.

import CoreGraphics
import XCTest
@testable import ScratchLab

final class ScratchNotationTravelMotionPathTests: XCTestCase {

    private let rane = ScratchAnalysisCalibration(stepsPerRevolution: 3932, crossfaderCutWidth: 0.05)

    // MARK: - Builders

    /// A display model built directly from preview strokes at an explicit full scale.
    private func display(_ strokes: [ScratchNotationLanePreviewModel.Stroke],
                         fullScale: Double,
                         warnings: [ScratchAnalysisWarning] = []) -> ScratchNotationLaneDisplayModel {
        ScratchNotationLaneDisplayAdapter.displayModel(
            from: ScratchNotationLanePreviewModel(strokes: strokes, warnings: warnings),
            fullScaleTravelPercent: fullScale)
    }

    private func pStroke(_ dir: ScratchStrokeDirection, _ start: Double, _ end: Double,
                         _ travel: Double, _ audible: ScratchAudibleState = .audible)
        -> ScratchNotationLanePreviewModel.Stroke {
        .init(direction: dir, startTime: start, endTime: end, travelPercent: travel, audibleState: audible)
    }

    private func fixtureData(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            XCTFail("fixture \(name).json not found in \(bundle.bundleURL.path)", file: file, line: line)
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    /// Largest deviation from centre (0.5) across all segment endpoints touching `time` range.
    private func peakDeviation(_ path: MotionPath) -> CGFloat {
        let positions = path.segments.flatMap { [$0.startPosition, $0.endPosition] }
        return positions.map { abs($0 - 0.5) }.max() ?? 0
    }

    // MARK: - Tests

    // 1. Empty model → single flat hold across [0, duration] at centre.
    func testEmptyModelFlatHold() {
        let path = ScratchNotationTravelMotionPath.motionPath(for: display([], fullScale: 1.0), duration: 4.0)
        XCTAssertEqual(path.segments.count, 1)
        XCTAssertTrue(path.segments.first?.isHold ?? false)
        XCTAssertEqual(path.segments.first?.startPosition ?? -1, 0.5)
        XCTAssertEqual(path.segments.first?.endPosition ?? -1, 0.5)
        XCTAssertEqual(path.timeRange, 0...4.0)
    }

    // 2. Forward stroke rises (out-half goes above centre); reverse falls.
    func testForwardRisesReverseFalls() {
        let fwd = ScratchNotationTravelMotionPath.motionPath(
            for: display([pStroke(.forward, 1, 2, 1.0)], fullScale: 1.0), duration: 3.0)
        // Stroke out-half: centre → rail. Forward rail is the path max → endPosition 1.0 region.
        let fwdStroke = fwd.segments.first { if case .stroke = $0.kind { return true }; return false }
        XCTAssertEqual(fwdStroke?.isRising, true)

        let rev = ScratchNotationTravelMotionPath.motionPath(
            for: display([pStroke(.reverse, 1, 2, 1.0)], fullScale: 1.0), duration: 3.0)
        let revStroke = rev.segments.first { if case .stroke = $0.kind { return true }; return false }
        XCTAssertEqual(revStroke?.isRising, false)
    }

    // 3. Short travel reads short; full travel reaches the rail (compare excursions, same scale).
    func testShortTravelReadsShorterThanFull() {
        // Two same-direction strokes, different travel, normalized at the same scale.
        let path = ScratchNotationTravelMotionPath.motionPath(
            for: display([pStroke(.forward, 0, 1, 0.2), pStroke(.forward, 2, 3, 1.0)], fullScale: 1.0),
            duration: 4.0)
        // Raw rails: 0.2 and 1.0. After normalization the bigger-travel stroke deviates more.
        // Find each stroke's out-half end position.
        let strokeSegs = path.segments.filter { if case .stroke = $0.kind { return true }; return false }
        // out-halves are at even indices within the pair; compare max deviation of first vs second stroke.
        XCTAssertGreaterThanOrEqual(strokeSegs.count, 4)
        let firstDev = abs((strokeSegs[0].endPosition) - normalizedCentre(path))
        let secondDev = abs((strokeSegs[2].endPosition) - normalizedCentre(path))
        XCTAssertLessThan(firstDev, secondDev, "smaller travel must deflect less than larger travel")
    }

    /// The normalized centre (rest) position for a path — the position of any hold segment.
    private func normalizedCentre(_ path: MotionPath) -> CGFloat {
        path.segments.first { $0.isHold }?.startPosition ?? 0.5
    }

    // 4. travel == fullScale → that stroke hits a rail (normalized 0 or 1 extreme).
    func testFullTravelReachesRail() {
        let path = ScratchNotationTravelMotionPath.motionPath(
            for: display([pStroke(.forward, 1, 2, 2.0)], fullScale: 2.0), duration: 3.0)
        // Single forward full-travel stroke: max normalized position should be 1.0 (top rail).
        let maxPos = path.segments.flatMap { [$0.startPosition, $0.endPosition] }.max() ?? 0
        XCTAssertEqual(maxPos, 1.0, accuracy: 1e-9)
    }

    // 5. Unusable scale (<=0 / non-finite) → all normalizedTravel 0 → flat path at centre.
    func testUnusableScaleRendersFlat() {
        for scale in [0.0, -1.0, Double.nan, Double.infinity] {
            let path = ScratchNotationTravelMotionPath.motionPath(
                for: display([pStroke(.forward, 1, 2, 5.0), pStroke(.reverse, 2, 3, 9.0)], fullScale: scale),
                duration: 4.0)
            // Every position collapses to centre 0.5 (range below epsilon → 0.5).
            let deviation = peakDeviation(path)
            XCTAssertEqual(deviation, 0.0, accuracy: 1e-9, "scale \(scale) must render flat")
        }
    }

    // 6. Zero-duration stroke → instantaneous mark (one stroke span, start==end position pair).
    func testZeroDurationStroke() {
        let path = ScratchNotationTravelMotionPath.motionPath(
            for: display([pStroke(.forward, 1.0, 1.0, 1.0)], fullScale: 1.0), duration: 2.0)
        let strokeSegs = path.segments.filter { if case .stroke = $0.kind { return true }; return false }
        XCTAssertEqual(strokeSegs.count, 1, "zero-duration stroke is a single instantaneous mark")
    }

    // 7. Times preserved; path covers [0, duration]; both ends rest at centre (seam closes).
    func testTimingAndSeam() {
        let path = ScratchNotationTravelMotionPath.motionPath(
            for: display([pStroke(.forward, 1, 2, 0.5)], fullScale: 1.0), duration: 3.0)
        XCTAssertEqual(path.timeRange, 0...3.0)
        XCTAssertEqual(path.position(at: 0.0), normalizedCentre(path), accuracy: 1e-9)
        XCTAssertEqual(path.position(at: 3.0), normalizedCentre(path), accuracy: 1e-9)
    }

    // 8. Deterministic output.
    func testDeterministic() {
        let m = display([pStroke(.forward, 0, 1, 0.3), pStroke(.reverse, 1, 2, 0.9)], fullScale: 1.0)
        let a = ScratchNotationTravelMotionPath.motionPath(for: m, duration: 3.0)
        let b = ScratchNotationTravelMotionPath.motionPath(for: m, duration: 3.0)
        XCTAssertEqual(a, b)
    }

    // 9. Real fader fixture: forward (larger travel) deflects more than reverse (smaller travel).
    func testRealFaderFixtureTravelScaling() throws {
        let out = try ScratchAnalysisTimelineAdapter.analyzeTimeline(
            data: try fixtureData("scratch_timeline_cc6_real_fader_cut_fixture"), calibration: rane)
        let intent = ScratchAnalysisNotationAdapter.notationIntent(from: out)
        let preview = ScratchNotationLanePreviewAdapter.preview(from: intent)
        let model = ScratchNotationLaneDisplayAdapter.displayModel(from: preview, fullScaleTravelPercent: 1.0)
        // Strokes are at ~168719s; supply a duration spanning them.
        let lastEnd = model.strokes.map(\.endTime).max() ?? 0
        let path = ScratchNotationTravelMotionPath.motionPath(for: model, duration: lastEnd + 0.5)

        let centre = normalizedCentre(path)
        let strokeSegs = path.segments.filter { if case .stroke = $0.kind { return true }; return false }
        XCTAssertGreaterThanOrEqual(strokeSegs.count, 4)
        // First stroke = forward (travel 0.814), second = reverse (travel 0.280). Forward out-half
        // is strokeSegs[0], reverse out-half is strokeSegs[2].
        XCTAssertEqual(strokeSegs[0].isRising, true)
        XCTAssertEqual(strokeSegs[2].isRising, false)
        let fwdDev = abs(strokeSegs[0].endPosition - centre)
        let revDev = abs(strokeSegs[2].endPosition - centre)
        XCTAssertGreaterThan(fwdDev, revDev, "forward (more travel) must deflect more than reverse")
    }

    // MARK: - 10. Source-dependency guard

    private func builderCodeWithoutComments(file: StaticString = #filePath) throws -> String {
        let url = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ScratchLab/Analysis/ScratchNotationTravelMotionPath.swift")
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
            } else { noBlocks.append(raw[index]); index = raw.index(after: index) }
        }
        return noBlocks.split(separator: "\n", omittingEmptySubsequences: false).map { lineText -> Substring in
            if let r = lineText.range(of: "//") { return lineText[lineText.startIndex..<r.lowerBound] }
            return lineText
        }.joined(separator: "\n")
    }

    func testBuilderDoesNotReferenceForbiddenTypes() throws {
        let code = try builderCodeWithoutComments()
        // Note: MotionPath / MotionSegment / MotionSegmentKind ARE allowed (the reused render types).
        // ScratchStrokeGeometry / LaneStroke / TimingLane / renderer / views / playback are NOT.
        let forbidden = [
            "import SwiftUI",
            "ScratchStrokeGeometry", "ScratchMotionRenderer", "ScratchMotionLane",
            "LaneStroke", "LaneContent", "TimingLane",
            "NotationPresentation", "NotationLaneGeometry", "NotationPrimitive",
            "ScratchPlaybackLabEngine", "ScratchPlaybackLabModel",
            "CoreMIDI", "RtMidi", "AVAudio", "AudioToolbox",
        ]
        for token in forbidden {
            XCTAssertFalse(code.contains(token), "builder must not reference \(token)")
        }
    }

    func testBuilderImportsOnlyFoundationAndCoreGraphics() throws {
        let code = try builderCodeWithoutComments()
        let imports = code.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("import ") }.sorted()
        XCTAssertEqual(imports, ["import CoreGraphics", "import Foundation"],
                       "builder must import only Foundation and CoreGraphics")
    }
}
