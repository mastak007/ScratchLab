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
    private static let stepsPerRevolution: Double = 3_932

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

    // MARK: - Revolution / cue-mapping parity with DVS's calibration

    func testMIDIContinuousOneFullRevolutionReturnsPhaseToOrigin() throws {
        let (controller, setNow, setSteps) = try makeController()
        setNow(0.0); setSteps(0)
        controller.testOnly_midiCoalescingTick() // priming

        setNow(1.0 / 60.0); setSteps(Int(Self.stepsPerRevolution))
        controller.testOnly_midiCoalescingTick()

        XCTAssertEqual(
            controller.currentSampleFrame,
            0,
            "Exactly one physical revolution of right-deck MIDI motion must return to the loop origin, " +
            "matching the DVS path's calibration and 12 o'clock cue mapping"
        )
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

        let framesPerStepValue = controller.dvsLoopFrames / Self.stepsPerRevolution
        func loopPhase(forSteps steps: Double) -> Double {
            let loop = controller.dvsLoopFrames
            var wrapped = (steps * framesPerStepValue).truncatingRemainder(dividingBy: loop)
            if wrapped < 0 { wrapped += loop }
            return wrapped
        }
        let expectedAnchor = Double(dvsPhase) / framesPerStepValue
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

    // MARK: - Platter test asset load-path defect (2026-08-09 hardware finding)
    //
    // Root cause: the Debug hardware-test button loaded `ahhh.wav`
    // (~4.4667 s, the hot-cue pad asset), which is longer than one physical
    // platter revolution (`dvsLoopFrames`, ~1.8 s) — `midiCoalescingTick`'s
    // loop-fit guard silently returned every tick, so moving the right
    // platter produced no audio. The validated `dvs_ahhh` asset
    // (`VirtualPlatter/ahhh.wav`, ~1.0474 s) fits the one-revolution
    // renderer geometry.

    func testBundledDVSAhhhFitsWithinOneRevolutionGeometryForDirectMIDI() throws {
        let controller = ScratchSamplePlaybackController()
        XCTAssertTrue(controller.load(sampleID: "dvs_ahhh"), "dvs_ahhh must be a known sample ID")
        controller.waitForAudioQueue()
        XCTAssertEqual(controller.loadedSampleID, "dvs_ahhh")
        XCTAssertGreaterThan(controller.totalFrames, 0)
        XCTAssertLessThanOrEqual(
            Double(controller.totalFrames),
            controller.dvsLoopFrames,
            "The validated platter-test asset must fit within one physical revolution — " +
            "the direct-MIDI continuous path silently rejects anything longer"
        )

        // No rejection diagnostic for a compatible sample.
        controller.testOnly_setRightDeckAccumulatedStepsProvider { 0 }
        controller.testOnly_midiCoalescingTick()
        XCTAssertNil(controller.lastMIDIContinuousRejectionReason)
    }

    func testSampleExceedingOneRevolutionCannotSilentlyEnterDirectMIDIMode() throws {
        let controller = ScratchSamplePlaybackController()
        // ~2.27 s at 44.1 kHz — clearly longer than the ~1.8 s/~79_380-frame
        // one-revolution loop (see `dvsLoopFrames`'s doc comment), the same
        // mismatch class as the ~4.4667 s hot-cue pad asset that produced
        // the silent-failure hardware finding.
        let longBuffer = try makeSyntheticLoopBuffer(frames: 100_000)
        controller.testOnly_installSyntheticSample(longBuffer, sampleID: "too-long-for-one-revolution")
        XCTAssertGreaterThan(
            Double(controller.totalFrames),
            controller.dvsLoopFrames,
            "test setup sanity: the synthetic sample must exceed one revolution"
        )

        controller.testOnly_setRightDeckAccumulatedStepsProvider { 40 }
        controller.testOnly_midiCoalescingTick() // priming attempt
        controller.testOnly_midiCoalescingTick() // real-motion attempt

        XCTAssertEqual(
            controller.dvsContinuousRenderer.publishCount,
            0,
            "A sample exceeding one revolution must never silently publish to the continuous renderer"
        )
        XCTAssertFalse(controller.testOnly_midiOwnsPlatterRender)
        let reason = try XCTUnwrap(
            controller.lastMIDIContinuousRejectionReason,
            "Rejection must produce a clear, readable diagnostic reason, not a silent no-op"
        )
        XCTAssertTrue(reason.contains("revolution"), "Diagnostic reason must be legible: \(reason)")
    }
}
