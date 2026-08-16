// V3.2 Phase 2 — canonical ScratchNotationPanel presentation.
//
// These tests pin the SEMANTIC regression gate from the Phase 2 spec against
// deterministic geometry/data — never a rendered pixel — per the project's
// pure-geometry testing convention (see ScratchStrokeGeometryTravelAmplitudeTests,
// LaneFaderSpanAdapterTests). ScratchNotationPanel itself contributes no new
// notation math; it only routes canonical data into the existing
// ScratchPhraseChartView / ScratchStrokeGeometry / faderAuthoritySpans
// pipeline, so these tests exercise exactly that routing plus the one new
// pure function (`ScratchStrokeGeometry.turnaroundAnchors`).

import CoreGraphics
import XCTest
@testable import ScratchLab

final class ScratchNotationPanelTests: XCTestCase {

    // MARK: - Fixtures

    /// The canonical Baby Scratch cycle, materialized at a fixed tempo so
    /// every assertion below is exact, not approximate.
    private func babyScratchNotation(bpm: Double = 90) -> ScratchNotation {
        guard let pattern = ScratchNotation.canonicalBeatPattern(forScratchID: "baby_scratch"),
              let notation = pattern.materialized(bpm: bpm) else {
            XCTFail("babyScratchCycle must materialize at a valid bpm")
            return ScratchNotation(version: 1, scratchID: "unreachable", demoStart: 0, demoEnd: 0,
                                    phraseStart: 0, phraseEnd: 0, timingBasis: "seconds", strokes: [])
        }
        return notation
    }

    // MARK: - 1 & 7. Baby Scratch fader authority: OPEN throughout, no cuts

    func testBabyScratchFaderAuthorityIsOpenThroughoutWithNoClosedSection() {
        let notation = babyScratchNotation()
        XCTAssertTrue(notation.faderEvents.isEmpty,
                       "babyScratchCycle must have no canonical fader-edge channel — per-stroke state is the sole description")

        let spans = notation.faderAuthoritySpans(documentEnd: notation.timelineDuration)
        XCTAssertFalse(spans.isEmpty)
        XCTAssertTrue(spans.allSatisfy { $0.state == .open },
                      "every authoritative fader span for Baby Scratch must be OPEN")
        XCTAssertFalse(spans.contains { $0.state == .closed },
                       "Baby Scratch must never show a CLOSED section")

        // Contiguous, gapless coverage of the full document — no invented or
        // dropped span between strokes.
        let sorted = spans.sorted { $0.startTime < $1.startTime }
        XCTAssertEqual(sorted.first?.startTime ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(sorted.last?.endTime ?? -1, notation.timelineDuration, accuracy: 1e-9)
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            XCTAssertEqual(a.endTime, b.startTime, accuracy: 1e-9, "fader spans must be contiguous, no gaps")
        }
    }

