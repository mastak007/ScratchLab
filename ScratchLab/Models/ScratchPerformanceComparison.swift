// ScratchPerformanceComparison — normalizes captured performance evidence into the
// canonical musical coordinate system (beats) and produces deterministic
// target-vs-performed comparison primitives.
//
// Layering rules, mirroring the canonical-model boundary in CaptureCore:
// - The canonical target side stays `ScratchNotation.BeatPattern` — nothing here
//   adds capture-side fields (confidence, provenance, source) to canonical types.
// - The performed side is a separate, capture-flavoured representation in beats.
//   Confidence/provenance live here, on performed types only.
// - No matching window or threshold is invented as a technique-specific constant:
//   every window/threshold is a required caller-supplied parameter, following the
//   `ScratchAnalysisNotationComparison.compare(..., timingToleranceSeconds:)`
//   convention.
// - Pure value transformation, deterministic, Foundation-only. No SwiftUI, no
//   rendering, no clock reads, no I/O, no UI strings. Scoring exposes
//   inspectable sub-scores only — fundamentally different errors (timing vs
//   direction vs completeness vs fader) are never hidden inside one opaque
//   number; `overall` is a documented mean of the named sub-scores.

import Foundation

// MARK: - Beat clock

/// Maps take-relative capture time (seconds) onto the session beat grid.
///
/// `beatZeroTime` is the take-relative time at which beat 0 falls. For
/// click-track captures both `ClickTrackEngine` and `ScratchLabBeatEngine`
/// schedule `clickStartHostTime == recordingStartHostTime`, so beat 0 of the
/// click (including any count-in beats the caller wants to skip) is at
/// take-relative 0; callers that treat "beat 0" as the first post-count-in
/// beat pass `beatZeroTime = countInBeats * 60 / bpm`. This type takes the
/// anchor as data and never guesses it.
struct PerformanceBeatClock: Equatable, Sendable {
    let bpm: Double
    /// Take-relative seconds at which beat 0 falls. May be negative when the
    /// beat grid started before the take window.
    let beatZeroTime: TimeInterval

    /// `nil` when `bpm` is unusable or the anchor is non-finite — a clock is
    /// never constructed in a state that could emit non-finite beats.
    init?(bpm: Double, beatZeroTime: TimeInterval) {
        guard bpm.isFinite, bpm > 0, beatZeroTime.isFinite else { return nil }
        self.bpm = bpm
        self.beatZeroTime = beatZeroTime
    }

    func beats(fromSeconds seconds: TimeInterval) -> Double {
        (seconds - beatZeroTime) * bpm / 60.0
    }

    func seconds(fromBeats beats: Double) -> TimeInterval {
        beatZeroTime + beats * 60.0 / bpm
    }

    /// Span conversion for offsets/durations (no anchor involved).
    func milliseconds(fromBeats beats: Double) -> Double {
        beats * 60_000.0 / bpm
    }
}

// MARK: - Normalized performed model

/// A captured performance normalized into beat coordinates.
///
/// This is evidence, not authorship: strokes/edges keep capture provenance and
/// confidence, may be sparse or noisy, and carry no target semantics (no
/// speed classification, no per-stroke fader snapshot, no pattern identity).
struct PerformedScratchTimeline: Equatable, Sendable {

    struct Stroke: Equatable, Sendable {
        let startBeat: Double
        let endBeat: Double
        /// Preserved capture direction; `nil` when the capture pipeline could
        /// not determine one. Alignment never guesses a direction for `nil`.
        let direction: ScratchNotationDirection?
        let confidence: Double
        let source: String
    }

    /// A performed fader-state edge: "at `beat`, the fader became `state`."
    struct FaderEdge: Equatable, Sendable {
        let beat: Double
        let state: ScratchNotationFaderState
        let source: String
    }

    /// Sorted by `startBeat` (ties by `endBeat`, then original capture order).
    let strokes: [Stroke]
    /// Sorted by `beat`, strictly alternating states (edges only exist where
    /// the thresholded fader state actually changed).
    let faderEdges: [FaderEdge]
    /// True when the take carried any crossfader capture evidence at all —
    /// distinguishes "fader never captured" from "fader captured but never
    /// crossed a threshold". Alignment reports the two differently.
    let hasFaderCapture: Bool
}

/// Schmitt-trigger thresholds for deriving open/closed edges from the raw
/// crossfader value stream. No repository-established open/closed cut point
/// exists, so both thresholds are required caller configuration.
struct PerformedFaderEdgeThresholds: Equatable, Sendable {
    /// Normalized value at or above which the fader counts as open.
    let openAtOrAbove: Double
    /// Normalized value at or below which the fader counts as closed.
    let closedAtOrBelow: Double

    /// `nil` unless `0 <= closedAtOrBelow <= openAtOrAbove <= 1` — the
    /// hysteresis band must be well-formed or edges would oscillate.
    init?(openAtOrAbove: Double, closedAtOrBelow: Double) {
        guard openAtOrAbove.isFinite, closedAtOrBelow.isFinite,
              closedAtOrBelow >= 0, openAtOrAbove <= 1,
              closedAtOrBelow <= openAtOrAbove else { return nil }
        self.openAtOrAbove = openAtOrAbove
        self.closedAtOrBelow = closedAtOrBelow
    }
}

enum PerformedScratchTimelineAdapter {

