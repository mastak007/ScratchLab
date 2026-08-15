// Tests for ScratchGameplayAttempt — the per-attempt gameplay wrapper built
// directly on ScratchPerformanceComparison. All fixtures are synthetic and
// deterministic; the target side is `ScratchNotation.babyScratchCycle`
// (production registry value) or a hand-built fadered pattern with the same
// geometry when a canonical fader channel is needed (babyScratchCycle
// authors none).

import Foundation
import SwiftUI
import Testing
@testable import ScratchLab

// MARK: - Shared fixtures

private let fixtureBPM = 100.0 // 1 beat = 600 ms
private let toleranceBeats = 0.05 // 30 ms at 100 BPM

private func stroke(
    start: Double,
    end: Double,
    direction: ScratchNotationDirection?,
    confidence: Double = 0.9,
    source: String = "timecode_live"
) -> PerformedScratchTimeline.Stroke {
    .init(startBeat: start, endBeat: end, direction: direction, confidence: confidence, source: source)
}

private func faderEdge(
    beat: Double,
    state: ScratchNotationFaderState,
    source: String = "midi"
) -> PerformedScratchTimeline.FaderEdge {
    .init(beat: beat, state: state, source: source)
}

/// Same geometry as `ScratchNotation.babyScratchCycle` (forward 0–0.5,
/// backward 0.5–1.0) plus an authored fader channel (open at 0, closed at
/// 0.5) — `babyScratchCycle` deliberately authors none, so fader-axis tests
/// need this instead.
private let faderedPattern = ScratchNotation.BeatPattern(
    version: 1,
    scratchID: "test_fadered_baby",
    timingBasis: "beat_canonical_cycle_v1",
    beatsPerBar: nil,
    strokes: [
        .init(startBeat: 0.0, endBeat: 0.5,
              direction: .forward, speedClassification: .medium, faderState: .open),
        .init(startBeat: 0.5, endBeat: 1.0,
              direction: .backward, speedClassification: .medium, faderState: .closed)
    ],
    faderEvents: [
        .init(beat: 0.0, state: .open),
        .init(beat: 0.5, state: .closed)
    ]
)

private func attempt(
    pattern: ScratchNotation.BeatPattern = ScratchNotation.babyScratchCycle,
    cycleIndex: Int = 0,
    strokes: [PerformedScratchTimeline.Stroke],
    faderEdges: [PerformedScratchTimeline.FaderEdge] = [],
    hasFaderCapture: Bool = false
) -> PracticeAttemptResult? {
    PracticeAttemptBuilder.attempt(
        techniqueID: pattern.scratchID,
        pattern: pattern,
        bpm: fixtureBPM,
        cycleIndex: cycleIndex,
        performed: .init(strokes: strokes, faderEdges: faderEdges, hasFaderCapture: hasFaderCapture),
        strokeCorrectToleranceBeats: toleranceBeats,
        faderCorrectToleranceBeats: toleranceBeats
    )
}

private func expectApproximatelyEqual(_ lhs: Double?, _ rhs: Double, tolerance: Double = 1e-9,
                                      sourceLocation: SourceLocation = #_sourceLocation) {
    guard let lhs else {
        Issue.record("expected \(rhs), got nil", sourceLocation: sourceLocation)
        return
    }
    #expect(abs(lhs - rhs) < tolerance, sourceLocation: sourceLocation)
}

// MARK: - Attempt scoring

@Suite("PracticeAttemptResult scoring")
struct PracticeAttemptResultScoringTests {

    @Test("Perfect attempt: full timing, completion, direction; no fader channel")
    func perfectAttempt() {
        let result = attempt(strokes: [
            stroke(start: 0.0, end: 0.5, direction: .forward),
            stroke(start: 0.5, end: 1.0, direction: .backward)
        ])
        let attempt = try! #require(result)
        expectApproximatelyEqual(attempt.timingScore, 100)
        expectApproximatelyEqual(attempt.completionScore, 100)
        expectApproximatelyEqual(attempt.directionScore, 100)
        #expect(attempt.faderScore == nil)
        expectApproximatelyEqual(attempt.overallScore, 100)
        #expect(attempt.grade == .s)
        #expect(attempt.isAssessable)
    }