    /// Non-empty canonical `faderEvents` are authoritative even when they
    /// disagree with per-stroke `faderState` — the authority rule the Baby
    /// Scratch gate depends on must hold in the other direction too.
    func testNonEmptyFaderEventsAreAuthoritativeOverConflictingPerStrokeState() {
        let notation = ScratchNotation(
            version: 1, scratchID: "test_fader_authority",
            demoStart: 0, demoEnd: 1.0, phraseStart: 0, phraseEnd: 1.0,
            timingBasis: "seconds",
            strokes: [
                // Per-stroke state says CLOSED — must be overridden by the
                // non-empty faderEvents channel below.
                .init(startTime: 0.0, endTime: 1.0, direction: .forward,
                      speedClassification: .medium, faderState: .closed)
            ],
            faderEvents: [
                .init(time: 0.0, state: .open),
                .init(time: 0.5, state: .closed)
            ]
        )
        let spans = notation.faderAuthoritySpans(documentEnd: 1.0)
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].state, .open, "the authoritative edge channel wins over per-stroke .closed")
        XCTAssertEqual(spans[1].state, .closed)
    }

    // MARK: - 2 & 3. Platter/fader and Target/Performance share one domain

    func testChartWindowRoutesTheSameSharedDomainToBothLanes() {
        let target = babyScratchNotation()
        let domain = ScratchPhraseChartComparisonDomain.commonDomain(targetDuration: target.timelineDuration)

        let targetWindow = ScratchNotationPanel.chartWindow(lane: .target, domain: domain)
        let performanceWindow = ScratchNotationPanel.chartWindow(lane: .performance, domain: domain)

        XCTAssertEqual(targetWindow.target, domain, "the TARGET panel must read the shared domain as its own window")
        XCTAssertNil(targetWindow.captured)
        XCTAssertEqual(performanceWindow.captured, domain, "the PERFORMANCE panel must read the SAME domain, never a derived one")
        XCTAssertNil(performanceWindow.target)
    }

    func testChartWindowIsNilWhenNoDomainIsSupplied() {
        let window = ScratchNotationPanel.chartWindow(lane: .target, domain: nil)
        XCTAssertNil(window.target)
        XCTAssertNil(window.captured)
    }

    // MARK: - 4. Direction semantics survive presentation mapping

    func testBabyScratchForwardRisesAndBackwardFalls() {
        let notation = babyScratchNotation()
        let content = LaneContent(notation: notation)
        let path = ScratchStrokeGeometry.motionPath(for: content)
        let strokeSegments = path.segments.filter { !$0.isHold }

        XCTAssertEqual(strokeSegments.count, 2)
        XCTAssertEqual(strokeSegments[0].kind, .stroke(.forward))
        XCTAssertGreaterThan(strokeSegments[0].endPosition, strokeSegments[0].startPosition,
                             "a forward stroke must rise on the platter-position curve")
        XCTAssertEqual(strokeSegments[1].kind, .stroke(.backward))
        XCTAssertLessThan(strokeSegments[1].endPosition, strokeSegments[1].startPosition,
                          "a backward stroke must fall on the platter-position curve")
    }

    // MARK: - 5. Turnaround anchors correspond to canonical reversal data

    func testBabyScratchTurnaroundAnchorAtTheForwardStrokesEnd() {
        let notation = babyScratchNotation(bpm: 90)
        let content = LaneContent(notation: notation)
        let path = ScratchStrokeGeometry.motionPath(for: content)
        let anchors = ScratchStrokeGeometry.turnaroundAnchors(strokes: content.strokes, path: path)

        XCTAssertEqual(anchors.count, 1, "one cycle of Baby Scratch has exactly one forward→backward reversal")
        let forwardStroke = content.strokes.sorted { $0.startTime < $1.startTime }[0]
        XCTAssertEqual(anchors[0].time, forwardStroke.endTime, accuracy: 1e-9,
                       "the turnaround must sit at the forward stroke's own end time, not a decorative extremum")
        XCTAssertEqual(anchors[0].position, path.position(at: forwardStroke.endTime), accuracy: 1e-9)
    }

    func testNoTurnaroundWithoutAForwardToBackwardBoundary() {
        // Two forward strokes in a row: no reversal exists, so no anchor
        // should be invented.
        let content = LaneContent(
            strokes: [
                LaneStroke(startTime: 0, endTime: 0.5, direction: .forward, speed: .medium, faderState: .open, isGhost: false),
                LaneStroke(startTime: 0.5, endTime: 1.0, direction: .forward, speed: .medium, faderState: .open, isGhost: false),
            ],
            segments: [], beatsPerMinute: nil, duration: 1.0, loops: false)
        let path = ScratchStrokeGeometry.motionPath(for: content)
        let anchors = ScratchStrokeGeometry.turnaroundAnchors(strokes: content.strokes, path: path)
        XCTAssertTrue(anchors.isEmpty)
    }

    // MARK: - 6. Holds/rests preserve musical time

    func testHoldBetweenStrokesOccupiesItsFullTimeSpanAndStaysFlat() {
        let content = LaneContent(
            strokes: [
                LaneStroke(startTime: 0.0, endTime: 0.5, direction: .forward, speed: .medium, faderState: .open, isGhost: false),
                // 1.0s silent gap — still occupies musical time.
                LaneStroke(startTime: 1.5, endTime: 2.0, direction: .backward, speed: .medium, faderState: .open, isGhost: false),
            ],
            segments: [], beatsPerMinute: nil, duration: 2.0, loops: false)
        let path = ScratchStrokeGeometry.motionPath(for: content)

        let holds = path.segments.filter { $0.isHold }
        let gapHold = holds.first { $0.startTime >= 0.5 - 1e-9 && $0.endTime <= 1.5 + 1e-9 }
        XCTAssertNotNil(gapHold, "the gap between strokes must materialize as an explicit hold segment")
        XCTAssertEqual(gapHold?.startTime ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(gapHold?.endTime ?? -1, 1.5, accuracy: 1e-9)
        XCTAssertEqual(gapHold?.startPosition, gapHold?.endPosition, "a hold must stay flat, never read as travel")

        // The full document duration must remain covered start-to-end —
        // silence never collapses the time domain.
        XCTAssertEqual(path.timeRange.lowerBound, 0, accuracy: 1e-9)
        XCTAssertEqual(path.timeRange.upperBound, 2.0, accuracy: 1e-9)
    }

    // MARK: - 8. Presentation mapping never mutates canonical notation data

    func testBuildingPanelInputsDoesNotMutateTheSourceNotation() {
        let original = babyScratchNotation()
        let beforeCopy = original

        // Exercise the same read path the panel exercises: LaneContent
        // construction, motion-path derivation, fader-authority resolution.
        let content = LaneContent(notation: original)
        _ = ScratchStrokeGeometry.motionPath(for: content)
        _ = original.faderAuthoritySpans(documentEnd: original.timelineDuration)
        _ = ScratchPhraseChartComparisonDomain.commonDomain(targetDuration: original.timelineDuration)

        XCTAssertEqual(original, beforeCopy, "reading canonical notation for presentation must never mutate it")
    }
}

