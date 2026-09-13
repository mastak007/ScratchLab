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

extension FaderChannelComparison {
    /// Learner-facing one-line fader summary — product language, never
    /// implementation terminology. `.noCanonicalFaderChannel` is the Baby
    /// Scratch case (the only canonical pattern today): the fader is open
    /// throughout and no cut is expected.
    var learnerFaderSummary: String {
        switch self {
        case .noCanonicalFaderChannel:
            return "Open throughout · no cuts expected"
        case .noPerformedFaderCapture:
            return "Fader not captured"
        case .compared(let matched, let missing, let extra):
            return "\(matched.count) cuts matched · \(missing.count) missed · \(extra.count) extra"
        }
    }
}

/// Renderer-independent comparison primitives for one target phrase vs one
/// performed take. Deliberately not collapsed into a score; carries no UI
/// strings. Consumed later by UI/coaching layers.
struct ScratchPerformanceComparisonResult: Equatable, Sendable {
    let matchedStrokes: [MatchedStrokeComparison]
    /// Target strokes with no performed match inside the window.
    let missingTargetStrokeIndices: [Int]
    /// Performed strokes claimed by no target stroke — boundary (setup /
    /// incomplete) strokes are reported separately, never as ordinary extras.
    let extraPerformedStrokeIndices: [Int]
    let faderChannel: FaderChannelComparison
    /// Tempo the millisecond projections were computed at.
    let bpm: Double
    /// Performed strokes classified as leading preparatory setup. These stay
    /// in the captured record and are reported as evidence, but are excluded
    /// from direction/extra penalties.
    let boundarySetupPerformedStrokeIndices: [Int]
    /// Performed strokes classified as incomplete boundary strokes (a
    /// truncated stroke at the leading or trailing edge). Retained evidence,
    /// excluded from direction/extra penalties.
    let boundaryIncompletePerformedStrokeIndices: [Int]
    /// Target strokes tiled beyond the performed phrase and therefore unscored
    /// — never reported as missed. Empty unless the caller tiled the target
    /// past the scored performed window.
    let unscoredTargetStrokeIndices: [Int]
    /// Human-readable explanation of the chosen phase/offset, for diagnostics.
    let alignmentExplanation: String

    // Defaults keep the synthesized memberwise initializer source-compatible
    // with callers that construct a result directly for tests.
    init(matchedStrokes: [MatchedStrokeComparison],
         missingTargetStrokeIndices: [Int],
         extraPerformedStrokeIndices: [Int],
         faderChannel: FaderChannelComparison,
         bpm: Double,
         boundarySetupPerformedStrokeIndices: [Int] = [],
         boundaryIncompletePerformedStrokeIndices: [Int] = [],
         unscoredTargetStrokeIndices: [Int] = [],
         alignmentExplanation: String = "") {
        self.matchedStrokes = matchedStrokes
        self.missingTargetStrokeIndices = missingTargetStrokeIndices
        self.extraPerformedStrokeIndices = extraPerformedStrokeIndices
        self.faderChannel = faderChannel
        self.bpm = bpm
        self.boundarySetupPerformedStrokeIndices = boundarySetupPerformedStrokeIndices
        self.boundaryIncompletePerformedStrokeIndices = boundaryIncompletePerformedStrokeIndices
        self.unscoredTargetStrokeIndices = unscoredTargetStrokeIndices
        self.alignmentExplanation = alignmentExplanation
    }
}

// MARK: - Alignment

/// The output of the source-neutral alignment stage: which performed strokes
/// form the scored phrase, which are boundary evidence, and which target
/// strokes (if any) were tiled beyond the performed phrase.
///
/// Alignment never mutates the captured record — `PerformedScratchTimeline`
/// and its strokes are untouched. Boundary strokes remain present in that
/// array; this type only records their classification so comparison/scoring
/// can exclude them from in-phrase penalties while still surfacing them as
/// evidence.
struct ScratchAlignment: Equatable, Sendable {
    /// Performed strokes classified as leading preparatory setup (indices into
    /// `PerformedScratchTimeline.strokes`).
    let boundarySetupPerformedIndices: [Int]
    /// Performed strokes classified as incomplete boundary strokes (a
    /// truncated stroke at the leading or trailing edge).
    let boundaryIncompletePerformedIndices: [Int]
    /// The contiguous scored performed window `[start, end)`.
    let scoredPerformedRange: Range<Int>
    /// Target strokes tiled beyond the performed phrase and therefore unscored
    /// (indices into `TargetScratchPhrase.strokes`).
    let unscoredTargetStrokeIndices: [Int]
    /// Human-readable explanation of the chosen phase/offset, for diagnostics.
    let explanation: String

    /// Scored performed indices in ascending order.
    var scoredPerformedIndices: [Int] { Array(scoredPerformedRange) }
}

enum ScratchPerformanceAlignment {

    // Boundary-classification evidence, all in beat-domain durations. A leading
    // stroke markedly longer than its neighbours is slow preparatory setup; a
    // stroke markedly shorter than its neighbours is a truncated/incomplete
    // boundary stroke. These are deliberately coarse, relative to the phrase's
    // own median so they stay BPM- and source-independent.
    /// A leading stroke whose duration exceeds this multiple of the median is
    /// treated as slow preparatory setup rather than an in-phrase stroke.
    static let setupDurationFactor = 1.6
    /// A stroke whose duration falls below this multiple of the median is
    /// treated as an incomplete (truncated) boundary stroke.
    static let incompleteDurationFactor = 0.55
    /// Minimum number of full target cycles that must remain in the scored
    /// window before a boundary is trimmed — a short phrase must not be
    /// over-trimmed on the strength of a single outlier ("insufficient
    /// neighbouring cycles").
    static let minimumScoredCycles = 2

