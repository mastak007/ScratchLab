// Headless automated proof behind Stage C's debug A/B view: for the same hand-authored phrase,
// the travel-driven MotionPath makes a short stroke deflect LESS than the speed-bucket MotionPath,
// while keeping identical stroke timing. No SwiftUI / Canvas rendering — pure geometry comparison.
//
// This guards the Stage C claim ("short stroke reads short, full stroke reaches the rail") without
// UI test infrastructure. It does not touch the production renderer; it only compares the two
// existing pure path builders.

import XCTest
@testable import ScratchLab

final class TravelLaneDebugComparisonTests: XCTestCase {

    private let duration: TimeInterval = 4.0

    // Same sample as TravelLaneDebugView (authored independently to avoid cross-target coupling):
    // a short stroke [0.2,0.5], a full stroke [1.0,1.6], a reversal [2.2,2.8].

    private var speedBucketPath: MotionPath {
        let strokes = [
            LaneStroke(startTime: 0.2, endTime: 0.5, direction: .forward,
                       speed: .fast, faderState: .open, isGhost: false),     // short but FAST
            LaneStroke(startTime: 1.0, endTime: 1.6, direction: .forward,
                       speed: .fast, faderState: .open, isGhost: false),
            LaneStroke(startTime: 2.2, endTime: 2.8, direction: .backward,
                       speed: .medium, faderState: .open, isGhost: false),
        ]
        let content = LaneContent(strokes: strokes, segments: [], beatsPerMinute: nil,
                                  duration: duration, loops: false)
        return ScratchStrokeGeometry.motionPath(for: content)
    }

    private func travelPath(fullScale: Double = 1.0) -> MotionPath {
        let preview = ScratchNotationLanePreviewModel(strokes: [
            .init(direction: .forward, startTime: 0.2, endTime: 0.5, travelPercent: 0.2, audibleState: .audible),
            .init(direction: .forward, startTime: 1.0, endTime: 1.6, travelPercent: 1.0, audibleState: .audible),
            .init(direction: .reverse, startTime: 2.2, endTime: 2.8, travelPercent: 0.5, audibleState: .cut),
        ], warnings: [])
        let model = ScratchNotationLaneDisplayAdapter.displayModel(from: preview, fullScaleTravelPercent: fullScale)
        return ScratchNotationTravelMotionPath.motionPath(for: model, duration: duration)
    }

    // MARK: - Helpers

    private func centre(_ path: MotionPath) -> CGFloat {
        path.segments.first { $0.isHold }?.startPosition ?? 0.5
    }

    /// The out-half end position of the first stroke (its deflection peak).
    private func firstStrokeDeviation(_ path: MotionPath) -> CGFloat {
        let firstStroke = path.segments.first { if case .stroke = $0.kind { return true }; return false }
        return abs((firstStroke?.endPosition ?? centre(path)) - centre(path))
    }

    private func firstStrokeSegment(_ path: MotionPath) -> MotionSegment? {
        path.segments.first { if case .stroke = $0.kind { return true }; return false }
    }

    // MARK: - Tests

    // 1. The short stroke deflects LESS in the travel lane than in the speed-bucket lane.
    func testTravelShortensTheShortStrokeVsSpeedBucket() {
        let speedDev = firstStrokeDeviation(speedBucketPath)
        let travelDev = firstStrokeDeviation(travelPath())
        XCTAssertGreaterThan(speedDev, 0.4, "fast short stroke nearly rails in the speed-bucket lane")
        XCTAssertLessThan(travelDev, speedDev, "travel lane must make the short stroke read shorter")
    }

    // 2. Timing (x) is identical: the first stroke covers the same time span in both lanes.
    func testTimingIdenticalAcrossLanes() {
        // Speed-bucket lane (continuous): the first stroke is ONE segment
        // covering its full [0.2, 0.5] window.
        let s = firstStrokeSegment(speedBucketPath)
        XCTAssertEqual(s?.startTime ?? -1, 0.2, accuracy: 1e-9)
        XCTAssertEqual(s?.endTime ?? -1, 0.5, accuracy: 1e-9)

        // Travel lane (unchanged out/return grammar): the first stroke's
        // out + return halves collectively cover the same [0.2, 0.5] window.
        let tStrokeSegs = travelPath().segments.filter {
            if case .stroke = $0.kind { return true }; return false
        }
        XCTAssertEqual(tStrokeSegs.first?.startTime ?? -1, 0.2, accuracy: 1e-9)
        XCTAssertEqual(tStrokeSegs[1].endTime, 0.5, accuracy: 1e-9)
    }

    // 3. In the travel lane, the full-travel stroke reaches the rail (normalized extreme 1.0).
    func testFullTravelStrokeReachesRailInTravelLane() {
        let maxPos = travelPath().segments.flatMap { [$0.startPosition, $0.endPosition] }.max() ?? 0
        XCTAssertEqual(maxPos, 1.0, accuracy: 1e-9)
    }

    // 4. Deterministic.
    func testDeterministic() {
        XCTAssertEqual(travelPath(), travelPath())
        XCTAssertEqual(speedBucketPath, speedBucketPath)
    }
}
