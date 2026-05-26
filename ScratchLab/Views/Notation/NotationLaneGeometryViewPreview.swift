#if DEBUG
import SwiftUI

// MARK: - Preview Data Factory

/// Synthesizes in-memory geometry for `NotationLaneGeometryView`
/// previews. No assets, no fixtures, no timing engine.
private enum PreviewFactory {

    private static let width: Double = 400
    private static let height: Double = 200

    // MARK: Empty

    static var emptyGeometry: NotationLaneGeometryModel {
        NotationLaneGeometryModel(strokes: [])
    }

    static var emptyGridlines: NotationGridlineGeometryModel {
        NotationGridlineGeometryModel(gridlines: [])
    }

    // MARK: Simple

    static var simpleGeometry: NotationLaneGeometryModel {
        let strokes: [NotationLaneStrokeGeometry] = [
            NotationLaneStrokeGeometry(
                primitiveIndex: 0, xStart: 20, xEnd: 80,
                yStart: height * 0.25, yEnd: height * 0.75,
                family: .baby, coachingKinds: []
            ),
            NotationLaneStrokeGeometry(
                primitiveIndex: 1, xStart: 100, xEnd: 160,
                yStart: height * 0.25, yEnd: height * 0.75,
                family: .chirp, coachingKinds: []
            ),
            NotationLaneStrokeGeometry(
                primitiveIndex: 2, xStart: 180, xEnd: 180,
                yStart: height * 0.5, yEnd: height * 0.5,
                family: nil, coachingKinds: []
            ),
            NotationLaneStrokeGeometry(
                primitiveIndex: 3, xStart: 220, xEnd: 300,
                yStart: height * 0.25, yEnd: height * 0.75,
                family: .flare, coachingKinds: [.lateReversal]
            ),
            NotationLaneStrokeGeometry(
                primitiveIndex: 4, xStart: 340, xEnd: 310,
                yStart: height * 0.75, yEnd: height * 0.25,
                family: .tear, coachingKinds: []
            ),
        ]
        return NotationLaneGeometryModel(strokes: strokes)
    }

    static var simpleGridlines: NotationGridlineGeometryModel {
        let lines: [NotationGridlineGeometry] = [
            NotationGridlineGeometry(kind: .bar, time: 0, x: 0),
            NotationGridlineGeometry(kind: .beat, time: 2.5, x: 100),
            NotationGridlineGeometry(kind: .subdivision, time: 3.75, x: 150),
            NotationGridlineGeometry(kind: .bar, time: 5, x: 200),
            NotationGridlineGeometry(kind: .beat, time: 7.5, x: 300),
        ]
        return NotationGridlineGeometryModel(gridlines: lines)
    }

    static var simplePlayhead: NotationPlayheadGeometry {
        NotationPlayheadGeometry(
            time: 4, x: 160, yTop: 0, yBottom: height,
            isWithinViewport: true
        )
    }

    // MARK: Dense

    static var denseGeometry: NotationLaneGeometryModel {
        var strokes: [NotationLaneStrokeGeometry] = []
        for i in 0..<30 {
            let xStart = Double(i) * 13 + 5
            let forward = i % 3 != 0
            let xEnd = forward ? xStart + Double(8 + (i % 15)) : xStart
            let yStart: Double
            let yEnd: Double
            if forward {
                yStart = height * 0.25
                yEnd = height * 0.75
            } else if i % 2 == 0 {
                yStart = height * 0.5
                yEnd = height * 0.5
            } else {
                yStart = height * 0.75
                yEnd = height * 0.25
            }
            let family: ScratchFamily? = i % 5 == 0 ? .baby : (i % 7 == 0 ? .chirp : nil)
            let kinds: [CoachingEventKind] = i % 4 == 0 ? [.unstableTiming] : []
            strokes.append(NotationLaneStrokeGeometry(
                primitiveIndex: i,
                xStart: xStart,
                xEnd: xEnd,
                yStart: yStart,
                yEnd: yEnd,
                family: family,
                coachingKinds: kinds
            ))
        }
        return NotationLaneGeometryModel(strokes: strokes)
    }

    static var denseGridlines: NotationGridlineGeometryModel {
        var lines: [NotationGridlineGeometry] = []
        for i in 0..<40 {
            let time = Double(i) * 0.25
            let x = (time / 10.0) * width
            let kind: NotationGridlineKind
            if i % 16 == 0 {
                kind = .bar
            } else if i % 4 == 0 {
                kind = .beat
            } else {
                kind = .subdivision
            }
            lines.append(NotationGridlineGeometry(kind: kind, time: time, x: x))
        }
        return NotationGridlineGeometryModel(gridlines: lines)
    }

    static var densePlayhead: NotationPlayheadGeometry {
        NotationPlayheadGeometry(
            time: 5, x: 200, yTop: 0, yBottom: height,
            isWithinViewport: true
        )
    }
}

// MARK: - Previews

#Preview("Empty Lane") {
    NotationLaneGeometryView(
        geometry: PreviewFactory.emptyGeometry,
        gridlines: PreviewFactory.emptyGridlines,
        playhead: nil
    )
    .frame(width: 400, height: 200)
}

#Preview("Simple") {
    NotationLaneGeometryView(
        geometry: PreviewFactory.simpleGeometry,
        gridlines: PreviewFactory.simpleGridlines,
        playhead: PreviewFactory.simplePlayhead
    )
    .frame(width: 400, height: 200)
}

#Preview("Dense") {
    NotationLaneGeometryView(
        geometry: PreviewFactory.denseGeometry,
        gridlines: PreviewFactory.denseGridlines,
        playhead: PreviewFactory.densePlayhead
    )
    .frame(width: 400, height: 200)
}

#endif
