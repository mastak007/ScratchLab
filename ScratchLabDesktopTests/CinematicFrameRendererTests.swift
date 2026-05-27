import XCTest
import CoreGraphics
@testable import ScratchLab

/// Phase D-X1 — locks the contract of `CinematicFrameRenderer`: pure,
/// deterministic CGImage rasterisation, no AVFoundation, no clock.
final class CinematicFrameRendererTests: XCTestCase {

    // MARK: - Helpers

    private func makeFrame() -> CinematicFrame {
        let viewport = NotationLaneViewport(
            startTime: 0, endTime: 4, width: 100, height: 40
        )!
        let stroke = NotationLaneStrokeGeometry(
            primitiveIndex: 0, xStart: 10, xEnd: 50,
            yStart: 10, yEnd: 30, family: .baby, coachingKinds: []
        )
        let lane = NotationLaneGeometryModel(strokes: [stroke])
        let gridlines = NotationGridlineGeometryModel(gridlines: [
            NotationGridlineGeometry(kind: .bar, time: 0, x: 0),
            NotationGridlineGeometry(kind: .beat, time: 1, x: 25),
        ])
        let playhead = NotationPlayheadGeometry(
            time: 1.5, x: 38, yTop: 0, yBottom: 40, isWithinViewport: true
        )
        let frame = NotationReplayFrame(index: 0, time: 1.5)!
        return CinematicFrame(
            frame: frame,
            viewport: viewport,
            laneGeometry: lane,
            gridlineGeometry: gridlines,
            playhead: playhead
        )
    }

    // MARK: - Construction

    func testRendersImageAtRequestedSize() {
        let image = CinematicFrameRenderer.renderImage(
            frame: makeFrame(), width: 100, height: 40
        )
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.width, 100)
        XCTAssertEqual(image?.height, 40)
    }

    func testRejectsZeroDimensions() {
        XCTAssertNil(CinematicFrameRenderer.renderImage(
            frame: makeFrame(), width: 0, height: 40
        ))
        XCTAssertNil(CinematicFrameRenderer.renderImage(
            frame: makeFrame(), width: 100, height: 0
        ))
    }

    func testRejectsNegativeDimensions() {
        XCTAssertNil(CinematicFrameRenderer.renderImage(
            frame: makeFrame(), width: -10, height: 40
        ))
    }

    // MARK: - Determinism

    func testRendersDeterministicPixelHash() {
        // Same frame + same dimensions → identical pixel byte stream.
        // Hashes the raw BGRA buffer; if any drawing call became
        // non-deterministic (e.g., timestamp leak), this fails.
        let frame = makeFrame()
        let hashA = pixelHash(width: 100, height: 40, frame: frame)
        let hashB = pixelHash(width: 100, height: 40, frame: frame)
        XCTAssertNotNil(hashA)
        XCTAssertEqual(hashA, hashB)
    }

    func testDifferentFramesProduceDifferentHashes() {
        let viewport = NotationLaneViewport(
            startTime: 0, endTime: 4, width: 100, height: 40
        )!
        let strokeA = NotationLaneStrokeGeometry(
            primitiveIndex: 0, xStart: 10, xEnd: 50,
            yStart: 10, yEnd: 30, family: .baby, coachingKinds: []
        )
        let strokeB = NotationLaneStrokeGeometry(
            primitiveIndex: 0, xStart: 10, xEnd: 50,
            yStart: 10, yEnd: 30, family: .baby, coachingKinds: [.lateReversal]
        )
        let frameA = CinematicFrame(
            frame: NotationReplayFrame(index: 0, time: 0)!,
            viewport: viewport,
            laneGeometry: NotationLaneGeometryModel(strokes: [strokeA]),
            gridlineGeometry: nil,
            playhead: nil
        )
        let frameB = CinematicFrame(
            frame: NotationReplayFrame(index: 0, time: 0)!,
            viewport: viewport,
            laneGeometry: NotationLaneGeometryModel(strokes: [strokeB]),
            gridlineGeometry: nil,
            playhead: nil
        )
        XCTAssertNotEqual(
            pixelHash(width: 100, height: 40, frame: frameA),
            pixelHash(width: 100, height: 40, frame: frameB)
        )
    }

    // MARK: - Pixel hash helper

    private func pixelHash(width: Int, height: Int, frame: CinematicFrame) -> Int? {
        guard let image = CinematicFrameRenderer.renderImage(
            frame: frame, width: width, height: height
        ) else { return nil }
        guard let data = image.dataProvider?.data else { return nil }
        let length = CFDataGetLength(data)
        let bytes = CFDataGetBytePtr(data)
        var hasher = Hasher()
        for i in 0..<length {
            hasher.combine(bytes![i])
        }
        return hasher.finalize()
    }
}