// MARK: - Phase 1 design-token / semantic-state mapping
//
// Pins the V3.2 semantic mapping rules (node 148:123 / 140:18 / 144:23 /
// 252:303 / 253:293 / 174:23) against the pure state enums — no rendered
// pixel, no SwiftUI colour comparison. These are the "component state"
// contracts from the Phase 1 spec.

final class ScratchLabDesignTokensTests: XCTestCase {

    // MARK: StatusBadge state → semantic variant

    func testStatusBadgeReadyIsBoneNeverGreen() {
        XCTAssertEqual(StatusBadgeState.ready.variant, .ready,
                       "READY is neutral bone; green is reserved for completion")
        XCTAssertNotEqual(StatusBadgeState.ready.variant, .success)
    }

    func testStatusBadgeCompletedIsGreen() {
        XCTAssertEqual(StatusBadgeState.completed.variant, .success)
        XCTAssertEqual(StatusBadgeState.completed.label, "COMPLETE")
    }

    func testStatusBadgeRecordingAndFailureAreRed() {
        XCTAssertEqual(StatusBadgeState.recording.variant, .danger)
        XCTAssertEqual(StatusBadgeState.failure.variant, .danger)
    }

    func testStatusBadgeAttentionAmberDetectedCyan() {
        XCTAssertEqual(StatusBadgeState.attention.variant, .warning)
        XCTAssertEqual(StatusBadgeState.detected.variant, .info)
    }

    // MARK: Input readiness — detected ≠ ready

    func testInputDetectedIsNotReady() {
        XCTAssertNotEqual(InputReadinessState.detected, InputReadinessState.ready,
                          "a connected/detected input is never READY by that fact alone")
    }

    func testInputReadinessStateLabels() {
        XCTAssertEqual(InputReadinessState.setupRequired.label, "SETUP REQUIRED")
        XCTAssertEqual(InputReadinessState.lost.label, "LOST")
    }

    // MARK: Hardware identity is independent of readiness state

    func testControllerMappingStateNeverHardcodesHardwareIdentity() {
        let forbidden = ["RANE", "DJM", "PIONEER", "S11", "S9", "S7", "MKII"]
        for state in ControllerMappingState.allCases {
            let upper = state.label.uppercased()
            for name in forbidden {
                XCTAssertFalse(upper.contains(name),
                               "\(state.label) must not bake a hardware name into a state variant")
            }
        }
    }

    // MARK: DVS — carrier detected is NOT ready

    func testDVSCarrierDetectedIsNotReady() {
        XCTAssertFalse(DVSSignalState.carrierDetected.isReady)
        XCTAssertFalse(DVSSignalState.noSignal.isReady)
        XCTAssertFalse(DVSSignalState.weak.isReady)
        XCTAssertFalse(DVSSignalState.lost.isReady)
    }