    @Test("Early stroke pulls timing score down and is verdict .early")
    func earlyStroke() {
        let result = attempt(strokes: [
            stroke(start: 0.0, end: 0.5, direction: .forward),
            stroke(start: 0.4, end: 0.9, direction: .backward) // target start 0.5, 0.1 beat early
        ])
        let attempt = try! #require(result)
        #expect(attempt.comparison.matchedStrokes.count == 2)
        #expect(attempt.comparison.matchedStrokes[1].timing == .early)
        expectApproximatelyEqual(attempt.timingScore, 80) // mean(100, 60)
        expectApproximatelyEqual(attempt.completionScore, 100)
    }

    @Test("Late stroke pulls timing score down and is verdict .late")
    func lateStroke() {
        let result = attempt(strokes: [
            stroke(start: 0.0, end: 0.5, direction: .forward),
            stroke(start: 0.6, end: 1.0, direction: .backward) // target start 0.5, 0.1 beat late
        ])
        let attempt = try! #require(result)
        #expect(attempt.comparison.matchedStrokes.count == 2)
        #expect(attempt.comparison.matchedStrokes[1].timing == .late)
        expectApproximatelyEqual(attempt.timingScore, 80) // mean(100, 60)
    }

    @Test("Wrong direction costs direction and completion scores, not timing")
    func wrongDirection() {
        let result = attempt(strokes: [
            stroke(start: 0.0, end: 0.5, direction: .backward), // wrong way
            stroke(start: 0.5, end: 1.0, direction: .backward)
        ])
        let attempt = try! #require(result)
        expectApproximatelyEqual(attempt.timingScore, 100)
        expectApproximatelyEqual(attempt.directionScore, 50) // 1 of 2 assessed correct
        expectApproximatelyEqual(attempt.completionScore, 50) // (2 matched - 1 wrong) / (2 target + 0 extra)
        expectApproximatelyEqual(attempt.overallScore, 75) // mean(100, 50)
        #expect(attempt.grade == .b)
    }

    @Test("Missing stroke reduces completion, never fabricates a matched stroke")
    func missingStroke() {
        let result = attempt(strokes: [
            stroke(start: 0.0, end: 0.5, direction: .forward)
            // backward stroke never performed
        ])
        let attempt = try! #require(result)
        #expect(attempt.comparison.matchedStrokes.count == 1)
        #expect(attempt.comparison.missingTargetStrokeIndices == [1])
        expectApproximatelyEqual(attempt.timingScore, 100) // computed only from the one match
        expectApproximatelyEqual(attempt.completionScore, 50) // 1 matched / (2 target + 0 extra)
        #expect(attempt.grade == .b)
    }

    @Test("Extra stroke is reported, never silently absorbed into a target slot")
    func extraStroke() {
        let result = attempt(strokes: [
            stroke(start: 0.0, end: 0.5, direction: .forward),
            stroke(start: 0.5, end: 1.0, direction: .backward),
            stroke(start: 0.85, end: 0.95, direction: .forward) // no target here
        ])
        let attempt = try! #require(result)
        #expect(attempt.comparison.extraPerformedStrokeIndices == [2])
        expectApproximatelyEqual(attempt.completionScore, 200.0 / 3.0) // 2 matched / (2 target + 1 extra)
    }

    @Test("Fader edge early is verdict .early and lowers fader timing")
    func faderEarly() {
        let result = attempt(
            pattern: faderedPattern,
            strokes: [
                stroke(start: 0.0, end: 0.5, direction: .forward),
                stroke(start: 0.5, end: 1.0, direction: .backward)
            ],
            faderEdges: [
                faderEdge(beat: 0.0, state: .open),
                faderEdge(beat: 0.4, state: .closed) // target 0.5, 0.1 beat early
            ],
            hasFaderCapture: true
        )
        let attempt = try! #require(result)
        guard case .compared(let matched, _, _) = attempt.comparison.faderChannel else {
            Issue.record("expected a compared fader channel"); return
        }
        #expect(matched.count == 2)
        #expect(matched[1].timing == .early)
        expectApproximatelyEqual(attempt.faderScore, 90) // mean(faderTiming 80, faderCompleteness 100)
    }

