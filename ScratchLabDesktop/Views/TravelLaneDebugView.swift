#if DEBUG
import SwiftUI

// TravelLaneDebugView — Stage C: a DEBUG-only, macOS-only visual A/B of the notation motion lane.
//
// It draws the SAME hand-authored sample phrase two ways, using the EXISTING renderer
// (`ScratchMotionRenderer.draw`) without modifying it, `ScratchStrokeGeometry`, `ScratchMotionLane`,
// or `LaneStroke`:
//
//   • Top lane (current production): excursion comes from the speed bucket
//     (`ScratchStrokeGeometry.motionPath(for:)`) — a short FAST flick still slams the rail.
//   • Bottom lane (proposed): excursion comes from platter travel
//     (`ScratchNotationTravelMotionPath.motionPath(for:)`, Stage A) — the short stroke reads short,
//     the full stroke approaches the rail. Timing (x) is identical in both.
//
// This is preview-only: it is NOT wired into any app navigation/menu and changes no production
// path. The sample is hand-authored here (no app resource, no file I/O, no live capture). Inspect
// it via the Xcode `#Preview` canvas. The `fullScaleTravelPercent` control shows the travel lane
// rescaling — there is deliberately no production default for "full rail".

struct TravelLaneDebugView: View {
    @State private var fullScaleTravelPercent: Double = 1.0

    private let sampleDuration: TimeInterval = 4.0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Notation lane: speed-bucket vs travel (DEBUG)")
                .font(.headline)

            labelledLane("Current — excursion from speed bucket", color: .cyan) { ctx, size in
                ScratchMotionRenderer.draw(speedBucketPath, in: ctx,
                                           viewport: viewport(size: size), style: .target)
            }

            labelledLane("Proposed — excursion from travelPercent", color: .green) { ctx, size in
                ScratchMotionRenderer.draw(travelPath, in: ctx,
                                           viewport: viewport(size: size), style: .user)
            }

            HStack {
                Text("fullScaleTravelPercent: \(fullScaleTravelPercent, specifier: "%.2f")")
                    .font(.caption).monospacedDigit()
                Slider(value: $fullScaleTravelPercent, in: 0.2...3.0)
            }
        }
        .padding()
        .frame(width: 560)
    }

    // MARK: - Lane sub-view

    @ViewBuilder
    private func labelledLane(_ title: String, color: Color,
                              draw: @escaping (GraphicsContext, CGSize) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(color)
            Canvas { context, size in draw(context, size) }
                .frame(height: 90)
                .background(Color.black.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func viewport(size: CGSize) -> LaneViewport {
        // Static full-phrase window [0, duration] mapped left→right.
        LaneViewport(size: size, now: 0, axis: .horizontal,
                     actionLineFraction: 0, secondsAhead: sampleDuration)
    }

    // MARK: - Hand-authored sample (DEBUG only; not derived, not production)

    /// Same phrase, expressed for the speed-bucket renderer: a short FAST flick, a long FAST push,
    /// a medium reversal. With speed driving amplitude, the short flick still reaches the rail.
    private var speedBucketPath: MotionPath {
        let strokes = [
            LaneStroke(startTime: 0.2, endTime: 0.5, direction: .forward,
                       speed: .fast, faderState: .open, isGhost: false),   // short but FAST → rails
            LaneStroke(startTime: 1.0, endTime: 1.6, direction: .forward,
                       speed: .fast, faderState: .open, isGhost: false),
            LaneStroke(startTime: 2.2, endTime: 2.8, direction: .backward,
                       speed: .medium, faderState: .open, isGhost: false),
        ]
        let content = LaneContent(strokes: strokes, segments: [], beatsPerMinute: nil,
                                  duration: sampleDuration, loops: false)
        return ScratchStrokeGeometry.motionPath(for: content)
    }

    /// The SAME phrase, expressed as travel: the first stroke travels little (0.2), the second is
    /// full (1.0 at scale 1.0), the reversal is medium (0.5). Excursion follows travel, not speed.
    private var travelPath: MotionPath {
        let preview = ScratchNotationLanePreviewModel(strokes: [
            .init(direction: .forward, startTime: 0.2, endTime: 0.5, travelPercent: 0.2, audibleState: .audible),
            .init(direction: .forward, startTime: 1.0, endTime: 1.6, travelPercent: 1.0, audibleState: .audible),
            .init(direction: .reverse, startTime: 2.2, endTime: 2.8, travelPercent: 0.5, audibleState: .cut),
        ], warnings: [])
        let model = ScratchNotationLaneDisplayAdapter.displayModel(
            from: preview, fullScaleTravelPercent: fullScaleTravelPercent)
        return ScratchNotationTravelMotionPath.motionPath(for: model, duration: sampleDuration)
    }
}

#Preview("Travel lane A/B") {
    TravelLaneDebugView()
}
#endif