    /// Runs the alignment stage: identifies boundary (setup / incomplete)
    /// performed strokes, the scored performed window, and any over-tiled
    /// target strokes, and selects the phase (target stroke 0 pairs with the
    /// first scored performed stroke).
    ///
    /// Deterministic and source-neutral: it reads only beat positions and
    /// directions, never `source`/`confidence`, and never reinterprets an
    /// individual stroke's captured direction. Phase is chosen from timing and
    /// structural evidence (duration outliers at the phrase edges), never by
    /// flipping directions to maximise a score.
    static func align(
        target: TargetScratchPhrase,
        performed: PerformedScratchTimeline
    ) -> ScratchAlignment {
        let strokes = performed.strokes
        let n = strokes.count
        let targetCount = target.strokes.count

        guard n > 0 else {
            return ScratchAlignment(boundarySetupPerformedIndices: [],
                                    boundaryIncompletePerformedIndices: [],
                                    scoredPerformedRange: 0..<0,
                                    unscoredTargetStrokeIndices: [],
                                    explanation: "No performed strokes to align.")
        }

        let durations = strokes.map { $0.endBeat - $0.startBeat }
        let median = Self.median(durations)
        let cyclesPerStroke = Self.strokesPerCycle(in: target)
        let requiredStrokes = cyclesPerStroke * Self.minimumScoredCycles

        // Leading boundary: a contiguous prefix of duration outliers (long →
        // setup, short → incomplete). Stops at the first stroke whose duration
        // is not a strong outlier.
        var leadingSetup: [Int] = []
        var leadingIncomplete: [Int] = []
        var scoredStart = 0
        if median > 0 {
            while scoredStart < n {
                let d = durations[scoredStart]
                if d > Self.setupDurationFactor * median {
                    leadingSetup.append(scoredStart)
                    scoredStart += 1
                } else if d < Self.incompleteDurationFactor * median {
                    leadingIncomplete.append(scoredStart)
                    scoredStart += 1
                } else {
                    break
                }
            }
        }

        // Trailing boundary: a contiguous suffix of short (incomplete) outliers.
        var trailingIncomplete: [Int] = []
        var scoredEnd = n
        if median > 0 {
            while scoredEnd > 0, durations[scoredEnd - 1] < Self.incompleteDurationFactor * median {
                trailingIncomplete.append(scoredEnd - 1)
                scoredEnd -= 1
            }
        }
        trailingIncomplete.reverse()

        // Guard against over-trimming: if the scored window no longer contains
        // enough cycles to establish a stable run, keep the whole phrase.
        if scoredEnd - scoredStart < requiredStrokes {
            leadingSetup = []
            leadingIncomplete = []
            trailingIncomplete = []
            scoredStart = 0
            scoredEnd = n
        }

        let scoredCount = scoredEnd - scoredStart
        var unscoredTarget: [Int] = []
        if scoredCount > 0, scoredCount % cyclesPerStroke == 0, scoredCount < targetCount {
            unscoredTarget = Array(scoredCount..<targetCount)
        }

        let explanation = Self.explain(setup: leadingSetup,
                                       incomplete: leadingIncomplete + trailingIncomplete,
                                       scoredRange: scoredStart..<scoredEnd,
                                       unscoredTarget: unscoredTarget,
                                       medianBeats: median,
                                       durations: durations)
        return ScratchAlignment(
            boundarySetupPerformedIndices: leadingSetup,
            boundaryIncompletePerformedIndices: leadingIncomplete + trailingIncomplete,
            scoredPerformedRange: scoredStart..<scoredEnd,
            unscoredTargetStrokeIndices: unscoredTarget,
            explanation: explanation
        )
    }

    /// Deterministic target-vs-performed comparison built on the alignment
    /// stage. Boundary strokes are excluded from in-phrase direction/extra
    /// penalties and over-tiled target strokes are reported unscored, so a
    /// preparatory setup stroke or a truncated final stroke never inverts the
    /// direction comparison for the stable phrase.
    ///
    /// `nil` when `bpm` is unusable.
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

        let alignment = align(target: target, performed: performed)
        let scoredStart = alignment.scoredPerformedRange.lowerBound
        let scoredEnd = alignment.scoredPerformedRange.upperBound
        let scoredTargetCount = alignment.unscoredTargetStrokeIndices.isEmpty
            ? target.strokes.count
            : (alignment.unscoredTargetStrokeIndices.first ?? target.strokes.count)

        func makeMatch(targetIndex: Int, performedIndex: Int) -> MatchedStrokeComparison {
            let targetStroke = target.strokes[targetIndex]
            let performedStroke = performed.strokes[performedIndex]
            let offsetBeats = performedStroke.startBeat - targetStroke.startBeat
            return MatchedStrokeComparison(
                targetIndex: targetIndex,
                performedIndex: performedIndex,
                offsetBeats: offsetBeats,
                offsetMilliseconds: offsetBeats * millisecondsPerBeat,
                timing: timingVerdict(offsetBeats: offsetBeats,
                                      tolerance: windows.strokeCorrectToleranceBeats),
                directionCorrect: performedStroke.direction.map { $0 == targetStroke.direction }
            )
        }

