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

    // MARK: - Absolute SIGNED scaling mode (DEBUG diagnostic — reverse dips below the mid-line)

    /// Largest position above centre and smallest below — to test directional peaks.
    private func maxPosition(_ path: MotionPath) -> CGFloat {
        path.segments.flatMap { [$0.startPosition, $0.endPosition] }.max() ?? 0.5
    }
    private func minPosition(_ path: MotionPath) -> CGFloat {
        path.segments.flatMap { [$0.startPosition, $0.endPosition] }.min() ?? 0.5
    }

    // A1. The defaulted call equals an explicit `.perPhrase` call (backward-compat) — across a
    //     synthetic model and the real fader fixture.
    func testDefaultEqualsPerPhrase() throws {
        let synthetic = display([pStroke(.forward, 0, 1, 0.3), pStroke(.reverse, 1, 2, 0.9)], fullScale: 1.0)
        XCTAssertEqual(
            ScratchNotationTravelMotionPath.motionPath(for: synthetic, duration: 3.0),
            ScratchNotationTravelMotionPath.motionPath(for: synthetic, duration: 3.0, scaling: .perPhrase))

        let out = try ScratchAnalysisTimelineAdapter.analyzeTimeline(
            data: try fixtureData("scratch_timeline_cc6_real_fader_cut_fixture"), calibration: rane)
        let preview = ScratchNotationLanePreviewAdapter.preview(
            from: ScratchAnalysisNotationAdapter.notationIntent(from: out))
        let model = ScratchNotationLaneDisplayAdapter.displayModel(from: preview, fullScaleTravelPercent: 1.0)
        let lastEnd = model.strokes.map(\.endTime).max() ?? 0
        XCTAssertEqual(
            ScratchNotationTravelMotionPath.motionPath(for: model, duration: lastEnd + 0.5),
            ScratchNotationTravelMotionPath.motionPath(for: model, duration: lastEnd + 0.5, scaling: .perPhrase))
    }

    // A2. `.absoluteSigned` makes fullScaleTravelPercent meaningful: for the SAME raw travel, a lower
    //     fullScale yields a larger excursion and a higher fullScale a smaller one. The same model
    //     under `.perPhrase` is INERT (the uniform scale cancels) — documenting the bug being fixed.
    func testAbsoluteScaleIsMeaningfulUnlikePerPhrase() {
        let scales: [Double] = [0.5, 1.0, 2.0, 3.0]
        // travelPercent 0.4 stays sub-rail at every scale tested (0.4/0.5 = 0.8 < 1.0).
        func absDev(_ fullScale: Double) -> CGFloat {
            peakDeviation(ScratchNotationTravelMotionPath.motionPath(
                for: display([pStroke(.forward, 1, 2, 0.4)], fullScale: fullScale),
                duration: 3.0, scaling: .absoluteSigned))
        }
        func perPhraseDev(_ fullScale: Double) -> CGFloat {
            peakDeviation(ScratchNotationTravelMotionPath.motionPath(
                for: display([pStroke(.forward, 1, 2, 0.4)], fullScale: fullScale),
                duration: 3.0, scaling: .perPhrase))
        }
        // Absolute: strictly decreasing excursion as the scale grows (lower scale = bigger).
        let absDevs = scales.map(absDev)
        for i in 1..<absDevs.count {
            XCTAssertLessThan(absDevs[i], absDevs[i - 1],
                              "absolute: larger fullScale must shrink excursion (scale \(scales[i]))")
        }
        // Per-phrase: identical excursion at every scale (cancellation — the inertness we fix).
        let perDevs = scales.map(perPhraseDev)
        for dev in perDevs { XCTAssertEqual(dev, perDevs[0], accuracy: 1e-9) }
    }

    // A3. `.absoluteSigned` forward stroke peaks ABOVE centre (0.5).
    func testAbsoluteForwardPeaksAboveCentre() {
        let path = ScratchNotationTravelMotionPath.motionPath(
            for: display([pStroke(.forward, 1, 2, 0.5)], fullScale: 1.0), duration: 3.0, scaling: .absoluteSigned)
        XCTAssertGreaterThan(maxPosition(path), 0.5)
        // centre 0 + half of nt(0.5)=0.25 above mid → 0.75.
        XCTAssertEqual(maxPosition(path), 0.75, accuracy: 1e-9)
    }

    // A4. `.absoluteSigned` reverse stroke peaks BELOW centre (0.5).
    func testAbsoluteReversePeaksBelowCentre() {
        let path = ScratchNotationTravelMotionPath.motionPath(
            for: display([pStroke(.reverse, 1, 2, 0.5)], fullScale: 1.0), duration: 3.0, scaling: .absoluteSigned)
        XCTAssertLessThan(minPosition(path), 0.5)
        XCTAssertEqual(minPosition(path), 0.25, accuracy: 1e-9)
    }

    // A5. `.absoluteSigned` normalizedTravel == 1 reaches the rail (forward → 1.0, reverse → 0.0).
    func testAbsoluteFullTravelReachesRail() {
        let fwd = ScratchNotationTravelMotionPath.motionPath(
            for: display([pStroke(.forward, 1, 2, 1.0)], fullScale: 1.0), duration: 3.0, scaling: .absoluteSigned)
        XCTAssertEqual(maxPosition(fwd), 1.0, accuracy: 1e-9)

        let rev = ScratchNotationTravelMotionPath.motionPath(
            for: display([pStroke(.reverse, 1, 2, 1.0)], fullScale: 1.0), duration: 3.0, scaling: .absoluteSigned)
        XCTAssertEqual(minPosition(rev), 0.0, accuracy: 1e-9)
    }

    // A6. `.absoluteSigned` centre / holds map to exactly 0.5; the loop seam stays closed at centre.
    func testAbsoluteCentreHoldsAndSeam() {
        let path = ScratchNotationTravelMotionPath.motionPath(
            for: display([pStroke(.forward, 1, 2, 0.6), pStroke(.reverse, 2.5, 3, 0.3)], fullScale: 1.0),
            duration: 4.0, scaling: .absoluteSigned)
        for hold in path.segments.filter(\.isHold) {
            XCTAssertEqual(hold.startPosition, 0.5, accuracy: 1e-9)
            XCTAssertEqual(hold.endPosition, 0.5, accuracy: 1e-9)
        }
        XCTAssertEqual(path.segments.first?.startPosition ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(path.segments.last?.endPosition ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(path.position(at: 0.0), 0.5, accuracy: 1e-9)
        XCTAssertEqual(path.position(at: 4.0), 0.5, accuracy: 1e-9)
    }

    // A7. Timing (segment start/end times) is identical between `.perPhrase` and `.absoluteSigned` —
    //     only the cross-axis positions differ.
    func testAbsolutePreservesTiming() {
        let model = display([pStroke(.forward, 0.2, 0.8, 0.7), pStroke(.reverse, 1.5, 2.1, 0.4)], fullScale: 1.0)
        let per = ScratchNotationTravelMotionPath.motionPath(for: model, duration: 3.0, scaling: .perPhrase)
        let abs = ScratchNotationTravelMotionPath.motionPath(for: model, duration: 3.0, scaling: .absoluteSigned)
        XCTAssertEqual(per.segments.count, abs.segments.count)
        XCTAssertEqual(per.timeRange, abs.timeRange)
        for (p, a) in zip(per.segments, abs.segments) {
            XCTAssertEqual(p.startTime, a.startTime, accuracy: 1e-9)
            XCTAssertEqual(p.endTime, a.endTime, accuracy: 1e-9)
            XCTAssertEqual(p.kind, a.kind)
        }
    }

    // A8. Short platter movement stays short under `.absoluteSigned`: a small travel stays near centre
    //     while a full travel reaches the rail, at the same scale.
    func testAbsoluteShortTravelStaysShort() {
        let path = ScratchNotationTravelMotionPath.motionPath(
            for: display([pStroke(.forward, 0, 1, 0.1), pStroke(.forward, 2, 3, 1.0)], fullScale: 1.0),
            duration: 4.0, scaling: .absoluteSigned)
        let strokeSegs = path.segments.filter { if case .stroke = $0.kind { return true }; return false }
        XCTAssertGreaterThanOrEqual(strokeSegs.count, 4)
        XCTAssertEqual(strokeSegs[0].endPosition, 0.55, accuracy: 1e-9)   // travel 0.1 → just off centre
        XCTAssertEqual(strokeSegs[2].endPosition, 1.0, accuracy: 1e-9)    // travel 1.0 → rail
    }

    // A9. The speed-bucket reference path (ScratchStrokeGeometry) is untouched by this change:
    //     it still differentiates speed buckets (fast deflects more than slow in the same phrase).
    func testSpeedBucketReferencePathStillDifferentiates() {
        let content = LaneContent(
            strokes: [
                LaneStroke(startTime: 0.2, endTime: 0.6, direction: .forward, speed: .slow, faderState: .open, isGhost: false),
                LaneStroke(startTime: 1.0, endTime: 1.4, direction: .forward, speed: .fast, faderState: .open, isGhost: false),
            ],
            segments: [], beatsPerMinute: nil, duration: 2.0, loops: false)
        let path = ScratchStrokeGeometry.motionPath(for: content)
        let strokeSegs = path.segments.filter { if case .stroke = $0.kind { return true }; return false }
        XCTAssertGreaterThanOrEqual(strokeSegs.count, 4)
        let centre = path.segments.first { $0.isHold }?.startPosition ?? 0.5
        let slowDev = abs(strokeSegs[0].endPosition - centre)
        let fastDev = abs(strokeSegs[2].endPosition - centre)
        XCTAssertLessThan(slowDev, fastDev, "speed-bucket reference must still rank fast above slow")
    }

    // A10. Real recording at the four UI slider values (signed mode): peak excursion strictly
    //      shrinks as fullScaleTravelPercent grows, and a low scale drives the larger stroke to the
    //      rail. (The DEBUG green lane itself now uses `.absoluteAboveBaseline` — see B10.)
    func testRealFixtureAbsoluteScaleAcrossSliderValues() throws {
        let data = try fixtureData("scratch_timeline_cc6_real_fader_cut_fixture")
        let sliderValues: [Double] = [0.5, 1.0, 2.0, 3.0]   // matches the DEBUG slider range
        var peaks: [CGFloat] = []
        for fullScale in sliderValues {
            let model = try ScratchTimelineProvenance.displayModel(
                from: data, calibration: rane, fullScaleTravelPercent: fullScale)
            let lastEnd = model.strokes.map(\.endTime).max() ?? 0
            let path = ScratchNotationTravelMotionPath.motionPath(
                for: model, duration: lastEnd + 0.5, scaling: .absoluteSigned)
            peaks.append(peakDeviation(path))
        }
        print("ABSOLUTE peak excursion by fullScaleTravelPercent \(sliderValues): \(peaks)")
        // Strictly decreasing excursion as the scale grows (lower scale = bigger / more rail).
        for i in 1..<peaks.count {
            XCTAssertLessThan(peaks[i], peaks[i - 1],
                              "real fixture: larger scale \(sliderValues[i]) must shrink excursion")
        }
        // At the lowest slider value the forward stroke reaches the rail (peak deviation 0.5).
        XCTAssertEqual(peaks.first ?? 0, 0.5, accuracy: 1e-9, "low scale must rail the larger stroke")
    }

    // MARK: - Absolute ABOVE-BASELINE scaling mode (DEBUG notation — the green lane's actual mode)

    /// The baseline (lane floor) for the above-baseline mode is raw 0 — any hold sits there.
    private func baselinePosition(_ path: MotionPath) -> CGFloat {
        path.segments.first { $0.isHold }?.startPosition ?? 0
    }

    private func aboveBaseline(_ strokes: [ScratchNotationLanePreviewModel.Stroke],
                               fullScale: Double, duration: TimeInterval = 4.0) -> MotionPath {
        ScratchNotationTravelMotionPath.motionPath(
            for: display(strokes, fullScale: fullScale), duration: duration,
            scaling: .absoluteAboveBaseline)
    }

    // B1. Above-baseline mode NEVER goes below the baseline (min position == baseline 0), for a
    //     phrase mixing forward and reverse strokes.
    func testAboveBaselineNeverGoesBelowBaseline() {
        let path = aboveBaseline([pStroke(.forward, 0.2, 0.8, 0.6),
                                  pStroke(.reverse, 1.2, 1.8, 0.9),
                                  pStroke(.forward, 2.2, 2.8, 0.3)], fullScale: 1.0)
        XCTAssertEqual(minPosition(path), 0.0, accuracy: 1e-9)
        XCTAssertEqual(baselinePosition(path), 0.0, accuracy: 1e-9)
        XCTAssertGreaterThan(maxPosition(path), 0.0, "strokes must rise above the baseline")
    }

    // B2. Travel 0 stays exactly on the baseline (no excursion).
    func testAboveBaselineZeroTravelStaysOnBaseline() {
        let path = aboveBaseline([pStroke(.forward, 1, 2, 0.0)], fullScale: 1.0, duration: 3.0)
        XCTAssertEqual(maxPosition(path), 0.0, accuracy: 1e-9)
        XCTAssertEqual(minPosition(path), 0.0, accuracy: 1e-9)
    }

    // B3. Larger normalizedTravel → taller excursion (same scale).
    func testAboveBaselineLargerTravelIsTaller() {
        let path = aboveBaseline([pStroke(.forward, 0, 1, 0.2),
                                  pStroke(.forward, 2, 3, 0.9)], fullScale: 1.0)
        let strokeSegs = path.segments.filter { if case .stroke = $0.kind { return true }; return false }
        XCTAssertGreaterThanOrEqual(strokeSegs.count, 4)
        XCTAssertEqual(strokeSegs[0].endPosition, 0.2, accuracy: 1e-9)   // travel 0.2 → height 0.2
        XCTAssertEqual(strokeSegs[2].endPosition, 0.9, accuracy: 1e-9)   // travel 0.9 → height 0.9
        XCTAssertLessThan(strokeSegs[0].endPosition, strokeSegs[2].endPosition)
    }

    // B4/B5. Lower fullScaleTravelPercent = taller; higher = shorter (strictly monotone).
    func testAboveBaselineScaleControlsHeight() {
        let scales: [Double] = [0.5, 1.0, 2.0, 3.0]
        // travel 0.4 stays sub-rail at every scale (0.4/0.5 = 0.8 < 1.0) so heights stay comparable.
        let heights = scales.map { maxPosition(aboveBaseline([pStroke(.forward, 1, 2, 0.4)], fullScale: $0, duration: 3.0)) }
        for i in 1..<heights.count {
            XCTAssertLessThan(heights[i], heights[i - 1],
                              "larger scale \(scales[i]) must make the stroke shorter")
        }
        // Concrete heights: 0.4/scale → 0.8, 0.4, 0.2, 0.133…
        XCTAssertEqual(heights[0], 0.8, accuracy: 1e-9)
        XCTAssertEqual(heights[1], 0.4, accuracy: 1e-9)
    }

    // B6. Forward AND reverse both rise above the baseline (neither dips below).
    func testAboveBaselineForwardAndReverseBothRise() {
        let fwd = aboveBaseline([pStroke(.forward, 1, 2, 0.6)], fullScale: 1.0, duration: 3.0)
        let rev = aboveBaseline([pStroke(.reverse, 1, 2, 0.6)], fullScale: 1.0, duration: 3.0)
        XCTAssertEqual(maxPosition(fwd), 0.6, accuracy: 1e-9)
        XCTAssertEqual(maxPosition(rev), 0.6, accuracy: 1e-9, "reverse rises to the same height as forward")
        XCTAssertEqual(minPosition(fwd), 0.0, accuracy: 1e-9)
        XCTAssertEqual(minPosition(rev), 0.0, accuracy: 1e-9, "reverse must NOT dip below the baseline")
        // Direction is still carried truthfully by the segment kind, not by sign.
        let revStroke = rev.segments.first { if case .stroke = $0.kind { return true }; return false }
        XCTAssertEqual(revStroke?.isRising, false, "reverse keeps its .backward kind for the renderer")
    }

    // B7. Timing (segment start/end times + kinds) is identical to `.perPhrase`; only positions differ.
    func testAboveBaselinePreservesTiming() {
        let model = display([pStroke(.forward, 0.2, 0.8, 0.7), pStroke(.reverse, 1.5, 2.1, 0.4)], fullScale: 1.0)
        let per = ScratchNotationTravelMotionPath.motionPath(for: model, duration: 3.0, scaling: .perPhrase)
        let ab = ScratchNotationTravelMotionPath.motionPath(for: model, duration: 3.0, scaling: .absoluteAboveBaseline)
        XCTAssertEqual(per.segments.count, ab.segments.count)
        XCTAssertEqual(per.timeRange, ab.timeRange)
        for (p, a) in zip(per.segments, ab.segments) {
            XCTAssertEqual(p.startTime, a.startTime, accuracy: 1e-9)
            XCTAssertEqual(p.endTime, a.endTime, accuracy: 1e-9)
            XCTAssertEqual(p.kind, a.kind)
        }
    }

    // B8. Holds return to the baseline and the loop seam closes there (first start == last end == 0).
    func testAboveBaselineHoldsAndSeamReturnToBaseline() {
        let path = aboveBaseline([pStroke(.forward, 1, 2, 0.6), pStroke(.reverse, 2.5, 3, 0.3)], fullScale: 1.0)
        for hold in path.segments.filter(\.isHold) {
            XCTAssertEqual(hold.startPosition, 0.0, accuracy: 1e-9)
            XCTAssertEqual(hold.endPosition, 0.0, accuracy: 1e-9)
        }
        XCTAssertEqual(path.segments.first?.startPosition ?? -1, 0.0, accuracy: 1e-9)
        XCTAssertEqual(path.segments.last?.endPosition ?? -1, 0.0, accuracy: 1e-9)
        XCTAssertEqual(path.position(at: 0.0), 0.0, accuracy: 1e-9)
        XCTAssertEqual(path.position(at: 4.0), 0.0, accuracy: 1e-9)
    }

    // B9. The default `.perPhrase` path is unchanged by the new mode (defaulted-arg backward-compat).
    func testAboveBaselineDoesNotChangePerPhraseDefault() {
        let model = display([pStroke(.forward, 0, 1, 0.3), pStroke(.reverse, 1, 2, 0.9)], fullScale: 1.0)
        XCTAssertEqual(
            ScratchNotationTravelMotionPath.motionPath(for: model, duration: 3.0),
            ScratchNotationTravelMotionPath.motionPath(for: model, duration: 3.0, scaling: .perPhrase))
    }

    // B10. Real recording, above-baseline, at the four UI slider values: stroke HEIGHT strictly
    //      shrinks as the scale grows, a low scale rails the larger stroke, and NOTHING dips below
    //      the baseline — the exact green-lane pipeline the DEBUG view renders.
    func testRealFixtureAboveBaselineAcrossSliderValues() throws {
        let data = try fixtureData("scratch_timeline_cc6_real_fader_cut_fixture")
        let sliderValues: [Double] = [0.5, 1.0, 2.0, 3.0]
        var heights: [CGFloat] = []
        for fullScale in sliderValues {
            let model = try ScratchTimelineProvenance.displayModel(
                from: data, calibration: rane, fullScaleTravelPercent: fullScale)
            let lastEnd = model.strokes.map(\.endTime).max() ?? 0
            let path = ScratchNotationTravelMotionPath.motionPath(
                for: model, duration: lastEnd + 0.5, scaling: .absoluteAboveBaseline)
            XCTAssertEqual(minPosition(path), 0.0, accuracy: 1e-9, "scale \(fullScale): nothing below baseline")
            heights.append(maxPosition(path))
        }
        print("ABOVE-BASELINE stroke height by fullScaleTravelPercent \(sliderValues): \(heights)")
        for i in 1..<heights.count {
            XCTAssertLessThan(heights[i], heights[i - 1],
                              "real fixture: larger scale \(sliderValues[i]) must shorten the stroke")
        }
        XCTAssertEqual(heights.first ?? 0, 1.0, accuracy: 1e-9, "low scale must rail the larger stroke")
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
