import XCTest
@testable import ScratchLab

/// Deterministic tests for the bridge-to-playback continuity fix
/// (2026-08-09): `MacCaptureEngine.forwardTimecodeDrive` now receives
/// `TimecodePlaybackBridge.lastDecision` alongside the optional drive, and
/// distinguishes genuine no-motion (`.unknownDirection`), transient signal
/// dropout (`.unusableSignalHealth` etc. — held for at most one tick), and
/// hard configuration gates (`.disabled` etc. — never held).
///
/// Prior to this fix, any nil `TimecodePlaybackDrive` — regardless of
/// cause — made `forwardTimecodeDrive` return without calling into the
/// playback controller at all, so its queued grain expired into digital
/// silence with no tick for the settling hysteresis to ever observe. These
/// tests exercise `forwardTimecodeDrive` directly against a real
/// `MacCaptureEngine` + `ScratchSamplePlaybackController`, using the
/// `testOnly_*` accessors added alongside this fix for synchronous
/// observability (the production `dvsPlaybackDiagnostics` is throttled to
/// 200ms and published async, which is unsuitable for asserting on the
/// effect of a single tick).
final class TimecodeBridgeContinuityFixTests: XCTestCase {

    private let tick: TimeInterval = 1.0 / 60.0

    private func makeDrive(direction: TimecodeDirection, rate: Double) -> TimecodePlaybackDrive {
        let timeline = PlatterPositionTimeline(
            source: .timecodeLive,
            startTime: 0,
            endTime: 0,
            samples: []
        )!
        return TimecodePlaybackDrive(
            direction: direction,
            rate: rate,
            sourceLabel: "test",
            timeline: timeline
        )
    }

    /// Establishes real, recognized DVS motion. The controller's very first
    /// direction-carrying tick only anchors its internal `lastPlatterSteps`
    /// baseline — no delta, no `wasDVSMotionActive`, nothing scheduled —
    /// matching `ScratchSamplePlaybackControllerTests`'s own established
    /// two-tick priming pattern (a `steps: 0` tick, then a real delta). A
    /// single `.driving` tick is therefore not yet "motion" as far as the
    /// stop-ramp trigger is concerned; two are needed before testing any
    /// immediate-stop behavior.
    private func establishSteadyMotion(_ engine: MacCaptureEngine, drive: TimecodePlaybackDrive) {
        engine.forwardTimecodeDrive(drive, decision: .driving, elapsed: tick)
        engine.testOnly_waitForPlaybackQueue()
        engine.forwardTimecodeDrive(drive, decision: .driving, elapsed: tick)
        engine.testOnly_waitForPlaybackQueue()
    }

    /// Boots a `MacCaptureEngine`, activates DVS drive, and blocks until the
    /// `dvs_ahhh` sample has actually finished loading — `forwardTimecodeDrive`
    /// kicks off the (async) load itself but does not wait for it, so every
    /// test needs one throwaway warm-up tick first. Fails hard (not a silent
    /// pass) if the bundled fixture is missing, matching
    /// `ScratchSamplePlaybackControllerTests.loadDVSAhhhOrFail`.
    private func makeReadyEngine(file: StaticString = #filePath, line: UInt = #line) -> MacCaptureEngine {
        let defaults = UserDefaults(suiteName: "TimecodeBridgeContinuityFixTests.\(UUID().uuidString)")!
        ScratchAudioOwnershipMode.scratchLabStandalone.persist(to: defaults)
        let engine = MacCaptureEngine(autoRefreshDevices: false, midiDefaults: defaults)
        engine.setDVSPlaybackDriveActive(true)
        engine.forwardTimecodeDrive(nil, decision: .notEvaluated, elapsed: 0)
        engine.testOnly_waitForPlaybackQueue()
        XCTAssertTrue(
            engine.isDVSSampleLoaded,
            "dvs_ahhh must load from the test bundle — required fixture for every test below",
            file: file,
            line: line
        )
        return engine
    }

    // MARK: - Valid drive -> one transient failure -> valid drive