    @Test("Fader edge late is verdict .late and lowers fader timing")
    func faderLate() {
        let result = attempt(
            pattern: faderedPattern,
            strokes: [
                stroke(start: 0.0, end: 0.5, direction: .forward),
                stroke(start: 0.5, end: 1.0, direction: .backward)
            ],
            faderEdges: [
                faderEdge(beat: 0.0, state: .open),
                faderEdge(beat: 0.6, state: .closed) // target 0.5, 0.1 beat late
            ],
            hasFaderCapture: true
        )
        let attempt = try! #require(result)
        guard case .compared(let matched, _, _) = attempt.comparison.faderChannel else {
            Issue.record("expected a compared fader channel"); return
        }
        #expect(matched[1].timing == .late)
        expectApproximatelyEqual(attempt.faderScore, 90)
    }

    @Test("Missing fader edge reduces fader completeness, not timing of the edge that did match")
    func missingFaderEdge() {
        let result = attempt(
            pattern: faderedPattern,
            strokes: [
                stroke(start: 0.0, end: 0.5, direction: .forward),
                stroke(start: 0.5, end: 1.0, direction: .backward)
            ],
            faderEdges: [
                faderEdge(beat: 0.0, state: .open)
                // closed edge never captured
            ],
            hasFaderCapture: true
        )
        let attempt = try! #require(result)
        guard case .compared(_, let missing, _) = attempt.comparison.faderChannel else {
            Issue.record("expected a compared fader channel"); return
        }
        #expect(missing == [1])
        expectApproximatelyEqual(attempt.faderScore, 75) // mean(faderTiming 100, faderCompleteness 50)
    }

    @Test("Combined missing + extra stroke is a genuine completion difference")
    func completionDifference() {
        let result = attempt(strokes: [
            stroke(start: 0.0, end: 0.5, direction: .forward),
            // backward stroke missing
            stroke(start: 0.85, end: 0.95, direction: .forward) // extra
        ])
        let attempt = try! #require(result)
        #expect(attempt.comparison.missingTargetStrokeIndices == [1])
        #expect(attempt.comparison.extraPerformedStrokeIndices == [1])
        expectApproximatelyEqual(attempt.completionScore, 100.0 / 3.0) // 1 matched / (2 target + 1 extra)
    }

    @Test("Unassessed axes stay nil, never a fabricated zero")
    func unassessedAxesStayNil() {
        // Empty performed evidence: nothing matched, so timing/direction/
        // fader are unassessable, but completeness is a real, assessed 0%
        // (the target had strokes, none were performed) — the two must not
        // be conflated.
        let result = attempt(strokes: [])
        let attempt = try! #require(result)
        #expect(attempt.timingScore == nil)
        #expect(attempt.directionScore == nil)
        #expect(attempt.faderScore == nil)
        expectApproximatelyEqual(attempt.completionScore, 0)
        expectApproximatelyEqual(attempt.overallScore, 0) // mean of the one real sub-score
        #expect(attempt.isAssessable) // overall IS assessable — it's a real 0%, not "no data"
        #expect(attempt.grade == .keepPracticing)
    }
}

// MARK: - Grade boundaries

@Suite("PracticeAttemptGrade boundaries")
struct PracticeAttemptGradeBoundaryTests {

    @Test("Grade bands", arguments: [
        (59.99, PracticeAttemptGrade.keepPracticing),
        (60.0, .c),
        (69.99, .c),
        (70.0, .b),
        (79.99, .b),
        (80.0, .a),
        (89.99, .a),
        (90.0, .s),
        (100.0, .s)
    ])
    func gradeBoundary(overall: Double, expected: PracticeAttemptGrade) {
        #expect(PracticeAttemptGrade(overall: overall) == expected)
    }
}

// MARK: - Attempt window

@Suite("GameplayAttemptWindow cycle isolation")
struct GameplayAttemptWindowTests {

