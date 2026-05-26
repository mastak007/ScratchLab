#if DEBUG
import SwiftUI

// MARK: - DebugNotationLaneHostView

/// A DEBUG-only host surface that wraps `NotationLaneGeometryView`
/// with synthetic in-memory geometry for manual inspection.
///
/// **Purpose:** allow a developer to open the notation lane renderer
/// inside the running app and switch between empty, simple, and dense
/// geometry presets without touching production Practice/Review flows.
///
/// **No production impact:** the entire file is gated behind `#if DEBUG`
/// and the navigation entry point is gated the same way inside
/// `AdvancedHubView`.
struct DebugNotationLaneHostView: View {

    private enum Preset: String, CaseIterable {
        case empty
        case simple
        case dense
    }

    @State private var preset: Preset = .simple

    private static let laneWidth: Double = 400
    private static let laneHeight: Double = 200

    var body: some View {
        VStack(spacing: 0) {
            Picker("Preset", selection: $preset) {
                ForEach(Preset.allCases, id: \.self) { mode in
                    Text(mode.rawValue.capitalized)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            NotationLaneGeometryView(
                geometry: geometry,
                gridlines: gridlines,
                playhead: playhead
            )
            .frame(height: Self.laneHeight)
            .padding(.horizontal)

            Spacer()
        }
        .background(Color.black)
        .navigationTitle("Notation Lane")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }

    // MARK: Geometry

    private var geometry: NotationLaneGeometryModel {
        switch preset {
        case .empty:  return Self.emptyStrokes
        case .simple: return Self.simpleStrokes
        case .dense:  return Self.denseStrokes
        }
    }

    private var gridlines: NotationGridlineGeometryModel {
        switch preset {
        case .empty:  return Self.emptyGridlines
        case .simple: return Self.simpleGridlines
        case .dense:  return Self.denseGridlines
        }
    }

    private var playhead: NotationPlayheadGeometry? {
        switch preset {
        case .empty:  return nil
        case .simple: return Self.simplePlayhead
        case .dense:  return Self.densePlayhead
        }
    }

    // MARK: Preset data

    private static let emptyStrokes = NotationLaneGeometryModel(strokes: [])
    private static let emptyGridlines = NotationGridlineGeometryModel(gridlines: [])

    private static let simpleStrokes: NotationLaneGeometryModel = {
        let h = laneHeight
        let strokes: [NotationLaneStrokeGeometry] = [
            NotationLaneStrokeGeometry(
                primitiveIndex: 0, xStart: 20, xEnd: 80,
                yStart: h * 0.25, yEnd: h * 0.75,
                family: .baby, coachingKinds: []
            ),
            NotationLaneStrokeGeometry(
                primitiveIndex: 1, xStart: 100, xEnd: 160,
                yStart: h * 0.25, yEnd: h * 0.75,
                family: .chirp, coachingKinds: []
            ),
            NotationLaneStrokeGeometry(
                primitiveIndex: 2, xStart: 180, xEnd: 180,
                yStart: h * 0.5, yEnd: h * 0.5,
                family: nil, coachingKinds: []
            ),
            NotationLaneStrokeGeometry(
                primitiveIndex: 3, xStart: 220, xEnd: 300,
                yStart: h * 0.25, yEnd: h * 0.75,
                family: .flare, coachingKinds: [.lateReversal]
            ),
            NotationLaneStrokeGeometry(
                primitiveIndex: 4, xStart: 340, xEnd: 310,
                yStart: h * 0.75, yEnd: h * 0.25,
                family: .tear, coachingKinds: []
            ),
        ]
        return NotationLaneGeometryModel(strokes: strokes)
    }()

    private static let simpleGridlines: NotationGridlineGeometryModel = {
        let lines: [NotationGridlineGeometry] = [
            NotationGridlineGeometry(kind: .bar, time: 0, x: 0),
            NotationGridlineGeometry(kind: .beat, time: 2.5, x: 100),
            NotationGridlineGeometry(kind: .subdivision, time: 3.75, x: 150),
            NotationGridlineGeometry(kind: .bar, time: 5, x: 200),
            NotationGridlineGeometry(kind: .beat, time: 7.5, x: 300),
        ]
        return NotationGridlineGeometryModel(gridlines: lines)
    }()

    private static let simplePlayhead = NotationPlayheadGeometry(
        time: 4, x: 160, yTop: 0, yBottom: laneHeight,
        isWithinViewport: true
    )

    private static let denseStrokes: NotationLaneGeometryModel = {
        let h = laneHeight
        var strokes: [NotationLaneStrokeGeometry] = []
        for i in 0..<30 {
            let xStart = Double(i) * 13 + 5
            let forward = i % 3 != 0
            let xEnd = forward ? xStart + Double(8 + (i % 15)) : xStart
            let yStart: Double
            let yEnd: Double
            if forward {
                yStart = h * 0.25
                yEnd = h * 0.75
            } else if i % 2 == 0 {
                yStart = h * 0.5
                yEnd = h * 0.5
            } else {
                yStart = h * 0.75
                yEnd = h * 0.25
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
    }()

    private static let denseGridlines: NotationGridlineGeometryModel = {
        let w = laneWidth
        var lines: [NotationGridlineGeometry] = []
        for i in 0..<40 {
            let time = Double(i) * 0.25
            let x = (time / 10.0) * w
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
    }()

    private static let densePlayhead = NotationPlayheadGeometry(
        time: 5, x: 200, yTop: 0, yBottom: laneHeight,
        isWithinViewport: true
    )
}

#endif
