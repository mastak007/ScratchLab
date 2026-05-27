import SwiftUI

// MARK: - StudioReplayScrubber

/// Phase D-A1 — minimal scrub primitive for the Studio tab.
///
/// Drives a `currentTime` over an arbitrary content range and supports
/// looping a sub-span at one of the four `ReplayPlaybackRate` settings.
/// **Audio rate stays 1.0×** at every setting — this view is a visual
/// inspection tool and never time-stretches audio.
///
/// The scrubber owns only its own scrub state. It does not render the
/// notation lane itself; downstream slices wire the timestamp into the
/// existing `NotationReplayDriver` projection so the lane re-uses the
/// same renderer the DEBUG host already proves works. macOS-only at
/// the host level — `FeatureFlags.studioScrubEnabled` gates the
/// callsite, and the parent `StudioSessionHostView` is itself behind
/// `STUDIO_MODE`.
///
/// Reduce-motion: when reduce-motion is on, auto-playback is
/// suppressed so the lane stays static; the user can still scrub
/// manually via the slider.
struct StudioReplayScrubber: View {

    let contentStart: TimeInterval
    let contentEnd: TimeInterval

    @State private var currentTime: TimeInterval
    @State private var loopRange: ReplayLoopRange
    @State private var rate: ReplayPlaybackRate = .normal
    @State private var isPlaying: Bool = false
    @State private var lastTick: Date?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let tickInterval: TimeInterval = 1.0 / 60.0

    init(contentStart: TimeInterval, contentEnd: TimeInterval) {
        let safeStart = contentStart.isFinite ? contentStart : 0
        let safeEnd = contentEnd.isFinite && contentEnd > safeStart
            ? contentEnd
            : safeStart + 1
        self.contentStart = safeStart
        self.contentEnd = safeEnd
        _currentTime = State(initialValue: safeStart)
        _loopRange = State(initialValue: ReplayLoopRange(
            startTime: safeStart,
            endTime: safeEnd
        ) ?? ReplayLoopRange(startTime: 0, endTime: 1)!)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            slider
            controls
            if reduceMotion {
                reducedMotionNotice
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .background(autoAdvance)
    }

    // MARK: Subviews

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Scrubber")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Spacer()
            Text(String(format: "%.2fs / %.2fs", currentTime, contentEnd))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var slider: some View {
        Slider(value: $currentTime, in: contentStart...contentEnd, step: 0.01)
            .onChange(of: currentTime) { _, newValue in
                // Manual scrub overrides the loop range; clamp into it
                // so the next auto-advance picks up cleanly.
                if newValue > loopRange.endTime || newValue < loopRange.startTime {
                    currentTime = loopRange.clamp(newValue)
                }
            }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button(action: togglePlay) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .disabled(reduceMotion)
            .help(reduceMotion ? "Auto-playback is suppressed when Reduce Motion is on." : "")

            Picker("Rate", selection: $rate) {
                ForEach(ReplayPlaybackRate.allCases, id: \.self) { value in
                    Text(value.label).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            Spacer()
        }
    }

    private var reducedMotionNotice: some View {
        Text("Auto-playback paused for Reduce Motion. Drag the slider to scrub.")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// `TimelineView` ticker used purely to advance `currentTime` while
    /// playing. Rendered behind the rest of the view so the visible
    /// controls drive the layout. Reduce-motion gates the auto-advance
    /// path entirely.
    @ViewBuilder
    private var autoAdvance: some View {
        if isPlaying, !reduceMotion {
            TimelineView(.periodic(from: .now, by: Self.tickInterval)) { timeline in
                Color.clear
                    .onChange(of: timeline.date) { _, newDate in
                        advance(to: newDate)
                    }
            }
        }
    }

    // MARK: Behaviour

    private func togglePlay() {
        isPlaying.toggle()
        lastTick = isPlaying ? Date() : nil
    }

    private func advance(to date: Date) {
        guard let previous = lastTick else {
            lastTick = date
            return
        }
        let wall = date.timeIntervalSince(previous)
        guard wall > 0, wall.isFinite else { return }
        lastTick = date
        let delta = wall * rate.rawValue
        currentTime = loopRange.advance(from: currentTime, by: delta)
    }
}