    @Test("One-cycle attempt window does not consume events belonging to the next cycle")
    func windowDoesNotLeakAcrossCycles() {
        // A two-cycle performance, perfectly played, laid out back to back:
        // cycle 0 in [0, 1.0), cycle 1 in [1.0, 2.0).
        let performed: [PerformedScratchTimeline.Stroke] = [
            stroke(start: 0.0, end: 0.5, direction: .forward),
            stroke(start: 0.5, end: 1.0, direction: .backward),
            stroke(start: 1.0, end: 1.5, direction: .forward),
            stroke(start: 1.5, end: 2.0, direction: .backward)
        ]

        let cycle0 = attempt(cycleIndex: 0, strokes: performed)
        let a0 = try! #require(cycle0)
        #expect(a0.comparison.matchedStrokes.count == 2)
        #expect(a0.comparison.extraPerformedStrokeIndices.isEmpty)
        #expect(a0.comparison.missingTargetStrokeIndices.isEmpty)
        expectApproximatelyEqual(a0.timingScore, 100)

        let cycle1 = attempt(cycleIndex: 1, strokes: performed)
        let a1 = try! #require(cycle1)
        #expect(a1.comparison.matchedStrokes.count == 2)
        #expect(a1.comparison.extraPerformedStrokeIndices.isEmpty)
        #expect(a1.comparison.missingTargetStrokeIndices.isEmpty)
        expectApproximatelyEqual(a1.timingScore, 100)
    }

    @Test("Cycle window bounds are exclusive at the end, inclusive at the start")
    func windowWindow() {
        let window = try! #require(GameplayAttemptWindow(cycleIndex: 0, cycleDurationBeats: 1.0))
        #expect(window.startBeat == 0.0)
        #expect(window.endBeat == 1.0)
        let next = try! #require(GameplayAttemptWindow(cycleIndex: 1, cycleDurationBeats: 1.0))
        #expect(next.startBeat == 1.0)
    }
}

// MARK: - Determinism

@Suite("PracticeAttemptResult determinism")
struct PracticeAttemptResultDeterminismTests {

    @Test("Same input produces an equal AttemptResult")
    func deterministicRepeat() {
        let strokes: [PerformedScratchTimeline.Stroke] = [
            stroke(start: 0.02, end: 0.5, direction: .forward),
            stroke(start: 0.55, end: 1.0, direction: .backward)
        ]
        let first = attempt(strokes: strokes)
        let second = attempt(strokes: strokes)
        #expect(first != nil)
        #expect(first == second)
    }
}

// MARK: - Practice result notation capability

@Suite("PracticeResultNotation capability")
struct PracticeResultNotationCapabilityTests {

    private func movementEvent() -> CaptureCore.DetectedNotationRecordMovementEvent {
        .init(startTime: 0, endTime: 0.5, startPosition: 0.2, endPosition: 0.6,
              direction: "forward", movementKind: .normalPush, speed: 1.0,
              confidence: 0.9, source: "timecode_live")
    }

    @Test("Empty movement evidence resolves to targetOnly, never a fabricated trace")
    func emptyEventsResolveToTargetOnly() {
        #expect(PracticeResultNotation.resolve(performedMovementEvents: []) == .targetOnly)
    }

    @Test("Present movement evidence resolves to a real comparison")
    func presentEventsResolveToComparison() {
        let event = movementEvent()
        #expect(PracticeResultNotation.resolve(performedMovementEvents: [event])
            == .comparison(performed: [event]))
    }

    @Test("targetOnly carries no performed payload to fabricate a trace from")
    func targetOnlyHasNoPayload() {
        if case .comparison = PracticeResultNotation.resolve(performedMovementEvents: []) {
            Issue.record("empty events must never resolve to a comparison")
        }
    }

    @Test("Capability resolution is evidence-driven, independent of a canonical target")
    func resolutionIgnoresTargetPresence() {
        #expect(ScratchNotation.canonicalBeatPattern(forScratchID: "baby_scratch") != nil)
        #expect(ScratchNotation.canonicalBeatPattern(forScratchID: "no_such_technique") == nil)
        // The decision is identical regardless of whether a target exists.
        #expect(PracticeResultNotation.resolve(performedMovementEvents: []) == .targetOnly)
    }

    @Test("Capability resolution and materialization never mutate canonical notation")
    func resolutionDoesNotMutateCanonicalNotation() throws {
        let materialized = try #require(
            ScratchNotation.canonicalBeatPattern(forScratchID: "baby_scratch")?.materialized(bpm: 90))
        let before = materialized
        _ = PracticeResultNotation.resolve(performedMovementEvents: [])
        _ = materialized.timelineDuration
        _ = materialized.faderAuthoritySpans(documentEnd: materialized.timelineDuration)
        #expect(materialized == before)
    }
}