    /// Movement-event kinds that represent an actual stroke. `hold` and
    /// `releaseNormalPlayback` are platter states, not strokes — including
    /// them would fabricate "extra stroke" verdicts out of stillness.
    static func isStrokeKind(_ kind: ScratchMovementKind) -> Bool {
        switch kind {
        case .fastPush, .normalPush, .slowDrag, .fastPull, .normalPull, .slowPullDrag:
            return true
        case .hold, .releaseNormalPlayback:
            return false
        }
    }

    /// Normalizes captured evidence into beat coordinates.
    ///
    /// Deterministic under re-ordering: events are sorted by capture time
    /// (movement: startTime, then endTime; MIDI: takeRelativeTime, then
    /// timestamp — the `deriveDetectedNotationFaderEvents` convention) before
    /// any state is accumulated, so a shuffled input produces the identical
    /// timeline. Zero/negative-duration movement events are dropped, matching
    /// `ScratchNotation.detectedPreview`.
    static func makeTimeline(
        movementEvents: [CaptureCore.DetectedNotationRecordMovementEvent],
        mixerMidiEvents: [CaptureCore.RawMixerMIDIEvent],
        clock: PerformanceBeatClock,
        faderThresholds: PerformedFaderEdgeThresholds
    ) -> PerformedScratchTimeline {
        let sortedMovements = movementEvents.enumerated().sorted { lhs, rhs in
            if lhs.element.startTime != rhs.element.startTime {
                return lhs.element.startTime < rhs.element.startTime
            }
            if lhs.element.endTime != rhs.element.endTime {
                return lhs.element.endTime < rhs.element.endTime
            }
            return lhs.offset < rhs.offset
        }

        let strokes: [PerformedScratchTimeline.Stroke] = sortedMovements.compactMap { _, event in
            guard event.endTime > event.startTime else { return nil }
            guard isStrokeKind(event.movementKind) else { return nil }
            let direction: ScratchNotationDirection?
            switch event.direction {
            case "forward": direction = .forward
            case "backward": direction = .backward
            default: direction = nil
            }
            return PerformedScratchTimeline.Stroke(
                startBeat: clock.beats(fromSeconds: event.startTime),
                endBeat: clock.beats(fromSeconds: event.endTime),
                direction: direction,
                confidence: event.confidence,
                source: event.source
            )
        }

        let crossfaderSamples = mixerMidiEvents
            .filter { $0.mappedControl == "crossfader" }
            .sorted { lhs, rhs in
                if lhs.takeRelativeTime == rhs.takeRelativeTime {
                    return lhs.timestamp < rhs.timestamp
                }
                return lhs.takeRelativeTime < rhs.takeRelativeTime
            }

        var faderEdges: [PerformedScratchTimeline.FaderEdge] = []
        var currentState: ScratchNotationFaderState?
        for sample in crossfaderSamples {
            let sampleState: ScratchNotationFaderState?
            if sample.normalizedValue >= faderThresholds.openAtOrAbove {
                sampleState = .open
            } else if sample.normalizedValue <= faderThresholds.closedAtOrBelow {
                sampleState = .closed
            } else {
                sampleState = nil // inside the hysteresis band — hold state
            }
            guard let sampleState else { continue }
            if currentState == nil {
                // First determinate sample establishes the initial state; an
                // edge is a *change*, so none is emitted here.
                currentState = sampleState
                continue
            }
            if sampleState != currentState {
                currentState = sampleState
                faderEdges.append(
                    PerformedScratchTimeline.FaderEdge(
                        beat: clock.beats(fromSeconds: sample.takeRelativeTime),
                        state: sampleState,
                        source: "midi"
                    )
                )
            }
        }

        return PerformedScratchTimeline(
            strokes: strokes,
            faderEdges: faderEdges,
            hasFaderCapture: !crossfaderSamples.isEmpty
        )
    }
}

// MARK: - Target phrase

/// The target side of a comparison: a canonical `BeatPattern` tiled across
/// one or more contiguous cycles. This is comparison *input preparation*, not
/// new authorship — every beat position is derived from the pattern itself.
struct TargetScratchPhrase: Equatable, Sendable {
    let strokes: [ScratchNotation.BeatPattern.BeatStroke]
    let faderEdges: [ScratchNotation.BeatPattern.BeatFaderEvent]
    /// True when the source pattern authored a canonical fader edge channel.
    /// When false, `faderEdges` is empty AND the absence means "no canonical
    /// fader description exists" — per the `BeatPattern.faderEvents` authority
    /// rule it must never be read as implicitly open or closed.
    let hasCanonicalFaderChannel: Bool

    /// Tiles `pattern` across `cycles` contiguous repetitions.
    ///
    /// `nil` when the pattern fails its own validation, has no strokes, has a
    /// non-positive duration, or `cycles < 1`. When tiling fader edges, a
    /// repeat whose first edge restates the running state at the cycle
    /// boundary is dropped so the edge stream keeps alternating.
    static func phrase(repeating pattern: ScratchNotation.BeatPattern,
                       cycles: Int) -> TargetScratchPhrase? {
        guard cycles >= 1,
              pattern.validationIssues().isEmpty,
              !pattern.strokes.isEmpty else { return nil }
        let cycleBeats = pattern.durationBeats
        guard cycleBeats > 0 else { return nil }

        var strokes: [ScratchNotation.BeatPattern.BeatStroke] = []
        var faderEdges: [ScratchNotation.BeatPattern.BeatFaderEvent] = []
        for cycle in 0..<cycles {
            let offset = Double(cycle) * cycleBeats
            for stroke in pattern.strokes {
                strokes.append(.init(startBeat: stroke.startBeat + offset,
                                     endBeat: stroke.endBeat + offset,
                                     direction: stroke.direction,
                                     speedClassification: stroke.speedClassification,
                                     faderState: stroke.faderState))
            }
            for event in pattern.faderEvents {
                let edge = ScratchNotation.BeatPattern.BeatFaderEvent(
                    beat: event.beat + offset,
                    state: event.state
                )
                if let last = faderEdges.last, last.state == edge.state {
                    continue
                }
                faderEdges.append(edge)
            }
        }
        return TargetScratchPhrase(strokes: strokes,
                                   faderEdges: faderEdges,
                                   hasCanonicalFaderChannel: !pattern.faderEvents.isEmpty)
    }
}

