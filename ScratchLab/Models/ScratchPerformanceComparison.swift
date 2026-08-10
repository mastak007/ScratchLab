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
//   rendering, no clock reads, no I/O, no UI strings, no aggregate score.

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