// MARK: - Practice review summary

@Suite("PracticeReviewSummary review evidence")
struct PracticeReviewSummaryTests {

    @Test("No detections yields noSignal and no coaching line")
    func noEvidence() {
        let s = PracticeReviewSummary(attempts: 0, averageAccuracy: 0, onBeatCount: 0,
                                      earlyCount: 0, lateCount: 0)
        #expect(!s.hasEvidence)
        #expect(s.timingDirection == .noSignal)
        #expect(s.onBeatRate == nil)
        #expect(s.coachingLine == nil)
    }

    @Test("Dominant early off-beat detections yield .early and the early coaching voice")
    func dominantEarly() {
        let s = PracticeReviewSummary(attempts: 10, averageAccuracy: 60, onBeatCount: 4,
                                      earlyCount: 5, lateCount: 1)
        #expect(s.timingDirection == .early)
        #expect(s.coachingLine?.contains("early") == true)
    }

    @Test("Dominant late off-beat detections yield .late and the late coaching voice")
    func dominantLate() {
        let s = PracticeReviewSummary(attempts: 10, averageAccuracy: 60, onBeatCount: 4,
                                      earlyCount: 1, lateCount: 5)
        #expect(s.timingDirection == .late)
        #expect(s.coachingLine?.contains("late") == true)
    }

    @Test("Balanced early/late resolves to onBeat, never a fabricated direction")
    func balancedOffBeatIsOnBeat() {
        let s = PracticeReviewSummary(attempts: 10, averageAccuracy: 60, onBeatCount: 4,
                                      earlyCount: 3, lateCount: 3)
        #expect(s.timingDirection == .onBeat)
    }

    @Test("On-beat rate is derived from real counts, not a constant")
    func onBeatRateIsDerived() {
        let s = PracticeReviewSummary(attempts: 12, averageAccuracy: 82, onBeatCount: 9,
                                      earlyCount: 2, lateCount: 1)
        #expect(abs((s.onBeatRate ?? 0) - 9.0 / 12.0) < 1e-9)
    }

    @Test("Coaching line reuses the established 70/90 accuracy tiers")
    func coachingTiers() {
        #expect(PracticeReviewSummary(attempts: 5, averageAccuracy: 65, onBeatCount: 5,
                                      earlyCount: 0, lateCount: 0).coachingLine
            == "Slow it down and focus on one smooth forward-and-back motion.")
        #expect(PracticeReviewSummary(attempts: 5, averageAccuracy: 75, onBeatCount: 5,
                                      earlyCount: 0, lateCount: 0).coachingLine
            == "Your timing was good. Repeat the motion more consistently.")
        #expect(PracticeReviewSummary(attempts: 5, averageAccuracy: 91, onBeatCount: 5,
                                      earlyCount: 0, lateCount: 0).coachingLine
            == "Good timing and a clean match.")
    }

    @Test("Headline is a semantic outcome, never a fabricated direction")
    func headlineTiers() {
        #expect(PracticeReviewSummary(attempts: 0, averageAccuracy: 0, onBeatCount: 0,
                                      earlyCount: 0, lateCount: 0).headline == "No scratches detected")
        #expect(PracticeReviewSummary(attempts: 5, averageAccuracy: 65, onBeatCount: 5,
                                      earlyCount: 0, lateCount: 0).headline == "Keep practicing")
        #expect(PracticeReviewSummary(attempts: 5, averageAccuracy: 75, onBeatCount: 5,
                                      earlyCount: 0, lateCount: 0).headline == "Good timing")
        #expect(PracticeReviewSummary(attempts: 5, averageAccuracy: 91, onBeatCount: 5,
                                      earlyCount: 0, lateCount: 0).headline == "Nice control")
        #expect(PracticeReviewSummary(attempts: 10, averageAccuracy: 60, onBeatCount: 4,
                                      earlyCount: 5, lateCount: 1).headline == "A touch early")
        #expect(PracticeReviewSummary(attempts: 10, averageAccuracy: 60, onBeatCount: 4,
                                      earlyCount: 1, lateCount: 5).headline == "A touch late")
    }
}

