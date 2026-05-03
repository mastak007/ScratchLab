import Testing
@testable import ScratchLab

// MARK: - Helpers

private func babyScratchNotation() -> ScratchNotation {
    // Minimal inline Baby Scratch notation matching the real bundle data shape.
    // 4-stroke phrase: fwd 0.0→0.2, back 0.3→0.5, fwd 0.6→0.8, back 0.9→1.0
    let strokes: [ScratchNotation.Stroke] = [
        .init(startTime: 0.0, endTime: 0.2, direction: .forward,  speedClassification: .slow,   faderState: .open),
        .init(startTime: 0.3, endTime: 0.5, direction: .backward, speedClassification: .medium, faderState: .open),
        .init(startTime: 0.6, endTime: 0.8, direction: .forward,  speedClassification: .fast,   faderState: .open),
        .init(startTime: 0.9, endTime: 1.0, direction: .backward, speedClassification: .fast,   faderState: .open),
    ]
    return ScratchNotation(
        version: 1,
        scratchID: "test_baby",
        demoStart: 0,
        demoEnd: 1.0,
        phraseStart: 0,
        phraseEnd: 1.2,
        timingBasis: "test",
        strokes: strokes
    )
}

private func makeTimeline() -> ScratchNotationTimeline {
    ScratchNotationTimeline(notation: babyScratchNotation())
}

// MARK: - Tests

@Suite("ScratchNotationTimeline")
struct ScratchNotationTimelineTests {

    @Test("Baby Scratch alternates Forward / Back strokes")
    func alternatingDirections() {
        let timeline = makeTimeline()
        let dirs = timeline.notation.strokes.map(\.direction)
        #expect(dirs == [.forward, .backward, .forward, .backward])
    }

    @Test("Stroke lookup at startTime returns that stroke")
    func strokeLookupAtStart() {
        let timeline = makeTimeline()
        let (idx, dir, progress) = timeline.currentStrokeInfo(at: 0.0)
        #expect(idx == 0)
        #expect(dir == .forward)
        #expect(progress == 0.0)
    }

    @Test("Stroke lookup at endTime returns that stroke with progress ≈ 1")
    func strokeLookupAtEnd() {
        let timeline = makeTimeline()
        let (idx, dir, progress) = timeline.currentStrokeInfo(at: 0.2)
        #expect(idx == 0)
        #expect(dir == .forward)
        #expect(progress >= 0.99)
    }

    @Test("Stroke lookup in gap returns nil")
    func strokeLookupInGap() {
        let timeline = makeTimeline()
        let (idx, dir, _) = timeline.currentStrokeInfo(at: 0.25)
        #expect(idx == nil)
        #expect(dir == nil)
    }

    @Test("LoopTime calculation wraps at phraseEnd")
    func loopTimeCalculation() {
        let timeline = makeTimeline()
        let loop = timeline.loopDuration   // 1.2
        #expect(abs(loop - 1.2) < 0.001)
    }

    @Test("Advance fires boundary on first tick crossing stroke startTime")
    func advanceFiresBoundary() {
        let timeline = makeTimeline()
        // Advance from just before stroke 0 start to just after
        let state = timeline.advance(to: 0.05, previousLoopTime: -0.01)
        #expect(state.isAtStrokeBoundary)
        #expect(state.currentStrokeIndex == 0)
        #expect(state.currentTargetDirection == .forward)
    }

    @Test("Advance does NOT re-fire boundary for same stroke on next tick")
    func noDuplicateBoundaryEvent() {
        let timeline = makeTimeline()
        let s1 = timeline.advance(to: 0.05, previousLoopTime: -0.01)
        #expect(s1.isAtStrokeBoundary)
        let s2 = timeline.advance(to: 0.10, previousLoopTime: 0.05)
        #expect(!s2.isAtStrokeBoundary)
    }

