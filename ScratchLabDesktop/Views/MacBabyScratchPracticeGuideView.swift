import SwiftUI

// MARK: - MacBabyScratchPracticeGuideView

/// Compact "Baby Scratch guide" card embedded in the macOS Practice
/// surface. Renders the bundled Baby Scratch notation in
/// `ScratchNotationCanvasView` and ticks the visible playhead in
/// lockstep with `BabyScratchDemoPlaybackCoordinator.currentAudioTime`
/// so the coach/demo audio actually has a visible reference partner.
///
/// **Why this view exists:** macOS Practice previously surfaced the
/// coach demo audio (Replay button) but no visible notation/motion
/// guidance — pressing Replay only highlighted the camera/calibration
/// overlay. This card pairs the audio with the same notation canvas
/// the existing Notation Lab uses, scoped to a quiet practice-side
/// card so it reads as guidance rather than as a developer diagnostic.
///
/// **Reuses** (does not invent):
/// - `ScratchNotation.loadBabyScratchFromBundle()` for the strokes.
/// - `BabyScratchDemoPlaybackCoordinator.notationCanvasLoopTime(
///    for:cycleDuration:)` to tile the single-phrase notation across
///    every Baby Scratch repetition in the demo audio.
/// - `ScratchNotationCanvasView` for the actual rendering.
///
/// **macOS-only** by file placement. iOS Practice is unchanged.
struct MacBabyScratchPracticeGuideView: View {

    @ObservedObject var demo: BabyScratchDemoPlaybackCoordinator

    private static let tickInterval: TimeInterval = 1.0 / 30.0
    private static let laneHeight: CGFloat = 156

    private let notation: ScratchNotation? = ScratchNotation.loadBabyScratchFromBundle()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            canvasCard
            captionLine
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Subviews

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(CoachCopy.PracticeGuide.babyScratchTitle)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
            Text(CoachCopy.PracticeGuide.babyScratchSubtitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    private var canvasCard: some View {
        TimelineView(.periodic(from: .now, by: Self.tickInterval)) { _ in
            ScratchNotationCanvasView(
                notation: notation,
                playbackTime: playbackTime,
                loopDuration: loopDuration
            )
            .frame(height: Self.laneHeight)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var captionLine: some View {
        Text(
            demo.isPlaying
                ? CoachCopy.PracticeGuide.babyScratchPlayingCaption
                : CoachCopy.PracticeGuide.babyScratchIdleCaption
        )
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.55))
    }

    // MARK: Derived state

    /// Visible loop duration for the canvas — the notation's own
    /// `timelineDuration`. Falls back to a small positive value when
    /// no notation is bundled so the canvas never divides by zero.
    private var loopDuration: TimeInterval {
        max(notation?.timelineDuration ?? 0, 0.0001)
    }

    /// Maps the demo audio's master clock onto the notation canvas's
    /// own phrase loop so the single-phrase notation tiles cleanly
    /// across every Baby Scratch repetition in the bundled audio.
    /// Re-uses the deterministic helper added in the macOS Template
    /// Demo bug fix (commit a4ea922).
    private var playbackTime: TimeInterval {
        BabyScratchDemoPlaybackCoordinator.notationCanvasLoopTime(
            for: demo.currentAudioTime,
            cycleDuration: loopDuration
        )
    }
}