// MARK: - Matching windows

/// Caller-supplied matching windows and correctness tolerances, in beats.
///
/// Beats (not seconds) so the same configuration is BPM-independent. No
/// defaults: the repository has no established beat-domain matching constants,
/// so every value is explicit at the call site (the
/// `timingToleranceSeconds`-parameter convention). The only established
/// timing-verdict convention today is UI-side and in milliseconds
/// (`NotationFeedbackState.earlyOffsetThresholdMs` / `lateOffsetThresholdMs`);
/// callers wanting that behaviour convert via
/// `PerformanceBeatClock.milliseconds(fromBeats:)`.
struct ScratchComparisonWindows: Equatable, Sendable {
    /// Max |performed start − target start| for a stroke to be a match
    /// candidate. Should be under half the smallest target inter-stroke gap
    /// or a performed stroke can be claimed by the wrong neighbour.
    let strokeMatchWindowBeats: Double
    /// Matched strokes within ± this offset are `.correct`; outside it they
    /// are `.early`/`.late`. Must not exceed `strokeMatchWindowBeats`.
    let strokeCorrectToleranceBeats: Double
    /// Max |performed beat − target beat| for a same-state fader edge match.
    let faderMatchWindowBeats: Double
    /// Matched fader edges within ± this offset are `.correct`.
    let faderCorrectToleranceBeats: Double

    init?(strokeMatchWindowBeats: Double,
          strokeCorrectToleranceBeats: Double,
          faderMatchWindowBeats: Double,
          faderCorrectToleranceBeats: Double) {
        let values = [strokeMatchWindowBeats, strokeCorrectToleranceBeats,
                      faderMatchWindowBeats, faderCorrectToleranceBeats]
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }),
              strokeCorrectToleranceBeats <= strokeMatchWindowBeats,
              faderCorrectToleranceBeats <= faderMatchWindowBeats else { return nil }
        self.strokeMatchWindowBeats = strokeMatchWindowBeats
        self.strokeCorrectToleranceBeats = strokeCorrectToleranceBeats
        self.faderMatchWindowBeats = faderMatchWindowBeats
        self.faderCorrectToleranceBeats = faderCorrectToleranceBeats
    }
}

// MARK: - Comparison result model

/// Timing verdict for a matched pair. Signed offsets stay on the pair — this
/// enum is the coarse classification only.
enum StrokeTimingVerdict: Equatable, Sendable {
    case correct
    case early
    case late
}

struct MatchedStrokeComparison: Equatable, Sendable {
    let targetIndex: Int
    let performedIndex: Int
    /// performed start − target start; negative = early.
    let offsetBeats: Double
    /// The same offset projected at the comparison tempo.
    let offsetMilliseconds: Double
    let timing: StrokeTimingVerdict
    /// `nil` when the performed stroke carried no determinate direction —
    /// direction is then unassessed, never assumed correct or wrong.
    let directionCorrect: Bool?
}

struct MatchedFaderEdgeComparison: Equatable, Sendable {
    let targetIndex: Int
    let performedIndex: Int
    /// performed beat − target beat; negative = early.
    let offsetBeats: Double
    let offsetMilliseconds: Double
    let timing: StrokeTimingVerdict
}

/// Fader comparison honours the canonical authority rule: an unauthored
/// target fader channel is *not comparable*, never a stream of implicit
/// opens — and an uncaptured performed fader is reported as absent evidence,
/// not as a wall of missing edges.
enum FaderChannelComparison: Equatable, Sendable {
    /// Target pattern authored no canonical fader edges.
    case noCanonicalFaderChannel
    /// Target has a canonical fader channel but the take carried no
    /// crossfader capture evidence.
    case noPerformedFaderCapture
    case compared(matched: [MatchedFaderEdgeComparison],
                  missingTargetIndices: [Int],
                  extraPerformedIndices: [Int])
}

/// Renderer-independent comparison primitives for one target phrase vs one
/// performed take. Deliberately not collapsed into a score; carries no UI
/// strings. Consumed later by UI/coaching layers.
struct ScratchPerformanceComparisonResult: Equatable, Sendable {
    let matchedStrokes: [MatchedStrokeComparison]
    /// Target strokes with no performed match inside the window.
    let missingTargetStrokeIndices: [Int]
    /// Performed strokes claimed by no target stroke.
    let extraPerformedStrokeIndices: [Int]
    let faderChannel: FaderChannelComparison
    /// Tempo the millisecond projections were computed at.
    let bpm: Double
}

// MARK: - Alignment

enum ScratchPerformanceAlignment {

