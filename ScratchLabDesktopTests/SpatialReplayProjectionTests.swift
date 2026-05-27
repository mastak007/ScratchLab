import XCTest
@testable import ScratchLab

/// Phase D-S0 — locks the contract of `SpatialReplayProjector`: pure
/// 3D projection, no AR imports, deterministic across calls.
final class SpatialReplayProjectionTests: XCTestCase {

    // MARK: - Helpers

    private func makeViewport() -> NotationLaneViewport {
        NotationLaneViewport(
            startTime: 0, endTime: 4, width: 100, height: 40
        )!
    }

    private func makeReplay(strokes: [NotationLaneStrokeGeometry]) -> NotationReplayProjection {
        NotationReplayProjection(
            viewport: makeViewport(),
            laneGeometry: NotationLaneGeometryModel(strokes: strokes),
            gridlineGeometry: nil,
            playhead: NotationPlayheadGeometry(
                time: 1.5, x: 38, yTop: 0, yBottom: 40, isWithinViewport: true
            )
        )
    }

    private func audioOnsetStroke() -> NotationLaneStrokeGeometry {
        // family == nil → audio-onset → solid (z = 0).
        NotationLaneStrokeGeometry(
            primitiveIndex: 0, xStart: 10, xEnd: 30,
            yStart: 10, yEnd: 30, family: nil, coachingKinds: []
        )
    }

    private func classifierStroke() -> NotationLaneStrokeGeometry {
        // family != nil → classifier-derived → dashed (z = depth).
        NotationLaneStrokeGeometry(
            primitiveIndex: 1, xStart: 40, xEnd: 60,
            yStart: 30, yEnd: 10, family: .baby, coachingKinds: [.lateReversal]
        )
    }

    // MARK: - Solid vs dashed split

    func testAudioOnsetStrokeProjectsAtZeroDepth() {
        let replay = makeReplay(strokes: [audioOnsetStroke()])
        let projection = SpatialReplayProjector.project(replay, depth: 0.5)
        XCTAssertEqual(projection.ribbon.count, 1)
        XCTAssertEqual(projection.ribbon[0].kind, .audioOnset)
        XCTAssertEqual(projection.ribbon[0].start.z, 0)
        XCTAssertEqual(projection.ribbon[0].end.z, 0)
    }

    func testClassifierStrokeProjectsAtDepth() {
        let replay = makeReplay(strokes: [classifierStroke()])
        let projection = SpatialReplayProjector.project(replay, depth: 0.5)
        XCTAssertEqual(projection.ribbon.count, 1)
        XCTAssertEqual(projection.ribbon[0].kind, .classifierDerived)
        XCTAssertEqual(projection.ribbon[0].start.z, 0.5)
        XCTAssertEqual(projection.ribbon[0].end.z, 0.5)
    }

    func testCoachingKindsPassThroughUnchanged() {
        let replay = makeReplay(strokes: [classifierStroke()])
        let projection = SpatialReplayProjector.project(replay)
        XCTAssertEqual(projection.ribbon[0].coachingKinds, [.lateReversal])
    }

    // MARK: - X / Y mirror viewport

    func testXYUnchangedFromLaneGeometry() {
        let replay = makeReplay(strokes: [audioOnsetStroke()])
        let projection = SpatialReplayProjector.project(replay, heightCoefficient: 1.0)
        XCTAssertEqual(projection.ribbon[0].start.x, 10)
        XCTAssertEqual(projection.ribbon[0].start.y, 10)
        XCTAssertEqual(projection.ribbon[0].end.x, 30)
        XCTAssertEqual(projection.ribbon[0].end.y, 30)
    }

    func testHeightCoefficientScalesY() {
        let replay = makeReplay(strokes: [audioOnsetStroke()])
        let projection = SpatialReplayProjector.project(replay, heightCoefficient: 2.0)
        XCTAssertEqual(projection.ribbon[0].start.y, 20)
        XCTAssertEqual(projection.ribbon[0].end.y, 60)
    }

    // MARK: - Defensive parameter validation

    func testNegativeDepthCollapsesToZero() {
        let replay = makeReplay(strokes: [classifierStroke()])
        let projection = SpatialReplayProjector.project(replay, depth: -0.5)
        XCTAssertEqual(projection.ribbon[0].start.z, 0)
        XCTAssertEqual(projection.ribbonDepth, 0)
    }

    func testNonFiniteDepthCollapsesToZero() {
        let replay = makeReplay(strokes: [classifierStroke()])
        let projection = SpatialReplayProjector.project(replay, depth: .nan)
        XCTAssertEqual(projection.ribbon[0].start.z, 0)
        XCTAssertEqual(projection.ribbonDepth, 0)
    }

    func testNonPositiveHeightCoefficientFallsBackToOne() {
        let replay = makeReplay(strokes: [audioOnsetStroke()])
        let projection = SpatialReplayProjector.project(replay, heightCoefficient: 0)
        XCTAssertEqual(projection.ribbon[0].start.y, 10)
    }

    // MARK: - Point-in-time markers

    func testZeroDurationAudioOnsetSurfacesAsMarker() {
        let stroke = NotationLaneStrokeGeometry(
            primitiveIndex: 5, xStart: 25, xEnd: 25,
            yStart: 20, yEnd: 20, family: nil, coachingKinds: []
        )
        let replay = makeReplay(strokes: [stroke])
        let projection = SpatialReplayProjector.project(replay)
        XCTAssertEqual(projection.audioOnsets.count, 1)
        XCTAssertEqual(projection.classifierDerivedMarkers.count, 0)
        XCTAssertEqual(projection.audioOnsets[0].primitiveIndex, 5)
    }

    func testZeroDurationClassifierStrokeSurfacesAsClassifierMarker() {
        let stroke = NotationLaneStrokeGeometry(
            primitiveIndex: 7, xStart: 25, xEnd: 25,
            yStart: 20, yEnd: 20, family: .chirp, coachingKinds: []
        )
        let replay = makeReplay(strokes: [stroke])
        let projection = SpatialReplayProjector.project(replay)
        XCTAssertEqual(projection.audioOnsets.count, 0)
        XCTAssertEqual(projection.classifierDerivedMarkers.count, 1)
        XCTAssertEqual(projection.classifierDerivedMarkers[0].primitiveIndex, 7)
    }

    // MARK: - Playhead mirror

    func testPlayheadProjectsToSamePosition() {
        let replay = makeReplay(strokes: [])
        let projection = SpatialReplayProjector.project(replay, heightCoefficient: 1.0)
        XCTAssertEqual(projection.playhead?.position.x, 38)
        XCTAssertEqual(projection.playhead?.position.y, 0)
        XCTAssertEqual(projection.playhead?.height, 40)
        XCTAssertEqual(projection.playhead?.isWithinViewport, true)
    }

    // MARK: - Determinism

    func testDeterministicAcrossReruns() {
        let replay = makeReplay(strokes: [audioOnsetStroke(), classifierStroke()])
        let first = SpatialReplayProjector.project(replay)
        for _ in 0..<99 {
            XCTAssertEqual(SpatialReplayProjector.project(replay), first)
        }
    }
}