    func testOneTransientFailureIsHeldWithNoStopAndNoMissingWindow() {
        let engine = makeReadyEngine()
        let drive = makeDrive(direction: .forward, rate: 1.0)

        // Two genuine driving ticks establish the reference per-tick frame
        // delta, and start real motion so a stop would be observable.
        engine.forwardTimecodeDrive(drive, decision: .driving, elapsed: tick)
        engine.testOnly_waitForPlaybackQueue()
        let afterFirst = engine.testOnly_scratchPlaybackDiagnosticsSnapshot()
        XCTAssertTrue(afterFirst.playerIsPlaying, "steady forward must start playback")

        engine.forwardTimecodeDrive(drive, decision: .driving, elapsed: tick)
        engine.testOnly_waitForPlaybackQueue()
        let afterSecond = engine.testOnly_scratchPlaybackDiagnosticsSnapshot()
        let normalDelta = afterSecond.currentSampleFrame - afterFirst.currentSampleFrame
        let scheduleCountAfterSecond = afterSecond.forwardScheduleCount

        // One transient bridge dropout (nil drive, no motion signal at all).
        engine.forwardTimecodeDrive(nil, decision: .unusableSignalHealth, elapsed: tick)
        engine.testOnly_waitForPlaybackQueue()
        let afterHeld = engine.testOnly_scratchPlaybackDiagnosticsSnapshot()

        XCTAssertTrue(afterHeld.playerIsPlaying, "a single transient gate failure must not stop the player")
        XCTAssertEqual(engine.testOnly_scratchAutoStopRampStartCount, 0,
            "a single transient gate failure must not start a stop ramp")
        XCTAssertGreaterThan(afterHeld.forwardScheduleCount, scheduleCountAfterSecond,
            "the held tick must schedule a real grain — no missing scheduled window / silence gap")

        let heldDelta = afterHeld.currentSampleFrame - afterSecond.currentSampleFrame
        // Tolerance of 1 frame absorbs independent rounding at each of the
        // three sampled points (`Int(dvsLoopPhaseFrame(...))`) — the
        // underlying continuous step accumulation itself is exact and
        // identical for both ticks (same rate, same elapsed).
        XCTAssertLessThanOrEqual(abs(heldDelta - normalDelta), 1,
            "the held tick must advance phase by exactly one bounded tick's worth of motion " +
            "(heldDelta=\(heldDelta) normalDelta=\(normalDelta)) — the same as a genuine driving " +
            "tick at the same rate and elapsed time, not more")

        // A valid drive resumes normally afterwards.
        engine.forwardTimecodeDrive(drive, decision: .driving, elapsed: tick)
        engine.testOnly_waitForPlaybackQueue()
        let afterResume = engine.testOnly_scratchPlaybackDiagnosticsSnapshot()
        XCTAssertTrue(afterResume.playerIsPlaying)
        XCTAssertEqual(engine.testOnly_scratchAutoStopRampStartCount, 0)
    }

    // MARK: - Valid drive -> two transient failures

    func testTwoConsecutiveTransientFailuresStopHoldingAfterOneTick() {
        let engine = makeReadyEngine()
        let drive = makeDrive(direction: .forward, rate: 1.0)

        engine.forwardTimecodeDrive(drive, decision: .driving, elapsed: tick)
        engine.testOnly_waitForPlaybackQueue()
        XCTAssertTrue(engine.testOnly_scratchPlaybackDiagnosticsSnapshot().playerIsPlaying)

        // First transient failure: held, no ramp yet.
        engine.forwardTimecodeDrive(nil, decision: .unusableSignalHealth, elapsed: tick)
        engine.testOnly_waitForPlaybackQueue()
        XCTAssertEqual(engine.testOnly_scratchAutoStopRampStartCount, 0,
            "the first transient tick must be held, not treated as a stop")

        // Second consecutive transient failure: holding stops, no-direction
        // is forwarded, and the existing motion -> noDirection transition
        // starts exactly one stop ramp.
        engine.forwardTimecodeDrive(nil, decision: .lowConfidence, elapsed: tick)
        engine.testOnly_waitForPlaybackQueue()
        XCTAssertEqual(engine.testOnly_scratchAutoStopRampStartCount, 1,
            "the second consecutive transient tick must give up holding and start exactly one stop ramp")

        // A third consecutive transient failure must not start a second ramp.
        engine.forwardTimecodeDrive(nil, decision: .missingTimeline, elapsed: tick)
        engine.testOnly_waitForPlaybackQueue()
        XCTAssertEqual(engine.testOnly_scratchAutoStopRampStartCount, 1,
            "repeated nil decisions after the first no-direction tick must not restart the stop ramp")

        Thread.sleep(forTimeInterval: 0.08) // past the ~10ms ramp
        engine.testOnly_waitForPlaybackQueue()
        XCTAssertFalse(engine.testOnly_scratchPlaybackDiagnosticsSnapshot().playerIsPlaying,
            "the single ramp must complete into a stopped player node")
    }

