import CoreGraphics
import Foundation

// Pure geometry layer for the live practice-notation viewport (stabilization
// slice). Given the current playback time it picks the active phrase, frames
// a readable time window around it, and maps the playhead and strokes into
// view points. It holds no SwiftUI, scroll, or layout state: every output is
// a deterministic function of (currentTime, visibleWidth), so playback time
// stays the single source of truth and the viewport cannot fight it.
//
// Scope: phrases are derived at runtime from stroke timings. This reads and
// modifies no notation JSON/schema, and touches no capture, export, audio, or
// ML code.

// MARK: - Input

/// One stroke reduced to its time span. Decouples the viewport geometry from
/// `ScratchNotation` so this file stays pure and trivially unit-testable.
struct StrokeSpan: Equatable {
    let startTime: TimeInterval
    let endTime: TimeInterval
}

// MARK: - Derived phrase

/// A contiguous run of strokes with no long silent gap between them — the
/// unit the viewport frames. A routine is several of these separated by
/// multi-second rests; phrases are derived, never read from the JSON.
struct NotationPhrase: Equatable {
    /// Position of this phrase in the derived list (0-based).
    let index: Int
    /// Start of the phrase's first stroke, in notation seconds.
    let startTime: TimeInterval
    /// End of the phrase's last stroke, in notation seconds.
    let endTime: TimeInterval
    /// Indices into the model's stroke array that belong to this phrase.
    let strokeIndices: Range<Int>

    var duration: TimeInterval { max(0, endTime - startTime) }
}

// MARK: - Output

/// A stroke positioned in view points within the current viewport.
struct PlacedStroke: Equatable {
    /// Index into the model's stroke array.
    let strokeIndex: Int
    let startX: CGFloat
    let endX: CGFloat
}

/// The fully resolved viewport for one instant of playback time. Every field
/// is a pure function of `(currentTime, visibleWidth)` — there is no scroll
/// or layout state, so nothing here can feed back into playback timing.
struct PhraseViewport: Equatable {
    /// Index of the framed phrase in `NotationViewportModel.phrases`.
    let activePhraseIndex: Int
    /// Padded notation-time window the viewport frames.
    let visibleTimeRange: ClosedRange<TimeInterval>
    /// Scale mapping notation seconds onto view points.
    let pointsPerSecond: CGFloat
    /// Playhead position in view points, always within `0...visibleWidth`.
    let playheadX: CGFloat
    /// `currentTime` clamped into the active phrase. Fed to the chart so the
    /// playhead parks on the last stroke during a rest instead of drifting
    /// off into empty padding.
    let clampedPlayheadTime: TimeInterval
    /// Strokes intersecting `visibleTimeRange`, positioned in view points.
    let visibleStrokes: [PlacedStroke]
}

// MARK: - Model

/// Derives the phrase list once, then resolves a `PhraseViewport` per frame.
struct NotationViewportModel {

    /// Tuning for phrase detection and window padding.
    struct Config: Equatable {
        /// A silent gap longer than this (seconds) splits one phrase from the
        /// next — set well above within-phrase gaps and below the routine's
        /// multi-second rests.
        var maxPhraseGap: TimeInterval = 2.0
        /// Lead-in shown before the phrase's first stroke.
        var preRoll: TimeInterval = 0.6
        /// Tail shown after the phrase's last stroke.
        var postRoll: TimeInterval = 0.6
        /// Floor on the visible window so a very short phrase is not magnified
        /// to an unreadable scale.
        var minimumVisibleDuration: TimeInterval = 2.5
    }

    /// Phrases derived from the strokes, in playback order.
    let phrases: [NotationPhrase]

    private let strokes: [StrokeSpan]
    private let config: Config

    /// Floor for the visible window, guarding the only division
    /// (`visibleWidth / windowDuration`) against a zero-length window.
    private static let minWindowDuration: TimeInterval = 0.0001

    init(strokes: [StrokeSpan], config: Config = Config()) {
        self.strokes = strokes
        self.config = config
        self.phrases = NotationViewportModel.derivePhrases(
            from: strokes, maxGap: config.maxPhraseGap)
    }