    /// Deterministic one-to-one greedy matching, in target order.
    ///
    /// For each target stroke (ascending index) the nearest unmatched
    /// performed stroke within `strokeMatchWindowBeats` of its start beat is
    /// claimed; equal distances break toward the earlier performed index.
    /// Unclaimed target strokes are missing; unclaimed performed strokes are
    /// extra. Fader edges match the same way but only against edges of the
    /// same state — an open edge never matches a close edge.
    ///
    /// `nil` when `bpm` is unusable (windows are validated at construction).
    static func compare(
        target: TargetScratchPhrase,
        performed: PerformedScratchTimeline,
        windows: ScratchComparisonWindows,
        bpm: Double
    ) -> ScratchPerformanceComparisonResult? {
        guard bpm.isFinite, bpm > 0 else { return nil }
        let millisecondsPerBeat = 60_000.0 / bpm

        func timingVerdict(offsetBeats: Double, tolerance: Double) -> StrokeTimingVerdict {
            if abs(offsetBeats) <= tolerance { return .correct }
            return offsetBeats < 0 ? .early : .late
        }

        // Strokes.
        let strokeAssignments = greedyAssignments(
            targetBeats: target.strokes.map(\.startBeat),
            performedBeats: performed.strokes.map(\.startBeat),
            window: windows.strokeMatchWindowBeats
        )
        var matchedStrokes: [MatchedStrokeComparison] = []
        var missingTargetStrokeIndices: [Int] = []
        var claimedPerformed = Set<Int>()
        for (targetIndex, performedIndex) in strokeAssignments.enumerated() {
            guard let performedIndex else {
                missingTargetStrokeIndices.append(targetIndex)
                continue
            }
            claimedPerformed.insert(performedIndex)
            let targetStroke = target.strokes[targetIndex]
            let performedStroke = performed.strokes[performedIndex]
            let offsetBeats = performedStroke.startBeat - targetStroke.startBeat
            matchedStrokes.append(
                MatchedStrokeComparison(
                    targetIndex: targetIndex,
                    performedIndex: performedIndex,
                    offsetBeats: offsetBeats,
                    offsetMilliseconds: offsetBeats * millisecondsPerBeat,
                    timing: timingVerdict(offsetBeats: offsetBeats,
                                          tolerance: windows.strokeCorrectToleranceBeats),
                    directionCorrect: performedStroke.direction.map { $0 == targetStroke.direction }
                )
            )
        }
        let extraPerformedStrokeIndices = performed.strokes.indices
            .filter { !claimedPerformed.contains($0) }

        // Fader channel.
        let faderChannel: FaderChannelComparison
        if !target.hasCanonicalFaderChannel {
            faderChannel = .noCanonicalFaderChannel
        } else if !performed.hasFaderCapture {
            faderChannel = .noPerformedFaderCapture
        } else {
            var matchedEdges: [MatchedFaderEdgeComparison] = []
            var missingEdgeIndices: [Int] = []
            var claimedEdges = Set<Int>()
            for (targetIndex, targetEdge) in target.faderEdges.enumerated() {
                let candidates = performed.faderEdges.indices.filter { index in
                    !claimedEdges.contains(index)
                        && performed.faderEdges[index].state == targetEdge.state
                        && abs(performed.faderEdges[index].beat - targetEdge.beat)
                            <= windows.faderMatchWindowBeats
                }
                guard let chosen = candidates.min(by: { lhs, rhs in
                    let lhsDistance = abs(performed.faderEdges[lhs].beat - targetEdge.beat)
                    let rhsDistance = abs(performed.faderEdges[rhs].beat - targetEdge.beat)
                    if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
                    return lhs < rhs
                }) else {
                    missingEdgeIndices.append(targetIndex)
                    continue
                }
                claimedEdges.insert(chosen)
                let offsetBeats = performed.faderEdges[chosen].beat - targetEdge.beat
                matchedEdges.append(
                    MatchedFaderEdgeComparison(
                        targetIndex: targetIndex,
                        performedIndex: chosen,
                        offsetBeats: offsetBeats,
                        offsetMilliseconds: offsetBeats * millisecondsPerBeat,
                        timing: timingVerdict(offsetBeats: offsetBeats,
                                              tolerance: windows.faderCorrectToleranceBeats)
                    )
                )
            }
            let extraEdgeIndices = performed.faderEdges.indices
                .filter { !claimedEdges.contains($0) }
            faderChannel = .compared(matched: matchedEdges,
                                     missingTargetIndices: missingEdgeIndices,
                                     extraPerformedIndices: extraEdgeIndices)
        }

        return ScratchPerformanceComparisonResult(
            matchedStrokes: matchedStrokes,
            missingTargetStrokeIndices: missingTargetStrokeIndices,
            extraPerformedStrokeIndices: extraPerformedStrokeIndices,
            faderChannel: faderChannel,
            bpm: bpm
        )
    }

    /// One performed index (or nil) per target index. Greedy in target order;
    /// nearest unmatched candidate within `window`; ties break toward the
    /// earlier performed index.
    private static func greedyAssignments(
        targetBeats: [Double],
        performedBeats: [Double],
        window: Double
    ) -> [Int?] {
        var claimed = Set<Int>()
        return targetBeats.map { targetBeat in
            let candidates = performedBeats.indices.filter { index in
                !claimed.contains(index) && abs(performedBeats[index] - targetBeat) <= window
            }
            let chosen = candidates.min { lhs, rhs in
                let lhsDistance = abs(performedBeats[lhs] - targetBeat)
                let rhsDistance = abs(performedBeats[rhs] - targetBeat)
                if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
                return lhs < rhs
            }
            if let chosen { claimed.insert(chosen) }
            return chosen
        }
    }
}