    // MARK: - .unknownDirection

    func testUnknownDirectionIsImmediateNoDirectionNeverHeld() {
        let engine = makeReadyEngine()
        let drive = makeDrive(direction: .forward, rate: 1.0)

        establishSteadyMotion(engine, drive: drive)
        XCTAssertTrue(engine.testOnly_scratchPlaybackDiagnosticsSnapshot().playerIsPlaying)

        // Unlike a transient gate failure, .unknownDirection must start the
        // stop ramp on its very first tick — no one-tick hold.
        engine.forwardTimecodeDrive(nil, decision: .unknownDirection, elapsed: tick)
        engine.testOnly_waitForPlaybackQueue()
        XCTAssertEqual(engine.testOnly_scratchAutoStopRampStartCount, 1,
            ".unknownDirection must be forwarded as an immediate no-direction tick, not held")

        Thread.sleep(forTimeInterval: 0.08)
        engine.testOnly_waitForPlaybackQueue()
        XCTAssertFalse(engine.testOnly_scratchPlaybackDiagnosticsSnapshot().playerIsPlaying)

        // The existing settling hysteresis (untouched by this fix) now
        // becomes active: two consecutive tiny-motion driving ticks are
        // needed before audible resumption — the first is suppressed.
        let tinyDrive = makeDrive(direction: .forward, rate: 0.01)
        engine.forwardTimecodeDrive(tinyDrive, decision: .driving, elapsed: tick)
        engine.testOnly_waitForPlaybackQueue()
        XCTAssertEqual(engine.testOnly_scratchPlaybackDiagnosticsSnapshot().lastScheduleSkippedReason, "settleSuppress",
            "a single tiny motion tick right after a real stop must be suppressed by the existing settling hysteresis")
    }

    // MARK: - Alternating settling wobble

    func testAlternatingSettlingWobbleProducesNoIsolatedRestartBursts() {
        let engine = makeReadyEngine()
        let drive = makeDrive(direction: .forward, rate: 1.0)

        establishSteadyMotion(engine, drive: drive)
        engine.forwardTimecodeDrive(nil, decision: .unknownDirection, elapsed: tick)
        engine.testOnly_waitForPlaybackQueue()
        Thread.sleep(forTimeInterval: 0.08)
        engine.testOnly_waitForPlaybackQueue()
        XCTAssertEqual(engine.testOnly_scratchAutoStopRampStartCount, 1)
        XCTAssertFalse(engine.testOnly_scratchPlaybackDiagnosticsSnapshot().playerIsPlaying)

        // Alternate isolated tiny motion ticks with unknownDirection ticks —
        // exactly the "settling wobble" pattern from the hardware capture.
        // None of these individually-isolated tiny ticks may restart
        // playback or start a new ramp: each is a single tick, and the
        // existing hysteresis requires two *consecutive* motion ticks.
        let tinyDrive = makeDrive(direction: .forward, rate: 0.01)
        for _ in 0..<5 {
            engine.forwardTimecodeDrive(tinyDrive, decision: .driving, elapsed: tick)
            engine.testOnly_waitForPlaybackQueue()
            engine.forwardTimecodeDrive(nil, decision: .unknownDirection, elapsed: tick)
            engine.testOnly_waitForPlaybackQueue()
        }

        XCTAssertEqual(engine.testOnly_scratchAutoStopRampStartCount, 1,
            "isolated settling wobble ticks must never start an additional stop ramp")
        XCTAssertFalse(engine.testOnly_scratchPlaybackDiagnosticsSnapshot().playerIsPlaying,
            "isolated settling wobble ticks must never restart audible playback")
    }