    func testDVSOnlyUsableIsReady() {
        XCTAssertTrue(DVSSignalState.usable.isReady)
        XCTAssertEqual(DVSSignalState.allCases.filter(\.isReady), [.usable],
                       "only USABLE satisfies 'DVS ready' — carrier/weak are never ready")
    }

    // MARK: Controller — crossfader mapping required is NOT DVS+MIDI ready

    func testControllerPartialStatesAreNotReady() {
        XCTAssertFalse(ControllerMappingState.crossfaderMappingRequired.isReady)
        XCTAssertFalse(ControllerMappingState.controllerDetected.isReady)
        XCTAssertFalse(ControllerMappingState.platterReady.isReady)
        XCTAssertFalse(ControllerMappingState.midiLearned.isReady,
                       "MIDI learned ≠ DVS + MIDI ready")
    }

    func testControllerOnlyDVSPlusMIDIReadyIsReady() {
        XCTAssertTrue(ControllerMappingState.dvsPlusMidiReady.isReady)
        XCTAssertEqual(ControllerMappingState.allCases.filter(\.isReady), [.dvsPlusMidiReady])
    }

    /// Pins the exact badge→colour mapping the Figma `ControllerMappingCard`
    /// (node 253:293) encodes via its `StatusBadge` reuse.
    func testControllerMappingBadgeVariantsMatchFigma() {
        XCTAssertEqual(ControllerMappingState.noController.variant, .neutral)
        XCTAssertEqual(ControllerMappingState.controllerDetected.variant, .info, "Detected = cyan")
        XCTAssertEqual(ControllerMappingState.platterReady.variant, .ready, "Platter Ready = bone READY, not green/cyan")
        XCTAssertEqual(ControllerMappingState.crossfaderMappingRequired.variant, .warning, "Crossfader Mapping Required = amber")
        XCTAssertEqual(ControllerMappingState.midiLearned.variant, .ready, "MIDI Learned = bone READY")
        XCTAssertEqual(ControllerMappingState.mappingConflict.variant, .danger, "Mapping Conflict = red")
        XCTAssertEqual(ControllerMappingState.dvsPlusMidiReady.variant, .success, "DVS + MIDI Ready = green COMPLETE")
    }

    /// Pins the badge→colour mapping the Figma `Review and Export Card`
    /// (node 255:219) encodes via its `StatusBadge` reuse.
    func testReviewExportBadgeVariantsMatchFigma() {
        XCTAssertEqual(ReviewExportState.awaitingConfirmation.variant, .warning, "Awaiting Confirmation = amber")
        XCTAssertEqual(ReviewExportState.confirmed.variant, .success, "Confirmed = green COMPLETE")
        XCTAssertEqual(ReviewExportState.preparingExport.variant, .info, "Preparing Export = cyan")
        XCTAssertEqual(ReviewExportState.exported.variant, .success, "Exported = green COMPLETE")
        XCTAssertEqual(ReviewExportState.exportFailed.variant, .danger, "Export Failed = red")
    }

    // MARK: Camera optional is non-blocking

    func testCameraDisclosureIsNeverBlocking() {
        for state in CameraDisclosureState.allCases {
            XCTAssertFalse(state.isBlocking, "camera must never block Practice/Capture/Review/Export")
        }
    }

    // MARK: Achievement derives from progress, never a new model

    func testAchievementStatesMapToSemanticVariants() {
        XCTAssertEqual(AchievementState.complete.variant, .success)
        XCTAssertEqual(AchievementState.empty.variant, .neutral)
        XCTAssertEqual(AchievementState.bestResult.variant, .warning)
    }

    // MARK: Hardware verification tier labels

    func testHardwareVerificationTierLabels() {
        XCTAssertEqual(HardwareVerificationTier.testedNotYetVerified.label, "TESTED — NOT YET VERIFIED")
        XCTAssertEqual(HardwareVerificationTier.knownOptionUnverified.label, "KNOWN OPTION — UNVERIFIED")
        XCTAssertEqual(HardwareVerificationTier.verifyInEngineering.label, "VERIFY IN ENGINEERING")
    }

    // MARK: Notation trace styles — Figma stroke weights + distinct roles