        // Strokes.
        let (matchedStrokes, missingTargetStrokeIndices, extraPerformedStrokeIndices) =
            matchStrokes(performed: performed.strokes,
                         scoredStart: scoredStart,
                         scoredEnd: scoredEnd,
                         target: target,
                         scoredTargetCount: scoredTargetCount,
                         window: windows.strokeMatchWindowBeats,
                         makeMatch: makeMatch)

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
            bpm: bpm,
            boundarySetupPerformedStrokeIndices: alignment.boundarySetupPerformedIndices,
            boundaryIncompletePerformedStrokeIndices: alignment.boundaryIncompletePerformedIndices,
            unscoredTargetStrokeIndices: alignment.unscoredTargetStrokeIndices,
            alignmentExplanation: alignment.explanation
        )
    }

    /// One-to-one monotonic stroke matching over the scored windows.
    ///
    /// When the scored performed and target windows have equal length and
    /// their direction sequences agree (or the performed direction is
    /// indeterminate), strokes pair by index — this is drift-tolerant: tempo
    /// drift shifts the *timing* verdicts, never the pairing, so a stable
    /// alternating phrase is never mis-paired into wrong-way or missing/extra.
    /// Otherwise (count or direction mismatch) a direction-aware monotonic
    /// two-pointer match locates the genuine missing/extra strokes within the
    /// caller's match window.
    private static func matchStrokes(
        performed: [PerformedScratchTimeline.Stroke],
        scoredStart: Int,
        scoredEnd: Int,
        target: TargetScratchPhrase,
        scoredTargetCount: Int,
        window: Double,
        makeMatch: (Int, Int) -> MatchedStrokeComparison
    ) -> (matched: [MatchedStrokeComparison], missing: [Int], extra: [Int]) {
        let scoredCount = scoredEnd - scoredStart

        func compatible(_ p: ScratchNotationDirection?, _ t: ScratchNotationDirection) -> Bool {
            p == nil || p == t
        }

        // Fast path: same length and every direction agrees → index pairing.
        if scoredCount == scoredTargetCount, scoredCount > 0 {
            var allCompatible = true
            for k in 0..<scoredCount
            where !compatible(performed[scoredStart + k].direction, target.strokes[k].direction) {
                allCompatible = false
                break
            }
            if allCompatible {
                var matched: [MatchedStrokeComparison] = []
                matched.reserveCapacity(scoredCount)
                for k in 0..<scoredCount {
                    matched.append(makeMatch(k, scoredStart + k))
                }
                return (matched, [], [])
            }
        }

        // Direction-aware monotonic two-pointer match.
        var matched: [MatchedStrokeComparison] = []
        var missing: [Int] = []
        var extra: [Int] = []
        var i = scoredStart
        var j = 0
        while i < scoredEnd && j < scoredTargetCount {
            let p = performed[i]
            let t = target.strokes[j]
            let offset = p.startBeat - t.startBeat
            if compatible(p.direction, t.direction) {
                if abs(offset) <= window {
                    matched.append(makeMatch(j, i))
                    i += 1
                    j += 1
                } else if offset < 0 {
                    extra.append(i)
                    i += 1
                } else {
                    missing.append(j)
                    j += 1
                }
            } else {
                // Direction mismatch: if the next target slot matches p's
                // direction and is nearer, the current target slot is missing
                // (p belongs to the following slot); otherwise it is a genuine
                // wrong-direction stroke for this slot.
                let belongsNext = j + 1 < scoredTargetCount
                    && p.direction != nil
                    && p.direction == target.strokes[j + 1].direction
                    && abs(p.startBeat - target.strokes[j + 1].startBeat) < abs(offset)
                if belongsNext {
                    missing.append(j)
                    j += 1
                } else if abs(offset) <= window {
                    matched.append(makeMatch(j, i))
                    i += 1
                    j += 1
                } else if offset < 0 {
                    extra.append(i)
                    i += 1
                } else {
                    missing.append(j)
                    j += 1
                }
            }
        }
        while i < scoredEnd {
            extra.append(i)
            i += 1
        }
        while j < scoredTargetCount {
            missing.append(j)
            j += 1
        }
        return (matched, missing, extra)
    }

    /// The number of strokes per target cycle, derived from the period of the
    /// tiled target's direction sequence. For the canonical Baby Scratch cycle
    /// (`forward`, `backward`) this is 2. Returns the whole target length when
    /// no periodic direction structure is detectable.
    private static func strokesPerCycle(in target: TargetScratchPhrase) -> Int {
        let directions = target.strokes.map(\.direction)
        let n = directions.count
        guard n > 0 else { return 1 }
        for period in 1...n where n % period == 0 {
            var periodic = true
            for i in period..<n where directions[i] != directions[i - period] {
                periodic = false
                break
            }
            if periodic { return period }
        }
        return n
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    private static func explain(setup: [Int],
                                incomplete: [Int],
                                scoredRange: Range<Int>,
                                unscoredTarget: [Int],
                                medianBeats: Double,
                                durations: [Double]) -> String {
        var parts: [String] = []
        if !setup.isEmpty {
            let detail = setup.map { index in
                "stroke \(index) (duration \(Self.fmt(durations[index])) beats ≈ \(Self.fmt(durations[index] / medianBeats))× median)"
            }.joined(separator: ", ")
            parts.append("boundary setup: \(detail)")
        }
        if !incomplete.isEmpty {
            let detail = incomplete.map { index in
                "stroke \(index) (duration \(Self.fmt(durations[index])) beats ≈ \(Self.fmt(durations[index] / medianBeats))× median)"
            }.joined(separator: ", ")
            parts.append("boundary incomplete: \(detail)")
        }
        let scoredCount = scoredRange.upperBound - scoredRange.lowerBound
        parts.append("scored \(scoredCount) performed stroke(s) at indices \(scoredRange.lowerBound)..<\(scoredRange.upperBound)")
        if !unscoredTarget.isEmpty {
            parts.append("unscored target stroke(s) \(unscoredTarget.first!)..<\(unscoredTarget.last! + 1) (over-tiled)")
        }
        return parts.joined(separator: "; ")
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.2f", value)
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
        /// Performed evidence classified as leading preparatory setup —
        /// retained as evidence, never scored.
        case boundarySetup
        /// Performed evidence classified as an incomplete boundary stroke —
        /// retained as evidence, never scored.
        case boundaryIncomplete
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
        for index in result.boundarySetupPerformedStrokeIndices
        where performed.strokes.indices.contains(index) {
            let stroke = performed.strokes[index]
            strokeMarks.append(StrokeMark(
                startTime: clock.seconds(fromBeats: stroke.startBeat),
                endTime: clock.seconds(fromBeats: stroke.endBeat),
                kind: .boundarySetup,
                offsetMilliseconds: nil,
                direction: stroke.direction
            ))
        }
        for index in result.boundaryIncompletePerformedStrokeIndices
        where performed.strokes.indices.contains(index) {
            let stroke = performed.strokes[index]
            strokeMarks.append(StrokeMark(
                startTime: clock.seconds(fromBeats: stroke.startBeat),
                endTime: clock.seconds(fromBeats: stroke.endBeat),
                kind: .boundaryIncomplete,
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
        case .boundarySetup: return 3
        case .boundaryIncomplete: return 4
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
        case missingTearHold
        case extraTearHold
        case tearHoldEarly
        case tearHoldLate
        case subdivisionRatioMismatch
        case motionShapeMismatch
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

extension SemanticError {

    /// Concise, non-localized family eyebrow for grouping and marker display.
    /// Kept as data (not UI strings) so a single renderer owns the styling;
    /// the value is a stable uppercase token, not a sentence.
    var familyLabel: String {
        switch family {
        case .timing: return "TIMING"
        case .platter: return "PLATTER"
        case .fader: return "FADER"
        }
    }

    /// Concise direct kind label for a row or marker — the error name the
    /// `expected`/`performed` sentences expand on.
    var kindLabel: String {
        switch kind {
        case .early: return "Early"
        case .late: return "Late"
        case .wrongDirection: return "Wrong direction"
        case .movementTooShort: return "Movement too short"
        case .movementTooLong: return "Movement too long"
        case .missedMovement: return "Missed movement"
        case .missingTearHold: return "Missing tear hold"
        case .extraTearHold: return "Extra tear hold"
        case .tearHoldEarly: return "Hold early"
        case .tearHoldLate: return "Hold late"
        case .subdivisionRatioMismatch: return "Subdivision rhythm"
        case .motionShapeMismatch: return "Motion shape"
        case .missedCut: return "Missed cut"
        case .extraCut: return "Extra cut"
        case .earlyCut: return "Cut early"
        case .lateCut: return "Cut late"
        }
    }
}

// MARK: - Canonical tear comparison

/// Compares explicitly selected canonical values. It does not select a target,
/// classify a take, change evidence, or award an overall grade. The same entry
/// point accepts live review values and values restored from a companion file.
enum CanonicalTearComparison {
    typealias Record = ScratchNotation.GestureRecord

    enum Axis: Int, CaseIterable, Equatable, Sendable {
        case directionOrder, holdCount, holdTiming, subdivisionRatios
        case motionShape, faderTiming, evidenceQuality

        var title: String {
            switch self {
            case .directionOrder: return "Gesture direction and order"
            case .holdCount: return "Tear-hold count"
            case .holdTiming: return "Hold onset and release"
            case .subdivisionRatios: return "Moving-duration ratios"
            case .motionShape: return "Motion continuity and sampled shape"
            case .faderTiming: return "Fader timing"
            case .evidenceQuality: return "Evidence quality"
            }
        }
    }

    enum Assessment: Equatable, Sendable {
        case withinTolerance, outsideTolerance, partiallyAssessed, unavailable, notRequested
        var title: String {
            switch self {
            case .withinTolerance: return "Within tolerance"
            case .outsideTolerance: return "Outside tolerance"
            case .partiallyAssessed: return "Partially assessed"
            case .unavailable: return "Unavailable"
            case .notRequested: return "Not requested"
            }
        }
    }

    enum UnavailableReason: String, Codable, CaseIterable, Equatable, Sendable {
        case invalidTempoOrOrigin, invalidConfiguration, missingTarget, missingPerformance
        case invalidTarget, invalidPerformance, unsupportedTimingDomain
        case unknownEvidence, ambiguousEvidence, lowConfidence, correctedTiming, unmeasuredTiming
        case inferredHoldEvidence
        case coordinateMismatch, insufficientCurveSamples, interpolatedCurve, missingCurve
        case missingAuthoredRatio, missingFaderEvidence, unmatchedGesture, unmatchedHold
        case unmatchedFaderEvent, nonFiniteMeasurement, comparisonLimitExceeded
        case unobservedInterGestureInterval

        var title: String {
            switch self {
            case .invalidTempoOrOrigin: return "A finite positive tempo and explicit time origin are required."
            case .invalidConfiguration: return "Comparison tolerances are invalid."
            case .missingTarget: return "Select an authored target."
            case .missingPerformance: return "No performed gesture evidence is selected."
            case .invalidTarget: return "The authored target has invalid or unsupported evidence."
            case .invalidPerformance: return "Performed evidence has invalid or unordered boundaries."
            case .unsupportedTimingDomain: return "Targets must use beats and performed records must use seconds."
            case .unknownEvidence: return "Motion evidence or its reviewed classification is unknown."
            case .ambiguousEvidence: return "Reviewed evidence is ambiguous or contradicts its boundaries."
            case .lowConfidence: return "Motion confidence is below the comparison requirement."
            case .correctedTiming: return "Corrected boundaries are not measured timing."
            case .unmeasuredTiming: return "Measured timing is unavailable."
            case .inferredHoldEvidence: return "Hold boundaries are inferred; their count and timing are descriptive, not assessed."
            case .coordinateMismatch: return "The two curves use different coordinate spaces."
            case .insufficientCurveSamples: return "Endpoints alone cannot establish within-run speed shape."
            case .interpolatedCurve: return "Interpolated travel runs cannot establish measured speed shape."
            case .missingCurve: return "A measured or authored curve is missing."
            case .missingAuthoredRatio: return "The target specifies no moving-duration ratio."
            case .missingFaderEvidence: return "Usable fader evidence is missing."
            case .unmatchedGesture: return "A gesture has no corresponding selected gesture."
            case .unmatchedHold: return "A hold has no corresponding hold for timing comparison."
            case .unmatchedFaderEvent: return "A fader transition has no corresponding transition."
            case .nonFiniteMeasurement: return "The requested measurement cannot be represented finitely."
            case .comparisonLimitExceeded: return "The selected evidence exceeds the bounded comparison size."
            case .unobservedInterGestureInterval: return "The canonical gesture records do not describe the interval between these gestures."
            }
        }
    }

    struct Configuration: Equatable, Sendable {
        var timingToleranceMilliseconds: Double
        /// Absolute difference between moving-duration shares, not a demand
        /// for equal subdivisions. This is an internal teaching tolerance.
        var ratioShareTolerance: Double
        var normalizedShapeRMSTolerance: Double
        var normalizedContinuityTolerance: Double
        var minimumMotionConfidence: Double
        /// Shape RMS 0.10, continuity 1e-6 and confidence 0.75 are provisional
        /// internal teaching/assessability choices, not hardware calibration.
        /// Existing beginner timing remains unchanged at 50 milliseconds.
        static let internalReview = Configuration(
            timingToleranceMilliseconds: NotationFeedbackState.lateOffsetThresholdMs,
            ratioShareTolerance: 0.10, normalizedShapeRMSTolerance: 0.10,
            normalizedContinuityTolerance: 0.000001, minimumMotionConfidence: 0.75
        )

        fileprivate var isValid: Bool {
            let tolerances = [timingToleranceMilliseconds, ratioShareTolerance,
                              normalizedShapeRMSTolerance, normalizedContinuityTolerance]
            return tolerances.allSatisfy { $0.isFinite && $0 >= 0 }
                && minimumMotionConfidence.isFinite && (0...1).contains(minimumMotionConfidence)
        }
    }

    struct Measurement: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case direction, missingGesture, extraGesture, holdCount
            case holdOnset, holdRelease, missingHold, extraHold, subdivisionRatio
            case continuity, sampledShape, faderState, faderOffset, missingFader, extraFader
            case supportedGestureShare
            case interGestureGap
        }
        enum Unit: Equatable, Sendable { case count, milliseconds, share, normalizedPosition }
        let kind: Kind
        let targetID: String?
        let performedID: String?
        let expected: Double?
        let observed: Double?
        let signedError: Double?
        let tolerance: Double?
        let unit: Unit?
        let detail: String
        let isWithinTolerance: Bool?

        init(kind: Kind, targetID: String? = nil, performedID: String? = nil,
             expected: Double? = nil, observed: Double? = nil, signedError: Double? = nil,
             tolerance: Double? = nil, unit: Unit? = nil, detail: String,
             isWithinTolerance: Bool? = nil) {
            self.kind = kind
            self.targetID = targetID
            self.performedID = performedID
            self.expected = expected
            self.observed = observed
            self.signedError = signedError
            self.tolerance = tolerance
            self.unit = unit
            self.detail = detail
            self.isWithinTolerance = isWithinTolerance
        }
    }

    struct Dimension: Equatable, Sendable {
        let axis: Axis
        let assessment: Assessment
        /// Percentage of this dimension's assessable observations within its
        /// stated tolerance. Evidence quality reports the supported directional
        /// travel share only when no evidence-quality limitation remains.
        /// Partial results never include unavailable observations as passes.
        let scorePercentage: Double?
        let measurements: [Measurement]
        let unavailableReasons: [UnavailableReason]
    }

    struct Result: Equatable, Sendable {
        let dimensions: [Dimension]
        let semanticErrors: [SemanticError]
        let coaching: [String]
    }

    private struct Accumulator {
        let axis: Axis
        var measurements: [Measurement] = []
        var reasons: [UnavailableReason] = []
        var notRequested = false

        var dimension: Dimension {
            let checks = measurements.compactMap(\.isWithinTolerance)
            let reasons = UnavailableReason.allCases.filter { self.reasons.contains($0) }
            let assessment: Assessment
            if notRequested { assessment = .notRequested }
            else if checks.isEmpty { assessment = .unavailable }
            else if !reasons.isEmpty { assessment = .partiallyAssessed }
            else { assessment = checks.allSatisfy { $0 } ? .withinTolerance : .outsideTolerance }
            var score: Double? = checks.isEmpty ? nil
                : Double(checks.filter { $0 }.count) / Double(checks.count) * 100
            if axis == .evidenceQuality,
               let share = measurements.first(where: { $0.kind == .supportedGestureShare })?.observed {
                // The supported directional travel share remains inspectable, but it is
                // not a complete quality score when another channel is unknown.
                score = reasons.isEmpty ? share * 100 : nil
            }
            return Dimension(axis: axis, assessment: assessment,
                             scorePercentage: notRequested ? nil : score,
                             measurements: measurements, unavailableReasons: reasons)
        }
    }

    /// Gesture arrays are compared in the caller's selected order, never
    /// reordered or matched by their direction/name/hold count. Within paired
    /// gestures, holds and fader transitions use an order-preserving alignment
    /// with maximal cardinality and minimum onset-time error. Equal counts
    /// therefore pair by ordinal even when early/late; timing tolerance never
    /// converts a late hold into a missing hold. Extra/missing events remain
    /// explicit. The origin is supplied by the caller, not estimated here.
    ///
    /// Limitations accompany evidence, including restored companion values.
    /// Unknown/ambiguous limits prevent affected motion judgments; inferred
    /// holds do not invalidate independently measured direction. Their counts
    /// remain descriptive, without learner verdicts. Corrected timing
    /// prevents measured timing/ratio claims; interpolated curves prevent shape
    /// claims. Independent fader observations are assessed independently.
    static func compare(
        target: [Record], performed: [Record], bpm: Double,
        performedOriginSeconds: Double,
        configuration: Configuration = .internalReview,
        performedLimitations: [String: [UnavailableReason]] = [:]
    ) -> Result {
        var axes = Axis.allCases.map { Accumulator(axis: $0) }
        func add(_ axis: Axis, _ measurement: Measurement) {
            axes[axis.rawValue].measurements.append(measurement)
        }
        func limit(_ selectedAxes: [Axis], _ reasons: [UnavailableReason]) {
            for axis in selectedAxes { axes[axis.rawValue].reasons.append(contentsOf: reasons) }
        }
        func finish() -> Result {
            let dimensions = axes.map(\.dimension)
            let errors = semanticErrors(for: dimensions)
            var coaching = Array(errors.prefix(3).map(\.performed))
            if coaching.isEmpty {
                if dimensions.contains(where: { !$0.unavailableReasons.isEmpty }) {
                    coaching = ["Some evidence could not be assessed. Check the reasons beside each dimension."]
                } else {
                    coaching = ["The assessed tear dimensions match the selected target."]
                }
            }
            return Result(dimensions: dimensions, semanticErrors: errors, coaching: coaching)
        }
        func fail(_ reason: UnavailableReason) -> Result {
            limit(Axis.allCases, [reason])
            return finish()
        }
        guard bpm.isFinite, bpm > 0, performedOriginSeconds.isFinite,
              (60 / bpm).isFinite else { return fail(.invalidTempoOrOrigin) }
        guard configuration.isValid else { return fail(.invalidConfiguration) }
        guard !target.isEmpty else { return fail(.missingTarget) }
        guard !performed.isEmpty else { return fail(.missingPerformance) }
        // Protect interactive review from unbounded sequence-alignment work.
        guard target.count <= 128, performed.count <= 128,
              (target + performed).allSatisfy({
                  $0.internalHolds.count <= 128 && $0.faderTransitions.count <= 128
                      && $0.faderIntervals.count <= 256 && $0.subdivisions.count <= 129
                      && $0.subdivisions.allSatisfy {
                          ($0.measuredCurve?.points.count ?? 0) <= 4096
                              && ($0.targetCurve?.points.count ?? 0) <= 4096
                      }
              }) else { return fail(.comparisonLimitExceeded) }
        let sampleCount = (target + performed).reduce(0) { total, record in
            total + record.subdivisions.reduce(0) {
                $0 + ($1.measuredCurve?.points.count ?? 0) + ($1.targetCurve?.points.count ?? 0)
            }
        }
        guard sampleCount <= 65_536 else { return fail(.comparisonLimitExceeded) }
        guard target.allSatisfy({ $0.timingDomain == .beats }),
              performed.allSatisfy({ $0.timingDomain == .seconds }) else {
            return fail(.unsupportedTimingDomain)
        }
        guard orderedRecords(target), target.allSatisfy({
            $0.evidence.provenance == .authored && $0.motionValidationIssues().isEmpty
                && $0.subdivisions.allSatisfy { $0.evidence.provenance == .authored }
                && $0.internalHolds.allSatisfy { $0.evidence.provenance == .authored }
        }) else { return fail(.invalidTarget) }
        guard orderedRecords(performed) else { return fail(.invalidPerformance) }

        let motionAxes: [Axis] = [.directionOrder, .holdCount, .holdTiming, .subdivisionRatios, .motionShape]
        let secondsPerBeat = 60 / bpm
        var supportedGestures = 0
        var anyFaderRequested = false

        for (previous, next) in zip(performed, performed.dropFirst()) {
            let gap = next.subdivisions.first!.span.startTime - previous.subdivisions.last!.span.endTime
            if gap > 0 {
                let gapMilliseconds = gap * 1000
                add(.evidenceQuality, Measurement(kind: .interGestureGap,
                    performedID: next.id, observed: gapMilliseconds.isFinite ? gapMilliseconds : nil,
                    unit: .milliseconds, detail: "There is an unrepresented interval between selected gestures."))
                limit([.directionOrder, .motionShape, .evidenceQuality], [.unobservedInterGestureInterval])
            }
        }

        for index in 0..<max(target.count, performed.count) {
            guard target.indices.contains(index), performed.indices.contains(index) else {
                let missing = !performed.indices.contains(index)
                add(.directionOrder, Measurement(
                    kind: missing ? .missingGesture : .extraGesture,
                    targetID: missing ? target[index].id : nil,
                    performedID: missing ? nil : performed[index].id,
                    expected: missing ? 1 : 0, observed: missing ? 0 : 1,
                    signedError: missing ? -1 : 1, tolerance: 0, unit: .count,
                    detail: missing ? "A selected target gesture was not performed."
                        : "The selected performance contains an extra gesture.",
                    isWithinTolerance: false))
                limit([.holdCount, .holdTiming, .subdivisionRatios, .motionShape], [.unmatchedGesture])
                if target.indices.contains(index), !target[index].faderTransitions.isEmpty {
                    anyFaderRequested = true
                    limit([.faderTiming], [.unmatchedGesture])
                }
                limit([.evidenceQuality], [.unmatchedGesture])
                continue
            }
            let t = target[index]
            let p = performed[index]
            let supplied = performedLimitations[p.id] ?? []
            // Preserve independent limitations even when another evidence
            // gate below prevents this record from reaching that dimension.
            limit([.holdTiming, .subdivisionRatios], supplied.filter {
                [.correctedTiming, .unmeasuredTiming, .inferredHoldEvidence].contains($0)
            })
            limit([.motionShape], supplied.filter {
                [.interpolatedCurve, .correctedTiming, .unmeasuredTiming, .inferredHoldEvidence].contains($0)
            })
            var motionReasons = supplied.filter {
                [.unknownEvidence, .ambiguousEvidence, .invalidPerformance, .lowConfidence].contains($0)
            }
            if p.evidence.provenance == .unknown { motionReasons.append(.unknownEvidence) }
            if !hasValidDirectionEvidence(p) { motionReasons.append(.invalidPerformance) }
            let directionObservations = [p.evidence] + p.subdivisions.map(\.evidence)
            let holdObservations = p.internalHolds.map(\.evidence)
            let observations = directionObservations + holdObservations
            if directionObservations.contains(where: {
                [.authored, .inferred, .unknown].contains($0.provenance)
            }) { motionReasons.append(.unknownEvidence) }
            if directionObservations.contains(where: {
                $0.observation.confidence < configuration.minimumMotionConfidence
            }) { motionReasons.append(.lowConfidence) }
            // Derive each channel's limitations before the direction gate so
            // unsupported travel cannot hide inferred or corrected hold timing.
            var holdReasons = supplied.filter { $0 == .inferredHoldEvidence }
            if !p.motionValidationIssues().isEmpty { holdReasons.append(.invalidPerformance) }
            if holdObservations.contains(where: { $0.provenance == .inferred }) {
                holdReasons.append(.inferredHoldEvidence)
            }
            if holdObservations.contains(where: { [.authored, .unknown].contains($0.provenance) }) {
                holdReasons.append(.unknownEvidence)
            }
            if holdObservations.contains(where: {
                $0.observation.confidence < configuration.minimumMotionConfidence
            }) { holdReasons.append(.lowConfidence) }
            var timingReasons = holdReasons + supplied.filter { $0 == .correctedTiming || $0 == .unmeasuredTiming }
            if observations.contains(where: { $0.provenance == .manuallyCorrected }) {
                timingReasons.append(.correctedTiming)
            }
            if observations.contains(where: { $0.provenance != .measured }) {
                timingReasons.append(.unmeasuredTiming)
            }
            limit([.holdCount], holdReasons)
            limit([.holdTiming, .subdivisionRatios, .motionShape, .evidenceQuality], timingReasons)
            limit([.evidenceQuality], supplied + motionReasons)
            let faderObservations = p.faderTransitions.map(\.evidence) + p.faderIntervals.map(\.evidence)
            let validFaderEvidence = p.faderValidationIssues().isEmpty
                && !faderObservations.isEmpty && faderObservations.allSatisfy {
                    $0.provenance == .measured
                        && $0.observation.confidence >= configuration.minimumMotionConfidence
                }
            let completeFaderCoverage = validFaderEvidence && faderCovers(
                p, from: p.subdivisions.first!.span.startTime, to: p.subdivisions.last!.span.endTime)
            if !completeFaderCoverage {
                limit([.evidenceQuality], [.missingFaderEvidence])
            }
            if motionReasons.isEmpty {
                supportedGestures += 1
                add(.directionOrder, Measurement(
                    kind: .direction, targetID: t.id, performedID: p.id,
                    detail: "Expected \(t.direction.rawValue); performed \(p.direction.rawValue).",
                    isWithinTolerance: t.direction == p.direction))
                let countError = Double(p.internalHolds.count - t.internalHolds.count)
                add(.holdCount, Measurement(
                    kind: .holdCount, targetID: t.id, performedID: p.id,
                    expected: Double(t.internalHolds.count), observed: Double(p.internalHolds.count),
                    signedError: countError, tolerance: holdReasons.isEmpty ? 0 : nil, unit: .count,
                    detail: holdReasons.isEmpty
                        ? "Expected \(t.internalHolds.count) holds; reviewed structure contains \(p.internalHolds.count)."
                        : "Target has \(t.internalHolds.count) holds; available structure describes \(p.internalHolds.count) (not assessed).",
                    isWithinTolerance: holdReasons.isEmpty ? countError == 0 : nil))

                if timingReasons.isEmpty {
                    let targetTimes = t.internalHolds.map { $0.span.startTime * secondsPerBeat }
                    let performedTimes = p.internalHolds.map { $0.span.startTime - performedOriginSeconds }
                    if (targetTimes + performedTimes).allSatisfy(\.isFinite) {
                        let pairs = orderedPairs(target: targetTimes, performed: performedTimes)
                        for (ti, pi) in pairs {
                            let th = t.internalHolds[ti], ph = p.internalHolds[pi]
                            for (kind, expectedTime, observedTime) in [
                                (Measurement.Kind.holdOnset, th.span.startTime * secondsPerBeat,
                                 ph.span.startTime - performedOriginSeconds),
                                (.holdRelease, th.span.endTime * secondsPerBeat,
                                 ph.span.endTime - performedOriginSeconds)
                            ] {
                                let offset = (observedTime - expectedTime) * 1000
                                guard offset.isFinite, (expectedTime * 1000).isFinite,
                                      (observedTime * 1000).isFinite else {
                                    limit([.holdTiming], [.nonFiniteMeasurement]); continue
                                }
                                add(.holdTiming, Measurement(
                                    kind: kind, targetID: th.id, performedID: ph.id,
                                    expected: expectedTime * 1000, observed: observedTime * 1000,
                                    signedError: offset, tolerance: configuration.timingToleranceMilliseconds,
                                    unit: .milliseconds,
                                    detail: "Hold \(kind == .holdOnset ? "onset" : "release"): \(String(format: "%+.1f", offset)) ms.",
                                    isWithinTolerance: abs(offset) <= configuration.timingToleranceMilliseconds))
                            }
                        }
                        for ti in t.internalHolds.indices where !pairs.contains(where: { $0.0 == ti }) {
                            add(.holdTiming, Measurement(kind: .missingHold, targetID: t.internalHolds[ti].id,
                                detail: "A target hold has no performed timing observation."))
                            limit([.holdTiming], [.unmatchedHold])
                        }
                        for pi in p.internalHolds.indices where !pairs.contains(where: { $0.1 == pi }) {
                            add(.holdTiming, Measurement(kind: .extraHold, performedID: p.internalHolds[pi].id,
                                detail: "An extra hold has no authored timing."))
                            limit([.holdTiming], [.unmatchedHold])
                        }
                    } else { limit([.holdTiming], [.nonFiniteMeasurement]) }

                    if let weights = t.authoredSubdivisionRatio {
                        if let shares = p.measuredSubdivisionRatio, weights.count == shares.count {
                            let total = weights.reduce(0, +)
                            if total.isFinite, total > 0 {
                                for i in weights.indices {
                                    let expected = weights[i] / total
                                    let delta = shares[i] - expected
                                    add(.subdivisionRatios, Measurement(
                                        kind: .subdivisionRatio, targetID: t.subdivisions[i].id,
                                        performedID: p.subdivisions[i].id, expected: expected, observed: shares[i],
                                        signedError: delta, tolerance: configuration.ratioShareTolerance, unit: .share,
                                        detail: "Moving share: \(String(format: "%.3f", shares[i])); target \(String(format: "%.3f", expected)).",
                                        isWithinTolerance: abs(delta) <= configuration.ratioShareTolerance))
                                }
                            } else { limit([.subdivisionRatios], [.nonFiniteMeasurement]) }
                        } else { limit([.subdivisionRatios], [.unmatchedHold]) }
                    } else { limit([.subdivisionRatios], [.missingAuthoredRatio]) }
                }
                let shape = compareShape(target: t, performed: p, limitations: supplied + timingReasons,
                                         configuration: configuration)
                for measurement in shape.measurements { add(.motionShape, measurement) }
                limit([.motionShape], shape.reasons)
                limit([.evidenceQuality], shape.reasons)
            } else {
                limit(motionAxes, motionReasons)
            }

            // An open interval is not a timed cut request. Plain tears never
            // earn missing/extra-cut penalties, even when a click was captured.
            guard !t.faderTransitions.isEmpty else { continue }
            anyFaderRequested = true
            guard t.faderValidationIssues().isEmpty,
                  t.faderTransitions.allSatisfy({ $0.evidence.provenance == .authored }) else {
                limit([.faderTiming, .evidenceQuality], [.invalidTarget]); continue
            }
            guard validFaderEvidence else {
                limit([.faderTiming, .evidenceQuality], [.missingFaderEvidence]); continue
            }
            if !completeFaderCoverage { limit([.faderTiming], [.missingFaderEvidence]) }
            let targetTimes = t.faderTransitions.map { $0.time * secondsPerBeat }
            let performedTimes = p.faderTransitions.map { $0.time - performedOriginSeconds }
            guard (targetTimes + performedTimes).allSatisfy(\.isFinite) else {
                limit([.faderTiming], [.nonFiniteMeasurement]); continue
            }
            let pairs = orderedPairs(target: targetTimes, performed: performedTimes)
            for (ti, pi) in pairs {
                let te = t.faderTransitions[ti], pe = p.faderTransitions[pi]
                let offset = (performedTimes[pi] - targetTimes[ti]) * 1000
                add(.faderTiming, Measurement(kind: .faderState, targetID: te.id, performedID: pe.id,
                    detail: "Expected fader \(te.state.rawValue); observed \(pe.state.rawValue).",
                    isWithinTolerance: te.state == pe.state))
                guard offset.isFinite, (targetTimes[ti] * 1000).isFinite,
                      (performedTimes[pi] * 1000).isFinite else {
                    limit([.faderTiming], [.nonFiniteMeasurement]); continue
                }
                add(.faderTiming, Measurement(kind: .faderOffset, targetID: te.id, performedID: pe.id,
                    expected: targetTimes[ti] * 1000, observed: performedTimes[pi] * 1000,
                    signedError: offset, tolerance: configuration.timingToleranceMilliseconds,
                    unit: .milliseconds, detail: "Fader transition: \(String(format: "%+.1f", offset)) ms.",
                    isWithinTolerance: abs(offset) <= configuration.timingToleranceMilliseconds))
            }
            for ti in t.faderTransitions.indices where !pairs.contains(where: { $0.0 == ti }) {
                let expectedTime = targetTimes[ti] + performedOriginSeconds
                let margin = configuration.timingToleranceMilliseconds / 1000
                guard faderCovers(p, from: expectedTime - margin, to: expectedTime + margin) else {
                    limit([.faderTiming], [.missingFaderEvidence]); continue
                }
                add(.faderTiming, Measurement(kind: .missingFader, targetID: t.faderTransitions[ti].id,
                    detail: "An authored fader transition was not observed.", isWithinTolerance: false))
            }
            for pi in p.faderTransitions.indices where !pairs.contains(where: { $0.1 == pi }) {
                add(.faderTiming, Measurement(kind: .extraFader, performedID: p.faderTransitions[pi].id,
                    detail: "An extra fader transition was observed.", isWithinTolerance: false))
            }
        }
        axes[Axis.faderTiming.rawValue].notRequested = !anyFaderRequested
        axes[Axis.holdTiming.rawValue].notRequested = target.allSatisfy { $0.internalHolds.isEmpty }
            && performed.allSatisfy { $0.internalHolds.isEmpty }
        let share = Double(supportedGestures) / Double(max(target.count, performed.count))
        add(.evidenceQuality, Measurement(kind: .supportedGestureShare,
            expected: 1, observed: share, signedError: share - 1, tolerance: 0, unit: .share,
            detail: "\(supportedGestures) of \(max(target.count, performed.count)) selected gesture pairs have supported directional motion.",
            isWithinTolerance: share == 1))
        return finish()
    }

    private static func orderedRecords(_ records: [Record]) -> Bool {
        var ids = Set<String>()
        var previousEnd: Double?
        for record in records {
            guard !record.id.isEmpty, ids.insert(record.id).inserted,
                  let start = record.subdivisions.first?.span.startTime,
                  let end = record.subdivisions.last?.span.endTime,
                  start.isFinite, end.isFinite, start >= 0, end > start,
                  previousEnd.map({ start >= $0 }) ?? true else { return false }
            previousEnd = end
        }
        return true
    }

    /// Direction depends on the record and travel subdivisions. Validate
    /// those observations independently of the separate hold channel; the
    /// full canonical motion validation still gates hold-derived dimensions.
    private static func hasValidDirectionEvidence(_ record: Record) -> Bool {
        guard Record.evidenceIssues(record.evidence, platter: true).isEmpty else { return false }
        var ids = Set([record.id])
        var previousEnd: Double?
        for subdivision in record.subdivisions {
            let span = subdivision.span
            guard !subdivision.id.isEmpty, ids.insert(subdivision.id).inserted,
                  span.startTime.isFinite, span.endTime.isFinite, span.startTime >= 0,
                  span.endTime > span.startTime,
                  previousEnd.map({ span.startTime >= $0 }) ?? true,
                  Record.evidenceIssues(subdivision.evidence, platter: true).isEmpty else { return false }
            for curve in [subdivision.measuredCurve, subdivision.targetCurve].compactMap({ $0 }) {
                guard Record.evidenceIssues(curve.evidence, platter: true).isEmpty,
                      curve.points.count >= 2, curve.points.first?.time == span.startTime,
                      curve.points.last?.time == span.endTime,
                      curve.points.allSatisfy({ $0.time.isFinite && $0.position.isFinite }),
                      zip(curve.points, curve.points.dropFirst()).allSatisfy({ pair in
                          pair.0.time < pair.1.time
                      }) else {
                    return false
                }
            }
            if subdivision.measuredCurve?.evidence.provenance == .authored { return false }
            previousEnd = span.endTime
        }
        return !record.subdivisions.isEmpty
    }

    /// Align the shorter ordered sequence to a subsequence of the longer one.
    /// Ties retain the earlier event. No timing window erases a measured error.
    private static func orderedPairs(target: [Double], performed: [Double]) -> [(Int, Int)] {
        guard !target.isEmpty, !performed.isEmpty else { return [] }
        let swapped = target.count > performed.count
        let short = swapped ? performed : target
        let long = swapped ? target : performed
        let scale = max(1, (short + long).map { abs($0) }.max() ?? 1)
        var costs = Array(repeating: Array(repeating: Double.infinity, count: long.count + 1),
                          count: short.count + 1)
        var matched = Array(repeating: Array(repeating: false, count: long.count + 1),
                            count: short.count + 1)
        costs[0] = Array(repeating: 0, count: long.count + 1)
        for i in 1...short.count {
            for j in i...long.count {
                let match = costs[i - 1][j - 1] + abs(short[i - 1] / scale - long[j - 1] / scale)
                let skip = costs[i][j - 1]
                if match < skip || j == i {
                    costs[i][j] = match
                    matched[i][j] = true
                } else { costs[i][j] = skip }
            }
        }
        var pairs: [(Int, Int)] = []
        var i = short.count, j = long.count
        while i > 0 && j > 0 {
            if matched[i][j] {
                pairs.append(swapped ? (j - 1, i - 1) : (i - 1, j - 1))
                i -= 1
            }
            j -= 1
        }
        return Array(pairs.reversed())
    }

    private static func compareShape(
        target: Record, performed: Record, limitations: [UnavailableReason],
        configuration: Configuration
    ) -> (measurements: [Measurement], reasons: [UnavailableReason]) {
        var reasons = limitations.filter {
            [.interpolatedCurve, .correctedTiming, .unmeasuredTiming, .inferredHoldEvidence,
             .unknownEvidence, .invalidPerformance, .lowConfidence].contains($0)
        }
        if target.coordinateSpace != performed.coordinateSpace { reasons.append(.coordinateMismatch) }
        if target.subdivisions.count != performed.subdivisions.count { reasons.append(.unmatchedHold) }
        let targetCurves = target.subdivisions.compactMap(\.targetCurve)
        let performedCurves = performed.subdivisions.compactMap(\.measuredCurve)
        if targetCurves.count != target.subdivisions.count
            || performedCurves.count != performed.subdivisions.count { reasons.append(.missingCurve) }
        if performedCurves.contains(where: { $0.points.count < 3 }) { reasons.append(.insufficientCurveSamples) }
        if performedCurves.contains(where: { $0.evidence.provenance != .measured }) {
            reasons.append(.unmeasuredTiming)
        }
        if performedCurves.contains(where: {
            $0.evidence.observation.confidence < configuration.minimumMotionConfidence
        }) { reasons.append(.lowConfidence) }
        guard reasons.isEmpty else { return ([], reasons) }
        guard let ts = targetCurves.first?.points.first?.position,
              let te = targetCurves.last?.points.last?.position,
              let ps = performedCurves.first?.points.first?.position,
              let pe = performedCurves.last?.points.last?.position else { return ([], [.missingCurve]) }
        let targetTravel = te - ts, performedTravel = pe - ps
        guard targetTravel.isFinite, performedTravel.isFinite,
              abs(targetTravel) > 0, abs(performedTravel) > 0 else {
            return ([], [.nonFiniteMeasurement])
        }
        var measurements: [Measurement] = []
        for i in performedCurves.indices {
            let tc = targetCurves[i], pc = performedCurves[i]
            let tSpan = target.subdivisions[i].span, pSpan = performed.subdivisions[i].span
            var squaredErrors: [Double] = []
            for point in pc.points {
                let fraction = (point.time - pSpan.startTime) / pSpan.duration
                let targetTime = tSpan.startTime + fraction * tSpan.duration
                let expected = (interpolate(tc.points, at: targetTime) - ts) / targetTravel
                let observed = (point.position - ps) / performedTravel
                let delta = observed - expected
                squaredErrors.append(delta * delta)
            }
            let rms = sqrt(squaredErrors.reduce(0, +) / Double(squaredErrors.count))
            guard rms.isFinite else { return ([], [.nonFiniteMeasurement]) }
            measurements.append(Measurement(kind: .sampledShape, targetID: target.subdivisions[i].id,
                performedID: performed.subdivisions[i].id, expected: 0, observed: rms,
                signedError: rms, tolerance: configuration.normalizedShapeRMSTolerance,
                unit: .normalizedPosition, detail: "Sampled normalized shape RMS: \(String(format: "%.4f", rms)).",
                isWithinTolerance: rms <= configuration.normalizedShapeRMSTolerance))
            if i < performed.internalHolds.count {
                guard let holdPosition = performed.internalHolds[i].position else {
                    return (measurements, [.missingCurve])
                }
                let before = pc.points.last!.position
                let after = performedCurves[i + 1].points.first!.position
                let gap = max(abs(holdPosition - before), abs(after - holdPosition)) / abs(performedTravel)
                guard gap.isFinite else { return ([], [.nonFiniteMeasurement]) }
                measurements.append(Measurement(kind: .continuity, targetID: target.internalHolds[i].id,
                    performedID: performed.internalHolds[i].id, expected: 0, observed: gap,
                    signedError: gap, tolerance: configuration.normalizedContinuityTolerance,
                    unit: .normalizedPosition, detail: "Normalized discontinuity at hold: \(String(format: "%.6f", gap)).",
                    isWithinTolerance: gap <= configuration.normalizedContinuityTolerance))
            }
        }
        return (measurements, [])
    }

    private static func interpolate(_ points: [Record.CurvePoint], at time: Double) -> Double {
        guard let first = points.first, let last = points.last else { return .nan }
        if time <= first.time { return first.position }
        if time >= last.time { return last.position }
        var lower = 0, upper = points.count - 1
        while upper - lower > 1 {
            let middle = lower + (upper - lower) / 2
            if points[middle].time <= time { lower = middle } else { upper = middle }
        }
        let a = points[lower], b = points[upper]
        return a.position + (b.position - a.position) * ((time - a.time) / (b.time - a.time))
    }

    /// Only bounded, previously validated measured intervals can establish
    /// absence of a requested transition. Edges never fill uncovered time.
    private static func faderCovers(_ record: Record, from lower: Double, to upper: Double) -> Bool {
        guard lower.isFinite, upper.isFinite, upper >= lower else { return false }
        var cursor = lower
        for interval in record.faderIntervals {
            if interval.span.endTime <= cursor { continue }
            if interval.span.startTime > cursor { return false }
            cursor = interval.span.endTime
            if cursor >= upper { return true }
        }
        return false
    }

    private static func semanticErrors(for dimensions: [Dimension]) -> [SemanticError] {
        dimensions.flatMap { dimension in
            dimension.measurements.compactMap { measurement -> SemanticError? in
                guard measurement.isWithinTolerance == false else { return nil }
                let kind: SemanticError.Kind
                let family: SemanticError.Family
                switch measurement.kind {
                case .direction: kind = .wrongDirection; family = .platter
                case .missingGesture: kind = .missedMovement; family = .platter
                case .extraGesture: kind = .movementTooLong; family = .platter
                case .holdCount:
                    kind = (measurement.signedError ?? 0) < 0 ? .missingTearHold : .extraTearHold
                    family = .platter
                case .holdOnset, .holdRelease:
                    kind = (measurement.signedError ?? 0) < 0 ? .tearHoldEarly : .tearHoldLate
                    family = .timing
                case .subdivisionRatio: kind = .subdivisionRatioMismatch; family = .platter
                case .continuity, .sampledShape: kind = .motionShapeMismatch; family = .platter
                case .faderState, .missingFader: kind = .missedCut; family = .fader
                case .extraFader: kind = .extraCut; family = .fader
                case .faderOffset:
                    kind = (measurement.signedError ?? 0) < 0 ? .earlyCut : .lateCut
                    family = .fader
                case .missingHold, .extraHold, .supportedGestureShare, .interGestureGap: return nil
                }
                return SemanticError(family: family, kind: kind, beatPosition: nil,
                    magnitudeMilliseconds: measurement.unit == .milliseconds ? measurement.signedError : nil,
                    expected: dimension.axis.title + ": follow the explicitly selected authored target.",
                    performed: measurement.detail)
            }
        }
    }
}