    // MARK: - Hard configuration/safety gates

    func testHardConfigurationGateStopsImmediatelyAndClearsHold() {
        let engine = makeReadyEngine()
        let drive = makeDrive(direction: .forward, rate: 1.0)

        establishSteadyMotion(engine, drive: drive)
        XCTAssertTrue(engine.testOnly_scratchPlaybackDiagnosticsSnapshot().playerIsPlaying)

        // A hard gate (e.g. the user disabling the bridge) must stop
        // immediately — on its very first tick, never held.
        engine.forwardTimecodeDrive(nil, decision: .disabled, elapsed: tick)
        engine.testOnly_waitForPlaybackQueue()
        XCTAssertEqual(engine.testOnly_scratchAutoStopRampStartCount, 1,
            "a hard configuration gate must be forwarded as an immediate no-direction tick, not held")

        let scheduleCountAfterDisabled = engine.testOnly_scratchPlaybackDiagnosticsSnapshot().forwardScheduleCount

        // The hard gate must also clear any held trusted drive: a
        // transient failure immediately afterwards must not resurrect the
        // pre-disable motion for one inferred tick.
        engine.forwardTimecodeDrive(nil, decision: .unusableSignalHealth, elapsed: tick)
        engine.testOnly_waitForPlaybackQueue()
        XCTAssertEqual(engine.testOnly_scratchPlaybackDiagnosticsSnapshot().forwardScheduleCount, scheduleCountAfterDisabled,
            "a transient tick immediately after a hard gate must not infer motion from a stale trusted drive")
        XCTAssertEqual(engine.testOnly_scratchAutoStopRampStartCount, 1,
            "no additional ramp should start from repeated no-direction ticks after the hard gate")
    }

    // MARK: - Stale-drive hole corrections (2026-08-09 follow-up)
    //
    // The first pass of this fix reset `consecutiveTransientDropoutTicks` on
    // `.unknownDirection` and hard gates, but left `lastTrustedTimecodeDrive`
    // populated. That meant: genuine stop -> a *later* transient dropout
    // could still find the old trusted drive and replay one tick of its
    // motion, recreating a post-stop burst. These three tests target exactly
    // that hole.

    /// Valid motion -> genuine stop (`.unknownDirection`) -> transient
    /// failure: the transient tick must not replay the pre-stop trusted
    /// drive as one inferred tick of motion.
    func testTransientFailureAfterGenuineStopDoesNotReplayStaleMotion() {
        let engine = makeReadyEngine()
        let drive = makeDrive(direction: .forward, rate: 1.0)

        establishSteadyMotion(engine, drive: drive)
        XCTAssertTrue(engine.testOnly_scratchPlaybackDiagnosticsSnapshot().playerIsPlaying)

        // Genuine stop.
        engine.forwardTimecodeDrive(nil, decision: .unknownDirection, elapsed: tick)
        engine.testOnly_waitForPlaybackQueue()
        XCTAssertEqual(engine.testOnly_scratchAutoStopRampStartCount, 1)
        Thread.sleep(forTimeInterval: 0.08) // past the ~10ms ramp
        engine.testOnly_waitForPlaybackQueue()
        XCTAssertFalse(engine.testOnly_scratchPlaybackDiagnosticsSnapshot().playerIsPlaying)

        let scheduleCountAfterStop = engine.testOnly_scratchPlaybackDiagnosticsSnapshot().forwardScheduleCount

        // A transient dropout right after the genuine stop must not schedule
        // a grain from the now-stale trusted drive.
        engine.forwardTimecodeDrive(nil, decision: .unusableSignalHealth, elapsed: tick)
        engine.testOnly_waitForPlaybackQueue()

        XCTAssertEqual(engine.testOnly_scratchPlaybackDiagnosticsSnapshot().forwardScheduleCount, scheduleCountAfterStop,
            "a transient tick right after a genuine stop must not schedule a grain — no stale held motion")
        XCTAssertFalse(engine.testOnly_scratchPlaybackDiagnosticsSnapshot().playerIsPlaying,
            "player must remain stopped — a stale trusted drive must not restart it")
        XCTAssertEqual(engine.testOnly_scratchAutoStopRampStartCount, 1,
            "the stale-drive-safe no-direction fallback must not trigger an additional ramp")
    }