// MARK: - Window derivation

extension ScratchComparisonWindows {

    /// Derives matching windows from the target phrase's own geometry — no
    /// technique-specific constant is invented; the window IS the authored
    /// beat spacing. The match window is half the smallest gap between
    /// consecutive target stroke start beats (the documented safe bound on
    /// `strokeMatchWindowBeats`, so a performed stroke can never be claimed
    /// by the wrong neighbour). The fader window derives the same way from
    /// the target fader-edge stream when it has 2+ edges, otherwise it
    /// reuses the stroke window (edges then have no tighter geometry of
    /// their own). Correctness tolerances remain caller judgment — they are
    /// clamped to the derived windows so construction cannot fail on a
    /// tight phrase.
    ///
    /// `nil` when the phrase has fewer than 2 strokes (no derivable stroke
    /// spacing — the caller must then supply explicit windows) or when the
    /// derived spacing is degenerate (identical start beats).
    static func derived(from target: TargetScratchPhrase,
                        strokeCorrectToleranceBeats: Double,
                        faderCorrectToleranceBeats: Double) -> ScratchComparisonWindows? {
        let starts = target.strokes.map(\.startBeat)
        guard starts.count >= 2 else { return nil }
        var minStrokeGap = Double.infinity
        for index in 1..<starts.count {
            minStrokeGap = min(minStrokeGap, starts[index] - starts[index - 1])
        }
        guard minStrokeGap.isFinite, minStrokeGap > 0 else { return nil }
        let strokeWindow = minStrokeGap / 2

        var faderWindow = strokeWindow
        let edgeBeats = target.faderEdges.map(\.beat)
        if edgeBeats.count >= 2 {
            var minEdgeGap = Double.infinity
            for index in 1..<edgeBeats.count {
                minEdgeGap = min(minEdgeGap, edgeBeats[index] - edgeBeats[index - 1])
            }
            if minEdgeGap.isFinite, minEdgeGap > 0 {
                faderWindow = minEdgeGap / 2
            }
        }

        return ScratchComparisonWindows(
            strokeMatchWindowBeats: strokeWindow,
            strokeCorrectToleranceBeats: min(max(strokeCorrectToleranceBeats, 0), strokeWindow),
            faderMatchWindowBeats: faderWindow,
            faderCorrectToleranceBeats: min(max(faderCorrectToleranceBeats, 0), faderWindow)
        )
    }
}

// MARK: - Target phrase materialization

extension TargetScratchPhrase {

    /// Materializes the tiled phrase as a seconds-ready `ScratchNotation`
    /// through the canonical `BeatPattern.materialized(bpm:)` boundary — the
    /// repository's ONLY beats→seconds path — so a comparison surface can
    /// render the exact phrase the alignment compared against. Rebuilding a
    /// `BeatPattern` from the tiled streams keeps its structural validation
    /// in force: a phrase that somehow tiled into an invalid pattern
    /// materializes as `nil`, never as fake seconds.
    func materializedNotation(bpm: Double,
                              scratchID: String,
                              timingBasis: String,
                              beatsPerBar: Int?,
                              version: Int) -> ScratchNotation? {
        ScratchNotation.BeatPattern(
            version: version,
            scratchID: scratchID,
            timingBasis: timingBasis,
            beatsPerBar: beatsPerBar,
            strokes: strokes,
            faderEvents: faderEdges
        ).materialized(bpm: bpm)
    }
}

// MARK: - Presentation overlay (seconds domain)

/// Renderer-neutral target-vs-performed marks, projected into the seconds
/// domain via a `PerformanceBeatClock` so existing seconds-domain notation
/// surfaces can draw them with their own visual language. Pure data — no
/// colors, no geometry, no UI strings. Matched and extra marks sit at the
/// PERFORMED time (what the user actually did); missing marks sit at the
/// TARGET time (the slot that went unplayed) — no time is ever invented.
struct ScratchComparisonOverlay: Equatable, Sendable {

    enum MarkKind: Equatable, Sendable {
        /// Performed evidence matched to a target slot. `directionCorrect`
        /// stays `nil` when the performed direction was indeterminate —
        /// unassessed, never assumed right or wrong.
        case matched(timing: StrokeTimingVerdict, directionCorrect: Bool?)
        /// A target slot no performed evidence claimed.
        case missingTarget
        /// Performed evidence no target slot claimed.
        case extraPerformed
    }

    struct StrokeMark: Equatable, Sendable {
        let startTime: TimeInterval
        let endTime: TimeInterval
        let kind: MarkKind
        /// Signed performed−target offset for matched marks; `nil` otherwise.
        let offsetMilliseconds: Double?
        /// The direction the mark should render with: performed direction
        /// for matched/extra evidence (nil when indeterminate), target
        /// direction for a missing slot.
        let direction: ScratchNotationDirection?
    }

    struct FaderMark: Equatable, Sendable {
        let time: TimeInterval
        let state: ScratchNotationFaderState
        let kind: MarkKind
        let offsetMilliseconds: Double?
    }

