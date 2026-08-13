// ScratchGameplayAttempt — one deterministic gameplay attempt, built directly
// on ScratchPerformanceComparison. This is not a second scoring/comparison
// system: an attempt wraps ScratchPerformanceComparisonResult and
// ScratchPerformanceScore verbatim and adds only gameplay-facing framing
// (attempt window, grade band, assessability) on top of facts those types
// already computed.
//
// Layering rules, matching ScratchPerformanceComparison.swift:
// - Pure value transformation, deterministic, Foundation-only. No SwiftUI,
//   no rendering, no clock reads, no I/O, no UI strings.
// - No window/threshold is invented as a technique-specific constant — the
//   attempt window is derived from the target pattern's own duration, and
//   match/tolerance windows are the caller-supplied values the comparison
//   engine already requires.

import Foundation

// MARK: - Attempt window

/// The beat-domain span of exactly one canonical target cycle. Performed
/// evidence is windowed to this span before comparison: a stroke that starts
/// a beat late belongs to the *next* cycle's attempt, not this one — nothing
/// here waits indefinitely for a missing stroke to show up.
struct GameplayAttemptWindow: Equatable, Sendable {
    let startBeat: Double
    let endBeat: Double

    /// `nil` unless both bounds are finite and `endBeat > startBeat` — an
    /// attempt window always has positive, well-formed duration.
    init?(startBeat: Double, endBeat: Double) {
        guard startBeat.isFinite, endBeat.isFinite, endBeat > startBeat else { return nil }
        self.startBeat = startBeat
        self.endBeat = endBeat
    }

    /// The window for the `cycleIndex`-th (0-based) repetition of a pattern
    /// whose single-cycle duration is `cycleDurationBeats`, measured from
    /// beat 0 of the target phrase (i.e. after any count-in the caller's
    /// `PerformanceBeatClock` already anchored out).
    init?(cycleIndex: Int, cycleDurationBeats: Double) {
        guard cycleIndex >= 0 else { return nil }
        self.init(startBeat: Double(cycleIndex) * cycleDurationBeats,
                  endBeat: Double(cycleIndex + 1) * cycleDurationBeats)
    }
}

extension PerformedScratchTimeline {
    /// Restricts this timeline to evidence whose *start* falls inside
    /// `window` — matching how `ScratchPerformanceAlignment` already matches
    /// strokes and fader edges by start beat only — and rebases it so
    /// `window.startBeat` becomes beat 0, the frame a single un-tiled
    /// `TargetScratchPhrase.phrase(repeating:cycles: 1)` already uses. A
    /// stroke starting before or at/after the window belongs to a different
    /// attempt and is dropped, never stretched to fit.
    ///
    /// `hasFaderCapture` is preserved unchanged: it records whether the take
    /// carried crossfader capture evidence at all, a take-level fact, not a
    /// window-level one — a window with capture but no edge crossing inside
    /// it is correctly "captured, nothing to match", not "uncaptured".
    func windowed(to window: GameplayAttemptWindow) -> PerformedScratchTimeline {
        let strokes = self.strokes
            .filter { $0.startBeat >= window.startBeat && $0.startBeat < window.endBeat }
            .map {
                Stroke(startBeat: $0.startBeat - window.startBeat,
                      endBeat: $0.endBeat - window.startBeat,
                      direction: $0.direction,
                      confidence: $0.confidence,
                      source: $0.source)
            }
        let edges = self.faderEdges
            .filter { $0.beat >= window.startBeat && $0.beat < window.endBeat }
            .map { FaderEdge(beat: $0.beat - window.startBeat, state: $0.state, source: $0.source) }
        return PerformedScratchTimeline(strokes: strokes, faderEdges: edges, hasFaderCapture: hasFaderCapture)
    }
}

// MARK: - Grade

/// Presentation-only banding of `ScratchPerformanceScore.overall` — a
/// gameplay/UI cut point, not an analysis threshold. No repository-wide
/// grade convention exists to defer to; the closest precedent is
/// `NotationFeedbackState`'s 90/70 excellent/correct split, reused here at
/// the S/B boundaries. 80 and 60 are new gameplay-presentation cut points.
enum PracticeAttemptGrade: String, Equatable, Sendable, CaseIterable {
    case s, a, b, c
    case keepPracticing

    /// Bands `overall` (expected in `[0, 100]`, but any finite value is
    /// accepted) into a grade. Never called with a `nil` overall — see
    /// `PracticeAttemptResult.grade`, which stays `nil` rather than banding
    /// an unassessable attempt into a fake grade.
    init(overall: Double) {
        switch overall {
        case 90...: self = .s
        case 80..<90: self = .a
        case 70..<80: self = .b
        case 60..<70: self = .c
        default: self = .keepPracticing
        }
    }
}