    /// Groups ordered strokes into phrases. Strokes are assumed sorted by
    /// `startTime` (true for the bundled notation and for detected previews,
    /// which sort their events); taking `max` on the running end keeps the
    /// result correct even if a stroke is briefly contained in the previous.
    static func derivePhrases(from strokes: [StrokeSpan],
                              maxGap: TimeInterval) -> [NotationPhrase] {
        guard let first = strokes.first else { return [] }

        var phrases: [NotationPhrase] = []
        var runStartIndex = 0
        var runStart = first.startTime
        var runEnd = first.endTime

        func closeRun(endingBefore index: Int) {
            phrases.append(NotationPhrase(
                index: phrases.count,
                startTime: runStart,
                endTime: runEnd,
                strokeIndices: runStartIndex..<index))
        }

        for i in 1..<strokes.count {
            let stroke = strokes[i]
            // A gap wider than maxGap between the running phrase end and the
            // next stroke's start closes the phrase and opens a new one.
            if stroke.startTime - runEnd > maxGap {
                closeRun(endingBefore: i)
                runStartIndex = i
                runStart = stroke.startTime
                runEnd = stroke.endTime
            } else {
                runEnd = max(runEnd, stroke.endTime)
            }
        }
        closeRun(endingBefore: strokes.count)
        return phrases
    }

    /// Resolves the viewport for `currentTime` (looped notation seconds) at a
    /// viewport `visibleWidth` (view points).
    func resolve(currentTime: TimeInterval, visibleWidth: CGFloat) -> PhraseViewport {
        let width = max(visibleWidth, 0)
        let minSpan = max(config.minimumVisibleDuration,
                          NotationViewportModel.minWindowDuration)

        // Degenerate notation: no strokes. One empty window, playhead parked.
        guard !phrases.isEmpty else {
            return PhraseViewport(
                activePhraseIndex: 0,
                visibleTimeRange: 0...minSpan,
                pointsPerSecond: width / CGFloat(minSpan),
                playheadX: 0,
                clampedPlayheadTime: 0,
                visibleStrokes: [])
        }

        // Phrase selection — a pure step function of currentTime: the last
        // phrase whose start has been reached. Inside a silent gap that is the
        // just-finished phrase, so the viewport holds it until the next phrase
        // begins. Being stateless it cannot oscillate, so no hysteresis state
        // is needed; the selection changes only when currentTime crosses a
        // phrase start.
        var activeIndex = 0
        for phrase in phrases where phrase.startTime <= currentTime {
            activeIndex = phrase.index
        }
        let phrase = phrases[activeIndex]

        // Visible window: the phrase plus small padding, never starting before
        // t = 0 and never narrower than minSpan.
        let lower = max(0, phrase.startTime - config.preRoll)
        var upper = max(phrase.endTime + config.postRoll, lower)
        if upper - lower < minSpan {
            upper = lower + minSpan
        }
        let span = upper - lower                       // ≥ minSpan > 0
        let pps = width / CGFloat(span)

        // Playhead: currentTime clamped into the phrase (so it parks on the
        // last stroke during a rest rather than sliding into empty padding),
        // mapped to points, then clamped to 0...width as a final safety net.
        let clampedTime = min(max(currentTime, phrase.startTime), phrase.endTime)
        let playheadX = min(max(CGFloat(clampedTime - lower) * pps, 0), width)

        // Strokes intersecting the visible window, positioned in view points.
        let placed: [PlacedStroke] = strokes.enumerated().compactMap { index, stroke in
            guard stroke.endTime > lower, stroke.startTime < upper else { return nil }
            return PlacedStroke(
                strokeIndex: index,
                startX: CGFloat(stroke.startTime - lower) * pps,
                endX: CGFloat(stroke.endTime - lower) * pps)
        }

        return PhraseViewport(
            activePhraseIndex: activeIndex,
            visibleTimeRange: lower...upper,
            pointsPerSecond: pps,
            playheadX: playheadX,
            clampedPlayheadTime: clampedTime,
            visibleStrokes: placed)
    }
}
