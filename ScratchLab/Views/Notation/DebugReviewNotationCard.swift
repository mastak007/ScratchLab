#if DEBUG
import SwiftUI

// MARK: - DebugReviewNotationCard

/// A DEBUG-only standalone card that demonstrates the Section 5/7
/// notation pipeline running against a paired *target* + *captured*
/// presentation model — the shape a future Review surface would
/// consume.
///
/// **Purpose:** prove that two `NotationPresentationModel`s sharing
/// one `NotationReplayState`, `TimingGrid`, and
/// `NotationViewportWindowRule` can be projected by the pure
/// `NotationReplayDriver` and rendered side-by-side through the
/// existing `NotationLaneGeometryView`. The card is the smallest
/// "looks like a Review preview" surface that we can stand up
/// without touching `MacAnalyzerView`, `ReviewOverlayLaneView`,
/// `NotationVisualizerView`, or any production Review behaviour.
///
/// **No production impact:** the entire file is gated behind
/// `#if DEBUG` and the card is not wired into any production
/// navigation entry point. A future slice that decides to expose
/// it can do so behind the same gate.
///
/// **What the card does (and only this):**
///
/// - Owns a `frameIndex` step state driven by a `Stepper`.
/// - Projects two synthetic in-memory presentation models against a
///   single shared replay state via `NotationReplayDriver.project(...)`.
/// - Renders the two projections through stacked
///   `NotationLaneGeometryView` instances.
///
/// **What the card does not do:** no clock, no timer, no
/// AVFoundation, no Combine, no AVAudioPlayer, no animation
/// `TimelineView`, no scoring, no ML, no export, no schema bump,
/// no production Review wiring.
struct DebugReviewNotationCard: View {

    @State private var frameIndex: Int = 0

    private static let laneWidth: Double = 400
    private static let laneHeight: Double = 80

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Debug Review Notation Card")
                .font(.headline)
                .foregroundStyle(.white)

            stepperRow

            laneSection(
                title: "Target (synthetic)",
                presentation: Self.targetPresentation
            )

            laneSection(
                title: "Captured (synthetic)",
                presentation: Self.capturedPresentation
            )
        }
        .padding(12)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Subviews

    private var stepperRow: some View {
        let lastIndex = max(0, Self.replayState.frames.count - 1)
        let safeIndex = min(max(frameIndex, 0), lastIndex)
        let frameTime = Self.replayState.frames[safeIndex].time
        return HStack {
            Stepper(
                "Frame \(safeIndex) / \(lastIndex)",
                value: $frameIndex,
                in: 0...lastIndex
            )
            .foregroundStyle(.white)
            Spacer()
            Text(String(format: "t = %.2fs", frameTime))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.white)
        }
    }

    @ViewBuilder
    private func laneSection(
        title: String,
        presentation: NotationPresentationModel
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
            laneView(for: presentation)
                .frame(height: Self.laneHeight)
        }
    }

    private func laneView(
        for presentation: NotationPresentationModel
    ) -> some View {
        let projection = project(presentation: presentation)
        return NotationLaneGeometryView(
            geometry: projection?.laneGeometry
                ?? NotationLaneGeometryModel(strokes: []),
            gridlines: projection?.gridlineGeometry
                ?? NotationGridlineGeometryModel(gridlines: []),
            playhead: projection?.playhead
        )
    }

    // MARK: Projection

    private func project(
        presentation: NotationPresentationModel
    ) -> NotationReplayProjection? {
        let lastIndex = max(0, Self.replayState.frames.count - 1)
        let safeIndex = min(max(frameIndex, 0), lastIndex)
        guard !Self.replayState.frames.isEmpty else { return nil }
        let frame = Self.replayState.frames[safeIndex]
        return NotationReplayDriver.project(
            frame: frame,
            state: Self.replayState,
            presentationModel: presentation,
            timingGrid: Self.replayGrid,
            viewportRule: Self.replayRule,
            width: Self.laneWidth,
            height: Self.laneHeight
        )
    }

    // MARK: Synthetic data
    //
    // Internal (not private) so the DEBUG-only test target can verify
    // determinism, frame coverage, and presentation-model shape.
    // Nothing outside the card depends on these.

    /// A clean reference pattern: eight strokes on the half-beat over
    /// four bars at 120 BPM. Half-bar / one-bar resolution is enough
    /// to make the grid visible without crowding the lane.
    static let targetPresentation: NotationPresentationModel = {
        var strokes: [NotationPresentationStroke] = []
        strokes.reserveCapacity(8)
        for i in 0..<8 {
            let start = 0.25 + Double(i) * 0.5
            strokes.append(NotationPresentationStroke(
                primitiveIndex: i,
                startTime: start,
                endTime: start + 0.20,
                startPosition: nil,
                endPosition: nil,
                family: .baby,
                coachingKinds: []
            ))
        }
        return NotationPresentationModel(strokes: strokes)
    }()

    /// The same eight strokes with a small, deterministic timing
    /// drift — alternating early/late by ~50ms — so the visual diff
    /// between the two lanes is obvious without using any
    /// classifier-derived data.
    static let capturedPresentation: NotationPresentationModel = {
        var strokes: [NotationPresentationStroke] = []
        strokes.reserveCapacity(8)
        for i in 0..<8 {
            let nominal = 0.25 + Double(i) * 0.5
            let drift = (i % 2 == 0) ? 0.05 : -0.03
            let start = nominal + drift
            strokes.append(NotationPresentationStroke(
                primitiveIndex: i,
                startTime: start,
                endTime: start + 0.20,
                startPosition: nil,
                endPosition: nil,
                family: .baby,
                coachingKinds: i == 5 ? [.lateReversal] : []
            ))
        }
        return NotationPresentationModel(strokes: strokes)
    }()

    /// 120 BPM, 4/4, sixteenth-note subdivisions, origin at 0.
    /// Force-unwrap is safe — all inputs are constant and valid.
    static let replayGrid: TimingGrid = {
        TimingGrid(
            beatsPerMinute: 120,
            beatsPerBar: 4,
            subdivisionsPerBeat: 4,
            origin: 0
        )!
    }()

    /// 4-second viewport with 1-second of pre-roll behind the
    /// playhead — same rule the Section 7 host uses, so visual
    /// behaviour is comparable between the two DEBUG surfaces.
    static let replayRule: NotationViewportWindowRule = {
        NotationViewportWindowRule(duration: 4, leadIn: 1)!
    }()

    /// 33 frames at 0.25 s steps covering [0, 8] inside an 8 s take
    /// (four bars at 120 BPM). Strictly ascending — satisfies the
    /// state's `frames` invariant trivially.
    static let replayState: NotationReplayState = {
        var frames: [NotationReplayFrame] = []
        frames.reserveCapacity(33)
        for i in 0..<33 {
            let time = Double(i) * 0.25
            frames.append(NotationReplayFrame(index: i, time: time)!)
        }
        return NotationReplayState(
            contentStart: 0,
            contentEnd: 8,
            frames: frames
        )!
    }()
}

#endif