    /// Valid motion -> first transient held -> second transient gives up
    /// holding -> further transients: none of the further transients may
    /// infer motion again, and only one stop ramp fires for the whole
    /// sequence.
    func testFurtherTransientFailuresAfterSecondNeverInferMotionAgain() {
        let engine = makeReadyEngine()
        let drive = makeDrive(direction: .forward, rate: 1.0)

        establishSteadyMotion(engine, drive: drive)
        XCTAssertTrue(engine.testOnly_scratchPlaybackDiagnosticsSnapshot().playerIsPlaying)

        // First transient: held (schedules one inferred-motion grain).
        engine.forwardTimecodeDrive(nil, decision: .unusableSignalHealth, elapsed: tick)
        engine.testOnly_waitForPlaybackQueue()
        XCTAssertEqual(engine.testOnly_scratchAutoStopRampStartCount, 0)
        let scheduleCountAfterHold = engine.testOnly_scratchPlaybackDiagnosticsSnapshot().forwardScheduleCount

        // Second transient: gives up holding, forwards no-direction, exactly
        // one ramp starts, and the trusted drive is cleared.
        engine.forwardTimecodeDrive(nil, decision: .lowConfidence, elapsed: tick)
        engine.testOnly_waitForPlaybackQueue()
        XCTAssertEqual(engine.testOnly_scratchAutoStopRampStartCount, 1)

        // Further, later transients must never infer motion again.
        let laterDecisions: [TimecodePlaybackBridgeDecision] = [.missingTimeline, .validationRequired, .staleSignal]
        for decision in laterDecisions {
            engine.forwardTimecodeDrive(nil, decision: decision, elapsed: tick)
            engine.testOnly_waitForPlaybackQueue()
        }

        XCTAssertEqual(engine.testOnly_scratchPlaybackDiagnosticsSnapshot().forwardScheduleCount, scheduleCountAfterHold,
            "no further grain may be scheduled by transient ticks once the second has given up holding")
        XCTAssertEqual(engine.testOnly_scratchAutoStopRampStartCount, 1,
            "exactly one stop ramp for the whole hold -> give-up -> further-transients sequence")
    }

    /// Valid motion -> Drive OFF -> Drive ON -> transient failure: the
    /// transient tick must not replay motion from the previous (deactivated)
    /// session's trusted drive.
    func testDeactivatingAndReactivatingDriveDoesNotReplayPreviousSessionMotion() {
        let engine = makeReadyEngine()
        let drive = makeDrive(direction: .forward, rate: 1.0)

        establishSteadyMotion(engine, drive: drive)
        XCTAssertTrue(engine.testOnly_scratchPlaybackDiagnosticsSnapshot().playerIsPlaying)

        engine.setDVSPlaybackDriveActive(false)
        engine.setDVSPlaybackDriveActive(true)

        let scheduleCountAfterReactivate = engine.testOnly_scratchPlaybackDiagnosticsSnapshot().forwardScheduleCount

        // A transient dropout right after reactivation must not replay
        // motion from the previous session's trusted drive.
        engine.forwardTimecodeDrive(nil, decision: .unusableSignalHealth, elapsed: tick)
        engine.testOnly_waitForPlaybackQueue()

        XCTAssertEqual(engine.testOnly_scratchPlaybackDiagnosticsSnapshot().forwardScheduleCount, scheduleCountAfterReactivate,
            "no grain may be scheduled from a previous-session trusted drive after Drive is re-enabled")
    }
}