// MARK: - Practice result truthfulness (source-string regression)

@Suite("Practice result truthfulness (source-string)")
struct PracticeResultTruthfulnessSourceTests {

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("Figma sample values are not embedded in the Result view")
    func noFigmaSampleValues() throws {
        let practice = try source("ScratchLab/Views/PracticeModeView.swift")
        #expect(!practice.contains("\"82% accuracy\""))
        #expect(!practice.contains("Average offset 34 ms"))
        #expect(!practice.contains("12 on-beat hits"))
    }

    @Test("The Result view routes to the capability decision, not a platform fork")
    func resultUsesCapabilityResolver() throws {
        let practice = try source("ScratchLab/Views/PracticeModeView.swift")
        #expect(practice.contains("PracticeResultNotation.resolve(performedMovementEvents:"))
        #expect(practice.contains("PracticeResultNotationSection(target: targetNotation"))
    }

    @Test("The Result hierarchy is V3.2 (eyebrow + Done), not the legacy overlay")
    func resultHierarchyIsV32() throws {
        let practice = try source("ScratchLab/Views/PracticeModeView.swift")
        #expect(practice.contains("RESULT · LOCAL"))
        #expect(practice.contains("Text(\"Done\")"))
        #expect(!practice.contains("\"Back to Level\""))
    }

    @Test("Baby Scratch target fader stays OPEN throughout")
    func babyScratchFaderStaysOpen() throws {
        let notation = try #require(
            ScratchNotation.canonicalBeatPattern(forScratchID: "baby_scratch")?.materialized(bpm: 90))
        let spans = notation.faderAuthoritySpans(documentEnd: notation.timelineDuration)
        #expect(!spans.isEmpty)
        #expect(spans.allSatisfy { $0.state == .open })
        #expect(!spans.contains { $0.state == .closed })
    }
}

// MARK: - Adaptive layout policy

@Suite("ScratchLabAdaptiveLayout")
struct ScratchLabAdaptiveLayoutTests {

    @Test("Compact horizontal resolves to compact mode")
    func compactHorizontal() {
        let mode = ScratchLabAdaptiveLayout.layoutMode(
            horizontalSizeClass: .compact, verticalSizeClass: .regular)
        #expect(mode == .compact)
    }

    @Test("Regular horizontal + compact vertical resolves to regular landscape")
    func regularLandscape() {
        let mode = ScratchLabAdaptiveLayout.layoutMode(
            horizontalSizeClass: .regular, verticalSizeClass: .compact)
        #expect(mode == .regularLandscape)
    }

    @Test("Regular + regular resolves to portrait")
    func portrait() {
        let mode = ScratchLabAdaptiveLayout.layoutMode(
            horizontalSizeClass: .regular, verticalSizeClass: .regular)
        #expect(mode == .portrait)
    }

    @Test("Notation is Compact only in compact mode, Standard otherwise")
    func notationPresentation() {
        #expect(ScratchLabAdaptiveLayout.notationPresentation(for: .compact) == .compact)
        #expect(ScratchLabAdaptiveLayout.notationPresentation(for: .portrait) == .standard)
        #expect(ScratchLabAdaptiveLayout.notationPresentation(for: .regularLandscape) == .standard)
    }

    @Test("Sidebar is shown only in regular landscape")
    func sidebarSelection() {
        #expect(ScratchLabAdaptiveLayout.usesNavigationSidebar(for: .regularLandscape) == true)
        #expect(ScratchLabAdaptiveLayout.usesNavigationSidebar(for: .portrait) == false)
        #expect(ScratchLabAdaptiveLayout.usesNavigationSidebar(for: .compact) == false)
    }

    @Test("Mapping is deterministic across repeated calls")
    func deterministicMapping() {
        let a = ScratchLabAdaptiveLayout.layoutMode(horizontalSizeClass: .regular, verticalSizeClass: .compact)
        let b = ScratchLabAdaptiveLayout.layoutMode(horizontalSizeClass: .regular, verticalSizeClass: .compact)
        #expect(a == b)
    }
}