    func testTargetAndPerformanceTraceStrokeWeightsMatchFigma() {
        XCTAssertEqual(ScratchMotionRenderer.Style.target.lineWidth,
                       ScratchLabDesign.Notation.targetStroke, accuracy: 0.0001)
        XCTAssertEqual(ScratchMotionRenderer.Style.performance.lineWidth,
                       ScratchLabDesign.Notation.performanceStroke, accuracy: 0.0001)
        XCTAssertNotEqual(ScratchLabDesign.Notation.targetStroke,
                          ScratchLabDesign.Notation.performanceStroke,
                          "target (1.6) and performance (2.0) trace weights must stay distinct")
    }

    // MARK: Notation panel mode headers + performance labels

    func testNotationPanelModeHeadersAndPerformanceLabels() {
        XCTAssertEqual(ScratchNotationPanelMode.targetReference.headerTitle, "TARGET REFERENCE")
        XCTAssertEqual(ScratchNotationPanelMode.liveComparison.headerTitle, "LIVE COMPARISON")
        XCTAssertEqual(ScratchNotationPanelMode.reviewComparison.headerTitle, "REVIEW COMPARISON")
        XCTAssertEqual(ScratchNotationPanelMode.liveComparison.performanceLabel, "MY PERFORMANCE — LIVE")
        XCTAssertEqual(ScratchNotationPanelMode.reviewComparison.performanceLabel, "MY PERFORMANCE — CAPTURED")
    }
}

// MARK: - Phase 2 Practice presentation-state derivation
//
// The single derived Practice state (ready/listening/copyActive/paused/result/
// review/lessonComplete) over the existing `PracticeGameplayState` + real
// playback flags. Pins the "no contradictory surfaces" contract.

final class PracticePresentationStateTests: XCTestCase {

    private func copyingState() -> PracticeGameplayState {
        guard let pattern = ScratchNotation.canonicalBeatPattern(forScratchID: "baby_scratch"),
              let window = GameplayAttemptWindow(cycleIndex: 0, cycleDurationBeats: pattern.durationBeats) else {
            fatalError("baby_scratch canonical pattern must materialize for the test")
        }
        let session = PracticeAttemptSession(
            pattern: pattern, bpm: 90, countInBeats: 4,
            window: window, startedAt: Date(timeIntervalSince1970: 0)
        )
        return .copying(session)
    }

    func testIdleWatchingReadyDeriveToReady() {
        XCTAssertEqual(PracticePresentationState.derive(gameplay: .idle), .ready)
        XCTAssertEqual(PracticePresentationState.derive(gameplay: .watching), .ready)
        XCTAssertEqual(PracticePresentationState.derive(gameplay: .ready), .ready)
    }

    func testListeningDerivesToListening() {
        XCTAssertEqual(PracticePresentationState.derive(gameplay: .ready, isListening: true), .listening)
    }

    func testCopyingDerivesToCopyActive() {
        XCTAssertEqual(PracticePresentationState.derive(gameplay: copyingState()), .copyActive)
    }

    func testPausedDerivesToPausedAndPreservesTheAttempt() {
        // Paused is derived from an open copy window + the pause flag — it is
        // NOT a new attempt and NOT a result.
        let derived = PracticePresentationState.derive(gameplay: copyingState(), isPaused: true)
        XCTAssertEqual(derived, .paused)
        XCTAssertNotEqual(derived, .result, "paused must never read as a completed result")
    }

    func testResultRequiresAScoredAttempt() {
        // The only path to `.result` is a real `.result` gameplay state.
        XCTAssertNotEqual(PracticePresentationState.derive(gameplay: .idle), .result)
        XCTAssertNotEqual(PracticePresentationState.derive(gameplay: .ready), .result)
        XCTAssertNotEqual(PracticePresentationState.derive(gameplay: copyingState()), .result)
    }

    func testReviewingDerivesToReviewOverAnOpenAttempt() {
        XCTAssertEqual(PracticePresentationState.derive(gameplay: copyingState(), isReviewing: true), .review)
    }

    func testLessonCompleteWinsOverEverything() {
        // Green completion must only come from a real completion condition and
        // must dominate the attempt/playback flags.
        XCTAssertEqual(
            PracticePresentationState.derive(gameplay: copyingState(), isListening: true, isPaused: true, isReviewing: true, isLessonComplete: true),
            .lessonComplete
        )
    }