    /// Sorted by `startTime` (ties keep matched → missing → extra stable).
    let strokeMarks: [StrokeMark]
    /// Empty whenever the fader channel was not `.compared` — the
    /// channel-level reason lives on the comparison result, and no fader
    /// marks are fabricated for an unauthored or uncaptured channel.
    let faderMarks: [FaderMark]

    /// Builds the overlay for a comparison result. Deterministic: output
    /// order is a pure function of the inputs. `clock` must be the same
    /// clock the performed timeline was normalized with, so performed beats
    /// project back to the take-relative seconds they came from.
    static func overlay(
        result: ScratchPerformanceComparisonResult,
        target: TargetScratchPhrase,
        performed: PerformedScratchTimeline,
        clock: PerformanceBeatClock
    ) -> ScratchComparisonOverlay {
        var strokeMarks: [ScratchComparisonOverlay.StrokeMark] = []

        for match in result.matchedStrokes {
            guard target.strokes.indices.contains(match.targetIndex),
                  performed.strokes.indices.contains(match.performedIndex) else { continue }
            let performedStroke = performed.strokes[match.performedIndex]
            strokeMarks.append(StrokeMark(
                startTime: clock.seconds(fromBeats: performedStroke.startBeat),
                endTime: clock.seconds(fromBeats: performedStroke.endBeat),
                kind: .matched(timing: match.timing,
                               directionCorrect: match.directionCorrect),
                offsetMilliseconds: match.offsetMilliseconds,
                direction: performedStroke.direction
            ))
        }
        for index in result.missingTargetStrokeIndices
        where target.strokes.indices.contains(index) {
            let stroke = target.strokes[index]
            strokeMarks.append(StrokeMark(
                startTime: clock.seconds(fromBeats: stroke.startBeat),
                endTime: clock.seconds(fromBeats: stroke.endBeat),
                kind: .missingTarget,
                offsetMilliseconds: nil,
                direction: stroke.direction
            ))
        }
        for index in result.extraPerformedStrokeIndices
        where performed.strokes.indices.contains(index) {
            let stroke = performed.strokes[index]
            strokeMarks.append(StrokeMark(
                startTime: clock.seconds(fromBeats: stroke.startBeat),
                endTime: clock.seconds(fromBeats: stroke.endBeat),
                kind: .extraPerformed,
                offsetMilliseconds: nil,
                direction: stroke.direction
            ))
        }
        strokeMarks.sort { lhs, rhs in
            if lhs.startTime != rhs.startTime { return lhs.startTime < rhs.startTime }
            return markOrder(lhs.kind) < markOrder(rhs.kind)
        }

        var faderMarks: [ScratchComparisonOverlay.FaderMark] = []
        if case .compared(let matched, let missingIndices, let extraIndices) = result.faderChannel {
            for match in matched
            where target.faderEdges.indices.contains(match.targetIndex)
                && performed.faderEdges.indices.contains(match.performedIndex) {
                let edge = performed.faderEdges[match.performedIndex]
                faderMarks.append(FaderMark(
                    time: clock.seconds(fromBeats: edge.beat),
                    state: edge.state,
                    kind: .matched(timing: match.timing, directionCorrect: nil),
                    offsetMilliseconds: match.offsetMilliseconds
                ))
            }
            for index in missingIndices where target.faderEdges.indices.contains(index) {
                let edge = target.faderEdges[index]
                faderMarks.append(FaderMark(
                    time: clock.seconds(fromBeats: edge.beat),
                    state: edge.state,
                    kind: .missingTarget,
                    offsetMilliseconds: nil
                ))
            }
            for index in extraIndices where performed.faderEdges.indices.contains(index) {
                let edge = performed.faderEdges[index]
                faderMarks.append(FaderMark(
                    time: clock.seconds(fromBeats: edge.beat),
                    state: edge.state,
                    kind: .extraPerformed,
                    offsetMilliseconds: nil
                ))
            }
            faderMarks.sort { lhs, rhs in
                if lhs.time != rhs.time { return lhs.time < rhs.time }
                return markOrder(lhs.kind) < markOrder(rhs.kind)
            }
        }

        return ScratchComparisonOverlay(strokeMarks: strokeMarks, faderMarks: faderMarks)
    }

    private static func markOrder(_ kind: MarkKind) -> Int {
        switch kind {
        case .matched: return 0
        case .missingTarget: return 1
        case .extraPerformed: return 2
        }
    }
}

// MARK: - Scoring

/// Inspectable sub-scores derived from a comparison result — never from a
/// second detection pass. Each axis is its own number (or `nil` when that
/// axis was not comparable, which is reported, not defaulted): timing
/// quality of the strokes that matched, completeness/direction of the
/// stroke stream, and the same two axes for the fader channel. `overall`
/// is the plain mean of the non-`nil` sub-scores — documented here, not an
/// opaque blend, so a surprising overall is always explainable from the
/// visible sub-scores.
struct ScratchPerformanceScore: Equatable, Sendable {

    // Inspectable counts the sub-scores are computed from.
    let matchedStrokeCount: Int
    let missingStrokeCount: Int
    let extraStrokeCount: Int
    /// Matched strokes whose performed direction was determinate and wrong.
    let wrongDirectionCount: Int
    /// Matched strokes whose performed direction was determinate at all —
    /// the denominator context for `wrongDirectionCount`.
    let assessedDirectionCount: Int
    let matchedFaderEdgeCount: Int
    let missingFaderEdgeCount: Int
    let extraFaderEdgeCount: Int

