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
import SwiftUI
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

    func testInputNeutralStateIsNonBlocking() {
        XCTAssertEqual(InputReadinessState.neutral.label, "—")
        XCTAssertFalse(InputReadinessState.neutral.isBlocking,
                       "optional/not-applicable inputs must not block readiness")
        XCTAssertTrue(InputReadinessState.setupRequired.isBlocking)
        XCTAssertTrue(InputReadinessState.needsAttention.isBlocking)
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

    // MARK: Controller mapping → readiness axis (hardware profile card)

    func testControllerMappingInputReadiness() {
        XCTAssertEqual(ControllerMappingState.noController.inputReadiness, .setupRequired)
        XCTAssertEqual(ControllerMappingState.controllerDetected.inputReadiness, .detected)
        XCTAssertEqual(ControllerMappingState.platterReady.inputReadiness, .detected,
                       "platter-ready is still short of the DVS+MIDI combined-ready gate")
        XCTAssertEqual(ControllerMappingState.crossfaderMappingRequired.inputReadiness, .needsAttention)
        XCTAssertEqual(ControllerMappingState.midiLearned.inputReadiness, .detected,
                       "MIDI learned is not DVS+MIDI ready")
        XCTAssertEqual(ControllerMappingState.mappingConflict.inputReadiness, .needsAttention)
        XCTAssertEqual(ControllerMappingState.dvsPlusMidiReady.inputReadiness, .ready)
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
        XCTAssertEqual(ScratchNotationPanelMode.targetReference.performanceLabel, "MY PERFORMANCE — CAPTURED",
                       "the target-only mode still labels a hypothetical performance lane as CAPTURED, never LIVE")
    }

    func testTargetAndPerformanceTraceIdentityIsDistinct() {
        XCTAssertNotEqual(ScratchMotionRenderer.Style.target, ScratchMotionRenderer.Style.performance,
                          "target and performed traces must be distinct visual identities")
    }

    func testEmptyDetectedEventsYieldNoNotationPreview() {
        XCTAssertNil(ScratchNotation.detectedPreview(scratchID: "baby_scratch", events: []),
                     "empty captured evidence must never fabricate a performed trace")
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

// MARK: - Phase 3 Capture readiness derivation

final class CaptureReadinessTests: XCTestCase {

    // MARK: - Lane semantics (contradictions & boundary cases)

    func testDVSCarrierDetectedIsNotUsable() {
        // carrierDetected is NOT DVS-ready; only `.usable` is.
        XCTAssertFalse(CaptureLaneReadiness.dvs(.carrierDetected, required: true).isUsable)
        XCTAssertTrue(CaptureLaneReadiness.dvs(.usable, required: true).isUsable)

        var carrierLanes = CaptureLanes()
        carrierLanes.audio = .audio(isAvailable: true)
        carrierLanes.dvsTimecode = .dvs(.carrierDetected, required: true)
        XCTAssertFalse(carrierLanes.isReady)
        XCTAssertEqual(
            CaptureReadiness.derive(CaptureReadinessInput(hasSession: true, isMetadataComplete: true, lanes: carrierLanes)),
            .needsAttention
        )

        var usableLanes = CaptureLanes()
        usableLanes.audio = .audio(isAvailable: true)
        usableLanes.dvsTimecode = .dvs(.usable, required: true)
        XCTAssertTrue(usableLanes.isReady)
        XCTAssertEqual(
            CaptureReadiness.derive(CaptureReadinessInput(hasSession: true, isMetadataComplete: true, lanes: usableLanes)),
            .ready
        )
    }

    func testMIDILearnedIsNotCombinedReady() {
        // midiLearned / platterReady are NOT combined-ready; only dvsPlusMidiReady is.
        XCTAssertFalse(CaptureLaneReadiness.controller(.midiLearned, required: true).isUsable)
        XCTAssertFalse(CaptureLaneReadiness.controller(.platterReady, required: true).isUsable)
        XCTAssertTrue(CaptureLaneReadiness.controller(.dvsPlusMidiReady, required: true).isUsable)

        var learnedLanes = CaptureLanes()
        learnedLanes.audio = .audio(isAvailable: true)
        learnedLanes.crossfaderMIDI = .controller(.midiLearned, required: true)
        XCTAssertFalse(learnedLanes.isReady)
        XCTAssertEqual(
            CaptureReadiness.derive(CaptureReadinessInput(hasSession: true, isMetadataComplete: true, lanes: learnedLanes)),
            .needsAttention
        )

        var combinedLanes = CaptureLanes()
        combinedLanes.audio = .audio(isAvailable: true)
        combinedLanes.crossfaderMIDI = .controller(.dvsPlusMidiReady, required: true)
        XCTAssertTrue(combinedLanes.isReady)
        XCTAssertEqual(
            CaptureReadiness.derive(CaptureReadinessInput(hasSession: true, isMetadataComplete: true, lanes: combinedLanes)),
            .ready
        )
    }

    func testCameraNeverBlocksReadiness() {
        // Camera is optional: even "setup required" camera must not gate READY.
        var lanes = CaptureLanes()
        lanes.audio = .audio(isAvailable: true)
        lanes.camera = .input(.setupRequired, required: false)
        XCTAssertTrue(lanes.isReady)
        XCTAssertEqual(
            CaptureReadiness.derive(CaptureReadinessInput(hasSession: true, isMetadataComplete: true, lanes: lanes)),
            .ready
        )
        // An optional lane is never blocking.
        XCTAssertFalse(CaptureLaneReadiness.notRequired.isBlocking)
    }

    func testReadyRequiresEveryBlockingLaneUsable() {
        // Audio is the default blocking lane: unavailable audio → not ready.
        var missingAudio = CaptureLanes()
        missingAudio.audio = .audio(isAvailable: false)
        XCTAssertFalse(missingAudio.isReady)
        XCTAssertEqual(
            CaptureReadiness.derive(CaptureReadinessInput(hasSession: true, isMetadataComplete: true, lanes: missingAudio)),
            .needsAttention
        )

        // A required-but-not-usable DVS lane blocks even when audio is fine.
        var dvsMissing = CaptureLanes()
        dvsMissing.audio = .audio(isAvailable: true)
        dvsMissing.dvsTimecode = .dvs(.noSignal, required: true)
        XCTAssertFalse(dvsMissing.isReady)
    }

    func testDVSReadyDoesNotReadCaptureReadyWhenAudioMissing() {
        var lanes = CaptureLanes()
        lanes.audio = .audio(isAvailable: false)
        lanes.dvsTimecode = .dvs(.usable, required: true)
        let derived = CaptureReadiness.derive(
            CaptureReadinessInput(hasSession: true, isMetadataComplete: true, lanes: lanes)
        )
        XCTAssertNotEqual(derived, .ready, "DVS ready must not read as capture ready")
    }

    // MARK: - Stale DVS state must not gate capture

    /// The exact contradictory state reported from the running app: timecode
    /// input had been enabled and its signal never became ready, the operator
    /// then selected Rane ONE MKII audio and it went READY — and Start
    /// recording stayed disabled with "DVS input is enabled but not ready",
    /// while the same panel offered "Use Serato Audio" (proving Serato was
    /// *not* the selected input) and exposed no way to disable DVS.
    func testStaleEnabledDVSDoesNotBlockWhenNormalAudioIsSelectedAndReady() {
        // DVS left enabled from an earlier attempt, still with no signal.
        // The selected capture input is Rane ONE MKII, not Serato/DVS.
        let lane = CaptureLaneReadiness.dvs(
            .noSignal,
            modeEnabled: true,
            isDVSSourceSelected: false
        )
        XCTAssertFalse(lane.isRequired, "DVS is optional unless its source is selected.")
        XCTAssertFalse(lane.isBlocking, "Stale DVS state must not gate recording.")

        var lanes = CaptureLanes()
        lanes.audio = .audio(isAvailable: true)
        lanes.dvsTimecode = lane
        XCTAssertTrue(lanes.blockingLanes.isEmpty)
        XCTAssertTrue(lanes.isReady)
        XCTAssertEqual(
            CaptureReadiness.derive(
                CaptureReadinessInput(hasSession: true, isMetadataComplete: true, lanes: lanes)
            ),
            .ready,
            "Rane audio ready + camera optional must unlock recording."
        )
    }

    /// Requirement 9: DVS that is genuinely selected and genuinely unready
    /// must still block. The fix must not simply disarm the lane.
    func testSelectedButUnreadyDVSStillBlocksRecording() {
        for signal in [DVSSignalState.noSignal, .weak, .clipped, .channelFault, .carrierDetected] {
            let lane = CaptureLaneReadiness.dvs(
                signal,
                modeEnabled: true,
                isDVSSourceSelected: true
            )
            XCTAssertTrue(lane.isRequired, "\(signal) — selected DVS is required.")
            XCTAssertTrue(lane.isBlocking, "\(signal) — selected but unready DVS must block.")

            var lanes = CaptureLanes()
            lanes.audio = .audio(isAvailable: true)
            lanes.dvsTimecode = lane
            XCTAssertEqual(lanes.blockingLanes, [.dvsTimecode])
            XCTAssertNotEqual(
                CaptureReadiness.derive(
                    CaptureReadinessInput(hasSession: true, isMetadataComplete: true, lanes: lanes)
                ),
                .ready,
                "\(signal) — must not read as ready."
            )
        }
    }

    /// Selected DVS that is actually usable is required and satisfied.
    func testSelectedAndUsableDVSIsRequiredAndNotBlocking() {
        let lane = CaptureLaneReadiness.dvs(.usable, modeEnabled: true, isDVSSourceSelected: true)
        XCTAssertTrue(lane.isRequired)
        XCTAssertTrue(lane.isUsable)
        XCTAssertFalse(lane.isBlocking)
    }

    /// Requirement 4: changing the audio source must flip the gate straight
    /// away, with no other input changing.
    func testChangingAudioSourceFlipsDVSGateImmediately() {
        func lanes(isDVSSourceSelected: Bool) -> CaptureLanes {
            var lanes = CaptureLanes()
            lanes.audio = .audio(isAvailable: true)
            lanes.dvsTimecode = .dvs(
                .noSignal,
                modeEnabled: true,
                isDVSSourceSelected: isDVSSourceSelected
            )
            return lanes
        }
        // Serato/DVS selected but dead -> blocked.
        XCTAssertEqual(lanes(isDVSSourceSelected: true).blockingLanes, [.dvsTimecode])
        // Operator switches to Rane ONE MKII -> unblocked, same instant.
        XCTAssertTrue(lanes(isDVSSourceSelected: false).blockingLanes.isEmpty)
    }

    /// Turning timecode input off must keep DVS optional however it is routed.
    func testDisabledTimecodeModeIsNeverRequired() {
        for selected in [true, false] {
            XCTAssertFalse(
                CaptureLaneReadiness.isDVSRequired(modeEnabled: false, isDVSSourceSelected: selected),
                "Disabled timecode input can never gate recording."
            )
        }
        XCTAssertTrue(
            CaptureLaneReadiness.isDVSRequired(modeEnabled: true, isDVSSourceSelected: true)
        )
    }

    // MARK: - Presentation-state derivation

    func testNoSessionIsSetupRequired() {
        XCTAssertEqual(CaptureReadiness.derive(CaptureReadinessInput()), .setupRequired)
    }

    func testIncompleteMetadataIsSetupRequired() {
        XCTAssertEqual(CaptureReadiness.derive(CaptureReadinessInput(hasSession: true, isMetadataComplete: false)), .setupRequired)
    }

    func testReadyRequiresFullSetup() {
        var lanes = CaptureLanes()
        lanes.audio = .audio(isAvailable: true)
        let input = CaptureReadinessInput(hasSession: true, isMetadataComplete: true, lanes: lanes)
        XCTAssertEqual(CaptureReadiness.derive(input), .ready)
    }

    func testLifecycleStatesDominate() {
        XCTAssertEqual(CaptureReadiness.derive(CaptureReadinessInput(isRecording: true)), .recording)
        XCTAssertEqual(CaptureReadiness.derive(CaptureReadinessInput(isFinalizing: true)), .finalizing)
        XCTAssertEqual(CaptureReadiness.derive(CaptureReadinessInput(didComplete: true)), .complete)
        XCTAssertEqual(CaptureReadiness.derive(CaptureReadinessInput(didFail: true)), .failed)
        XCTAssertEqual(CaptureReadiness.derive(CaptureReadinessInput(didEndIncomplete: true)), .incomplete)
    }

    func testBlockingInterruptions() {
        XCTAssertEqual(CaptureReadiness.derive(CaptureReadinessInput(hasSession: true, isTimecodeLost: true)), .timecodeLost)
        XCTAssertEqual(CaptureReadiness.derive(CaptureReadinessInput(hasSession: true, hasAudioPermission: false)), .permissionRequired)
    }

    func testIncompleteIsDistinctFromNeedsAttention() {
        // A post-recording incomplete take is `.incomplete`, NOT `.needsAttention`
        // (which is the pre-recording "resolve a blocking lane" state).
        let incomplete = CaptureReadiness.derive(CaptureReadinessInput(hasSession: true, isMetadataComplete: true, didEndIncomplete: true))
        XCTAssertEqual(incomplete, .incomplete)
        XCTAssertNotEqual(incomplete, .needsAttention)
    }

    func testHardwareDetectedIsNotReady() {
        // A connected device with no usable audio is DETECTED, not READY.
        var lanes = CaptureLanes()
        lanes.audio = .audio(isAvailable: false)
        let input = CaptureReadinessInput(
            hasSession: true, isMetadataComplete: true,
            hasDetectedHardware: true, lanes: lanes
        )
        XCTAssertEqual(CaptureReadiness.derive(input), .hardwareDetected)
        XCTAssertNotEqual(CaptureReadiness.derive(input), .ready)
    }

    func testGreenIsReservedForComplete() {
        XCTAssertEqual(CaptureReadiness.complete.variant, .success)
        let nonComplete: [CaptureReadiness] = [.setupRequired, .hardwareDetected, .needsAttention, .ready, .recording, .finalizing, .incomplete, .failed, .timecodeLost, .permissionRequired]
        for state in nonComplete {
            XCTAssertNotEqual(state.variant, .success, "\(state) must never render green")
        }
    }

    func testLabelsAreNonBlankAndUppercase() {
        let all: [CaptureReadiness] = [.setupRequired, .hardwareDetected, .needsAttention, .ready, .recording, .finalizing, .complete, .incomplete, .failed, .timecodeLost, .permissionRequired]
        for state in all {
            XCTAssertFalse(state.label.isEmpty)
            XCTAssertEqual(state.label, state.label.uppercased())
        }
    }
}

// MARK: - Phase 4 Review presentation-state derivation

final class ReviewPresentationStateTests: XCTestCase {

    func testNoTakeWhenNoCapturedTake() {
        XCTAssertEqual(ReviewPresentationState.derive(ReviewPresentationInput()), .noTake)
    }

    func testTakeLifecycleStatesDominate() {
        XCTAssertEqual(ReviewPresentationState.derive(ReviewPresentationInput(hasTake: true, isRecording: true)), .recording)
        XCTAssertEqual(ReviewPresentationState.derive(ReviewPresentationInput(hasTake: true, isFinalizing: true)), .finalizing)
        XCTAssertEqual(ReviewPresentationState.derive(ReviewPresentationInput(hasTake: true, hasIssue: true)), .issue)
    }

    func testReadyThenConfirmed() {
        XCTAssertEqual(ReviewPresentationState.derive(ReviewPresentationInput(hasTake: true)), .ready)
        XCTAssertEqual(ReviewPresentationState.derive(ReviewPresentationInput(hasTake: true, decisionStatus: .accepted)), .confirmed)
    }

    func testCorrectedIsDistinctFromConfirmed() {
        let corrected = ReviewPresentationState.derive(ReviewPresentationInput(hasTake: true, decisionStatus: .corrected))
        let confirmed = ReviewPresentationState.derive(ReviewPresentationInput(hasTake: true, decisionStatus: .accepted))
        XCTAssertEqual(corrected, .corrected)
        XCTAssertEqual(confirmed, .confirmed)
        XCTAssertNotEqual(corrected, confirmed, "a label correction must never read as a confirmation")
    }

    func testUnknownDecisionDoesNotReadAsConfirmedOrCorrected() {
        let unknown = ReviewPresentationState.derive(ReviewPresentationInput(hasTake: true, decisionStatus: .unknown))
        XCTAssertEqual(unknown, .ready, "leaving a label unknown is neither a confirmation nor a correction")
    }

    func testCorrectionConfirmationTransitionIsOrdered() {
        let ready = ReviewPresentationState.derive(ReviewPresentationInput(hasTake: true))
        let corrected = ReviewPresentationState.derive(ReviewPresentationInput(hasTake: true, decisionStatus: .corrected))
        let confirmed = ReviewPresentationState.derive(ReviewPresentationInput(hasTake: true, decisionStatus: .accepted))
        XCTAssertEqual([ready, corrected, confirmed], [.ready, .corrected, .confirmed])
        XCTAssertNotEqual(corrected.variant, .success, "corrected is informational, never green")
    }

    func testExportLifecycleStates() {
        XCTAssertEqual(ReviewPresentationState.derive(ReviewPresentationInput(hasTake: true, decisionStatus: .accepted, isExporting: true)), .exporting)
        XCTAssertEqual(ReviewPresentationState.derive(ReviewPresentationInput(hasTake: true, decisionStatus: .accepted, didExportFail: true)), .exportFailed)
        XCTAssertEqual(ReviewPresentationState.derive(ReviewPresentationInput(hasTake: true, decisionStatus: .accepted, isExported: true)), .exported)
    }

    func testExportGatingFailureOverridesSuccess() {
        let both = ReviewPresentationState.derive(ReviewPresentationInput(hasTake: true, isExported: true, didExportFail: true))
        XCTAssertEqual(both, .exportFailed, "a failed export must never read as success")
    }

    func testExportStatesRequireATake() {
        XCTAssertEqual(ReviewPresentationState.derive(ReviewPresentationInput(isExported: true)), .noTake, "no take must never read as exported")
        XCTAssertEqual(ReviewPresentationState.derive(ReviewPresentationInput(didExportFail: true)), .noTake)
        XCTAssertEqual(ReviewPresentationState.derive(ReviewPresentationInput(isExporting: true)), .noTake)
    }

    func testGreenIsReservedForConfirmedAndExported() {
        XCTAssertEqual(ReviewPresentationState.confirmed.variant, .success)
        XCTAssertEqual(ReviewPresentationState.exported.variant, .success)
        let nonGreen: [ReviewPresentationState] = [.noTake, .recording, .finalizing, .issue, .ready, .corrected, .exporting, .exportFailed]
        for state in nonGreen {
            XCTAssertNotEqual(state.variant, .success, "\(state) must never render green")
        }
    }

    func testNoTakeNeverReadsAsReadyOrConfirmed() {
        let noTake = ReviewPresentationState.derive(ReviewPresentationInput())
        XCTAssertEqual(noTake, .noTake)
        XCTAssertNotEqual(noTake, .ready)
        XCTAssertNotEqual(noTake, .confirmed, "no take must never fabricate captured/confirmed evidence")
        XCTAssertNotEqual(noTake, .corrected, "no take must never fabricate a correction")
    }

    func testLabelsAreNonBlankAndUppercase() {
        let all: [ReviewPresentationState] = [.noTake, .recording, .finalizing, .issue, .ready, .corrected, .confirmed, .exporting, .exported, .exportFailed]
        for state in all {
            XCTAssertFalse(state.label.isEmpty)
            XCTAssertEqual(state.label, state.label.uppercased())
        }
    }
}

// MARK: - Advanced Overview summary derivation

final class AdvancedOverviewSummaryTests: XCTestCase {

    // MARK: Helpers

    private func lane(_ lane: AdvancedOverviewLane, in input: AdvancedOverviewInput) -> AdvancedOverviewStatus {
        guard let item = AdvancedOverviewSummary.derive(input).items.first(where: { $0.lane == lane }) else {
            XCTFail("Missing \(lane) lane in derived summary")
            return .unavailable
        }
        return item.status
    }

    private func nextAction(_ input: AdvancedOverviewInput) -> AdvancedOverviewNextAction {
        AdvancedOverviewSummary.derive(input).nextAction
    }

    // MARK: Audio — READY only when the selected input is actually present

    func testAudioNoDeviceIsSetupRequired() {
        XCTAssertEqual(lane(.audio, in: AdvancedOverviewInput(hasAnyAudioDevice: false)), .setupRequired)
    }

    func testAudioSelectedDeviceMissingIsNeedsAttention() {
        XCTAssertEqual(lane(.audio, in: AdvancedOverviewInput(hasAnyAudioDevice: true, isSelectedAudioAvailable: false)), .needsAttention)
    }

    func testAudioAvailableIsReady() {
        XCTAssertEqual(lane(.audio, in: AdvancedOverviewInput(hasAnyAudioDevice: true, isSelectedAudioAvailable: true)), .ready)
    }

    // MARK: DVS — only a usable signal is READY; carrier/weak/clipped never are

    func testDVSDisabledIsUnavailableNotSetupRequired() {
        XCTAssertEqual(lane(.dvsTimecode, in: AdvancedOverviewInput(isDVSEnabled: false, dvsSignalHealth: .usable)), .unavailable)
    }

    func testDVSNoSignalIsSetupRequired() {
        XCTAssertEqual(lane(.dvsTimecode, in: AdvancedOverviewInput(isDVSEnabled: true, dvsSignalHealth: .noSignal)), .setupRequired)
    }

    func testDVSNonUsableHealthIsNeverReady() {
        // Guarded over ALL non-usable cases so a future carrier-detected state
        // can never slip in and read as READY.
        for health in SignalHealth.allCases where health != .usable {
            let status = lane(.dvsTimecode, in: AdvancedOverviewInput(isDVSEnabled: true, dvsSignalHealth: health))
            XCTAssertNotEqual(status, .ready, "\(health) must never read as READY — only .usable is ready")
        }
    }

    func testDVSOnlyUsableHealthIsReady() {
        XCTAssertEqual(lane(.dvsTimecode, in: AdvancedOverviewInput(isDVSEnabled: true, dvsSignalHealth: .usable)), .ready)
    }

    // MARK: MIDI — connected ≠ mapped; mapped ≠ DVS+MIDI ready

    func testMIDINoControllerIsSetupRequired() {
        XCTAssertEqual(lane(.midiController, in: AdvancedOverviewInput(hasMIDIController: false)), .setupRequired)
    }

    func testMIDIUnmappedCrossfaderIsNeedsAttention() {
        XCTAssertEqual(lane(.midiController, in: AdvancedOverviewInput(hasMIDIController: true, isCrossfaderMapped: false)), .needsAttention)
    }

    func testMIDIMappedWithoutDVSIsDetectedNotReady() {
        let status = lane(.midiController, in: AdvancedOverviewInput(
            isDVSEnabled: true, dvsSignalHealth: .noSignal, hasMIDIController: true, isCrossfaderMapped: true))
        XCTAssertEqual(status, .detected)
    }

    func testMIDIDVSPlusMIDIReadyIsReady() {
        let status = lane(.midiController, in: AdvancedOverviewInput(
            isDVSEnabled: true, dvsSignalHealth: .usable, hasMIDIController: true, isCrossfaderMapped: true))
        XCTAssertEqual(status, .ready)
    }

    // MARK: Camera — optional, non-blocking

    func testCameraHiddenWhenNotEnabledOrActive() {
        let items = AdvancedOverviewSummary.derive(AdvancedOverviewInput(isCameraActive: false, isLiveInputEnabled: false)).items
        XCTAssertFalse(items.contains { $0.lane == .camera }, "optional camera must be omitted when inactive")
    }

    func testCameraActiveIsDetected() {
        XCTAssertEqual(lane(.camera, in: AdvancedOverviewInput(isCameraActive: true)), .detected)
    }

    func testCameraEnabledButInactiveIsUnavailable() {
        XCTAssertEqual(lane(.camera, in: AdvancedOverviewInput(isCameraActive: false, isLiveInputEnabled: true)), .unavailable)
    }

    func testCameraDoesNotChangeNextAction() {
        let base = AdvancedOverviewInput(hasSession: true, hasAnyAudioDevice: true, isSelectedAudioAvailable: true, hasMIDIController: true, isCrossfaderMapped: true)
        let withCamera = AdvancedOverviewInput(hasSession: true, hasAnyAudioDevice: true, isSelectedAudioAvailable: true, hasMIDIController: true, isCrossfaderMapped: true, isCameraActive: true)
        XCTAssertEqual(nextAction(base), nextAction(withCamera), "camera must never gate the next action")
    }

    // MARK: Performer Monitor — connected is informational, not ready

    func testMonitorDisconnectedIsSetupRequired() {
        XCTAssertEqual(lane(.performerMonitor, in: AdvancedOverviewInput(isPerformerMonitorConnected: false)), .setupRequired)
    }

    func testMonitorConnectedIsDetectedNotReady() {
        XCTAssertEqual(lane(.performerMonitor, in: AdvancedOverviewInput(isPerformerMonitorConnected: true)), .detected)
    }

    // MARK: Next action — recording dominates, then setup, then blocking lanes

    func testRecordingDominatesNextAction() {
        let input = AdvancedOverviewInput(hasSession: true, isRecording: true, hasAnyAudioDevice: true, isSelectedAudioAvailable: true, hasMIDIController: true, isCrossfaderMapped: true)
        XCTAssertEqual(nextAction(input), .recording)
    }

    func testNoSessionIsCreateSession() {
        let input = AdvancedOverviewInput(hasSession: false, hasAnyAudioDevice: true, isSelectedAudioAvailable: true, hasMIDIController: true, isCrossfaderMapped: true)
        XCTAssertEqual(nextAction(input), .createSession)
    }

    func testAudioBlockedIsFixAudio() {
        XCTAssertEqual(nextAction(AdvancedOverviewInput(hasSession: true, hasAnyAudioDevice: false)), .fixAudio)
    }

    func testNoControllerIsConnectController() {
        let input = AdvancedOverviewInput(hasSession: true, hasAnyAudioDevice: true, isSelectedAudioAvailable: true, hasMIDIController: false)
        XCTAssertEqual(nextAction(input), .connectController)
    }

    func testUnmappedCrossfaderIsMapCrossfader() {
        let input = AdvancedOverviewInput(hasSession: true, hasAnyAudioDevice: true, isSelectedAudioAvailable: true, hasMIDIController: true, isCrossfaderMapped: false)
        XCTAssertEqual(nextAction(input), .mapCrossfader)
    }

    func testAllNonBlockingLanesReadyIsReady() {
        let input = AdvancedOverviewInput(hasSession: true, hasAnyAudioDevice: true, isSelectedAudioAvailable: true, hasMIDIController: true, isCrossfaderMapped: true)
        XCTAssertEqual(nextAction(input), .ready)
    }

    // MARK: Status vocabulary stays distinct

    func testStatusLabelsAreDistinctAndUppercase() {
        let statuses: [AdvancedOverviewStatus] = [.setupRequired, .needsAttention, .detected, .ready, .recording, .unavailable]
        var seen = Set<String>()
        for status in statuses {
            XCTAssertFalse(status.label.isEmpty)
            XCTAssertEqual(status.label, status.label.uppercased())
            seen.insert(status.label)
        }
        XCTAssertEqual(seen.count, statuses.count, "six summary states must have distinct labels")
    }

    func testStatusVariantsMatchSemanticContract() {
        XCTAssertEqual(AdvancedOverviewStatus.setupRequired.variant, .neutral)
        XCTAssertEqual(AdvancedOverviewStatus.needsAttention.variant, .warning)
        XCTAssertEqual(AdvancedOverviewStatus.detected.variant, .info)
        XCTAssertEqual(AdvancedOverviewStatus.ready.variant, .ready)
        XCTAssertEqual(AdvancedOverviewStatus.recording.variant, .danger)
        XCTAssertEqual(AdvancedOverviewStatus.unavailable.variant, .neutral)
    }

    // MARK: Hardware identity is not part of a readiness badge

    func testOverviewStatusLabelsNeverBakeHardwareIdentity() {
        let forbidden = ["RANE", "DJM", "PIONEER", "S11", "S9", "S7", "MKII", "USB MIDI"]
        for status in AdvancedOverviewStatus.allCases {
            let upper = status.label.uppercased()
            for name in forbidden {
                XCTAssertFalse(upper.contains(name), "\(status.label) must not bake a hardware name into a summary status")
            }
        }
    }
}

// MARK: - Performer Monitor connection-state derivation

final class PerformerMonitorStateTests: XCTestCase {

    // MARK: Disconnected states (truthful — no transport required)

    func testSearchingAndConnectingAreSearching() {
        XCTAssertEqual(PerformerMonitorConnectionState.disconnectedState(fromStatus: "Searching for Performer Monitor on a nearby device"), .searching)
        XCTAssertEqual(PerformerMonitorConnectionState.disconnectedState(fromStatus: "Connecting to Karl's Mac"), .searching)
        XCTAssertEqual(PerformerMonitorConnectionState.disconnectedState(fromStatus: "Enter the connection name shown in ScratchLab"), .searching)
    }

    func testPausedAndLostAreConnectionFailed() {
        XCTAssertEqual(PerformerMonitorConnectionState.disconnectedState(fromStatus: "Device connection paused. Check network."), .connectionFailed)
        XCTAssertEqual(PerformerMonitorConnectionState.disconnectedState(fromStatus: "Connection to device paused. Check connection."), .connectionFailed)
        XCTAssertEqual(PerformerMonitorConnectionState.disconnectedState(fromStatus: "Connection to device lost."), .connectionFailed)
        XCTAssertEqual(PerformerMonitorConnectionState.disconnectedState(fromStatus: "Unable to send to device. Check connection."), .connectionFailed)
    }

    func testUnableToStartIsUnavailable() {
        XCTAssertEqual(PerformerMonitorConnectionState.disconnectedState(fromStatus: "Unable to start device sharing. Check network."), .unavailable)
    }

    // MARK: Connected peers map to the role-appropriate state

    func testConnectedPeersMapToControlledByMacOnClients() {
        // The mobile client is read-only: a connected peer means CONTROLLED BY MAC.
        let clientState: PerformerMonitorConnectionState = {
            let peers: [String] = ["Karl's Mac"]
            return peers.isEmpty ? .searching : .controlledByMac
        }()
        XCTAssertEqual(clientState, .controlledByMac)
        XCTAssertEqual(clientState.label, "CONTROLLED BY MAC")
    }

    func testConnectedPeersMapToConnectedOnControllingMac() {
        // The Mac is the controller: a connected peer means CONNECTED.
        let macState: PerformerMonitorConnectionState = {
            let peers: [String] = ["iPhone"]
            return peers.isEmpty ? .searching : .connected
        }()
        XCTAssertEqual(macState, .connected)
        XCTAssertEqual(macState.label, "CONNECTED")
    }

    // MARK: Labels stay truthful and role-distinct

    func testConnectionStateLabels() {
        XCTAssertEqual(PerformerMonitorConnectionState.searching.label, "SEARCHING")
        XCTAssertEqual(PerformerMonitorConnectionState.connected.label, "CONNECTED")
        XCTAssertEqual(PerformerMonitorConnectionState.controlledByMac.label, "CONTROLLED BY MAC")
        XCTAssertEqual(PerformerMonitorConnectionState.connectionFailed.label, "CONNECTION FAILED")
        XCTAssertEqual(PerformerMonitorConnectionState.unavailable.label, "UNAVAILABLE")
    }

    func testConnectionStateVariantsAreSemantic() {
        XCTAssertEqual(PerformerMonitorConnectionState.searching.variant, .info)
        XCTAssertEqual(PerformerMonitorConnectionState.connected.variant, .ready)
        XCTAssertEqual(PerformerMonitorConnectionState.controlledByMac.variant, .ready, "controlled is bone READY, never green")
        XCTAssertEqual(PerformerMonitorConnectionState.connectionFailed.variant, .danger)
        XCTAssertEqual(PerformerMonitorConnectionState.unavailable.variant, .neutral)
    }
}

/// Beta-blocker regressions for the 2026-08-17 cross-workspace fix list.
/// These defects live in `MacAnalyzerView` (a SwiftUI view that needs a full
/// engine/environment to instantiate), so they are pinned as source-string
/// regressions against the live production source — the same pattern as the
/// `RegistryDrivenComparisonSurfaceTests` suite — rather than behavioral tests.
final class CrossWorkspaceFixRegressionTests: XCTestCase {

    private func macAnalyzerSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ScratchLabDesktopTests/
            .deletingLastPathComponent()   // repo root
        return try String(
            contentsOf: root.appendingPathComponent("ScratchLabDesktop/Views/MacAnalyzerView.swift"),
            encoding: .utf8
        )
    }

    /// B2 — after relaunch the Review header must restore the persisted label
    /// decision (status + label), not just `reviewMetadata`. Pins that the
    /// reload path actually reads `sidecar.reviewDecision`.
    func testReviewReloadReadsPersistedLabelDecision() throws {
        let source = try macAnalyzerSource()
        XCTAssertTrue(
            source.contains("sidecar.reviewDecision"),
            "loadReviewMetadataForCurrentTake must read sidecar.reviewDecision to restore the label decision"
        )
        XCTAssertTrue(
            source.contains("reviewDecisionStatusByTakeID[reviewTakeID] = decision.status"),
            "the persisted decision status must be restored into the header-badge source"
        )
        XCTAssertTrue(
            source.contains("reviewDecisionByTakeID[reviewTakeID] = correction"),
            "the persisted decision label must be restored into the summary source"
        )
    }

    /// B3 — the Capture action row must not offer a destructive "Discard" that
    /// is actually a no-op (`prepareRetake`). The single real action is
    /// "Record another", accurately labeled.
    func testCaptureActionRowHasNoDiscardNoOp() throws {
        let source = try macAnalyzerSource()
        XCTAssertFalse(
            source.contains("Button(\"Discard\")"),
            "the misleading no-op Discard button must stay removed"
        )
        XCTAssertTrue(
            source.contains("Button(\"Record another\")"),
            "the accurate 'Record another' action must remain"
        )
    }
}

/// Privacy / permission / App-Store-safety regression guards for the
/// 2026-08-17 quality audit. These pin invariants that, if regressed, cause a
/// hard crash (missing usage description), App Store rejection (missing
/// required-reason API categories, tracking, undeclared data collection), or
/// unintended data exfiltration (cloud upload enabled outside DEBUG).
final class PrivacyAndPermissionRegressionTests: XCTestCase {

    private func repoFile(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ScratchLabDesktopTests/
            .deletingLastPathComponent()   // repo root
        return try String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    /// Camera/mic/local-network usage descriptions must stay present — a
    /// missing `NSCameraUsageDescription`/`NSMicrophoneUsageDescription`
    /// crashes the process the moment the permission prompt would appear.
    func testUsageDescriptionsPresentOnBothPlatforms() throws {
        for path in ["ScratchLab/Info.plist", "ScratchLabDesktop/Info.plist"] {
            let plist = try repoFile(path)
            XCTAssertTrue(plist.contains("NSCameraUsageDescription"), "\(path) missing NSCameraUsageDescription")
            XCTAssertTrue(plist.contains("NSMicrophoneUsageDescription"), "\(path) missing NSMicrophoneUsageDescription")
            XCTAssertTrue(plist.contains("NSLocalNetworkUsageDescription"), "\(path) missing NSLocalNetworkUsageDescription")
        }
    }

    /// Privacy manifests must declare no tracking and no collected data types,
    /// and carry the required-reason API categories (mandatory for App Store
    /// submission since 2024).
    func testPrivacyManifestsDeclareNoTrackingOrCollection() throws {
        for path in ["ScratchLab/PrivacyInfo.xcprivacy", "ScratchLabDesktop/PrivacyInfo.xcprivacy"] {
            let manifest = try repoFile(path)
            XCTAssertTrue(manifest.contains("<key>NSPrivacyTracking</key>"), "\(path) missing tracking declaration")
            XCTAssertTrue(manifest.contains("<false/>"), "\(path) does not declare tracking false")
            XCTAssertTrue(manifest.contains("NSPrivacyCollectedDataTypes"), "\(path) missing collected-data-types declaration")
            XCTAssertFalse(manifest.contains("NSPrivacyCollectedDataTypeType"),
                           "\(path) must not declare any collected data type")
            XCTAssertTrue(manifest.contains("NSPrivacyAccessedAPICategoryUserDefaults"), "\(path) missing UserDefaults reason")
            XCTAssertTrue(manifest.contains("NSPrivacyAccessedAPICategoryFileTimestamp"), "\(path) missing FileTimestamp reason")
            XCTAssertTrue(manifest.contains("NSPrivacyAccessedAPICategorySystemBootTime"), "\(path) missing SystemBootTime reason")
        }
    }

    /// Cloud session upload must remain Release-disabled (`apiBaseURL` nil
    /// outside DEBUG) so captured sessions stay on-device unless the user
    /// explicitly exports them.
    func testCloudUploadDisabledOutsideDebug() throws {
        let source = try repoFile("ScratchLab/Services/SessionUploadManager.swift")
        XCTAssertTrue(source.contains("#if !DEBUG"),
                      "SessionUploadConfiguration.current() must gate its Release branch with #if !DEBUG")
        XCTAssertTrue(source.contains("apiBaseURL: nil"),
                      "the Release branch must return apiBaseURL: nil (upload unavailable)")
    }
}

// Canonical renderer snapshots use the exact projected line segments consumed
// by Canvas, following this file's deterministic geometry testing convention.
final class CanonicalTearRendererTests: XCTestCase {
    private typealias Record = ScratchNotation.GestureRecord
    private typealias Geometry = ScratchStrokeGeometry.CanonicalGeometry
    private typealias Frame = ScratchStrokeGeometry.CanonicalFrame

    private var motionEvidence: Record.Evidence {
        .init(provenance: .measured, observation: .init(source: .platterTimeline,
            confidence: 1, reason: "Deterministic curve fixture"))
    }
    private var faderEvidence: Record.Evidence {
        .init(provenance: .measured, observation: .init(source: .crossfaderRaw,
            confidence: 1, reason: "Deterministic fader fixture"))
    }
    private func frame(time: ClosedRange<Double> = 0...8, position: ClosedRange<Double> = 0...4,
                       bpm: Double = 120) throws -> Frame {
        try XCTUnwrap(Frame(timeRange: time, positionRange: position,
                            coordinateSpace: .samplePosition, beatsPerMinute: bpm))
    }
    private func tear(_ weights: [Double] = [1, 1], direction: ScratchNotationDirection = .forward,
                      domain: ScratchNotationTimingDomain = .seconds,
                      faderState: ScratchNotationFaderState = .open) -> Record {
        var subdivisions: [Record.Subdivision] = []
        var holds: [Record.TearHold] = []
        var time = 0.0
        let sign = direction == .forward ? 1.0 : -1.0
        for (index, weight) in weights.enumerated() {
            let position = Double(index) * sign
            let curve = Record.MotionCurve(points: [.init(time: time, position: position),
                .init(time: time + weight, position: position + sign)], evidence: motionEvidence)
            subdivisions.append(.init(id: "move-\(index)", span: .init(startTime: time, endTime: time + weight),
                evidence: motionEvidence, measuredCurve: curve, targetCurve: curve, authoredDurationWeight: weight))
            time += weight
            if index < weights.count - 1 {
                holds.append(.init(id: "hold-\(index)", span: .init(startTime: time, endTime: time + 0.25),
                    label: .init(derived: .stationary), evidence: motionEvidence, position: position + sign))
                time += 0.25
            }
        }
        return Record(id: "tear-fixture", direction: direction, timingDomain: domain,
            coordinateSpace: .samplePosition, evidence: motionEvidence,
            subdivisions: subdivisions, internalHolds: holds,
            faderIntervals: [.init(id: "fader", span: .init(startTime: 0, endTime: time),
                                  state: faderState, evidence: faderEvidence)])
    }
    private func replacing(_ record: Record, subdivisions: [Record.Subdivision]? = nil,
                           holds: [Record.TearHold]? = nil, intervals: [Record.FaderSpan]? = nil,
                           edges: [Record.FaderTransition]? = nil) -> Record {
        .init(id: record.id, direction: record.direction, timingDomain: record.timingDomain,
              coordinateSpace: record.coordinateSpace, evidence: record.evidence,
              subdivisions: subdivisions ?? record.subdivisions, internalHolds: holds ?? record.internalHolds,
              faderTransitions: edges ?? record.faderTransitions, faderIntervals: intervals ?? record.faderIntervals)
    }
    private func geometry(_ record: Record, layer: ScratchStrokeGeometry.CanonicalLayer = .performance,
                          in frame: Frame? = nil) throws -> Geometry {
        ScratchStrokeGeometry.canonicalGeometry(records: [record], layer: layer, frame: try frame ?? self.frame())
    }
    private func snapshot(_ path: MotionPath, time: ClosedRange<Double> = 0...8,
                          width: CGFloat = 800) -> [[Double]] {
        let viewport = LaneViewport(size: CGSize(width: width, height: 100), now: time.lowerBound,
            axis: .horizontal, actionLineFraction: 0, secondsAhead: time.upperBound - time.lowerBound)
        return ScratchMotionRenderer.projectedSegments(path, viewport: viewport)
            .filter { $0.segment.drawsLine }.map { item in
                [item.a.x, item.a.y, item.b.x, item.b.y].map { (Double($0) * 1e6).rounded() / 1e6 }
            }
    }

    func testOneTwoAndThreeTearCoordinateSnapshots() throws {
        let snapshots: [[[Double]]] = [
            [[0,88,100,69], [100,69,125,69], [125,69,225,50]],
            [[0,88,100,69], [100,69,125,69], [125,69,225,50], [225,50,250,50], [250,50,350,31]],
            [[0,88,100,69], [100,69,125,69], [125,69,225,50], [225,50,250,50],
             [250,50,350,31], [350,31,375,31], [375,31,475,12]]
        ]
        for count in 1...3 {
            let record = tear(Array(repeating: 1, count: count + 1))
            XCTAssertTrue(record.validationIssues().isEmpty)
            for layer in [ScratchStrokeGeometry.CanonicalLayer.target, .performance] {
                let result = try geometry(record, layer: layer)
                XCTAssertEqual(snapshot(result.motion), snapshots[count - 1])
                XCTAssertEqual(result.motion.segments.filter(\.isHold).count, count)
                XCTAssertTrue(result.faderEdges.isEmpty, "a tear hold never creates a fader glyph")
                XCTAssertEqual(result, try geometry(record, layer: layer))
            }
        }
    }

    func testIrregularRatiosRetainActualTimingAndSlope() throws {
        let result = try geometry(tear([0.5, 1.5, 0.75]))
        XCTAssertEqual(snapshot(result.motion), [[0,88,50,69], [50,69,75,69],
            [75,69,225,50], [225,50,250,50], [250,50,325,31]])
        XCTAssertEqual(result.motion.segments.filter { !$0.isHold }.map(\.duration), [0.5, 1.5, 0.75])
    }

    func testBackwardTearsFallAndHoldsStayHorizontal() throws {
        let result = try geometry(tear([1, 1], direction: .backward), in: frame(position: -4...0))
        XCTAssertEqual(snapshot(result.motion), [[0,12,100,31], [100,31,125,31], [125,31,225,50]])
    }

    func testLocalCurveSpeedSurvivesWithoutSpeedBucketGeometry() throws {
        let record = tear([1])
        let curve = Record.MotionCurve(points: [.init(time: 0, position: 0),
            .init(time: 0.2, position: 0.8), .init(time: 1, position: 1)], evidence: motionEvidence)
        let subdivision = Record.Subdivision(id: "move", span: .init(startTime: 0, endTime: 1),
            evidence: motionEvidence, measuredCurve: curve, targetCurve: curve)
        let result = try geometry(replacing(record, subdivisions: [subdivision]))
        XCTAssertEqual(snapshot(result.motion), [[0,88,20,72.8], [20,72.8,100,69]])
    }

    func testHoldAndClickAreIndependentEvenWhenClickFallsInsideHold() throws {
        let record = tear()
        let intervals: [Record.FaderSpan] = [
            .init(id: "open1", span: .init(startTime: 0, endTime: 1.1), state: .open, evidence: faderEvidence),
            .init(id: "close", span: .init(startTime: 1.1, endTime: 1.15), state: .closed, evidence: faderEvidence),
            .init(id: "open2", span: .init(startTime: 1.15, endTime: 2.25), state: .open, evidence: faderEvidence)
        ]
        let edges: [Record.FaderTransition] = [
            .init(id: "click-down", time: 1.1, state: .closed, evidence: faderEvidence),
            .init(id: "click-up", time: 1.15, state: .open, evidence: faderEvidence)
        ]
        let result = try geometry(replacing(record, intervals: intervals, edges: edges))
        XCTAssertEqual(result.faderEdges.map(\.time), [1.1, 1.15])
        let holds = result.motion.segments.filter(\.isHold)
        XCTAssertEqual(holds.map(\.evidenceStyle), [.open, .closed, .open])
        XCTAssertTrue(holds.allSatisfy { $0.drawsLine && $0.startPosition == $0.endPosition })
        XCTAssertEqual(holds.reduce(0) { $0 + $1.duration }, 0.25, accuracy: 1e-12)
        XCTAssertTrue(try geometry(replacing(record, intervals: intervals)).faderEdges.isEmpty,
                      "rail state boundaries alone do not claim a click")
    }

    func testMeasuredLocalPlateauPreservesZeroSlopeWithoutInventingAClick() throws {
        let record = tear([1])
        let curve = Record.MotionCurve(points: [.init(time: 0, position: 0),
            .init(time: 0.4, position: 0.5), .init(time: 0.5, position: 0.5),
            .init(time: 1, position: 1)], evidence: motionEvidence)
        let sub = Record.Subdivision(id: "move", span: .init(startTime: 0, endTime: 1),
            evidence: motionEvidence, measuredCurve: curve)
        let result = try geometry(replacing(record, subdivisions: [sub]))
        XCTAssertEqual(snapshot(result.motion), [[0,88,40,78.5], [40,78.5,50,78.5], [50,78.5,100,69]])
        XCTAssertTrue(result.faderEdges.isEmpty)
    }

    func testFaderEdgesDoNotFillMissingIntervalsAndUseTheSameBeatMapping() throws {
        let record = replacing(tear([1], domain: .beats), intervals: [], edges: [
            .init(id: "close", time: 0.2, state: .closed, evidence: faderEvidence),
            .init(id: "open", time: 0.4, state: .open, evidence: faderEvidence)])
        let result = try geometry(record)
        XCTAssertEqual(result.faderEdges.map(\.time), [0.1, 0.2])
        XCTAssertTrue(result.fader.allSatisfy { $0.state == nil })
        XCTAssertTrue(result.motion.segments.allSatisfy { $0.evidenceStyle == .unknownFader })
    }

    func testGhostAndGhostHoldUseClosedStylingInBothTraceIdentities() throws {
        let open = try geometry(tear())
        let closed = try geometry(tear(faderState: .closed))
        XCTAssertEqual(snapshot(open.motion), snapshot(closed.motion))
        XCTAssertTrue(closed.motion.segments.allSatisfy { $0.evidenceStyle == .closed && !$0.isGhost })
        XCTAssertTrue(closed.faderEdges.isEmpty, "extended closure is not a click")
        for style in [ScratchMotionRenderer.Style.target, .performance] {
            for segment in closed.motion.segments {
                let appearance = ScratchMotionRenderer.lineAppearance(for: segment, style: style)
                XCTAssertEqual(appearance.dash, [4, 3])
                XCTAssertEqual(appearance.opacity, 0.45)
                XCTAssertEqual(appearance.width, style.lineWidth)
            }
        }
        XCTAssertEqual(ScratchMotionRenderer.Style.target.color, ScratchLabDesign.Notation.targetTrace)
        XCTAssertEqual(ScratchMotionRenderer.Style.performance.color, ScratchLabDesign.Notation.performanceTrace)
    }

    func testMissingFaderIsExplicitAndDoesNotInventOpenOrClosed() throws {
        let result = try geometry(replacing(tear(), intervals: []))
        XCTAssertTrue(result.motion.segments.allSatisfy { $0.evidenceStyle == .unknownFader })
        XCTAssertEqual(result.fader, [.init(range: 0...8, state: nil)])
        XCTAssertTrue(result.faderEdges.isEmpty)
        let appearance = ScratchMotionRenderer.lineAppearance(for: try XCTUnwrap(result.motion.segments.first), style: .target)
        XCTAssertEqual(appearance.dash, [1, 3])
    }

    func testPlatterEvidenceCannotMintAFaderClick() throws {
        let record = replacing(tear(), edges: [
            .init(id: "phantom", time: 1, state: .closed, evidence: motionEvidence)])
        let result = try geometry(record)
        XCTAssertFalse(result.motion.isEmpty)
        XCTAssertTrue(result.faderEdges.isEmpty)
        XCTAssertTrue(result.hasUnplacedEvidence)
        XCTAssertTrue(result.fader.allSatisfy { $0.state == nil })
    }

    func testMissingTargetCurveNeverFallsBackToPerformance() throws {
        let record = tear([1])
        let sub = record.subdivisions[0]
        let onlyMeasured = Record.Subdivision(id: sub.id, span: sub.span, evidence: sub.evidence,
                                               measuredCurve: sub.measuredCurve)
        let input = replacing(record, subdivisions: [onlyMeasured])
        XCTAssertFalse(try geometry(input).motion.isEmpty)
        let target = try geometry(input, layer: .target)
        XCTAssertTrue(target.motion.isEmpty)
        XCTAssertEqual(target.missingMotion, [0...8])
        let onlyTarget = Record.Subdivision(id: sub.id, span: sub.span, evidence: sub.evidence,
                                             targetCurve: sub.targetCurve)
        XCTAssertTrue(try geometry(replacing(record, subdivisions: [onlyTarget])).motion.isEmpty)
    }

    func testMissingHoldPositionIsAGapNotAZeroPositionOrClick() throws {
        let record = tear()
        let hold = record.internalHolds[0]
        let missing = Record.TearHold(id: hold.id, span: hold.span, label: hold.label,
                                      evidence: hold.evidence, position: nil)
        let result = try geometry(replacing(record, holds: [missing]))
        XCTAssertEqual(result.missingMotion, [1...1.25, 2.25...8])
        XCTAssertFalse(result.motion.segments.contains(where: \.isHold))
        XCTAssertTrue(result.faderEdges.isEmpty)
    }

    func testObservedHoldPositionIsNotSnappedToAdjacentCurveEndpoints() throws {
        let record = tear(), hold = record.internalHolds[0]
        let observed = Record.TearHold(id: hold.id, span: hold.span, label: hold.label,
            evidence: hold.evidence, position: 1.125)
        let result = try geometry(replacing(record, holds: [observed]))
        XCTAssertEqual(snapshot(result.motion), [[0,88,100,69], [100,66.625,125,66.625], [125,69,225,50]])
        XCTAssertTrue(result.faderEdges.isEmpty)
    }

    func testUnknownOrReleasedHoldDoesNotProduceValidMotion() throws {
        for state in [ScratchNotationMotionState.unknown, .released] {
            let record = tear(), hold = record.internalHolds[0]
            let unknown = Record.TearHold(id: hold.id, span: hold.span, label: .init(derived: state),
                                          evidence: hold.evidence, position: hold.position)
            let result = try geometry(replacing(record, holds: [unknown]))
            XCTAssertTrue(result.motion.isEmpty)
            XCTAssertEqual(result.missingMotion, [0...8])
            XCTAssertEqual(result.fader.first?.state, .open, "independent fader evidence survives")
        }
    }

    func testNonFiniteContradictoryAndFlatMovingCurvesAreUnknown() throws {
        for position in [Double.nan, .infinity, -1, 0] {
            let record = tear([1])
            let curve = Record.MotionCurve(points: [.init(time: 0, position: 0),
                .init(time: 1, position: position)], evidence: motionEvidence)
            let sub = Record.Subdivision(id: "move", span: .init(startTime: 0, endTime: 1),
                evidence: motionEvidence, measuredCurve: curve)
            let result = try geometry(replacing(record, subdivisions: [sub]))
            XCTAssertTrue(result.motion.isEmpty)
            XCTAssertEqual(result.missingMotion, [0...8])
        }
    }

    func testOverlappingMotionAndFaderEvidenceRemainUnknown() throws {
        let record = tear()
        let result = ScratchStrokeGeometry.canonicalGeometry(records: [record, record], layer: .performance, frame: try frame())
        XCTAssertTrue(result.motion.isEmpty)
        XCTAssertEqual(result.missingMotion, [0...8])
        XCTAssertTrue(result.fader.allSatisfy { $0.state == nil })
    }

    func testBeatsAndSecondsShareGridCoordinatesWithoutSnapping() throws {
        let beats = tear([1, 1], domain: .beats)
        let seconds = tear([1, 1])
        // At 60 bpm beats and seconds coincide, including the quarter-unit hold.
        let shared = try frame(time: 0.5...4, bpm: 60)
        let target = try geometry(beats, layer: .target, in: shared)
        let performance = try geometry(seconds, in: shared)
        XCTAssertEqual(target, performance)
        XCTAssertEqual(snapshot(target.motion, time: 0.5...4, width: 350).first, [0,78.5,50,69])
        // At 120 bpm beat coordinates halve; seconds evidence remains verbatim.
        let fast = try geometry(beats, in: frame())
        XCTAssertEqual(fast.motion.segments.map(\.startTime), [0, 0.5, 0.625])
        XCTAssertEqual(try geometry(seconds).motion.segments.map(\.startTime), [0, 1, 1.25])
    }

    func testFaderBoundaryInterpolatesCurveWithoutChangingSlope() throws {
        let record = tear([1])
        let intervals: [Record.FaderSpan] = [
            .init(id: "a", span: .init(startTime: 0, endTime: 0.25), state: .open, evidence: faderEvidence),
            .init(id: "b", span: .init(startTime: 0.25, endTime: 1), state: .closed, evidence: faderEvidence)]
        let result = try geometry(replacing(record, intervals: intervals))
        XCTAssertEqual(snapshot(result.motion), [[0,88,25,83.25], [25,83.25,100,69]])
        XCTAssertEqual(result.motion.segments.map(\.evidenceStyle), [.open, .closed])
    }

    func testOutOfFramePositionsAreNotClampedIntoFalseHolds() throws {
        let result = try geometry(tear([1]), in: frame(position: 0...0.25))
        XCTAssertEqual(snapshot(result.motion), [[0,88,100,-216]])
        XCTAssertFalse(result.motion.segments[0].isHold)
    }

    func testInvalidOrMismatchedFrameNeverInventsGeometry() throws {
        XCTAssertNil(Frame(timeRange: 0...0, positionRange: 0...1, coordinateSpace: .samplePosition, beatsPerMinute: 120))
        XCTAssertNil(Frame(timeRange: 0...1, positionRange: 0...0, coordinateSpace: .samplePosition, beatsPerMinute: 120))
        XCTAssertNil(Frame(timeRange: 0...1, positionRange: 0...1, coordinateSpace: .samplePosition, beatsPerMinute: .nan))
        let mismatch = try XCTUnwrap(Frame(timeRange: 0...8, positionRange: 0...4,
                                           coordinateSpace: .platterRevolutions, beatsPerMinute: 120))
        XCTAssertTrue(try geometry(tear(), in: mismatch).motion.isEmpty)
    }

    func testEmptyRecordsRenderBothEvidenceLanesUnknown() throws {
        let result = ScratchStrokeGeometry.canonicalGeometry(records: [], layer: .target, frame: try frame())
        XCTAssertTrue(result.motion.isEmpty)
        XCTAssertEqual(result.missingMotion, [0...8])
        XCTAssertEqual(result.fader, [.init(range: 0...8, state: nil)])
    }

    func testCanonicalSourceUsesExistingPanelAndCanvas() throws {
        let shared = try frame()
        for layer in [ScratchStrokeGeometry.CanonicalLayer.target, .performance] {
            let source = ScratchPhraseChartView.ChartSource.canonical([tear()], layer: layer, frame: shared)
            let panel = ScratchNotationPanel(lane: layer == .target ? .target : .performance,
                presentation: .standard, source: source)
            _ = panel.body
            _ = ScratchPhraseChartView(source: source).body
        }
    }

    func testLegacyBabyChirpAndTransformerGeometryAndStyleSnapshots() throws {
        // Representative existing seconds-domain inputs, not new registry targets.
        let edgeSets: [[ScratchNotation.FaderEvent]] = [[],
            [.init(time: 0, state: .open), .init(time: 0.45, state: .closed), .init(time: 0.55, state: .open)],
            [.init(time: 0, state: .closed), .init(time: 0.2, state: .open), .init(time: 0.3, state: .closed),
             .init(time: 0.5, state: .open), .init(time: 0.6, state: .closed), .init(time: 0.8, state: .open)]
        ]
        for (name, edges) in zip(["baby_scratch", "chirp", "transformer"], edgeSets) {
            let notation = ScratchNotation(version: 1, scratchID: name, demoStart: 0, demoEnd: 1,
                phraseStart: 0, phraseEnd: 1, timingBasis: "seconds", strokes: [
                    .init(startTime: 0, endTime: 0.5, direction: .forward, speedClassification: .medium, faderState: .open),
                    .init(startTime: 0.5, endTime: 1, direction: .backward, speedClassification: .medium, faderState: .open)
                ], faderEvents: edges)
            let path = ScratchStrokeGeometry.motionPath(for: LaneContent(notation: notation))
            XCTAssertEqual(snapshot(path, time: 0...1, width: 100), [[0,88,50,12], [50,12,100,88]], name)
            XCTAssertTrue(path.segments.allSatisfy { $0.evidenceStyle == .legacy })
            for style in [ScratchMotionRenderer.Style.target, .performance] {
                for segment in path.segments {
                    let appearance = ScratchMotionRenderer.lineAppearance(for: segment, style: style)
                    XCTAssertEqual(appearance.dash, [])
                    XCTAssertEqual(appearance.opacity, 1)
                    XCTAssertEqual(appearance.width, style.lineWidth)
                }
            }
            let spans = notation.faderAuthoritySpans(documentEnd: 1)
            if edges.isEmpty {
                XCTAssertTrue(spans.allSatisfy { $0.state == .open })
            } else {
                XCTAssertEqual(spans.map(\.startTime), edges.map(\.time))
                XCTAssertEqual(spans.map(\.state), edges.map(\.state))
            }
        }
    }
}