// MARK: - Attempt result

/// One deterministic gameplay attempt: exactly one canonical target cycle,
/// compared against the performed evidence captured inside `window`.
///
/// This wraps `ScratchPerformanceComparisonResult` / `ScratchPerformanceScore`
/// verbatim — the only new derived facts are `directionScore` and
/// `faderScore`, both plain views over counts `ScratchPerformanceScore`
/// already computed (the same "mean of the sub-scores that exist" rule
/// `ScratchPerformanceScore.overall` already establishes), and `grade`, a
/// presentation-only banding of `score.overall`. Nothing here re-judges
/// correctness independently of the comparison result.
struct PracticeAttemptResult: Equatable, Sendable {
    let techniqueID: String
    let bpm: Double
    let window: GameplayAttemptWindow
    let comparison: ScratchPerformanceComparisonResult
    let score: ScratchPerformanceScore
    /// `NotationFeedbackState.coachingMessages(for:)` verbatim — no second
    /// coaching engine.
    let coaching: [String]
    /// Priority-ordered semantic errors derived from `comparison` via
    /// `SemanticError.derive` — the formal TIMING / PLATTER / FADER error
    /// language the result surface renders. Purely a projection of
    /// `comparison`; nothing here re-judges correctness.
    let semanticErrors: [SemanticError]

    /// `score.overall`, unmodified.
    var overallScore: Double? { score.overall }
    /// `score.platterTiming`, unmodified.
    var timingScore: Double? { score.platterTiming }
    /// `score.platterCompleteness`, unmodified — already bakes in
    /// wrong-direction cost as well as missing/extra strokes (see
    /// `ScratchPerformanceScore.platterCompleteness`'s own documentation).
    var completionScore: Double? { score.platterCompleteness }
    /// Derived, not independently judged: the correct-direction share of the
    /// matched strokes whose performed direction was determinate at all.
    /// `nil` when no matched stroke had a determinate direction — direction
    /// was never assessed, never assumed correct.
    var directionScore: Double? {
        guard score.assessedDirectionCount > 0 else { return nil }
        let correct = score.assessedDirectionCount - score.wrongDirectionCount
        return Double(correct) / Double(score.assessedDirectionCount) * 100
    }
    /// Mean of `faderTiming` / `faderCompleteness` when at least one exists
    /// — the same "mean of the sub-scores that exist" rule
    /// `ScratchPerformanceScore.overall` already uses. `nil` when the fader
    /// channel was not `.compared` (unauthored target channel or uncaptured
    /// performed evidence) — never a fake fader score.
    var faderScore: Double? {
        let parts = [score.faderTiming, score.faderCompleteness].compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0, +) / Double(parts.count)
    }
    /// Presentation-only band over `score.overall`; `nil` when nothing in
    /// the attempt was comparable at all — never a fake grade.
    var grade: PracticeAttemptGrade? { score.overall.map(PracticeAttemptGrade.init(overall:)) }
    /// True when at least one axis produced a real (non-`nil`) sub-score,
    /// i.e. the attempt has something to show the player rather than a
    /// blank result.
    var isAssessable: Bool { score.overall != nil }
}

// MARK: - Attempt builder

enum PracticeAttemptBuilder {

