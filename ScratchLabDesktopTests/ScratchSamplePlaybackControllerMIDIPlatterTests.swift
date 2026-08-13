// ScratchSamplePlaybackControllerMIDIPlatterTests.swift
// Controller-level, fixture-free coverage of the right-deck direct-MIDI
// continuous platter drive (2026-08-09): phase-per-revolution parity with
// DVS's calibration, idle/restart lifecycle, DVS-vs-MIDI ownership
// arbitration (click-free handoff, no stale-event resume), left/right
// deck isolation, and the legacy-rollback lever. Uses the synthetic-sample
// seam (`testOnly_installSyntheticSample`) so every test here also runs
// under the command-line harness that cannot resolve app-bundle fixtures.

import XCTest
import AVFoundation
@testable import ScratchLab

final class ScratchSamplePlaybackControllerMIDIPlatterTests: XCTestCase {

    private static let rate: Double = 44_100
    /// Direct-MIDI geometry (cue-lock drift fix, 2026-08-10) — derived from
    /// the shared production constant rather than duplicating the literal
    /// 3600 here, so this file and production code can never drift apart.
    private static let stepsPerRevolution = Double(ScratchSamplePlaybackController.raneOneMKIIDirectMIDIStepsPerRevolution)

    private func makeSyntheticLoopBuffer(frames: Int = 8_000) throws -> AVAudioPCMBuffer {
        // Stereo, matching the player-node graph the legacy grain path
        // schedules onto (a mono buffer trips AVAudioPlayerNode's
        // channel-count precondition).
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            let value = 0.8 * Float(sin(Double(i) * 2 * .pi / 100))
            buffer.floatChannelData![0][i] = value
            buffer.floatChannelData![1][i] = value
        }
        return buffer
    }

    /// Builds a controller with an injectable clock and a right-deck steps
    /// provider backed by a mutable local, plus a helper to drive one
    /// coalesced tick at a given `(steps, time)` pair.
    private func makeController() throws -> (
        controller: ScratchSamplePlaybackController,
        setNow: (TimeInterval) -> Void,
        setSteps: (Int) -> Void
    ) {
        final class Clock { var now: TimeInterval = 0 }
        final class Steps { var value: Int = 0 }
        let clock = Clock()
        let steps = Steps()
        let controller = ScratchSamplePlaybackController(schedulingClock: { clock.now })
        controller.testOnly_installSyntheticSample(try makeSyntheticLoopBuffer(), sampleID: "synthetic")
        controller.testOnly_setRightDeckAccumulatedStepsProvider { steps.value }
        return (controller, { clock.now = $0 }, { steps.value = $0 })
    }

    // MARK: - Forward / backward phase advancement

    func testMIDIContinuousForwardMotionAdvancesPhaseAndPublishesPositiveVelocity() throws {
        let (controller, setNow, setSteps) = try makeController()
        setNow(0.0); setSteps(0)
        controller.testOnly_midiCoalescingTick() // priming

        setNow(1.0 / 60.0); setSteps(40)
        controller.testOnly_midiCoalescingTick()

        XCTAssertGreaterThan(controller.currentSampleFrame, 0)
        XCTAssertEqual(controller.dvsContinuousRenderer.lastPublishedActive, true)
        XCTAssertGreaterThan(try XCTUnwrap(controller.dvsContinuousRenderer.lastPublishedVelocity), 0)
    }

    func testMIDIContinuousBackwardMotionPublishesNegativeVelocity() throws {
        let (controller, setNow, setSteps) = try makeController()
        setNow(0.0); setSteps(200)
        controller.testOnly_midiCoalescingTick() // priming

        setNow(1.0 / 60.0); setSteps(160)
        controller.testOnly_midiCoalescingTick()

        XCTAssertLessThan(try XCTUnwrap(controller.dvsContinuousRenderer.lastPublishedVelocity), 0)
    }

    /// Direct-MIDI geometry fix (2026-08-10; reaffirmed 2026-08-13 after
    /// reverting a same-day rate-rescaling experiment that a hardware test
    /// proved caused a "chipmunk" pitch/speed shift): precise numeric check
    /// that the published render velocity is `stepVelocity *
    /// midiFramesPerStep` using the 3600-based direct-MIDI real-vinyl-RPM
    /// scale, not a scale derived from the sample's own length —
    /// `midiFramesPerStep = (rate * vinylSecondsPerRevolution) / 3600`
    /// = `(44_100 * 1.8) / 3600` = `22.05` exactly for this synthetic
    /// buffer's rate, so both sides of this check are exact rationals.
    func testMIDIContinuousVelocityConversionUsesDirectMIDIScale() throws {
        let (controller, setNow, setSteps) = try makeController()
        setNow(0.0); setSteps(0)
        controller.testOnly_midiCoalescingTick() // priming

        setNow(1.0 / 60.0); setSteps(40)
        controller.testOnly_midiCoalescingTick()

        let stepVelocity = 40.0 / (1.0 / 60.0) // deltaSteps / elapsed
        let vinylSecondsPerRevolution = 1.8
        let midiFramesPerStep = (Self.rate * vinylSecondsPerRevolution) / Self.stepsPerRevolution
        let expectedFrameVelocity = stepVelocity * midiFramesPerStep

        XCTAssertEqual(
            try XCTUnwrap(controller.dvsContinuousRenderer.lastPublishedVelocity),
            expectedFrameVelocity,
            accuracy: 0.01,
            "Published velocity must use the direct-MIDI 3600-based real-vinyl-RPM frame scale, " +
            "not one derived from the sample's own length — sample duration must not affect pitch"
        )
    }

    // MARK: - Revolution / cue-mapping parity with the Rane's direct-MIDI geometry

    func testMIDIContinuousOneFullRevolutionForwardReturnsPhaseToOrigin() throws {
        let (controller, setNow, setSteps) = try makeController()
        setNow(0.0); setSteps(0)
        controller.testOnly_midiCoalescingTick() // priming

        setNow(1.0 / 60.0); setSteps(Int(Self.stepsPerRevolution))
        controller.testOnly_midiCoalescingTick()

        XCTAssertEqual(
            controller.currentSampleFrame,
            0,
            "Exactly one physical revolution forward of right-deck MIDI motion must return to the loop " +
            "origin, using the Rane's direct-MIDI (3600-step) geometry and 12 o'clock cue mapping"
        )
    }

    func testMIDIContinuousOneFullRevolutionBackwardReturnsPhaseToOrigin() throws {
        let (controller, setNow, setSteps) = try makeController()
        setNow(0.0); setSteps(Int(Self.stepsPerRevolution))
        controller.testOnly_midiCoalescingTick() // priming

        setNow(1.0 / 60.0); setSteps(0)
        controller.testOnly_midiCoalescingTick()

        XCTAssertEqual(
            controller.currentSampleFrame,
            0,
            "Exactly one physical revolution backward of right-deck MIDI motion must return to the loop origin"
        )
    }

    func testMIDIContinuousTenRevolutionsForwardReturnToOrigin() throws {
        let (controller, setNow, setSteps) = try makeController()
        setNow(0.0); setSteps(0)
        controller.testOnly_midiCoalescingTick() // priming

        setNow(1.0 / 60.0); setSteps(Int(Self.stepsPerRevolution) * 10)
        controller.testOnly_midiCoalescingTick()

        XCTAssertEqual(
            controller.currentSampleFrame,
            0,
            "Ten physical revolutions forward of right-deck MIDI motion must return to the loop origin"
        )
    }

    func testMIDIContinuousTenRevolutionsBackwardReturnToOrigin() throws {
        let (controller, setNow, setSteps) = try makeController()
        setNow(0.0); setSteps(Int(Self.stepsPerRevolution) * 10)
        controller.testOnly_midiCoalescingTick() // priming

        setNow(1.0 / 60.0); setSteps(0)
        controller.testOnly_midiCoalescingTick()

        assertReturnsToLoopOrigin(
            controller,
            "Ten physical revolutions backward of right-deck MIDI motion must return to the loop origin"
        )
    }

    func testMIDIContinuousTwentyRevolutionsForwardReturnToOrigin() throws {
        let (controller, setNow, setSteps) = try makeController()
        setNow(0.0); setSteps(0)
        controller.testOnly_midiCoalescingTick() // priming

        setNow(1.0 / 60.0); setSteps(Int(Self.stepsPerRevolution) * 20)
        controller.testOnly_midiCoalescingTick()

        XCTAssertEqual(
            controller.currentSampleFrame,
            0,
            "Twenty physical revolutions forward of right-deck MIDI motion must return to the loop origin " +
            "(hardware-verification scale — matches the powered-rotation measurement protocol)"
        )
    }

    func testMIDIContinuousTwentyRevolutionsBackwardReturnToOrigin() throws {
        let (controller, setNow, setSteps) = try makeController()
        setNow(0.0); setSteps(Int(Self.stepsPerRevolution) * 20)
        controller.testOnly_midiCoalescingTick() // priming

        setNow(1.0 / 60.0); setSteps(0)
        controller.testOnly_midiCoalescingTick()

        assertReturnsToLoopOrigin(
            controller,
            "Twenty physical revolutions backward of right-deck MIDI motion must return to the loop origin"
        )
    }

    /// A single large backward jump (10 or 20 revolutions in one synthetic
    /// tick — never how real CC6 arrives) can land the wrapped phase one
    /// frame short of the true origin (e.g. `dvsLoopFrames - 1` instead of
    /// `0`): `AVAudioFormat.sampleRate` does not round-trip to a bit-exact
    /// Double, and that sub-ULP deviation gets amplified by a large
    /// negative multiplier before `truncatingRemainder`'s wrap correction.
    /// This is a pre-existing floating-point characteristic of the shared
    /// mod-based phase math (equally present in DVS's own
    /// `dvsLoopPhaseFrame` for large accumulated step counts), not
    /// something this fix introduced — 1 frame out of ~79,380 is
    /// 0.0013% of a revolution, inaudible and irrelevant to real
    /// incremental CC6 accumulation. Accepting a 1-frame tolerance here,
    /// matching how the rest of this codebase treats phase-error
    /// comparisons.
    private func assertReturnsToLoopOrigin(
        _ controller: ScratchSamplePlaybackController,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let loopFrames = Int(controller.dvsLoopFrames)
        let frame = controller.currentSampleFrame
        let distanceFromOrigin = min(frame, loopFrames - frame)
        XCTAssertLessThanOrEqual(distanceFromOrigin, 1, message, file: file, line: line)
    }

    func testMIDIContinuousTenBabyScratchesReturnToStartingPhase() throws {
        let (controller, setNow, setSteps) = try makeController()
        setNow(0.0); setSteps(0)
        controller.testOnly_midiCoalescingTick() // priming

        var t = 0.0
        var steps = 0
        for _ in 0..<10 {
            t += 1.0 / 60.0
            steps += 25
            setNow(t); setSteps(steps)
            controller.testOnly_midiCoalescingTick()

            t += 1.0 / 60.0
            steps -= 25
            setNow(t); setSteps(steps)
            controller.testOnly_midiCoalescingTick()
        }

        XCTAssertEqual(
            controller.currentSampleFrame,
            0,
            "Ten equal forward/backward MIDI baby scratches must net back to exactly the starting phase"
        )
    }

    // MARK: - Idle / restart lifecycle

    func testMIDIContinuousIdleRetainsPhaseAndPublishesIdlePromptlyOnce() throws {
        let (controller, setNow, setSteps) = try makeController()
        setNow(0.0); setSteps(0)
        controller.testOnly_midiCoalescingTick() // priming

        setNow(1.0 / 60.0); setSteps(40)
        controller.testOnly_midiCoalescingTick()
        let phaseAtStop = controller.currentSampleFrame
        let idleCountAfterMotion = controller.dvsContinuousRenderer.idlePublishCount

        // Platter stops: two consecutive no-motion ticks.
        setNow(2.0 / 60.0)
        controller.testOnly_midiCoalescingTick()
        XCTAssertEqual(controller.dvsContinuousRenderer.idlePublishCount, idleCountAfterMotion + 1,
                        "The active -> idle transition must publish idle exactly once, promptly")
        XCTAssertEqual(controller.currentSampleFrame, phaseAtStop, "Idle must never reset phase")

        setNow(3.0 / 60.0)
        controller.testOnly_midiCoalescingTick()
        XCTAssertEqual(controller.dvsContinuousRenderer.idlePublishCount, idleCountAfterMotion + 1,
                        "An already-idle tick must not re-publish idle every cycle")
        XCTAssertEqual(controller.currentSampleFrame, phaseAtStop)
    }

    func testMIDIContinuousImmediateSlowRestartFromRetainedPhase() throws {
        let (controller, setNow, setSteps) = try makeController()
        setNow(0.0); setSteps(0)
        controller.testOnly_midiCoalescingTick() // priming

        setNow(1.0 / 60.0); setSteps(40)
        controller.testOnly_midiCoalescingTick()
        let phaseBeforeStop = controller.currentSampleFrame

        setNow(2.0 / 60.0) // no motion: settles idle
        controller.testOnly_midiCoalescingTick()

        // A small, slow restart tick.
        setNow(3.0 / 60.0); setSteps(41)
        controller.testOnly_midiCoalescingTick()

        XCTAssertEqual(controller.dvsContinuousRenderer.lastPublishedActive, true,
                        "Restart must respond immediately with an active publish")
        XCTAssertNotEqual(controller.currentSampleFrame, 0,
                           "Restart must resume from the retained phase, not a reset origin")
        XCTAssertGreaterThanOrEqual(controller.currentSampleFrame, phaseBeforeStop,
                                     "Forward restart must continue forward from where it stopped")
    }

    // MARK: - DVS ownership arbitration

    func testDVSOwnershipSuppressesMIDIContinuousPublication() throws {
        let (controller, setNow, setSteps) = try makeController()
        controller.setDVSOwnership(active: true)
        controller.waitForAudioQueue()

        setNow(0.0); setSteps(0)
        controller.testOnly_midiCoalescingTick() // priming attempt
        setNow(1.0 / 60.0); setSteps(40)
        controller.testOnly_midiCoalescingTick() // motion attempt

        XCTAssertEqual(controller.dvsContinuousRenderer.publishCount, 0,
                        "Active DVS ownership must suppress MIDI continuous publication entirely")
        XCTAssertFalse(controller.testOnly_midiOwnsPlatterRender)
        XCTAssertTrue(controller.testOnly_dvsOwnsPlatterRender)
    }

    func testOwnershipHandoffToDVSIsClickFree() throws {
        let (controller, setNow, setSteps) = try makeController()
        setNow(0.0); setSteps(0)
        controller.testOnly_midiCoalescingTick() // priming
        setNow(1.0 / 60.0); setSteps(40)
        controller.testOnly_midiCoalescingTick() // real MIDI motion, now owns + active
        XCTAssertTrue(controller.testOnly_midiOwnsPlatterRender)
        XCTAssertEqual(controller.dvsContinuousRenderer.lastPublishedActive, true)

        controller.setDVSOwnership(active: true)
        controller.waitForAudioQueue()

        XCTAssertEqual(controller.dvsContinuousRenderer.lastPublishedActive, false,
                        "DVS taking ownership from an actively-publishing MIDI must settle to idle, not leave a stale non-zero velocity active")
        XCTAssertTrue(controller.testOnly_dvsOwnsPlatterRender)
    }

    func testMIDICannotResumeFromStaleEventsAfterDVSTakesOwnership() throws {
        let (controller, setNow, setSteps) = try makeController()
        setNow(0.0); setSteps(0)
        controller.testOnly_midiCoalescingTick() // priming
        setNow(1.0 / 60.0); setSteps(40)
        controller.testOnly_midiCoalescingTick() // MIDI owns, real motion

        // DVS takes over; the platter's real encoder keeps moving a lot
        // while DVS drives (simulated: steps advance far during the
        // ownership window), but MIDI is suppressed the whole time.
        controller.setDVSOwnership(active: true)
        controller.waitForAudioQueue()
        setSteps(5_000)
        setNow(2.0)
        controller.testOnly_midiCoalescingTick() // must be a no-op: DVS owns

        // DVS relinquishes ownership back to MIDI.
        controller.setDVSOwnership(active: false)
        controller.waitForAudioQueue()
        let publishCountAtHandback = controller.dvsContinuousRenderer.publishCount

        // MIDI's very first tick after regaining ownership must NOT replay
        // the huge backlog (5_000 - 40 = 4_960 steps over ~2 s) as a
        // catch-up burst — it must be treated as a fresh priming baseline.
        setNow(2.0 + 1.0 / 60.0)
        controller.testOnly_midiCoalescingTick()
        XCTAssertEqual(controller.dvsContinuousRenderer.publishCount, publishCountAtHandback,
                        "The first post-handoff MIDI tick must not publish a stale-backlog catch-up velocity")

        // The NEXT tick, with a small real delta, resumes normally.
        setNow(2.0 + 2.0 / 60.0); setSteps(5_010)
        controller.testOnly_midiCoalescingTick()
        XCTAssertEqual(controller.dvsContinuousRenderer.publishCount, publishCountAtHandback + 1)
        XCTAssertGreaterThan(try XCTUnwrap(controller.dvsContinuousRenderer.lastPublishedVelocity), 0)
    }

    // MARK: - Left/right deck isolation (product decision 2026-08-09)

    func testLeftDeckMotionNeverReachesTheRightDeckOwnedPlaybackPath() throws {
        let (controller, setNow, _) = try makeController()
        let tracker = ScratchPlatterTracker()
        // Production wiring reads only the right channel; simulate that
        // contract directly instead of the mutable-Int helper above.
        controller.testOnly_setRightDeckAccumulatedStepsProvider {
            tracker.accumulatedSteps(for: ScratchPlatterTracker.rightChannel)
        }

        setNow(0.0)
        controller.testOnly_midiCoalescingTick() // priming (right deck reads 0)

        // Left deck (channel 0) spins a lot — must have zero effect.
        tracker.ingest(channel: ScratchPlatterTracker.leftChannel, value: 0)
        for raw in stride(from: 1, through: 100, by: 1) {
            tracker.ingest(channel: ScratchPlatterTracker.leftChannel, value: raw % 128)
        }

        setNow(1.0 / 60.0)
        controller.testOnly_midiCoalescingTick()

        XCTAssertEqual(controller.dvsContinuousRenderer.publishCount, 0,
                        "Left-deck (channel 0) motion must never publish to the continuous renderer")
        XCTAssertEqual(controller.currentSampleFrame, 0)
    }

    // MARK: - Legacy rollback

    func testMIDILegacyRollbackDisablesContinuousPublicationEvenWithRealMotion() throws {
        let (controller, setNow, setSteps) = try makeController()
        controller.midiUsesContinuousRenderer = false

        setNow(0.0); setSteps(0)
        controller.testOnly_midiCoalescingTick() // priming attempt (no-op: flag off)
        setNow(1.0 / 60.0); setSteps(40)
        controller.testOnly_midiCoalescingTick() // motion attempt (no-op: flag off)

        XCTAssertEqual(controller.dvsContinuousRenderer.publishCount, 0,
                        "midiUsesContinuousRenderer = false must fully disable the continuous MIDI tick")
        XCTAssertFalse(controller.testOnly_midiOwnsPlatterRender)

        // The untouched legacy entry point remains fully available and
        // unaffected by this flag.
        controller.positionDidChange(steps: 0, direction: .forward)
        controller.waitForAudioQueue()
        controller.positionDidChange(steps: 40, direction: .forward)
        controller.waitForAudioQueue()
        XCTAssertEqual(controller.diagnosticsSnapshot().forwardScheduleCount, 1,
                        "Legacy grain scheduling must still work exactly as before")
    }

    // MARK: - Legacy rollback direct-MIDI geometry (cue-lock drift fix, 2026-08-10)
    //
    // `positionDidChangeOnQueue` is shared between DVS and this legacy
    // MIDI rollback path (active when `midiUsesContinuousRenderer =
    // false`), discriminated by `dvsWindow == nil`. These tests prove the
    // legacy path now uses the direct-MIDI (3600-step) scale, not DVS's
    // (3932-step) scale, for its frame-delta math — this path is
    // compiled, reachable production code (not dead), so it needed the
    // same correction as the continuous path.

    func testLegacyRollbackForwardFrameDeltaUsesDirectMIDIScale() throws {
        let (controller, setNow, _) = try makeController()
        controller.midiUsesContinuousRenderer = false

        // `positionDidChangeOnQueue`'s legacy-path rate limiter
        // (`minScheduleInterval`) requires `now - lastScheduleTime >=
        // 1/60`; `lastScheduleTime` starts at 0, so a priming call at
        // `now = 0` is itself rate-limited away before it can even reach
        // the priming logic. Starting at `now = 1/60` avoids that.
        setNow(1.0 / 60.0)
        controller.positionDidChange(steps: 0, direction: .forward)
        controller.waitForAudioQueue()

        setNow(2.0 / 60.0)
        controller.positionDidChange(steps: 100, direction: .forward)
        controller.waitForAudioQueue()

        // effectiveFramesPerStep = (44_100 * 1.8) / 3600 = 22.05 exactly;
        // frameDelta = round(100 * 22.05) = 2205 — the direct-MIDI scale.
        // DVS's ~20.19-based scale would instead give 2019.
        XCTAssertEqual(controller.currentSampleFrame, 2205,
            "Legacy rollback forward frameDelta must use the direct-MIDI (3600-step) scale, not DVS's")
    }

    func testLegacyRollbackBackwardFrameDeltaUsesDirectMIDIScale() throws {
        let (controller, setNow, _) = try makeController()
        controller.midiUsesContinuousRenderer = false

        setNow(1.0 / 60.0)
        controller.positionDidChange(steps: 0, direction: .backward)
        controller.waitForAudioQueue()

        setNow(2.0 / 60.0)
        controller.positionDidChange(steps: -100, direction: .backward)
        controller.waitForAudioQueue()

        // frameDelta = round(100 * 22.05) = 2205, wrapped backward from
        // frame 0 within the 8_000-frame synthetic loop: 8_000 - 2_205.
        XCTAssertEqual(controller.currentSampleFrame, 5795,
            "Legacy rollback backward frameDelta must use the direct-MIDI (3600-step) scale, not DVS's")
    }

    func testLegacyRollbackOneRevolutionForwardReturnsToOriginUsingDirectMIDIScale() throws {
        final class Clock { var now: TimeInterval = 0 }
        let clock = Clock()
        let controller = ScratchSamplePlaybackController(schedulingClock: { clock.now })
        controller.midiUsesContinuousRenderer = false
        // Sized to exactly one physical revolution's worth of frames at
        // 44.1kHz/33⅓RPM (rate * 1.8s = 79_380), so a full direct-MIDI
        // revolution wraps this synthetic buffer's own loop exactly back
        // to frame 0 — isolating the legacy path's frame-delta math from
        // the buffer-length cap that would otherwise clamp a single large
        // tick before it could demonstrate the full-revolution wrap.
        let oneRevolutionFrames = 79_380
        controller.testOnly_installSyntheticSample(
            try makeSyntheticLoopBuffer(frames: oneRevolutionFrames),
            sampleID: "legacy-one-revolution"
        )

        // See the rate-limiter note in testLegacyRollbackForwardFrameDeltaUsesDirectMIDIScale above.
        clock.now = 1.0 / 60.0
        controller.positionDidChange(steps: 0, direction: .forward)
        controller.waitForAudioQueue()
        XCTAssertEqual(controller.lastScheduleSkippedReason, "priming")

        clock.now = 2.0 / 60.0
        controller.positionDidChange(steps: Int(Self.stepsPerRevolution), direction: .forward)
        controller.waitForAudioQueue()

        XCTAssertEqual(
            controller.currentSampleFrame,
            0,
            "One full direct-MIDI revolution (3600 steps) through the legacy rollback path must return " +
            "to the loop origin, using the Rane's direct-MIDI geometry, not DVS's 3932-step geometry"
        )
    }

    // MARK: - DVS legacy grain path unchanged (cue-lock drift fix, 2026-08-10)
    //
    // Explicit regression proof, not just "existing tests still pass".
    // Two distinct DVS code paths both feed off `dvsWindow != nil`, and
    // both are proven unchanged below:
    //
    // 1. `isDVSLoop == true` (the normal case — a short "ahh"-style
    //    sample within one revolution): `currentSampleFrame` comes from
    //    `dvsLoopPhaseFrame`, which was already unconditionally
    //    DVS-only (`framesPerStep`) and untouched by this fix.
    // 2. `isDVSLoop == false` (a sample at least as long as one
    //    revolution — the documented long-sample DVS fallback): this is
    //    exactly where my new `effectiveFramesPerStep = dvsWindow == nil
    //    ? midiFramesPerStep : framesPerStep` conditional lives, so it
    //    needs its own direct proof that `dvsWindow != nil` still
    //    resolves to `framesPerStep`.

    func testDVSLegacyGrainPathFrameDeltaRemainsUnchangedAt3932Scale() throws {
        let (controller, setNow, _) = try makeController()
        controller.dvsUsesContinuousRenderer = false

        let tick = 1.0 / 60.0
        setNow(0.0)
        controller.positionDidChangeContinuous(steps: 0, direction: .forward, segmentWindow: tick)
        controller.waitForAudioQueue()

        setNow(tick)
        controller.positionDidChangeContinuous(steps: 100, direction: .forward, segmentWindow: tick)
        controller.waitForAudioQueue()

        // isDVSLoop == true here (8_000-frame synthetic buffer fits
        // within dvsLoopFrames), so currentSampleFrame comes from
        // dvsLoopPhaseFrame: Int((100 * framesPerStep) mod dvsLoopFrames),
        // truncating (not rounding) — framesPerStep = (44_100 * 1.8) /
        // 3932 ≈ 20.188206..., 100 * that ≈ 2018.82 → truncates to 2018.
        XCTAssertEqual(controller.currentSampleFrame, 2018,
            "DVS's legacy grain path (isDVSLoop path) must remain on the unchanged 3932-step scale")
    }

    func testDVSLongSampleFallbackFrameDeltaRemainsUnchangedAt3932Scale() throws {
        // A buffer at least as long as one revolution forces
        // isDVSLoop == false even though dvsWindow != nil — the documented
        // long-sample DVS fallback that shares `effectiveFrameDelta`'s
        // `wrappedSampleFrame` update with the legacy MIDI rollback path,
        // discriminated only by `dvsWindow`. This is the one test that
        // directly exercises my new conditional for a DVS-originated tick.
        final class Clock { var now: TimeInterval = 0 }
        let clock = Clock()
        let controller = ScratchSamplePlaybackController(schedulingClock: { clock.now })
        controller.dvsUsesContinuousRenderer = false
        controller.testOnly_installSyntheticSample(
            try makeSyntheticLoopBuffer(frames: 100_000),
            sampleID: "dvs-long-sample-fallback"
        )

        let tick = 1.0 / 60.0
        clock.now = 0.0
        controller.positionDidChangeContinuous(steps: 0, direction: .forward, segmentWindow: tick)
        controller.waitForAudioQueue()

        clock.now = tick
        controller.positionDidChangeContinuous(steps: 100, direction: .forward, segmentWindow: tick)
        controller.waitForAudioQueue()

        // effectiveFramesPerStep must resolve to framesPerStep (DVS,
        // 3932-based) here since dvsWindow != nil: frameDelta =
        // round(100 * 20.188206...) = 2019 (rounded, via the
        // wrappedSampleFrame/effectiveFrameDelta path this time, not
        // truncated dvsLoopPhaseFrame — a different rounding rule than
        // the isDVSLoop==true test above, by design of the existing code).
        XCTAssertEqual(controller.currentSampleFrame, 2019,
            "DVS's long-sample fallback (isDVSLoop == false, dvsWindow != nil) must still use the " +
            "unchanged 3932-step scale, not the direct-MIDI 3600-step scale")
    }

    // MARK: - DEFECT 1: DVS ownership must survive load/unload

    func testDVSOwnershipRemainsActiveAcrossSyntheticSampleReload() throws {
        let (controller, _, _) = try makeController()
        controller.setDVSOwnership(active: true)
        controller.waitForAudioQueue()
        XCTAssertTrue(controller.testOnly_dvsOwnershipActive)
        XCTAssertTrue(controller.testOnly_dvsOwnsPlatterRender)

        controller.testOnly_installSyntheticSample(try makeSyntheticLoopBuffer(), sampleID: "reloaded")

        XCTAssertTrue(controller.testOnly_dvsOwnershipActive,
                       "The authoritative DVS-active flag must never be touched by a reload")
        XCTAssertTrue(controller.testOnly_dvsOwnsPlatterRender,
                       "platterRenderOwner must be re-forced back to .dvs by the reload, not left at .none")
    }

    func testMIDICannotPublishAfterAReloadPerformedWhileDVSIsActive() throws {
        let (controller, setNow, setSteps) = try makeController()
        controller.setDVSOwnership(active: true)
        controller.waitForAudioQueue()

        // A reload happens while DVS is the active control source (e.g. a
        // fresh DVS auto-load mid-session).
        controller.testOnly_installSyntheticSample(try makeSyntheticLoopBuffer(), sampleID: "reloaded")

        // The 60 Hz MIDI timer ticking right after that reload must never
        // observe `.none` and briefly claim ownership.
        setNow(0.0); setSteps(0)
        controller.testOnly_midiCoalescingTick() // priming attempt
        setNow(1.0 / 60.0); setSteps(40)
        controller.testOnly_midiCoalescingTick() // real-motion attempt

        XCTAssertEqual(controller.dvsContinuousRenderer.publishCount, 0,
                        "MIDI must never publish after a reload performed while DVS is active")
        XCTAssertFalse(controller.testOnly_midiOwnsPlatterRender)
        XCTAssertTrue(controller.testOnly_dvsOwnsPlatterRender)
    }

    func testDVSOwnershipRemainsAuthoritativeAcrossUnloadAndReloadUntilExplicitlyReleased() throws {
        let (controller, _, _) = try makeController()
        controller.setDVSOwnership(active: true)
        controller.waitForAudioQueue()

        controller.unload()
        controller.waitForAudioQueue()
        XCTAssertTrue(controller.testOnly_dvsOwnershipActive, "unload() must not clear DVS-active ownership")
        XCTAssertTrue(controller.testOnly_dvsOwnsPlatterRender)

        controller.testOnly_installSyntheticSample(try makeSyntheticLoopBuffer(), sampleID: "reloaded-after-unload")
        XCTAssertTrue(controller.testOnly_dvsOwnershipActive, "A reload after unload must still preserve DVS ownership")
        XCTAssertTrue(controller.testOnly_dvsOwnsPlatterRender)

        // Only an explicit release changes it.
        controller.setDVSOwnership(active: false)
        controller.waitForAudioQueue()
        XCTAssertFalse(controller.testOnly_dvsOwnershipActive)
        XCTAssertFalse(controller.testOnly_dvsOwnsPlatterRender)
    }

    func testRepeatedSetDVSOwnershipActiveTrueIsIdempotent() throws {
        let (controller, setNow, setSteps) = try makeController()
        setNow(0.0); setSteps(0)
        controller.testOnly_midiCoalescingTick() // priming
        setNow(1.0 / 60.0); setSteps(40)
        controller.testOnly_midiCoalescingTick() // MIDI owns, actively publishing
        XCTAssertTrue(controller.testOnly_midiOwnsPlatterRender)

        let idleCountBefore = controller.dvsContinuousRenderer.idlePublishCount
        controller.setDVSOwnership(active: true)
        controller.waitForAudioQueue()
        XCTAssertTrue(controller.testOnly_dvsOwnershipActive)
        XCTAssertEqual(controller.dvsContinuousRenderer.idlePublishCount, idleCountBefore + 1,
                        "The genuine MIDI -> DVS handoff must publish idle exactly once")

        // A repeated activation call must be a complete no-op.
        controller.setDVSOwnership(active: true)
        controller.waitForAudioQueue()
        controller.setDVSOwnership(active: true)
        controller.waitForAudioQueue()
        XCTAssertTrue(controller.testOnly_dvsOwnershipActive)
        XCTAssertEqual(controller.dvsContinuousRenderer.idlePublishCount, idleCountBefore + 1,
                        "Repeated active:true calls must not publish idle again or otherwise re-run the handoff")
        XCTAssertTrue(controller.testOnly_dvsOwnsPlatterRender)
    }

    // MARK: - DEFECT 2: DVS -> MIDI phase handoff must rebase, not freeze

    /// End-to-end: MIDI establishes a phase, DVS takes over and moves the
    /// audible phase somewhere entirely different (plus a suppressed CC6
    /// backlog accumulates on the right deck), then DVS releases. Proves
    /// requirements 4-7: the rebase uses DVS's retained phase (not MIDI's
    /// stale one), the first post-release tick only primes, the second
    /// tick continues from the rebased anchor with only the new real
    /// delta, and no pre-DVS MIDI phase or suppressed backlog is replayed.
    func testDVSReleaseRebasesMIDIToCurrentDVSPhaseAndDiscardsStaleHistory() throws {
        let (controller, setNow, setSteps) = try makeController()

        // 1. MIDI establishes an initial phase before DVS ever engages.
        setNow(0.0); setSteps(0)
        controller.testOnly_midiCoalescingTick() // priming
        setNow(1.0 / 60.0); setSteps(40)
        controller.testOnly_midiCoalescingTick() // real motion
        let staleMIDIPhase = controller.currentSampleFrame
        XCTAssertGreaterThan(staleMIDIPhase, 0)

        // 2. DVS takes ownership and drives the audible phase somewhere
        // clearly different from MIDI's stale phase.
        controller.setDVSOwnership(active: true)
        controller.waitForAudioQueue()
        let window = 1.0 / 60.0
        controller.positionDidChangeContinuous(steps: 0, direction: .forward, segmentWindow: window)
        controller.waitForAudioQueue()
        controller.positionDidChangeContinuous(steps: 900, direction: .forward, segmentWindow: window)
        controller.waitForAudioQueue()
        let dvsPhase = controller.currentSampleFrame
        XCTAssertNotEqual(dvsPhase, staleMIDIPhase,
                           "test setup sanity: DVS must leave a different phase than MIDI's stale one")

        // Suppressed CC6 backlog: the right deck's raw accumulated steps
        // keep climbing (as if the platter kept physically spinning) while
        // MIDI is suppressed — this must never be replayed as real motion.
        // publishCount is shared with MIDI's own earlier real-motion tick
        // (step 1 above), so compare against a freshly captured baseline
        // rather than an absolute value.
        let publishCountBeforeSuppressedTick = controller.dvsContinuousRenderer.publishCount
        setSteps(5_000)
        setNow(10.0)
        controller.testOnly_midiCoalescingTick() // no-op: DVS still owns
        XCTAssertEqual(controller.dvsContinuousRenderer.publishCount, publishCountBeforeSuppressedTick,
                        "Suppressed CC6 while DVS owns must never publish")

        // 3. DVS relinquishes ownership.
        controller.setDVSOwnership(active: false)
        controller.waitForAudioQueue()

        // Onset-alignment fix (2026-08-13): MIDI's continuous phase is
        // offset by `hotCueOnsetFrame` and wraps at `hotCueLoopFrames`, but
        // the rate stays the real-vinyl `midiFramesPerStep`/3600 scale
        // (unchanged — a same-day experiment that rescaled this to the
        // sample's own length caused an audible pitch/speed shift on real
        // hardware and was reverted). The synthetic loop buffer is loud
        // from frame 0, so `hotCueOnsetFrame` is 0 here.
        let onset = Double(controller.hotCueOnsetFrame)
        let loopFrames = controller.hotCueLoopFrames
        let stepRate = (Self.rate * 1.8) / Self.stepsPerRevolution // midiFramesPerStep
        func loopPhase(forSteps steps: Double) -> Double {
            var wrapped = (steps * stepRate).truncatingRemainder(dividingBy: loopFrames)
            if wrapped < 0 { wrapped += loopFrames }
            return onset + wrapped
        }
        let expectedAnchor = (Double(dvsPhase) - onset) / stepRate
        XCTAssertEqual(controller.testOnly_midiContinuousAccumulatedSteps, expectedAnchor, accuracy: 0.01,
                        "Release must rebase MIDI's anchor to DVS's retained phase, not leave it at the stale pre-DVS value")
        XCTAssertNotEqual(controller.testOnly_midiContinuousAccumulatedSteps, 40,
                           "The stale pre-DVS MIDI phase (from step 1) must not survive the handoff")

        // 4. First post-release tick only primes: no publish, no phase move.
        let publishCountAtRelease = controller.dvsContinuousRenderer.publishCount
        setNow(10.0 + 1.0 / 60.0) // steps unchanged (still the 5_000 backlog value)
        controller.testOnly_midiCoalescingTick()
        XCTAssertEqual(controller.dvsContinuousRenderer.publishCount, publishCountAtRelease,
                        "The first post-release MIDI tick must only prime, never publish")
        XCTAssertEqual(controller.currentSampleFrame, dvsPhase,
                        "The priming tick must not move the phase away from the rebased DVS phase")

        // 5. Second tick: only the NEW real delta (+10, not the 4_960
        // backlog) continues from the rebased anchor.
        setSteps(5_010)
        setNow(10.0 + 2.0 / 60.0)
        controller.testOnly_midiCoalescingTick()
        XCTAssertEqual(controller.dvsContinuousRenderer.publishCount, publishCountAtRelease + 1)
        let expectedPhaseAfter = loopPhase(forSteps: expectedAnchor + 10)
        XCTAssertEqual(Double(controller.currentSampleFrame), expectedPhaseAfter, accuracy: 1,
                        "The resumed phase must continue from the retained DVS phase plus only the new real delta")
    }

    // MARK: - DEFECT 3: coalescing timer teardown

    func testTimerConfigurationRemainsIdempotent() throws {
        let (controller, _, _) = try makeController()
        controller.configureMIDIPlatterProvider(rightDeckAccumulatedSteps: { 0 })
        controller.waitForAudioQueue()
        XCTAssertEqual(controller.testOnly_midiCoalescingTimerStartCount, 1)

        controller.configureMIDIPlatterProvider(rightDeckAccumulatedSteps: { 0 })
        controller.waitForAudioQueue()
        XCTAssertEqual(controller.testOnly_midiCoalescingTimerStartCount, 1,
                        "A second configure call must not start a second timer")
    }

    func testUnloadDoesNotCancelTheCoalescingTimer() throws {
        let (controller, _, _) = try makeController()
        controller.configureMIDIPlatterProvider(rightDeckAccumulatedSteps: { 0 })
        controller.waitForAudioQueue()
        XCTAssertTrue(controller.testOnly_midiCoalescingTimerActive)

        controller.unload()
        controller.waitForAudioQueue()
        XCTAssertTrue(controller.testOnly_midiCoalescingTimerActive,
                       "unload() (ordinary platter idle) must never cancel the coalescing timer")
    }

    func testPausePlaybackDoesNotCancelTheCoalescingTimer() throws {
        let (controller, _, _) = try makeController()
        controller.configureMIDIPlatterProvider(rightDeckAccumulatedSteps: { 0 })
        controller.waitForAudioQueue()

        controller.pausePlayback()
        controller.waitForAudioQueue()
        XCTAssertTrue(controller.testOnly_midiCoalescingTimerActive,
                       "pausePlayback() (ordinary platter idle) must never cancel the coalescing timer")
    }

    func testTimerTeardownCancelsTheSourceAndRestartStillWorksWhileControllerIsAlive() throws {
        let (controller, _, _) = try makeController()
        controller.configureMIDIPlatterProvider(rightDeckAccumulatedSteps: { 0 })
        controller.waitForAudioQueue()
        XCTAssertTrue(controller.testOnly_midiCoalescingTimerActive)

        controller.testOnly_cancelMIDICoalescingTimer()
        XCTAssertFalse(controller.testOnly_midiCoalescingTimerActive,
                        "The bounded teardown cancellation helper must cancel and nil the timer")

        // Restart behaviour is preserved while the controller remains alive.
        controller.configureMIDIPlatterProvider(rightDeckAccumulatedSteps: { 0 })
        controller.waitForAudioQueue()
        XCTAssertTrue(controller.testOnly_midiCoalescingTimerActive,
                       "configureMIDIPlatterProvider must be able to restart the timer after a teardown-style cancellation")
        XCTAssertEqual(controller.testOnly_midiCoalescingTimerStartCount, 2)
    }

    // MARK: - Platter test asset load-path defect (2026-08-09 hardware finding,
    // resolved 2026-08-13 by arbitrary-length platter playback)
    //
    // Original root cause: the Debug hardware-test button loaded `ahhh.wav`
    // (~4.4667 s, the hot-cue pad asset), which is longer than one physical
    // platter revolution (`dvsLoopFrames`, ~1.8 s) — `midiCoalescingTick`'s
    // loop-fit guard silently returned every tick, so moving the right
    // platter produced no audio. The direct-MIDI continuous path is no
    // longer capped at one revolution (see `continuousLoopFrames`'s doc
    // comment): both the validated `dvs_ahhh` asset and samples longer than
    // one revolution now drive the continuous renderer correctly.

    func testBundledDVSAhhhFitsWithinOneRevolutionGeometryForDirectMIDI() throws {
        final class Clock { var now: TimeInterval = 0 }
        final class Steps { var value: Int = 0 }
        let clock = Clock()
        let steps = Steps()
        let controller = ScratchSamplePlaybackController(schedulingClock: { clock.now })
        XCTAssertTrue(controller.load(sampleID: "dvs_ahhh"), "dvs_ahhh must be a known sample ID")
        controller.waitForAudioQueue()
        XCTAssertEqual(controller.loadedSampleID, "dvs_ahhh")
        XCTAssertGreaterThan(controller.totalFrames, 0)
        XCTAssertLessThanOrEqual(
            Double(controller.totalFrames),
            controller.dvsLoopFrames,
            "The validated platter-test asset fits within one physical revolution, so " +
            "continuousLoopFrames must equal dvsLoopFrames unchanged for it"
        )
        XCTAssertEqual(
            controller.continuousLoopFrames,
            controller.dvsLoopFrames,
            "A sample that already fits one revolution must keep the existing one-revolution loop bound"
        )

        // Drives the continuous renderer normally — no rejection.
        controller.testOnly_setRightDeckAccumulatedStepsProvider { steps.value }
        clock.now = 0.0; steps.value = 0
        controller.testOnly_midiCoalescingTick() // priming
        clock.now = 1.0 / 60.0; steps.value = 40
        controller.testOnly_midiCoalescingTick()
        XCTAssertTrue(controller.testOnly_midiOwnsPlatterRender)
    }

    func testSampleExceedingOneRevolutionNowEntersDirectMIDIModeAtItsOwnLength() throws {
        final class Clock { var now: TimeInterval = 0 }
        final class Steps { var value: Int = 0 }
        let clock = Clock()
        let steps = Steps()
        let controller = ScratchSamplePlaybackController(schedulingClock: { clock.now })
        // ~2.27 s at 44.1 kHz — clearly longer than the ~1.8 s/~79_380-frame
        // one-revolution loop (see `dvsLoopFrames`'s doc comment), the same
        // mismatch class as the ~4.4667 s hot-cue pad asset that produced
        // the original silent-failure hardware finding. Arbitrary-length
        // platter playback (2026-08-13) now supports it.
        let longBuffer = try makeSyntheticLoopBuffer(frames: 100_000)
        controller.testOnly_installSyntheticSample(longBuffer, sampleID: "longer-than-one-revolution")
        XCTAssertGreaterThan(
            Double(controller.totalFrames),
            controller.dvsLoopFrames,
            "test setup sanity: the synthetic sample must exceed one revolution"
        )
        XCTAssertEqual(
            controller.continuousLoopFrames,
            Double(controller.totalFrames),
            "A sample longer than one revolution must loop at its own length, not the fixed revolution bound"
        )

        controller.testOnly_setRightDeckAccumulatedStepsProvider { steps.value }
        clock.now = 0.0; steps.value = 40
        controller.testOnly_midiCoalescingTick() // priming attempt
        clock.now = 1.0 / 60.0; steps.value = 80
        controller.testOnly_midiCoalescingTick() // real-motion attempt

        XCTAssertGreaterThan(
            controller.dvsContinuousRenderer.publishCount,
            0,
            "A sample exceeding one revolution must now publish to the continuous renderer, not be silently rejected"
        )
        XCTAssertTrue(controller.testOnly_midiOwnsPlatterRender)

        // Natural-pitch requirement (reaffirmed 2026-08-13 after reverting a
        // same-day experiment that stretched a sample's content to fit
        // exactly one revolution — a hardware test proved that shifts
        // pitch/speed with sample length): the RATE (`midiFramesPerStep`)
        // is never rescaled by sample length. One-revolution cue window
        // (2026-08-15 hardware finding): a sample with at least one
        // revolution's worth of frames after its onset — this 100_000-frame
        // buffer, loud from frame 0 so `hotCueOnsetFrame` is 0, easily
        // qualifies — loops at exactly one physical revolution
        // (`hotCueLoopFrames == midiFramesPerStep * 3600`), so one full
        // revolution of real platter motion returns exactly to cue start,
        // at the unchanged real-vinyl rate. Priming captured its baseline
        // at raw step 40 (above), so the accumulator (deltas since priming)
        // reaches exactly 3600 at raw step 40 + 3600 = 3640, not 3600.
        clock.now = 2.0 / 60.0; steps.value = 40 + Int(Self.stepsPerRevolution)
        controller.testOnly_midiCoalescingTick()
        XCTAssertEqual(
            controller.currentSampleFrame,
            controller.hotCueOnsetFrame,
            "One physical revolution (3600 steps) at the unchanged real-vinyl-RPM rate must return exactly " +
            "to cue start for a long hot-cue sample — the actual hardware fix (2026-08-15)"
        )
    }

    // MARK: - Hot-cue onset alignment, natural real-vinyl-RPM rate (2026-08-13 hardware findings)

    /// Builds a stereo buffer with `silenceFrames` of true silence followed
    /// by a continuous tone for the remainder — models the leading silence
    /// found in the bundled `ah_yeah`/`check_it_out`/`ahhh` pad WAVs.
    private func makeSilenceThenToneBuffer(silenceFrames: Int, toneFrames: Int) throws -> AVAudioPCMBuffer {
        let totalFrames = silenceFrames + toneFrames
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrames)))
        buffer.frameLength = AVAudioFrameCount(totalFrames)
        for i in 0..<totalFrames {
            let value: Float
            if i < silenceFrames {
                value = 0
            } else {
                value = 0.8 * Float(sin(Double(i - silenceFrames) * 2 * .pi / 100))
            }
            buffer.floatChannelData![0][i] = value
            buffer.floatChannelData![1][i] = value
        }
        return buffer
    }

    func testDetectHotCueOnsetFrameSkipsLeadingSilence() throws {
        let buffer = try makeSilenceThenToneBuffer(silenceFrames: 12_000, toneFrames: 4_000)
        let onset = ScratchSamplePlaybackController.detectHotCueOnsetFrame(in: buffer)
        // Detected at the start of the windowed-RMS block containing the
        // true silence/tone boundary — within one detection window (5 ms
        // default) of frame 12_000, not exact-to-the-sample and not still
        // deep inside the leading silence.
        let windowFrames = Int(0.005 * Self.rate)
        XCTAssertLessThanOrEqual(abs(onset - 12_000), windowFrames)
    }

    func testDetectHotCueOnsetFrameIsZeroForContentLoudFromTheStart() throws {
        let buffer = try makeSyntheticLoopBuffer(frames: 4_000)
        XCTAssertEqual(ScratchSamplePlaybackController.detectHotCueOnsetFrame(in: buffer), 0)
    }

    func testDetectHotCueOnsetFrameIsZeroForPureSilence() throws {
        let buffer = try makeSilenceThenToneBuffer(silenceFrames: 4_000, toneFrames: 0)
        XCTAssertEqual(ScratchSamplePlaybackController.detectHotCueOnsetFrame(in: buffer), 0,
                        "No block ever crosses the threshold, so the safe fallback is frame 0")
    }

    /// End-to-end: a sample with leading silence must sound immediately at
    /// cue position 0 (12 o'clock) — no silent travel before the audible
    /// content — matching the hardware finding that triggering at 12
    /// o'clock produced audible sound only around 2 o'clock.
    func testLoadedSampleWithLeadingSilenceStartsAtOnsetNotFileFrameZero() throws {
        final class Clock { var now: TimeInterval = 0 }
        final class Steps { var value: Int = 0 }
        let clock = Clock()
        let steps = Steps()
        let controller = ScratchSamplePlaybackController(schedulingClock: { clock.now })
        let buffer = try makeSilenceThenToneBuffer(silenceFrames: 12_000, toneFrames: 4_000)
        controller.testOnly_installSyntheticSample(buffer, sampleID: "leading-silence")

        XCTAssertGreaterThan(controller.hotCueOnsetFrame, 0, "test setup sanity: leading silence must be detected")

        controller.testOnly_setRightDeckAccumulatedStepsProvider { steps.value }
        clock.now = 0.0; steps.value = 0
        controller.testOnly_midiCoalescingTick() // priming
        clock.now = 1.0 / 60.0; steps.value = 1 // the smallest possible motion off cue position 0
        controller.testOnly_midiCoalescingTick()

        XCTAssertGreaterThanOrEqual(
            controller.currentSampleFrame,
            controller.hotCueOnsetFrame,
            "The very first tick off cue position 0 must already be at or past the audible onset, " +
            "not still inside the leading silence"
        )
    }

    /// Cue-start-alignment fix (2026-08-14): direct proof against the
    /// render core itself, not just the controller's own bookkeeping. Before
    /// this fix `DVSContinuousVinylRenderCore.ingest(table:)` always reset
    /// its render-side `phase` to file frame 0 on install, regardless of
    /// any onset — the authoritative-phase correction toward
    /// `hotCueOnsetFrame` published by the first real MIDI tick is bounded
    /// (≤ 2% of current velocity per frame, frozen entirely at zero
    /// velocity — see `DVSContinuousVinylRenderCore.maxPhaseCorrectionRatio`),
    /// so a hot-cue press played silence until the platter had physically
    /// travelled far enough to close that gap. `installSample` must now be
    /// called with `initialPhase: hotCueOnsetFrame`, so the render core's
    /// own `phase` is already at the onset — with zero platter motion.
    func testRenderCorePhaseStartsAtOnsetImmediatelyOnInstallBeforeAnyPlatterMotion() throws {
        let controller = ScratchSamplePlaybackController()
        let buffer = try makeSilenceThenToneBuffer(silenceFrames: 12_000, toneFrames: 4_000)
        controller.testOnly_installSyntheticSample(buffer, sampleID: "leading-silence")
        XCTAssertGreaterThan(controller.hotCueOnsetFrame, 0, "test setup sanity: leading silence must be detected")

        // Force the renderer to ingest the just-installed table (production
        // does this inside the real render callback; a zero-length render
        // exercises the exact same ingest path deterministically, with no
        // audio engine and before any platter movement/publish).
        var left: Float = 0
        var right: Float = 0
        controller.dvsContinuousRenderer.testOnly_render(left: &left, right: &right, frameCount: 0)

        XCTAssertEqual(
            controller.dvsContinuousRenderer.testOnly_corePhase,
            Double(controller.hotCueOnsetFrame),
            "The render core's own phase must start exactly at the onset on install, before any platter " +
            "motion — not file frame 0, which would only slowly (and inaudibly, at low/zero velocity) " +
            "correct toward the onset afterward"
        )
    }

    /// Onset offset must shift only the INITIAL position and the loop's
    /// wrap point, never the playback rate (reaffirmed 2026-08-13 after
    /// reverting a same-day experiment that rescaled the rate to force
    /// exactly one cycle per revolution — a hardware test proved that
    /// causes an audible pitch/speed shift). Phase must start exactly at
    /// the onset (cue position 0) and advance at the real-vinyl-RPM
    /// `midiFramesPerStep` pace from there — cue start and playback rate
    /// are independent, per product decision.
    func testHotCuePhaseStartsAtOnsetAndAdvancesAtRealVinylRateWithLeadingSilence() throws {
        final class Clock { var now: TimeInterval = 0 }
        final class Steps { var value: Int = 0 }
        let clock = Clock()
        let steps = Steps()
        let controller = ScratchSamplePlaybackController(schedulingClock: { clock.now })
        let buffer = try makeSilenceThenToneBuffer(silenceFrames: 12_000, toneFrames: 4_000)
        controller.testOnly_installSyntheticSample(buffer, sampleID: "leading-silence")
        controller.testOnly_setRightDeckAccumulatedStepsProvider { steps.value }
        XCTAssertGreaterThan(controller.hotCueOnsetFrame, 0, "test setup sanity: leading silence must be detected")

        clock.now = 0.0; steps.value = 0
        controller.testOnly_midiCoalescingTick() // priming

        // A modest, arbitrary step delta (not tied to 3600) — the rate is
        // real-vinyl-calibrated, not sample-length-derived, so there is no
        // special significance to 3600 steps for this assertion.
        clock.now = 1.0 / 60.0; steps.value = 500
        controller.testOnly_midiCoalescingTick()
        let midiFramesPerStep = (Self.rate * 1.8) / Self.stepsPerRevolution
        let expectedFrame = Double(controller.hotCueOnsetFrame) + 500 * midiFramesPerStep
        XCTAssertEqual(
            Double(controller.currentSampleFrame),
            expectedFrame,
            accuracy: 1,
            "Phase must start at the onset and advance at the real-vinyl-RPM rate, independent of the " +
            "sample's own length"
        )
    }

    /// Reverse motion must traverse the same active cue range backward,
    /// continuously (no phase jump), symmetric with forward traversal.
    func testHotCueReverseMotionTraversesActiveRangeBackwardContinuously() throws {
        final class Clock { var now: TimeInterval = 0 }
        final class Steps { var value: Int = 0 }
        let clock = Clock()
        let steps = Steps()
        let controller = ScratchSamplePlaybackController(schedulingClock: { clock.now })
        let buffer = try makeSilenceThenToneBuffer(silenceFrames: 12_000, toneFrames: 4_000)
        controller.testOnly_installSyntheticSample(buffer, sampleID: "leading-silence")
        controller.testOnly_setRightDeckAccumulatedStepsProvider { steps.value }

        clock.now = 0.0; steps.value = 0
        controller.testOnly_midiCoalescingTick() // priming

        // Forward well into the interior of the loop (accumulator=1000
        // steps, i.e. 1000 * midiFramesPerStep ≈ 22_050 frames — comfortably
        // inside `hotCueLoopFrames`, clear of the cue-origin/loop-end seam),
        // then reverse by a smaller amount — "phase decreases on reversal"
        // is unambiguous here (crossing the seam itself wraps to the other
        // end of the loop by design and is intentionally not what this test
        // exercises).
        clock.now = 1.0 / 60.0; steps.value = 1_000
        controller.testOnly_midiCoalescingTick()
        let phaseBeforeReversal = controller.currentSampleFrame

        clock.now = 2.0 / 60.0; steps.value = 800
        controller.testOnly_midiCoalescingTick()
        let phaseAfterReversal = controller.currentSampleFrame

        XCTAssertLessThan(
            phaseAfterReversal, phaseBeforeReversal,
            "Reversing platter direction must move the phase backward"
        )
        let jump = abs(phaseAfterReversal - phaseBeforeReversal)
        let midiFramesPerStep = (Self.rate * 1.8) / Self.stepsPerRevolution
        let maxPlausibleStep = Int(200 * midiFramesPerStep) + 1
        XCTAssertLessThanOrEqual(
            jump, maxPlausibleStep,
            "Reversal must be continuous — no larger phase jump than the actual step delta implies"
        )
    }

    // MARK: - Intermittent hot-cue-retrigger investigation (2026-08-14)

    /// Controlled reproduction of hypothesis (a) "duplicate load/reinstall":
    /// if a second `applyLoadedBufferState` for the SAME sample runs while
    /// the first is already actively playing mid-scratch (phase away from
    /// the onset), the render core's phase snaps back to `hotCueOnsetFrame`
    /// — exactly the "brief extra fragment of the initial ah in the middle
    /// of the sample" hardware symptom. This does not identify the actual
    /// real-hardware trigger source (a genuine duplicate MIDI Note On, a
    /// duplicate `resolveAndLoadHotCueSample` call, etc. — the new
    /// `[HotCueTrace]`/`[HotCueOnset]` logs are what identify that on real
    /// hardware), but it proves the mechanism: ANY unexpected second
    /// install while a hot cue is active reproduces the reported symptom,
    /// and the new diagnostics (`renderIngestCount`, `PREEMPTING` log)
    /// correctly observe it.
    func testDuplicateReinstallWhileActiveReproducesOnsetRetriggerSymptom() throws {
        final class Clock { var now: TimeInterval = 0 }
        final class Steps { var value: Int = 0 }
        let clock = Clock()
        let steps = Steps()
        let controller = ScratchSamplePlaybackController(schedulingClock: { clock.now })
        let buffer = try makeSilenceThenToneBuffer(silenceFrames: 12_000, toneFrames: 4_000)
        controller.testOnly_installSyntheticSample(buffer, sampleID: "leading-silence")
        let onset = controller.hotCueOnsetFrame
        XCTAssertGreaterThan(onset, 0, "test setup sanity: leading silence must be detected")

        // Scratch forward, well away from the onset — simulates "mid-playback".
        controller.testOnly_setRightDeckAccumulatedStepsProvider { steps.value }
        clock.now = 0.0; steps.value = 0
        controller.testOnly_midiCoalescingTick() // priming
        clock.now = 1.0 / 60.0; steps.value = 1_000
        controller.testOnly_midiCoalescingTick()
        XCTAssertNotEqual(
            controller.currentSampleFrame, onset,
            "test setup sanity: playback must have moved away from the onset before the duplicate reinstall"
        )

        // The bug mechanism: an unexpected second install for the SAME
        // sample while it is already active (mirrors a duplicate MIDI
        // trigger, a duplicate resolveAndLoadHotCueSample call, or any
        // other unintended second `load()`).
        let ingestCountBeforeDuplicate = controller.dvsContinuousRenderer.renderIngestCount
        controller.testOnly_installSyntheticSample(buffer, sampleID: "leading-silence")

        XCTAssertEqual(
            controller.currentSampleFrame, onset,
            "A duplicate reinstall for the already-active sample must reproduce the retrigger symptom: " +
            "phase snaps back to the onset (replaying the initial \"ah\") instead of continuing from " +
            "wherever real platter motion had already reached"
        )

        // Force the renderer to ingest the second table (production does
        // this on the real render callback) and confirm the diagnostic
        // counter observed exactly one additional real ingest — proving
        // `renderIngestCount` correctly distinguishes "installed twice"
        // from "installed once."
        var left: Float = 0
        var right: Float = 0
        controller.dvsContinuousRenderer.testOnly_render(left: &left, right: &right, frameCount: 0)
        XCTAssertEqual(
            controller.dvsContinuousRenderer.renderIngestCount, ingestCountBeforeDuplicate + 1,
            "renderIngestCount must observe exactly one additional real ingest for the duplicate install"
        )
    }

    // MARK: - One-physical-revolution cue window (2026-08-15 hardware finding)
    //
    // Hardware trace proved the earlier onset fix was correct (no duplicate
    // load) but incomplete: for a long hot-cue sample (`ah_yeah`), the loop
    // bound was the ENTIRE post-onset WAV (~191k frames), so a legitimate
    // loop wrap only occurred after several physical revolutions instead of
    // one — matching the "does not loop once per revolution" hardware
    // observation. The fix caps the loop bound to exactly one revolution's
    // worth of frames at the UNCHANGED real-vinyl-RPM rate
    // (`midiFramesPerStep`) for samples with enough post-onset frames to
    // support it; `midiFramesPerStep` itself is never rescaled, unlike the
    // rejected 2026-08-13 `activeFrames / 3600` experiment.

    /// A long buffer (short silence, long tone) with enough frames after
    /// the detected onset to trigger the one-revolution cue window
    /// (`availableFramesAfterOnset >= hotCueRevolutionFrames`, i.e. >=
    /// ~79_380 frames at this file's 44.1 kHz rate) — models `ah_yeah`/
    /// `check_it_out`.
    private func makeLongHotCueBuffer() throws -> AVAudioPCMBuffer {
        try makeSilenceThenToneBuffer(silenceFrames: 1_000, toneFrames: 150_000)
    }

    func testLongHotCueSamplePhaseAtStepZeroIsOnset() throws {
        let controller = ScratchSamplePlaybackController()
        let buffer = try makeLongHotCueBuffer()
        controller.testOnly_installSyntheticSample(buffer, sampleID: "long-hot-cue")
        let onset = controller.hotCueOnsetFrame
        let hotCueRevolutionFrames = (Self.rate * 1.8)
        XCTAssertGreaterThanOrEqual(
            controller.hotCueLoopFrames, hotCueRevolutionFrames - 1,
            "test setup sanity: this buffer must have enough post-onset frames to trigger the one-revolution window"
        )
        XCTAssertLessThanOrEqual(
            controller.hotCueLoopFrames, hotCueRevolutionFrames + 1,
            "A long sample's loop must be capped at exactly one revolution's worth of frames, not the whole post-onset WAV"
        )
        // Phase at accumulated steps = 0 is the controller's own initial
        // position immediately after load — see `applyLoadedBufferState`.
        XCTAssertEqual(controller.currentSampleFrame, onset, "phase(0) must equal the onset")
    }

    func testLongHotCueSamplePhaseAtEighteenHundredStepsIsHalfRevolution() throws {
        final class Clock { var now: TimeInterval = 0 }
        final class Steps { var value: Int = 0 }
        let clock = Clock()
        let steps = Steps()
        let controller = ScratchSamplePlaybackController(schedulingClock: { clock.now })
        let buffer = try makeLongHotCueBuffer()
        controller.testOnly_installSyntheticSample(buffer, sampleID: "long-hot-cue")
        let onset = controller.hotCueOnsetFrame
        controller.testOnly_setRightDeckAccumulatedStepsProvider { steps.value }

        clock.now = 0.0; steps.value = 0
        controller.testOnly_midiCoalescingTick() // priming
        clock.now = 1.0 / 60.0; steps.value = 1_800
        controller.testOnly_midiCoalescingTick()

        let midiFramesPerStep = (Self.rate * 1.8) / Self.stepsPerRevolution
        let expected = Double(onset) + 1_800 * midiFramesPerStep
        XCTAssertEqual(
            Double(controller.currentSampleFrame), expected, accuracy: 1,
            "phase(1800) must sit exactly halfway through the one-revolution cue window"
        )
        // Sanity: this must be exactly the midpoint of the cue window, not
        // some other fraction of the whole post-onset WAV.
        XCTAssertEqual(
            Double(controller.currentSampleFrame) - Double(onset), controller.hotCueLoopFrames / 2, accuracy: 1
        )
    }

    func testLongHotCueSamplePhaseAtThirtyFiveNinetyNineIsNearEndOfWindow() throws {
        final class Clock { var now: TimeInterval = 0 }
        final class Steps { var value: Int = 0 }
        let clock = Clock()
        let steps = Steps()
        let controller = ScratchSamplePlaybackController(schedulingClock: { clock.now })
        let buffer = try makeLongHotCueBuffer()
        controller.testOnly_installSyntheticSample(buffer, sampleID: "long-hot-cue")
        let onset = controller.hotCueOnsetFrame
        controller.testOnly_setRightDeckAccumulatedStepsProvider { steps.value }

        clock.now = 0.0; steps.value = 0
        controller.testOnly_midiCoalescingTick() // priming
        clock.now = 1.0 / 60.0; steps.value = 3_599
        controller.testOnly_midiCoalescingTick()

        let midiFramesPerStep = (Self.rate * 1.8) / Self.stepsPerRevolution
        let expected = Double(onset) + 3_599 * midiFramesPerStep
        XCTAssertEqual(Double(controller.currentSampleFrame), expected, accuracy: 1)
        XCTAssertLessThan(
            Double(controller.currentSampleFrame) - Double(onset), controller.hotCueLoopFrames,
            "phase(3599) must be near, but strictly before, the end of the cue window"
        )
        XCTAssertGreaterThan(
            Double(controller.currentSampleFrame) - Double(onset), controller.hotCueLoopFrames - midiFramesPerStep - 1
        )
    }

    func testLongHotCueSamplePhaseAtThirtySixHundredStepsReturnsExactlyToOnset() throws {
        final class Clock { var now: TimeInterval = 0 }
        final class Steps { var value: Int = 0 }
        let clock = Clock()
        let steps = Steps()
        let controller = ScratchSamplePlaybackController(schedulingClock: { clock.now })
        let buffer = try makeLongHotCueBuffer()
        controller.testOnly_installSyntheticSample(buffer, sampleID: "long-hot-cue")
        let onset = controller.hotCueOnsetFrame
        controller.testOnly_setRightDeckAccumulatedStepsProvider { steps.value }

        clock.now = 0.0; steps.value = 0
        controller.testOnly_midiCoalescingTick() // priming
        clock.now = 1.0 / 60.0; steps.value = Int(Self.stepsPerRevolution)
        controller.testOnly_midiCoalescingTick()

        XCTAssertEqual(
            controller.currentSampleFrame, onset,
            "+3600 steps (one physical platter revolution) must return exactly to the onset — the actual " +
            "hardware fix: a long sample must complete one logical cycle per revolution, not several"
        )
    }

    func testLongHotCueSamplePhaseAtNegativeOneStepTraversesBackwardIntoEndOfWindow() throws {
        final class Clock { var now: TimeInterval = 0 }
        final class Steps { var value: Int = 0 }
        let clock = Clock()
        let steps = Steps()
        let controller = ScratchSamplePlaybackController(schedulingClock: { clock.now })
        let buffer = try makeLongHotCueBuffer()
        controller.testOnly_installSyntheticSample(buffer, sampleID: "long-hot-cue")
        let onset = controller.hotCueOnsetFrame
        controller.testOnly_setRightDeckAccumulatedStepsProvider { steps.value }

        clock.now = 0.0; steps.value = 0
        controller.testOnly_midiCoalescingTick() // priming
        clock.now = 1.0 / 60.0; steps.value = -1
        controller.testOnly_midiCoalescingTick()

        let midiFramesPerStep = (Self.rate * 1.8) / Self.stepsPerRevolution
        // Reversing one step past the onset must wrap to the END of the
        // same cue window (loop-wrap, not a jump elsewhere) — the exact
        // mirror of `phase(3599)`, one step before the wrap back to onset.
        let expected = Double(onset) + controller.hotCueLoopFrames - midiFramesPerStep
        XCTAssertEqual(Double(controller.currentSampleFrame), expected, accuracy: 1)
    }

    /// Velocity computation must be byte-for-byte unaffected by which loop
    /// bound (`hotCueLoopFrames`) is active — this fix changes only the
    /// modulus of the phase wrap, never the rate a given real step delta
    /// is converted to frames/second.
    func testLongHotCueSampleVelocityCalculationUnaffectedByOneRevolutionWindow() throws {
        final class Clock { var now: TimeInterval = 0 }
        final class Steps { var value: Int = 0 }
        let clock = Clock()
        let steps = Steps()
        let controller = ScratchSamplePlaybackController(schedulingClock: { clock.now })
        let buffer = try makeLongHotCueBuffer()
        controller.testOnly_installSyntheticSample(buffer, sampleID: "long-hot-cue")
        controller.testOnly_setRightDeckAccumulatedStepsProvider { steps.value }

        clock.now = 0.0; steps.value = 0
        controller.testOnly_midiCoalescingTick() // priming
        clock.now = 1.0 / 60.0; steps.value = 40
        controller.testOnly_midiCoalescingTick()

        let stepVelocity = 40.0 / (1.0 / 60.0)
        let midiFramesPerStep = (Self.rate * 1.8) / Self.stepsPerRevolution
        let expectedFrameVelocity = stepVelocity * midiFramesPerStep

        XCTAssertEqual(
            try XCTUnwrap(controller.dvsContinuousRenderer.lastPublishedVelocity),
            expectedFrameVelocity,
            accuracy: 0.01,
            "Published velocity must use the unchanged real-vinyl-RPM scale regardless of the active loop bound"
        )
    }

    /// A short hot-cue sample (the validated `dvs_ahhh`-equivalent case:
    /// not enough post-onset frames for a full revolution) must keep
    /// exactly its prior, already-correct behavior — the one-revolution
    /// cue window must not engage.
    func testShortHotCueSampleDoesNotEngageOneRevolutionWindow() throws {
        let controller = ScratchSamplePlaybackController()
        // Loud from frame 0 (no onset), short — mirrors dvs_ahhh's shape:
        // well under one revolution's worth of frames.
        let buffer = try makeSyntheticLoopBuffer(frames: 8_000)
        controller.testOnly_installSyntheticSample(buffer, sampleID: "short-hot-cue")
        XCTAssertEqual(controller.hotCueOnsetFrame, 0)
        XCTAssertEqual(
            controller.hotCueLoopFrames, controller.continuousLoopFrames,
            "A short sample's loop bound must remain the full available span, exactly as before this fix"
        )
    }
}