    @Test("Loop wrap resets fired stroke tracking")
    func loopWrapResetsTracking() {
        let timeline = makeTimeline()
        // Advance past all strokes
        _ = timeline.advance(to: 0.05, previousLoopTime: 0.0)
        _ = timeline.advance(to: 0.35, previousLoopTime: 0.05)
        _ = timeline.advance(to: 0.65, previousLoopTime: 0.35)
        _ = timeline.advance(to: 0.95, previousLoopTime: 0.65)
        #expect(timeline.lastFiredStrokeIndices.count == 3)
        
        // Simulate wrap: newLoopTime < previousLoopTime
        let afterWrap = timeline.advance(to: 0.01, previousLoopTime: 1.15)
        #expect(timeline.loopIndex == 1)
        #expect(afterWrap.isAtStrokeBoundary)  // stroke 0 fires again
    }

    @Test("First stroke of next loop fires correctly after wrap")
    func firstStrokeFiresAfterWrap() {
        let timeline = makeTimeline()
        // Run through the whole loop
        _ = timeline.advance(to: 0.05, previousLoopTime: 0.0)
        _ = timeline.advance(to: 0.35, previousLoopTime: 0.05)
        _ = timeline.advance(to: 0.65, previousLoopTime: 0.35)
        _ = timeline.advance(to: 0.95, previousLoopTime: 0.65)

        // Wrap: go from 1.15 → 0.05
        let state = timeline.advance(to: 0.05, previousLoopTime: 1.15)
        #expect(state.loopIndex == 1)
        #expect(state.currentStrokeIndex == 0)
        #expect(state.currentTargetDirection == .forward)
        #expect(state.isAtStrokeBoundary)
    }

    @Test("Target stroke can be recorded while observed motion is idle")
    func targetStrokeIndependentOfMotion() {
        // This is a data-model test: targetDirection comes from notation, not motion.
        let timeline = makeTimeline()
        let dir = timeline.targetDirection(at: 0.1)
        // Direction is forward regardless of any observed hand state.
        #expect(dir == .forward)
    }

    @Test("Observed motion does not change target direction")
    func targetNotationIsImmutable() {
        let timeline = makeTimeline()
        // Even after "observing" backward motion, targetDirection at 0.1 is still forward.
        // (No API on the timeline accepts motion input — this is the architecture guarantee.)
        #expect(timeline.targetDirection(at: 0.1) == .forward)
        #expect(timeline.targetDirection(at: 0.4) == .backward)
    }

    @Test("Reset clears loopIndex and fired stroke tracking")
    func resetClearsState() {
        let timeline = makeTimeline()
        _ = timeline.advance(to: 0.05, previousLoopTime: 0.0)
        _ = timeline.advance(to: 0.35, previousLoopTime: 0.05)
        timeline.reset()
        #expect(timeline.loopIndex == 0)
        #expect(timeline.lastFiredStrokeIndices.isEmpty)
        #expect(timeline.loopTime == 0)
    }

    @Test("Scoring correctly classifies onTime / early / late / wrongDirection / idle")
    func scoringClassification() {
        // onTime: within ±120ms, correct direction
        let onTime = CXLNotationCaptureRecorder.classify(
            target: .forward, observed: .forward, timingErrorMs: 50, confidence: 0.9)
        #expect(onTime == .onTime)

        // early: more than 120ms early
        let early = CXLNotationCaptureRecorder.classify(
            target: .forward, observed: .forward, timingErrorMs: -150, confidence: 0.9)
        #expect(early == .early)

        // late: more than 120ms late
        let late = CXLNotationCaptureRecorder.classify(
            target: .forward, observed: .forward, timingErrorMs: 200, confidence: 0.9)
        #expect(late == .late)

        // wrongDirection
        let wrong = CXLNotationCaptureRecorder.classify(
            target: .forward, observed: .back, timingErrorMs: 10, confidence: 0.9)
        #expect(wrong == .wrongDirection)

        // idle (low confidence)
        let idle = CXLNotationCaptureRecorder.classify(
            target: .forward, observed: .idle, timingErrorMs: 0, confidence: 0.05)
        #expect(idle == .idle)
    }
}