    /// 0–100. Mean per-matched-stroke timing quality:
    /// `1 − |offsetBeats| / strokeMatchWindowBeats`. `nil` when no stroke
    /// matched (timing is then unassessable, not zero).
    let platterTiming: Double?
    /// 0–100. Matched-with-direction-not-wrong strokes over
    /// `targetCount + extraCount`: a missing stroke, an extra stroke, and a
    /// wrong-direction stroke all cost this axis. `nil` when the target had
    /// no strokes.
    let platterCompleteness: Double?
    /// 0–100. Mean per-matched-edge timing quality against the fader match
    /// window. `nil` unless the fader channel was `.compared` and at least
    /// one edge matched.
    let faderTiming: Double?
    /// 0–100. Matched fader edges over `targetEdgeCount + extraEdgeCount`.
    /// `nil` unless the fader channel was `.compared`.
    let faderCompleteness: Double?
    /// Plain mean of the non-`nil` sub-scores; `nil` when nothing was
    /// comparable at all.
    let overall: Double?

    /// Derives the score. `windows` must be the same windows the comparison
    /// ran with — offsets are normalized against the match window that
    /// admitted them, so a just-inside-the-window match scores near 0 on
    /// that stroke and an exact hit scores 100.
    static func score(
        result: ScratchPerformanceComparisonResult,
        windows: ScratchComparisonWindows
    ) -> ScratchPerformanceScore {
        let matched = result.matchedStrokes
        let missingCount = result.missingTargetStrokeIndices.count
        let extraCount = result.extraPerformedStrokeIndices.count
        let targetCount = matched.count + missingCount

        let wrongDirectionCount = matched.filter { $0.directionCorrect == false }.count
        let assessedDirectionCount = matched.filter { $0.directionCorrect != nil }.count

        var platterTiming: Double?
        if !matched.isEmpty, windows.strokeMatchWindowBeats > 0 {
            let total = matched.reduce(0.0) { sum, match in
                sum + max(0, 1 - abs(match.offsetBeats) / windows.strokeMatchWindowBeats)
            }
            platterTiming = total / Double(matched.count) * 100
        }

        var platterCompleteness: Double?
        if targetCount > 0 {
            let completed = matched.count - wrongDirectionCount
            platterCompleteness = Double(completed) / Double(targetCount + extraCount) * 100
        }

        var faderTiming: Double?
        var faderCompleteness: Double?
        var matchedEdgeCount = 0
        var missingEdgeCount = 0
        var extraEdgeCount = 0
        if case .compared(let matchedEdges, let missingEdges, let extraEdges) = result.faderChannel {
            matchedEdgeCount = matchedEdges.count
            missingEdgeCount = missingEdges.count
            extraEdgeCount = extraEdges.count
            if !matchedEdges.isEmpty, windows.faderMatchWindowBeats > 0 {
                let total = matchedEdges.reduce(0.0) { sum, match in
                    sum + max(0, 1 - abs(match.offsetBeats) / windows.faderMatchWindowBeats)
                }
                faderTiming = total / Double(matchedEdges.count) * 100
            }
            let targetEdgeCount = matchedEdges.count + missingEdges.count
            if targetEdgeCount + extraEdges.count > 0 {
                faderCompleteness = Double(matchedEdges.count)
                    / Double(targetEdgeCount + extraEdges.count) * 100
            }
        }

        let subScores = [platterTiming, platterCompleteness, faderTiming, faderCompleteness]
            .compactMap { $0 }
        let overall = subScores.isEmpty
            ? nil
            : subScores.reduce(0, +) / Double(subScores.count)

        return ScratchPerformanceScore(
            matchedStrokeCount: matched.count,
            missingStrokeCount: missingCount,
            extraStrokeCount: extraCount,
            wrongDirectionCount: wrongDirectionCount,
            assessedDirectionCount: assessedDirectionCount,
            matchedFaderEdgeCount: matchedEdgeCount,
            missingFaderEdgeCount: missingEdgeCount,
            extraFaderEdgeCount: extraEdgeCount,
            platterTiming: platterTiming,
            platterCompleteness: platterCompleteness,
            faderTiming: faderTiming,
            faderCompleteness: faderCompleteness,
            overall: overall
        )
    }
}

// MARK: - Semantic error model (V2 Practice & Review)

/// A formal, presentation-ready error mapped from `ScratchPerformanceComparisonResult`.
/// Each error isolates exactly one mismatch — timing, platter, or fader — at a
/// specific musical-time position. The coaching layer and review inspector
/// consume these directly; no view should duplicate the mapping logic.
struct SemanticError: Equatable, Sendable {
    enum Family: String, Equatable, Sendable, CaseIterable {
        case timing
        case platter
        case fader
    }

    enum Kind: Equatable, Sendable {
        // TIMING
        case early
        case late
        // PLATTER
        case wrongDirection
        case movementTooShort
        case movementTooLong
        case missedMovement
        // FADER
        case missedCut
        case extraCut
        case earlyCut
        case lateCut
    }

    let family: Family
    let kind: Kind
    /// Beat-relative position, or `nil` when not determinable.
    let beatPosition: Double?
    /// Magnitude in milliseconds where meaningful (timing offsets), `nil` otherwise.
    let magnitudeMilliseconds: Double?
    /// Human-readable expected behaviour.
    let expected: String
    /// Human-readable performed behaviour.
    let performed: String
}

extension SemanticError {

