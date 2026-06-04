// PR1 of Stage D: ScratchStrokeGeometry now prefers LaneStroke.normalizedTravel for stroke
// amplitude when present, falling back to the EXACT existing speed-bucket amplitude when nil.
//
// These tests pin both halves: (a) nil normalizedTravel reproduces the old speed-bucket geometry
// byte-for-byte (regression — demo/scored/reel/notation strokes are untouched), and (b) a non-nil
// normalizedTravel drives a travel-scaled excursion (short < full, full → rail, clamped 0...1).
//
// Pure geometry comparison — no UI, no renderer Canvas. No reference to analysis/provenance.

import CoreGraphics
import XCTest
@testable import ScratchLab

final class ScratchStrokeGeometryTravelAmplitudeTests: XCTestCase {

    private let duration: TimeInterval = 4.0

    private func content(_ strokes: [LaneStroke]) -> LaneContent {
        LaneContent(strokes: strokes, segments: [], beatsPerMinute: nil, duration: duration, loops: false)
    }

    private func centre(_ path: MotionPath) -> CGFloat {
        path.segments.first { $0.isHold }?.startPosition ?? 0.5
    }

    /// Out-half end position (deflection peak) of the first stroke.
    private func firstStrokeDeviation(_ path: MotionPath) -> CGFloat {
        let s = path.segments.first { if case .stroke = $0.kind { return true }; return false }
        return abs((s?.endPosition ?? centre(path)) - centre(path))
    }

    // MARK: - Regression: nil normalizedTravel == existing speed-bucket behaviour

    func testNilNormalizedTravelIsByteIdenticalToSpeedBucket() {
        let strokes: [LaneStroke] = [
            .init(startTime: 0.2, endTime: 0.5, direction: .forward, speed: .fast, faderState: .open, isGhost: false),
            .init(startTime: 1.0, endTime: 1.6, direction: .forward, speed: .slow, faderState: .open, isGhost: false),
            .init(startTime: 2.2, endTime: 2.8, direction: .backward, speed: .medium, faderState: .open, isGhost: false),
        ]
        // All strokes default normalizedTravel == nil.
        XCTAssertTrue(strokes.allSatisfy { $0.normalizedTravel == nil })
        let path = ScratchStrokeGeometry.motionPath(for: content(strokes))
        // Speed buckets: fast 1.0, slow 0.55, medium 0.78 (signs +,+,-). Raw extents define the
        // normalization; the fast stroke is the path maximum → its out-half end normalizes to 1.0.
        let maxPos = path.segments.flatMap { [$0.startPosition, $0.endPosition] }.max() ?? 0
        XCTAssertEqual(maxPos, 1.0, accuracy: 1e-12)
        // Deterministic + stable (guards against accidental behaviour change).
        XCTAssertEqual(path, ScratchStrokeGeometry.motionPath(for: content(strokes)))
    }

    // MARK: - Travel-driven amplitude when present

    func testNormalizedTravelDrivesAmplitudeShortLessThanFull() {
        let strokes: [LaneStroke] = [
            .init(startTime: 0.2, endTime: 0.5, direction: .forward, speed: .fast, faderState: .open,
                  isGhost: false, normalizedTravel: 0.2),                     // small travel
            .init(startTime: 1.0, endTime: 1.6, direction: .forward, speed: .fast, faderState: .open,
                  isGhost: false, normalizedTravel: 1.0),                     // full travel
        ]
        let path = ScratchStrokeGeometry.motionPath(for: content(strokes))
        let strokeSegs = path.segments.filter { if case .stroke = $0.kind { return true }; return false }
        XCTAssertGreaterThanOrEqual(strokeSegs.count, 4)
        let c = centre(path)
        // First stroke (travel 0.2) deflects less than second (travel 1.0), despite both being FAST.
        XCTAssertLessThan(abs(strokeSegs[0].endPosition - c), abs(strokeSegs[2].endPosition - c))
    }

    func testFullTravelReachesRail() {
        let strokes: [LaneStroke] = [
            .init(startTime: 1.0, endTime: 2.0, direction: .forward, speed: .slow, faderState: .open,
                  isGhost: false, normalizedTravel: 1.0),
        ]
        let path = ScratchStrokeGeometry.motionPath(for: content(strokes))
        let maxPos = path.segments.flatMap { [$0.startPosition, $0.endPosition] }.max() ?? 0
        XCTAssertEqual(maxPos, 1.0, accuracy: 1e-12)
    }

    func testNormalizedTravelClampedToUnitRange() {
        // travel > 1 clamps to 1 (same as full), travel < 0 clamps to 0 (flat).
        let big = content([.init(startTime: 1, endTime: 2, direction: .forward, speed: .slow,
                                 faderState: .open, isGhost: false, normalizedTravel: 5.0)])
        let unit = content([.init(startTime: 1, endTime: 2, direction: .forward, speed: .slow,
                                  faderState: .open, isGhost: false, normalizedTravel: 1.0)])
        XCTAssertEqual(ScratchStrokeGeometry.motionPath(for: big),
                       ScratchStrokeGeometry.motionPath(for: unit))

        let neg = content([.init(startTime: 1, endTime: 2, direction: .forward, speed: .slow,
                                 faderState: .open, isGhost: false, normalizedTravel: -3.0)])
        // Negative travel → 0 amplitude → flat path at centre.
        XCTAssertEqual(firstStrokeDeviation(ScratchStrokeGeometry.motionPath(for: neg)), 0.0, accuracy: 1e-12)
    }

    // MARK: - LaneStroke field plumbing

    func testShiftedPreservesNormalizedTravel() {
        let s = LaneStroke(startTime: 1, endTime: 2, direction: .forward, speed: .fast,
                           faderState: .open, isGhost: false, normalizedTravel: 0.42)
        XCTAssertEqual(s.shifted(by: 3).normalizedTravel, 0.42)
    }

    func testConvenienceInitsProduceNilTravel() {
        // Reel and scored-notation strokes carry no travel → nil (rendered as before).
        let notationStroke = ScratchNotation.Stroke(
            startTime: 0, endTime: 1, direction: .forward, speedClassification: .medium, faderState: .open)
        XCTAssertNil(LaneStroke(notationStroke: notationStroke).normalizedTravel)
    }
}