    /// Builds the `cycleIndex`-th (0-based) attempt for `pattern` from
    /// full-take performed evidence, following the same clock/threshold/
    /// window conventions `MacAnalyzerView.reviewPerformanceComparison`
    /// already uses, but scoped to one canonical cycle's window rather than
    /// a whole-take tiled comparison.
    ///
    /// `nil` when the pattern/tempo/windows can't be constructed, matching
    /// the comparison engine's own "never guess, report unavailable"
    /// convention — callers present that as "not assessable yet", not a
    /// zero-score attempt.
    static func attempt(
        techniqueID: String,
        pattern: ScratchNotation.BeatPattern,
        bpm: Double,
        cycleIndex: Int,
        performed: PerformedScratchTimeline,
        strokeCorrectToleranceBeats: Double,
        faderCorrectToleranceBeats: Double
    ) -> PracticeAttemptResult? {
        guard bpm.isFinite, bpm > 0 else { return nil }
        guard let target = TargetScratchPhrase.phrase(repeating: pattern, cycles: 1) else { return nil }
        guard let window = GameplayAttemptWindow(
            cycleIndex: cycleIndex, cycleDurationBeats: pattern.durationBeats
        ) else { return nil }
        guard let windows = ScratchComparisonWindows.derived(
            from: target,
            strokeCorrectToleranceBeats: strokeCorrectToleranceBeats,
            faderCorrectToleranceBeats: faderCorrectToleranceBeats
        ) else { return nil }
        let windowedPerformed = performed.windowed(to: window)
        guard let result = ScratchPerformanceAlignment.compare(
            target: target, performed: windowedPerformed, windows: windows, bpm: bpm
        ) else { return nil }
        let score = ScratchPerformanceScore.score(result: result, windows: windows)
        let coaching = NotationFeedbackState.coachingMessages(for: result, limit: 3)
        // Semantic error derivation is a pure projection of `result`; the
        // clock argument only anchors `beatPosition` (currently beat-relative
        // and unused by any seconds consumer). A cycle-0 attempt aligns
        // pattern beat 0 with window beat 0, so a zero anchor is the correct
        // frame for the single-cycle attempt this builder produces.
        let semanticErrors = PerformanceBeatClock(bpm: bpm, beatZeroTime: 0)
            .map { SemanticError.derive(from: result, target: target, performed: windowedPerformed, clock: $0) }
            ?? []
        return PracticeAttemptResult(
            techniqueID: techniqueID,
            bpm: bpm,
            window: window,
            comparison: result,
            score: score,
            coaching: coaching,
            semanticErrors: semanticErrors
        )
    }
}

// MARK: - Evidence resolution (capture snapshot → attempt)

/// Turns a captured `CaptureCore.DetectedNotationSnapshot` — macOS's only
/// evidence source, populated once a take finishes (see
/// `MacCaptureEngine.lastRoutineDetectedNotation`) — into one cycle-0
/// `PracticeAttemptResult`. This is the single place the clock/threshold
/// conventions `MacAnalyzerView`'s Review preview originated are decided, so
/// every consumer (the post-hoc Review preview and the live gameplay
/// coordinator) agrees, rather than two independent copies that could
/// drift apart.
enum PracticeAttemptEvidenceResolver {

    /// Schmitt-trigger thresholds for deriving performed open/closed fader
    /// edges from raw crossfader MIDI: a symmetric band (0.4–0.6) around
    /// mid-travel, wide enough that jitter inside it never oscillates the
    /// derived state. No repository-wide open/closed cut point exists —
    /// this is the one place it's decided for live/attempt evidence.
    static let faderOpenAtOrAbove = 0.6
    static let faderClosedAtOrBelow = 0.4

    /// Builds the cycle-0 attempt for `pattern` from a finished take's
    /// evidence. `nil` under the same "never guess" conditions
    /// `PracticeAttemptBuilder`/`PerformanceBeatClock` already report as
    /// unavailable (unusable tempo, no movement evidence in the take at
    /// all, unusable clock/threshold construction) — callers present that
    /// as "not assessable yet", never a zero-score attempt.
    static func firstCycleAttempt(
        pattern: ScratchNotation.BeatPattern,
        bpm: Double,
        countInBeats: Int,
        snapshot: CaptureCore.DetectedNotationSnapshot
    ) -> PracticeAttemptResult? {
        guard bpm.isFinite, bpm > 0 else { return nil }
        guard !snapshot.recordMovementEvents.isEmpty else { return nil }
        // Beat 0 of the click (incl. count-in) is at take-relative 0 in both
        // click engines; the target phrase starts on the first post-count-in
        // beat, so the anchor skips the configured count-in.
        guard let clock = PerformanceBeatClock(
            bpm: bpm, beatZeroTime: Double(countInBeats) * 60.0 / bpm
        ) else { return nil }
        guard let thresholds = PerformedFaderEdgeThresholds(
            openAtOrAbove: faderOpenAtOrAbove, closedAtOrBelow: faderClosedAtOrBelow
        ) else { return nil }
        let performed = PerformedScratchTimelineAdapter.makeTimeline(
            movementEvents: snapshot.recordMovementEvents,
            mixerMidiEvents: snapshot.mixerMidiEvents,
            clock: clock,
            faderThresholds: thresholds
        )
        // Same ±50 ms convention `NotationFeedbackState` already establishes,
        // converted to beats at this session's tempo.
        let toleranceBeats = NotationFeedbackState.lateOffsetThresholdMs * bpm / 60_000.0
        return PracticeAttemptBuilder.attempt(
            techniqueID: pattern.scratchID,
            pattern: pattern,
            bpm: bpm,
            cycleIndex: 0,
            performed: performed,
            strokeCorrectToleranceBeats: toleranceBeats,
            faderCorrectToleranceBeats: toleranceBeats
        )
    }
}