    /// Derives a flat, priority-ordered list of semantic errors from a
    /// completed comparison result. Coaching precedence: timing errors first,
    /// then platter direction/completeness, then fader — matching the
    /// fundamental-first hierarchy the coaching messages already use.
    ///
    /// Each matched stroke with a timing or direction problem produces one
    /// error; each missing target stroke produces one missed-movement error;
    /// extra performed strokes are listed as movement-too-long errors.
    /// Fader edge mismatches produce cut-level errors.
    static func derive(
        from result: ScratchPerformanceComparisonResult,
        target: TargetScratchPhrase,
        performed: PerformedScratchTimeline,
        clock: PerformanceBeatClock
    ) -> [SemanticError] {
        var errors: [SemanticError] = []

        // --- Timing / platter direction ---
        for match in result.matchedStrokes {
            guard target.strokes.indices.contains(match.targetIndex),
                  performed.strokes.indices.contains(match.performedIndex) else { continue }
            let tStroke = target.strokes[match.targetIndex]
            let beat = tStroke.startBeat

            switch match.timing {
            case .early:
                errors.append(SemanticError(
                    family: .timing, kind: .early,
                    beatPosition: beat,
                    magnitudeMilliseconds: match.offsetMilliseconds,
                    expected: "On beat \(String(format: "%.1f", beat)).",
                    performed: "Turnaround \(String(format: "%.0f ms early", abs(match.offsetMilliseconds)))."))
            case .late:
                errors.append(SemanticError(
                    family: .timing, kind: .late,
                    beatPosition: beat,
                    magnitudeMilliseconds: match.offsetMilliseconds,
                    expected: "On beat \(String(format: "%.1f", beat)).",
                    performed: "Turnaround \(String(format: "%.0f ms late", match.offsetMilliseconds))."))
            case .correct:
                break
            }

            if match.directionCorrect == false {
                errors.append(SemanticError(
                    family: .platter, kind: .wrongDirection,
                    beatPosition: beat,
                    magnitudeMilliseconds: nil,
                    expected: "\(tStroke.direction) stroke.",
                    performed: "Opposite direction played."))
            }
        }

        // --- Missing target strokes (missed movement) ---
        for index in result.missingTargetStrokeIndices
        where target.strokes.indices.contains(index) {
            let stroke = target.strokes[index]
            errors.append(SemanticError(
                family: .platter, kind: .missedMovement,
                beatPosition: stroke.startBeat,
                magnitudeMilliseconds: nil,
                expected: "\(stroke.direction) stroke at beat \(String(format: "%.1f", stroke.startBeat)).",
                performed: "No movement detected."))
        }

        // --- Extra performed strokes (movement too long / extra) ---
        for index in result.extraPerformedStrokeIndices
        where performed.strokes.indices.contains(index) {
            let stroke = performed.strokes[index]
            errors.append(SemanticError(
                family: .platter, kind: .movementTooLong,
                beatPosition: stroke.startBeat,
                magnitudeMilliseconds: nil,
                expected: "No extra movement beyond the pattern.",
                performed: "Extra stroke detected at beat \(String(format: "%.1f", stroke.startBeat))."))
        }

        // --- Fader edge errors ---
        switch result.faderChannel {
        case .compared(let matchedEdges, let missingTargetEdgeIndices, let extraPerformedEdgeIndices):
            for match in matchedEdges
            where target.faderEdges.indices.contains(match.targetIndex) {
                let targetBeat = target.faderEdges[match.targetIndex].beat
                switch match.timing {
                case .early:
                    errors.append(SemanticError(
                        family: .fader, kind: .earlyCut,
                        beatPosition: targetBeat,
                        magnitudeMilliseconds: match.offsetMilliseconds,
                        expected: "Cut on beat \(String(format: "%.1f", targetBeat)).",
                        performed: "Cut \(String(format: "%.0f ms early", abs(match.offsetMilliseconds)))."))
                case .late:
                    errors.append(SemanticError(
                        family: .fader, kind: .lateCut,
                        beatPosition: targetBeat,
                        magnitudeMilliseconds: match.offsetMilliseconds,
                        expected: "Cut on beat \(String(format: "%.1f", targetBeat)).",
                        performed: "Cut \(String(format: "%.0f ms late", match.offsetMilliseconds))."))
                case .correct:
                    break
                }
            }
            for _ in missingTargetEdgeIndices {
                errors.append(SemanticError(
                    family: .fader, kind: .missedCut,
                    beatPosition: nil, magnitudeMilliseconds: nil,
                    expected: "Fader cut expected.",
                    performed: "No cut detected."))
            }
            for _ in extraPerformedEdgeIndices {
                errors.append(SemanticError(
                    family: .fader, kind: .extraCut,
                    beatPosition: nil, magnitudeMilliseconds: nil,
                    expected: "No fader cut expected here.",
                    performed: "Extra cut detected."))
            }
        case .noCanonicalFaderChannel, .noPerformedFaderCapture:
            break // no fader errors when channel isn't compared
        }

        // Stable sort: timing first, then platter, then fader; within each
        // family, earlier beat positions first.
        errors.sort { a, b in
            if a.family != b.family {
                return familyPriority(a.family) < familyPriority(b.family)
            }
            return (a.beatPosition ?? .infinity) < (b.beatPosition ?? .infinity)
        }
        return errors
    }

    private static func familyPriority(_ f: Family) -> Int {
        switch f {
        case .timing: return 0
        case .platter: return 1
        case .fader: return 2
        }
    }
}