    func testNotationModeMapping() {
        XCTAssertEqual(PracticePresentationState.ready.notationMode, .targetReference)
        XCTAssertEqual(PracticePresentationState.listening.notationMode, .targetReference)
        XCTAssertEqual(PracticePresentationState.copyActive.notationMode, .liveComparison)
        XCTAssertEqual(PracticePresentationState.paused.notationMode, .liveComparison)
        XCTAssertEqual(PracticePresentationState.result.notationMode, .reviewComparison)
        XCTAssertEqual(PracticePresentationState.review.notationMode, .reviewComparison)
        XCTAssertEqual(PracticePresentationState.lessonComplete.notationMode, .reviewComparison)
    }

    func testShowsPerformanceOnlyForLiveOrCapturedStates() {
        XCTAssertFalse(PracticePresentationState.ready.showsPerformance)
        XCTAssertFalse(PracticePresentationState.listening.showsPerformance)
        XCTAssertTrue(PracticePresentationState.copyActive.showsPerformance)
        XCTAssertTrue(PracticePresentationState.paused.showsPerformance)
        XCTAssertTrue(PracticePresentationState.result.showsPerformance)
        XCTAssertTrue(PracticePresentationState.review.showsPerformance)
        XCTAssertFalse(PracticePresentationState.lessonComplete.showsPerformance)
    }

    func testFlowOrderIsWatchListenCopyResultReview() {
        XCTAssertEqual(
            PracticePresentationState.flowOrder,
            [.ready, .listening, .copyActive, .result, .review]
        )
    }

    // MARK: iOS boolean derivation

    func testIOSDerivationReadyAndListening() {
        XCTAssertEqual(PracticePresentationState.derive(isSessionActive: false, isPaused: false, isResult: false), .ready)
        XCTAssertEqual(PracticePresentationState.derive(isSessionActive: false, isPaused: false, isResult: false, isListening: true), .listening)
    }

    func testIOSDerivationCopyActiveAndPaused() {
        XCTAssertEqual(PracticePresentationState.derive(isSessionActive: true, isPaused: false, isResult: false), .copyActive)
        XCTAssertEqual(PracticePresentationState.derive(isSessionActive: true, isPaused: true, isResult: false), .paused)
    }

    func testIOSDerivationResultWinsOverActive() {
        XCTAssertEqual(PracticePresentationState.derive(isSessionActive: true, isPaused: false, isResult: true), .result)
    }

    func testIOSDerivationLessonCompleteWins() {
        XCTAssertEqual(
            PracticePresentationState.derive(isSessionActive: true, isPaused: true, isResult: true, isLessonComplete: true),
            .lessonComplete
        )
    }

    // MARK: label / variant (non-colour + green-only-on-complete)

    func testLabelIsNonColourStateDescription() {
        XCTAssertEqual(PracticePresentationState.ready.label, "READY")
        XCTAssertEqual(PracticePresentationState.copyActive.label, "COPY ACTIVE")
        XCTAssertEqual(PracticePresentationState.lessonComplete.label, "LESSON COMPLETE")
    }

    func testGreenIsReservedForLessonComplete() {
        XCTAssertEqual(PracticePresentationState.lessonComplete.variant, .success)
        for state in PracticePresentationState.flowOrder {
            XCTAssertNotEqual(state.variant, .success,
                              "\(state) must never render green — green is lesson-complete only")
        }
    }

    // MARK: Accessibility

    func testInteractiveButtonsMeetMinimum44ptTarget() {
        XCTAssertGreaterThanOrEqual(ScratchLabDesign.Button.primaryHeight, 44,
                                    "primary action must meet the 44pt touch target")
        XCTAssertGreaterThanOrEqual(ScratchLabDesign.Button.secondaryHeight, 44)
        XCTAssertGreaterThanOrEqual(ScratchLabDesign.Button.destructiveHeight, 44)
    }

    func testPracticeStateLabelsAreNeverBlankOrColourOnly() {
        let all: [PracticePresentationState] = [.ready, .listening, .copyActive, .paused, .result, .review, .lessonComplete]
        for state in all {
            XCTAssertFalse(state.label.isEmpty, "\(state) must have a non-blank, non-colour label")
            XCTAssertEqual(state.label, state.label.uppercased(), "state labels are uppercase voice text")
        }
    }
}
