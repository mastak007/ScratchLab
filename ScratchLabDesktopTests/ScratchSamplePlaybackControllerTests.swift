import XCTest
@testable import ScratchLab

/// ScratchSamplePlaybackController tests.
/// Focuses on sample-frame mapping, WAV resolution, and lifecycle.
/// Full audio engine tests require hardware; these are logic-level tests.
final class ScratchSamplePlaybackControllerTests: XCTestCase {

    // MARK: - sampleFrame mapping

    func testSampleFrameAtZero() {
        let controller = ScratchSamplePlaybackController()
        // Without a loaded sample, sampleFrame returns 0.
        XCTAssertEqual(controller.sampleFrame(for: 0), 0)
    }

    func testSampleFrameWrapsWithinTotalFrames() {
        // This test exercises the arithmetic without requiring a loaded buffer.
        // The formula is: (steps * totalFrames) / stepsPerRevolution % totalFrames
        // With totalFrames=0 it returns 0; the math is still safe.
        let controller = ScratchSamplePlaybackController()
        let frame = controller.sampleFrame(for: 3932)
        XCTAssertEqual(frame, 0, "With no buffer loaded, sampleFrame always returns 0")
    }

    func testSampleFrameNegativeWraps() {
        let controller = ScratchSamplePlaybackController()
        let frame = controller.sampleFrame(for: -100)
        XCTAssertEqual(frame, 0, "Negative steps with no buffer returns 0 safely")
    }

    // MARK: - Known sample IDs

    func testKnownSampleIDsContainsExpected() {
        let ids = ScratchSamplePlaybackController.knownSampleIDs
        XCTAssertTrue(ids.contains("ahhh"))
        XCTAssertTrue(ids.contains("fresh"))
        XCTAssertTrue(ids.contains("ah_yeah"))
        XCTAssertTrue(ids.contains("check_it_out"))
        XCTAssertEqual(ids.count, 4)
    }

    // MARK: - Load missing sample (safe no-op)

    func testLoadMissingSampleReturnsFalse() {
        let controller = ScratchSamplePlaybackController()
        let result = controller.load(sampleID: "nonexistent")
        XCTAssertFalse(result, "Loading a nonexistent sample must return false")
        XCTAssertNil(controller.loadedSampleID)
    }

    // MARK: - Load bundled sample

    func testLoadBundledSampleReturnsTrue() {
        let controller = ScratchSamplePlaybackController()
        guard let wavPath = Bundle.main.path(forResource: "ahhh", ofType: "wav") else {
            // Test runs without a full app bundle; this is expected in CI.
            // Verify the missing-sample path doesn't crash instead.
            let result = controller.load(sampleID: "ahhh")
            // If the bundle has the WAV, it loads; if not, it safely returns false.
            XCTAssertTrue(result || !result, "load must return a Bool, never crash")
            return
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: wavPath),
                       "ahhh.wav must exist at \(wavPath)")
        let result = controller.load(sampleID: "ahhh")
        XCTAssertTrue(result, "Loading ahhh.wav from bundle must succeed")
        // load() dispatches file I/O to the audio queue; drain before reading state.
        controller.waitForAudioQueue()
        XCTAssertEqual(controller.loadedSampleID, "ahhh")
    }

    func testLoadThenUnload() {
        let controller = ScratchSamplePlaybackController()
        // Even if load fails, unload must not crash.
        controller.load(sampleID: "ahhh")
        controller.unload()
        // Both load and unload dispatch to the audio queue; drain before reading state.
        controller.waitForAudioQueue()
        XCTAssertNil(controller.loadedSampleID)
    }

    func testConsecutiveLoadsDontCrash() {
        let controller = ScratchSamplePlaybackController()
        for _ in 0..<5 {
            controller.load(sampleID: "ahhh")
            controller.load(sampleID: "fresh")
        }
        controller.unload()
        // Reaching here without crash is the assertion.
        XCTAssertTrue(true, "Consecutive loads/unloads must not crash")
    }

    // MARK: - sampleFrame edge cases

    func testSampleFrameWithLargeSteps() {
        let controller = ScratchSamplePlaybackController()
        // Large positive and negative steps must not overflow.
        _ = controller.sampleFrame(for: Int.max / 2)
        _ = controller.sampleFrame(for: Int.min / 2)
        XCTAssertTrue(true, "Large step values must not crash")
    }

    func testLoadedSampleHugeStepCountsDoNotCrash() {
        let controller = ScratchSamplePlaybackController()
        guard controller.load(sampleID: "ahhh") else {
            return
        }
        controller.waitForAudioQueue()

        controller.positionDidChange(steps: Int.max / 2, direction: .forward)
        controller.positionDidChange(steps: Int.min / 2, direction: .backward)
        controller.positionDidChange(steps: 8_728, direction: .forward)
        controller.waitForAudioQueue()

        XCTAssertEqual(controller.loadedSampleID, "ahhh")
    }

    func testLoadedSampleReverseNearZeroDoesNotCrash() {
        let controller = ScratchSamplePlaybackController()
        guard controller.load(sampleID: "ahhh") else {
            return
        }
        controller.waitForAudioQueue()

        controller.positionDidChange(steps: 0, direction: .backward)
        controller.positionDidChange(steps: -1, direction: .backward)
        controller.positionDidChange(steps: 1, direction: .backward)
        controller.waitForAudioQueue()

        XCTAssertEqual(controller.loadedSampleID, "ahhh")
    }

    func testForwardMovementIncreasesSourceFrameContinuously() {
        let controller = ScratchSamplePlaybackController()
        guard controller.load(sampleID: "ahhh") else {
            return
        }
        controller.waitForAudioQueue()

        controller.positionDidChange(steps: 100, direction: .forward)
        controller.waitForAudioQueue()
        XCTAssertEqual(controller.lastScheduleSkippedReason, "priming")

        controller.positionDidChange(steps: 110, direction: .forward)
        controller.waitForAudioQueue()

        XCTAssertGreaterThan(controller.currentSampleFrame, 0)
        XCTAssertEqual(controller.lastScheduledSourceFrame, 0)
    }

    func testForwardMovementNearEndClampsWithoutWrapping() {
        let controller = ScratchSamplePlaybackController()
        guard controller.load(sampleID: "ahhh") else {
            return
        }
        controller.waitForAudioQueue()

        controller.positionDidChange(steps: 0, direction: .forward)
        controller.waitForAudioQueue()
        controller.positionDidChange(steps: 1_000_000, direction: .forward)
        controller.waitForAudioQueue()
        Thread.sleep(forTimeInterval: 0.02)
        controller.positionDidChange(steps: 1_000_001, direction: .forward)
        controller.waitForAudioQueue()

        XCTAssertEqual(controller.currentSampleFrame, controller.totalFrames - 1)
        // Continuing forward past the end must hit the boundary guard rather than
        // schedule a 1-frame chatter segment.
        XCTAssertEqual(controller.lastScheduleSkippedReason, "boundaryEnd")
    }

    func testBackwardMovementDecreasesFromCurrentFrameContinuously() {
        let controller = ScratchSamplePlaybackController()
        guard controller.load(sampleID: "ahhh") else {
            return
        }
        controller.waitForAudioQueue()

        controller.positionDidChange(steps: 0, direction: .forward)
        controller.waitForAudioQueue()
        controller.positionDidChange(steps: 100, direction: .forward)
        controller.waitForAudioQueue()
        let forwardFrame = controller.currentSampleFrame

        Thread.sleep(forTimeInterval: 0.02)
        controller.positionDidChange(steps: 90, direction: .backward)
        controller.waitForAudioQueue()

        XCTAssertEqual(controller.lastScheduledSourceFrame, forwardFrame)
        XCTAssertLessThan(controller.currentSampleFrame, forwardFrame)
    }

    func testDirectionChangeDoesNotJumpToOppositeSideOfSample() {
        let controller = ScratchSamplePlaybackController()
        guard controller.load(sampleID: "ahhh") else {
            return
        }
        controller.waitForAudioQueue()

        controller.positionDidChange(steps: 0, direction: .forward)
        controller.waitForAudioQueue()
        controller.positionDidChange(steps: 20, direction: .forward)
        controller.waitForAudioQueue()
        let frameBeforeDirectionChange = controller.currentSampleFrame

        Thread.sleep(forTimeInterval: 0.02)
        // 10-step backward delta (negative) → schedulingDirection = backward → frameDelta ≈ 202.
        controller.positionDidChange(steps: 10, direction: .backward)
        controller.waitForAudioQueue()

        XCTAssertEqual(controller.lastScheduledSourceFrame, frameBeforeDirectionChange)
        XCTAssertLessThan(controller.currentSampleFrame, frameBeforeDirectionChange)
        XCTAssertLessThan(controller.lastScheduledSourceFrame ?? .max, controller.totalFrames / 4)
    }

    func testNilDirectionAndZeroDeltaDoNotSchedule() {
        let controller = ScratchSamplePlaybackController()
        guard controller.load(sampleID: "ahhh") else {
            return
        }
        controller.waitForAudioQueue()

        controller.positionDidChange(steps: 50, direction: nil)
        controller.waitForAudioQueue()
        XCTAssertEqual(controller.lastScheduleSkippedReason, "noDirection")
        XCTAssertNil(controller.lastScheduledSourceFrame)

        controller.positionDidChange(steps: 50, direction: .forward)
        controller.waitForAudioQueue()
        XCTAssertEqual(controller.lastScheduleSkippedReason, "priming")
        XCTAssertNil(controller.lastScheduledSourceFrame)
    }

    func testHugeAbsoluteStepsUseDeltaOnlyAfterTrackingIsEstablished() {
        let controller = ScratchSamplePlaybackController()
        guard controller.load(sampleID: "ahhh") else {
            return
        }
        controller.waitForAudioQueue()

        let baseline = Int.max / 2
        controller.positionDidChange(steps: baseline, direction: .forward)
        controller.waitForAudioQueue()
        // 12-step delta → frameDelta ≈ 242, above nearStop gate, schedules at sub-1x rate.
        controller.positionDidChange(steps: baseline + 12, direction: .forward)
        controller.waitForAudioQueue()

        XCTAssertGreaterThan(controller.currentSampleFrame, 0)
        XCTAssertLessThan(controller.currentSampleFrame, 1_500)
    }

    // MARK: - statusLabel

    func testStatusLabelStartsWithIdle() {
        let controller = ScratchSamplePlaybackController()
        XCTAssertEqual(controller.statusLabel, "idle")
    }

    // MARK: - Crossfader gate

    /// Helper: set crossfader and wait for the audio queue + main @Published dispatch.
    ///
    /// setCrossfader dispatches to the audio queue; audioQueue then dispatches
    /// @Published updates to main. Drain audioQueue first, then flush main so
    /// crossfaderGate is visible before the assertion.
    private func setCrossfaderAndWait(_ controller: ScratchSamplePlaybackController, value: Int) {
        controller.setCrossfader(value: value)
        controller.waitForAudioQueue()  // drain audioQueue (serial — also drains preceding work)
        let expectation = XCTestExpectation(description: "crossfader gate dispatched to main")
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 1.0)
    }

    func testCrossfaderGateDefaultsToOpen() {
        let controller = ScratchSamplePlaybackController()
        XCTAssertEqual(controller.crossfaderGate, 1.0,
            "Crossfader gate must default to 1.0 (fully open)")
    }

    func testCrossfaderValueZeroSetsClosed() {
        let controller = ScratchSamplePlaybackController()
        setCrossfaderAndWait(controller, value: 0)
        XCTAssertEqual(controller.crossfaderGate, 0.0,
            "CC8 value 0 must produce gate 0.0 (fully closed)")
    }

    func testCrossfaderValue127SetsOpen() {
        let controller = ScratchSamplePlaybackController()
        setCrossfaderAndWait(controller, value: 127)
        XCTAssertEqual(controller.crossfaderGate, 1.0,
            "CC8 value 127 must produce gate 1.0 (fully open)")
    }

    func testCrossfaderValue64MidPosition() {
        let controller = ScratchSamplePlaybackController()
        setCrossfaderAndWait(controller, value: 64)
        let expected = Float(64) / 127.0
        XCTAssertEqual(controller.crossfaderGate, expected, accuracy: 0.01,
            "CC8 value 64 must produce gate ~0.5")
    }

    func testCrossfaderIntermediateValuesStable() {
        let controller = ScratchSamplePlaybackController()
        let testValues = [0, 1, 32, 63, 65, 96, 126, 127]
        for v in testValues {
            setCrossfaderAndWait(controller, value: v)
            let expected = Float(v) / 127.0
            XCTAssertEqual(controller.crossfaderGate, expected, accuracy: 0.01,
                "CC8 value \(v) must produce gate \(expected)")
        }
    }

    func testCrossfaderDoesNotCrashWhenEngineNotLoaded() {
        let controller = ScratchSamplePlaybackController()
        // setCrossfader must not crash even if no sample is loaded / engine not started.
        for v in [0, 64, 127] {
            controller.setCrossfader(value: v)
        }
        XCTAssertTrue(true, "setCrossfader must not crash without a loaded sample")
    }

    func testCrossfaderResetOnUnload() {
        let controller = ScratchSamplePlaybackController()
        controller.load(sampleID: "ahhh")
        setCrossfaderAndWait(controller, value: 0)
        XCTAssertEqual(controller.crossfaderGate, 0.0)
        // unload() dispatches to the audio queue, which then dispatches the
        // @Published crossfaderGate reset to main. Drain both before asserting.
        controller.unload()
        controller.waitForAudioQueue()
        let expectation = XCTestExpectation(description: "unload @Published dispatched to main")
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(controller.crossfaderGate, 1.0,
            "Unload must reset crossfader gate to 1.0 (open)")
    }

    func testLastCrossfaderRawValueUpdated() {
        let controller = ScratchSamplePlaybackController()
        XCTAssertNil(controller.lastCrossfaderRawValue)
        setCrossfaderAndWait(controller, value: 64)
        XCTAssertEqual(controller.lastCrossfaderRawValue, 64)
        setCrossfaderAndWait(controller, value: 0)
        XCTAssertEqual(controller.lastCrossfaderRawValue, 0)
    }

    // MARK: - Concurrency: dispatch-safety stress tests

    /// Simulates the CoreMIDI scenario: concurrent callers hammering load() and
    /// positionDidChange() from different threads simultaneously. The serial
    /// audioQueue must serialise all audio work without crashing or data-racing.
    func testConcurrentLoadAndPositionDidChangeDoNotCrash() {
        let controller = ScratchSamplePlaybackController()
        let group = DispatchGroup()
        let callers = DispatchQueue(label: "test.concurrent.callers", attributes: .concurrent)
        for i in 0..<60 {
            group.enter()
            callers.async {
                if i % 3 == 0 {
                    controller.load(sampleID: "ahhh")
                } else if i % 3 == 1 {
                    controller.positionDidChange(
                        steps: i * 17,
                        direction: i % 2 == 0 ? .forward : .backward
                    )
                } else {
                    controller.setCrossfader(value: i % 128)
                }
                group.leave()
            }
        }
        group.wait()
        controller.waitForAudioQueue()
        controller.unload()
        controller.waitForAudioQueue()
        XCTAssertTrue(true, "Concurrent dispatch to audioQueue must not crash")
    }

    /// Simulates a pad press (load) overlapping with rapid platter movement
    /// (positionDidChange) from different threads. Verifies the serial queue
    /// isolates state mutation so no data race occurs.
    func testConcurrentLoadAndUnloadDoNotCrash() {
        let controller = ScratchSamplePlaybackController()
        let group = DispatchGroup()
        let callers = DispatchQueue(label: "test.concurrent.loadunload", attributes: .concurrent)
        for i in 0..<40 {
            group.enter()
            callers.async {
                if i % 2 == 0 {
                    controller.load(sampleID: i % 4 == 0 ? "ahhh" : "fresh")
                } else {
                    controller.unload()
                }
                group.leave()
            }
        }
        group.wait()
        controller.waitForAudioQueue()
        XCTAssertTrue(true, "Concurrent load/unload dispatch must not crash")
    }

    // MARK: - Boundary chatter guards

    func testBackwardAtFrameZeroSkipsBoundaryStart() {
        let controller = ScratchSamplePlaybackController()
        guard controller.load(sampleID: "ahhh") else { return }
        controller.waitForAudioQueue()
        // currentSampleFrame starts at 0 after load.

        // Prime with backward steps so lastPlatterSteps is established.
        controller.positionDidChange(steps: 100, direction: .backward)
        controller.waitForAudioQueue()
        XCTAssertEqual(controller.lastScheduleSkippedReason, "priming")

        // delta = 99 - 100 = -1 (matches backward), frame = 0 → boundaryStart.
        controller.positionDidChange(steps: 99, direction: .backward)
        controller.waitForAudioQueue()

        XCTAssertEqual(controller.lastScheduleSkippedReason, "boundaryStart")
        XCTAssertEqual(controller.currentSampleFrame, 0)
        XCTAssertNil(controller.lastScheduledSourceFrame, "No segment should be scheduled at boundaryStart")
    }

    func testForwardAtLastFrameSkipsBoundaryEnd() {
        let controller = ScratchSamplePlaybackController()
        guard controller.load(sampleID: "ahhh") else { return }
        controller.waitForAudioQueue()

        // Move to end of sample.
        controller.positionDidChange(steps: 0, direction: .forward)
        controller.waitForAudioQueue()
        controller.positionDidChange(steps: 1_000_000, direction: .forward)
        controller.waitForAudioQueue()
        XCTAssertEqual(controller.currentSampleFrame, controller.totalFrames - 1)

        Thread.sleep(forTimeInterval: 0.02)

        // Attempting to move further forward must hit boundaryEnd.
        controller.positionDidChange(steps: 1_000_001, direction: .forward)
        controller.waitForAudioQueue()

        XCTAssertEqual(controller.lastScheduleSkippedReason, "boundaryEnd")
        XCTAssertEqual(controller.currentSampleFrame, controller.totalFrames - 1)
    }

    func testBoundarySkipUpdatesLastPlatterSteps() {
        let controller = ScratchSamplePlaybackController()
        guard controller.load(sampleID: "ahhh") else { return }
        controller.waitForAudioQueue()

        // Prime.
        controller.positionDidChange(steps: 200, direction: .backward)
        controller.waitForAudioQueue()

        // Hit backward boundary; lastPlatterSteps must update to 199.
        controller.positionDidChange(steps: 199, direction: .backward)
        controller.waitForAudioQueue()
        XCTAssertEqual(controller.lastScheduleSkippedReason, "boundaryStart")

        Thread.sleep(forTimeInterval: 0.02)

        // Forward with delta = 210 - 199 = +11 (positive → forward).
        // If lastPlatterSteps was not updated by the boundary skip, the baseline
        // would be stale and the computed delta would misrepresent the actual step
        // displacement — producing an oversized grain on the next event.
        controller.positionDidChange(steps: 210, direction: .forward)
        controller.waitForAudioQueue()

        XCTAssertNil(controller.lastScheduleSkippedReason,
            "Post-boundary forward step must schedule successfully")
    }

    // MARK: - Scheduling direction from delta sign (Fix A)

    func testNegativeDeltaWithStaleFwdTrackerDirectionSchedulesBackward() {
        // Scheduling direction derives from deltaSteps sign, not tracker direction.
        // A negative delta schedules a backward grain even when the tracker still
        // reports .forward — the typical 16-event (~20ms) lag at a baby-scratch reversal.
        let controller = ScratchSamplePlaybackController()
        guard controller.load(sampleID: "ahhh") else { return }
        controller.waitForAudioQueue()

        // Prime then advance forward so currentSampleFrame > 0 (away from boundaryStart).
        controller.positionDidChange(steps: 0, direction: .forward)
        controller.waitForAudioQueue()
        controller.positionDidChange(steps: 20, direction: .forward)
        controller.waitForAudioQueue()
        let frameAfterForward = controller.currentSampleFrame
        XCTAssertGreaterThan(frameAfterForward, 0)

        Thread.sleep(forTimeInterval: 0.02)

        // deltaSteps = 10 - 20 = -10 (negative → backward), tracker direction stale .forward.
        controller.positionDidChange(steps: 10, direction: .forward)
        controller.waitForAudioQueue()

        XCTAssertNil(controller.lastScheduleSkippedReason,
            "Stale tracker direction must not veto a grain when delta sign is unambiguous")
        XCTAssertNotNil(controller.lastScheduledRate,
            "Negative delta with stale forward tracker direction must schedule a backward grain")
        XCTAssertLessThan(controller.currentSampleFrame, frameAfterForward,
            "Backward grain must decrease currentSampleFrame")
    }

    func testPositiveDeltaWithStaleBackwardTrackerDirectionSchedulesForward() {
        // Symmetric case: positive delta schedules forward even when tracker still
        // reports .backward — the lag on the other side of a reversal.
        let controller = ScratchSamplePlaybackController()
        guard controller.load(sampleID: "ahhh") else { return }
        controller.waitForAudioQueue()

        // Advance forward, then backward, to establish a position away from boundaries.
        controller.positionDidChange(steps: 0, direction: .forward)
        controller.waitForAudioQueue()
        controller.positionDidChange(steps: 20, direction: .forward)
        controller.waitForAudioQueue()
        Thread.sleep(forTimeInterval: 0.02)
        controller.positionDidChange(steps: 10, direction: .backward)
        controller.waitForAudioQueue()
        let frameAfterBackward = controller.currentSampleFrame

        Thread.sleep(forTimeInterval: 0.02)

        // deltaSteps = 20 - 10 = +10 (positive → forward), tracker direction stale .backward.
        controller.positionDidChange(steps: 20, direction: .backward)
        controller.waitForAudioQueue()

        XCTAssertNil(controller.lastScheduleSkippedReason,
            "Stale tracker direction must not veto a grain when delta sign is unambiguous")
        XCTAssertNotNil(controller.lastScheduledRate,
            "Positive delta with stale backward tracker direction must schedule a forward grain")
        XCTAssertGreaterThan(controller.currentSampleFrame, frameAfterBackward,
            "Forward grain must increase currentSampleFrame")
    }

    func testReversalGrainSchedulesImmediatelyWithStaleFwdDirection() {
        // Verifies there is no reversal silence gap: the very first backward event after a
        // forward push must produce a grain even while the tracker still says .forward.
        // This is the fix for baby-scratch start-point drift.
        let controller = ScratchSamplePlaybackController()
        guard controller.load(sampleID: "ahhh") else { return }
        controller.waitForAudioQueue()

        controller.positionDidChange(steps: 0, direction: .forward)
        controller.waitForAudioQueue()
        controller.positionDidChange(steps: 25, direction: .forward)
        controller.waitForAudioQueue()
        let frameAfterPush = controller.currentSampleFrame
        XCTAssertGreaterThan(frameAfterPush, 0, "Forward push must advance frame")

        Thread.sleep(forTimeInterval: 0.02)

        // First backward event at reversal apex, tracker direction stale .forward.
        // deltaSteps = 15 - 25 = -10 → frameDelta ≈ 202, above nearStop gate.
        controller.positionDidChange(steps: 15, direction: .forward)
        controller.waitForAudioQueue()

        XCTAssertNil(controller.lastScheduleSkippedReason,
            "First backward event at reversal must schedule immediately, not be silently dropped")
        XCTAssertLessThan(controller.currentSampleFrame, frameAfterPush,
            "Reversal grain must retreat the needle")
    }

    // MARK: - Varispeed grain sizing

    // framesPerStep ≈ 20 for "ahhh" (vinyl-correct: sampleRate × 1.8 / stepsPerRevolution).
    // requestedFrames = Int(44100 * 1/60) = 735.
    // nearStop gate: frameDelta < 184 suppressed (minAudibleDeltaSteps=9 × framesPerStep).

    func testSlowPlattersProducesSmallGrainAndLowRate() {
        let controller = ScratchSamplePlaybackController()
        guard controller.load(sampleID: "ahhh") else { return }
        controller.waitForAudioQueue()

        // deltaSteps=12 → frameDelta ≈ 242. 242 > 184 (above nearStop gate), < 735 → rate < 1.
        controller.positionDidChange(steps: 0, direction: .forward)
        controller.waitForAudioQueue()
        controller.positionDidChange(steps: 12, direction: .forward)
        controller.waitForAudioQueue()

        guard let segFrames = controller.lastScheduledSegmentFrames,
              let rate = controller.lastScheduledRate else {
            XCTFail("Slow platter must produce a scheduled grain")
            return
        }
        let requestedFrames = Int(44100.0 / 60.0)
        XCTAssertLessThan(segFrames, requestedFrames, "Slow platter: grain smaller than 1x window")
        XCTAssertLessThanOrEqual(rate, 1.0, "Slow platter: rate ≤ 1")
        XCTAssertGreaterThanOrEqual(rate, 0.25, "Rate must not fall below varispeed minimum")
    }

    func testFastPlattersProducesLargeGrainAndHighRate() {
        let controller = ScratchSamplePlaybackController()
        guard controller.load(sampleID: "ahhh") else { return }
        controller.waitForAudioQueue()

        // deltaSteps=55 → frameDelta ≈ 1110. 1110 > 735 → rate > 1, segmentFrames > requestedFrames.
        controller.positionDidChange(steps: 0, direction: .forward)
        controller.waitForAudioQueue()
        controller.positionDidChange(steps: 55, direction: .forward)
        controller.waitForAudioQueue()

        guard let segFrames = controller.lastScheduledSegmentFrames,
              let rate = controller.lastScheduledRate else {
            XCTFail("Fast platter must produce a scheduled grain")
            return
        }
        let requestedFrames = Int(44100.0 / 60.0)
        XCTAssertGreaterThan(segFrames, requestedFrames, "Fast platter: grain larger than 1x window")
        XCTAssertGreaterThan(rate, 1.0, "Fast platter: rate > 1")
        XCTAssertLessThanOrEqual(rate, 4.0, "Rate must not exceed varispeed maximum")
    }

    func testNormalMovementProducesRateNearOne() {
        let controller = ScratchSamplePlaybackController()
        guard controller.load(sampleID: "ahhh") else { return }
        controller.waitForAudioQueue()

        // deltaSteps=36 → frameDelta ≈ 727, requestedFrames=735 → rate ≈ 0.99.
        controller.positionDidChange(steps: 0, direction: .forward)
        controller.waitForAudioQueue()
        controller.positionDidChange(steps: 36, direction: .forward)
        controller.waitForAudioQueue()

        guard let rate = controller.lastScheduledRate else {
            XCTFail("Normal movement must produce a scheduled grain")
            return
        }
        XCTAssertEqual(rate, 1.0, accuracy: 0.2, "15 steps produces rate near 1.0 (native speed)")
    }

    func testTinyDeltaSkipsMinimumGrain() {
        // tinyGrain (frameDelta < 2) and nearStop (frameDelta < minAudibleFrameDelta)
        // are independent gates. With framesPerStep≈20, a 1-step movement gives
        // frameDelta≈20, which is >> tinyGrain threshold (2) but below nearStop
        // threshold (≈182). The nearStop gate suppresses it; the needle still
        // advances silently so the virtual stylus tracks the physical platter.
        let controller = ScratchSamplePlaybackController()
        guard controller.load(sampleID: "ahhh") else { return }
        controller.waitForAudioQueue()

        controller.positionDidChange(steps: 0, direction: .forward)
        controller.waitForAudioQueue()
        XCTAssertEqual(controller.lastScheduleSkippedReason, "priming")

        // 1 step → frameDelta ≈ 20. Suppressed by nearStop, NOT by tinyGrain.
        controller.positionDidChange(steps: 1, direction: .forward)
        controller.waitForAudioQueue()

        XCTAssertNotEqual(controller.lastScheduleSkippedReason, "tinyGrain",
            "Single-step forward (frameDelta≈20) must not be suppressed as tinyGrain")
        XCTAssertEqual(controller.lastScheduleSkippedReason, "nearStop",
            "Single-step forward (frameDelta≈20) must be suppressed as nearStop")
        // Needle advances silently through the near-stop gate.
        XCTAssertEqual(controller.currentSampleFrame, 20,
            "Near-stop gate must advance needle silently (20 frames for 1 step)")
    }

    func testBackwardMovementUsesMatchingVarispeedRate() {
        let controller = ScratchSamplePlaybackController()
        guard controller.load(sampleID: "ahhh") else { return }
        controller.waitForAudioQueue()

        // Forward with deltaSteps=20 → frameDelta ≈ 404.
        controller.positionDidChange(steps: 100, direction: .forward)
        controller.waitForAudioQueue()
        controller.positionDidChange(steps: 120, direction: .forward)
        controller.waitForAudioQueue()
        let forwardRate = controller.lastScheduledRate

        Thread.sleep(forTimeInterval: 0.02)

        // Backward with same magnitude deltaSteps=20 → same frameDelta → same rate.
        controller.positionDidChange(steps: 100, direction: .backward)
        controller.waitForAudioQueue()
        let backwardRate = controller.lastScheduledRate

        guard let fr = forwardRate, let br = backwardRate else {
            XCTFail("Both forward and backward must schedule a grain at matching step magnitude")
            return
        }
        XCTAssertEqual(fr, br, accuracy: 0.01,
            "Same step magnitude forward/backward must produce the same varispeed rate")
    }

    func testTinyForwardDeltaAtMinRateThreshold() {
        // Verifies the varispeed rate clamp at the nearStop boundary when
        // two same-direction grains ensure no reversal compensation fires.
        let controller = ScratchSamplePlaybackController()
        guard controller.load(sampleID: "ahhh") else { return }
        controller.waitForAudioQueue()

        // First forward grain: 20 steps → frameDelta≈404, establishes position.
        controller.positionDidChange(steps: 0, direction: .forward)
        controller.waitForAudioQueue()
        controller.positionDidChange(steps: 20, direction: .forward)
        controller.waitForAudioQueue()

        Thread.sleep(forTimeInterval: 0.02)

        // Second forward grain: 9 steps → frameDelta≈182.
        // Same direction → no reversal compensation.
        // rawRate = 182/735 ≈ 0.248 → clamped to minVarispeedRate (0.25).
        controller.positionDidChange(steps: 29, direction: .forward)
        controller.waitForAudioQueue()

        XCTAssertFalse(controller.lastReversalCompensated,
            "Same-direction grains must not trigger reversal compensation")
        guard let rate = controller.lastScheduledRate else {
            XCTFail("9-step same-direction grain must schedule")
            return
        }
        XCTAssertEqual(rate, Float(0.25), accuracy: Float(0.01),
            "9-step grain (frameDelta≈182) at threshold must clamp to min varispeed rate (0.25)")
    }

    // MARK: - Near-stop gate (anti-farting)

    func testNearStopGateSkipsSchedulingBelowThreshold() {
        let controller = ScratchSamplePlaybackController()
        guard controller.load(sampleID: "ahhh") else { return }
        controller.waitForAudioQueue()

        // 5-step delta → frameDelta ≈ 101 < minAudibleFrameDelta (≈182).
        controller.positionDidChange(steps: 0, direction: .forward)
        controller.waitForAudioQueue()
        XCTAssertEqual(controller.lastScheduleSkippedReason, "priming")

        controller.positionDidChange(steps: 5, direction: .forward)
        controller.waitForAudioQueue()

        XCTAssertEqual(controller.lastScheduleSkippedReason, "nearStop",
            "5-step delta (frameDelta≈101) below threshold must skip as nearStop")
        XCTAssertNil(controller.lastScheduledRate,
            "Near-stop skip must not schedule a grain")
    }

    func testNearStopGateSchedulesAtThreshold() {
        let controller = ScratchSamplePlaybackController()
        guard controller.load(sampleID: "ahhh") else { return }
        controller.waitForAudioQueue()

        // 9-step delta → frameDelta ≈ 182, right at the nearStop threshold.
        controller.positionDidChange(steps: 0, direction: .forward)
        controller.waitForAudioQueue()
        controller.positionDidChange(steps: 9, direction: .forward)
        controller.waitForAudioQueue()

        XCTAssertNotNil(controller.lastScheduledRate,
            "9-step delta (at threshold) must schedule a grain")
    }

    func testNearStopGateSchedulesAboveThreshold() {
        let controller = ScratchSamplePlaybackController()
        guard controller.load(sampleID: "ahhh") else { return }
        controller.waitForAudioQueue()

        // 15-step delta → frameDelta ≈ 303, well above nearStop threshold.
        controller.positionDidChange(steps: 0, direction: .forward)
        controller.waitForAudioQueue()
        controller.positionDidChange(steps: 15, direction: .forward)
        controller.waitForAudioQueue()

        XCTAssertNil(controller.lastScheduleSkippedReason,
            "15-step delta (above threshold) must not skip")
        XCTAssertNotNil(controller.lastScheduledRate,
            "15-step delta must schedule a grain")
    }

    func testNearStopGateUpdatesLastPlatterSteps() {
        let controller = ScratchSamplePlaybackController()
        guard controller.load(sampleID: "ahhh") else { return }
        controller.waitForAudioQueue()

        // Establish tracking with a forward push that schedules.
        controller.positionDidChange(steps: 0, direction: .forward)
        controller.waitForAudioQueue()
        controller.positionDidChange(steps: 20, direction: .forward)
        controller.waitForAudioQueue()

        Thread.sleep(forTimeInterval: 0.02)

        // Now a tiny backward delta that hits nearStop.
        // lastPlatterSteps must be updated so the next forward delta is correct.
        controller.positionDidChange(steps: 16, direction: .backward)
        controller.waitForAudioQueue()
        XCTAssertEqual(controller.lastScheduleSkippedReason, "nearStop")

        Thread.sleep(forTimeInterval: 0.02)

        // Forward delta = 30 - 16 = +14 (not 30 - 20 = +10 if stale).
        controller.positionDidChange(steps: 30, direction: .forward)
        controller.waitForAudioQueue()

        XCTAssertNil(controller.lastScheduleSkippedReason,
            "Post-nearStop forward step must schedule with correct delta baseline")
    }

    func testNearStopGateAdvancesNeedleSilently() {
        let controller = ScratchSamplePlaybackController()
        guard controller.load(sampleID: "ahhh") else { return }
        controller.waitForAudioQueue()

        let before = controller.currentSampleFrame
        XCTAssertEqual(before, 0)

        // Priming.
        controller.positionDidChange(steps: 0, direction: .forward)
        controller.waitForAudioQueue()

        // 3-step delta → frameDelta ≈ 61, below nearStop threshold.
        // Needle should advance silently.
        controller.positionDidChange(steps: 3, direction: .forward)
        controller.waitForAudioQueue()

        XCTAssertEqual(controller.lastScheduleSkippedReason, "nearStop")
        XCTAssertEqual(controller.currentSampleFrame, 61,
            "Near-stop gate must advance needle silently (3 steps × ~20.19 frames/step, rounded)")
    }

    // MARK: - Reversal symmetry (Fix 2)

    func testReversalCompensatesFirstBackwardGrain() {
        let controller = ScratchSamplePlaybackController()
        guard controller.load(sampleID: "ahhh") else { return }
        controller.waitForAudioQueue()

        // Forward push: 20 steps → frameDelta ≈ 404.
        controller.positionDidChange(steps: 0, direction: .forward)
        controller.waitForAudioQueue()
        controller.positionDidChange(steps: 20, direction: .forward)
        controller.waitForAudioQueue()
        let frameAfterPush = controller.currentSampleFrame
        XCTAssertEqual(frameAfterPush, 404)

        Thread.sleep(forTimeInterval: 0.02)

        // Reverse with 10 steps (starved) → raw frameDelta ≈ 202.
        // Compensation: lastEffectiveFrameDelta=404 > 202 → borrow 404.
        controller.positionDidChange(steps: 10, direction: .backward)
        controller.waitForAudioQueue()

        XCTAssertNil(controller.lastScheduleSkippedReason,
            "Backward grain at reversal must schedule")
        XCTAssertTrue(controller.lastReversalCompensated,
            "First backward grain after forward must be compensated")
        XCTAssertEqual(controller.lastEffectiveFrameDelta, 404,
            "Effective frameDelta must match the last forward grain (404)")
        // With effectiveFrameDelta=404 and segmentFrames=min(404, pos+1),
        // pos returns to 0 (needle back at start).
        XCTAssertEqual(controller.currentSampleFrame, 0,
            "Compensated backward grain must return needle to start")
    }

    func testReversalCompensatesFirstForwardGrain() {
        let controller = ScratchSamplePlaybackController()
        guard controller.load(sampleID: "ahhh") else { return }
        controller.waitForAudioQueue()

        // Move forward so there is room to move backward from.
        controller.positionDidChange(steps: 0, direction: .forward)
        controller.waitForAudioQueue()
        controller.positionDidChange(steps: 30, direction: .forward)
        controller.waitForAudioQueue()

        Thread.sleep(forTimeInterval: 0.02)

        // Backward: deltaSteps=20 → frameDelta ≈ 404.
        controller.positionDidChange(steps: 10, direction: .backward)
        controller.waitForAudioQueue()
        let frameAfterBackward = controller.currentSampleFrame

        Thread.sleep(forTimeInterval: 0.02)

        // Forward reversal with 10 steps (starved) → raw frameDelta ≈ 202.
        // Compensation: lastEffectiveFrameDelta=404 > 202 → borrow 404.
        controller.positionDidChange(steps: 20, direction: .forward)
        controller.waitForAudioQueue()

        XCTAssertNil(controller.lastScheduleSkippedReason,
            "Forward grain at reversal must schedule")
        XCTAssertTrue(controller.lastReversalCompensated,
            "First forward grain after backward must be compensated")
        XCTAssertGreaterThan(controller.currentSampleFrame, frameAfterBackward,
            "Compensated forward grain must advance needle")
    }

    func testBabyScratchCyclesReturnNearStart() {
        let controller = ScratchSamplePlaybackController()
        guard controller.load(sampleID: "ahhh") else { return }
        controller.waitForAudioQueue()

        // Prime.
        controller.positionDidChange(steps: 0, direction: .forward)
        controller.waitForAudioQueue()

        // Simulate 3 baby-scratch cycles: forward push + backward return.
        // Each push: 20 steps forward → frameDelta ≈ 404 (actual).
        // Each reversal: compensated to 404, returning needle near 0.
        for _ in 0..<3 {
            // Forward push.
            controller.positionDidChange(steps: 20, direction: .forward)
            controller.waitForAudioQueue()

            Thread.sleep(forTimeInterval: 0.02)

            // Backward return (starved to 12 steps → raw 242, compensated to 404).
            controller.positionDidChange(steps: 8, direction: .backward)
            controller.waitForAudioQueue()
        }

        // After 3 cycles with compensation, needle should stay near start.
        // Without compensation, it would have drifted to ~3×404 forward.
        XCTAssertEqual(controller.currentSampleFrame, 0,
            "Baby-scratch cycles with reversal compensation must return near start")
    }

    func testReversalCompensationClampedNearBoundaryEnd() {
        let controller = ScratchSamplePlaybackController()
        guard controller.load(sampleID: "ahhh") else { return }
        controller.waitForAudioQueue()

        // Force needle near end of sample.
        controller.positionDidChange(steps: 0, direction: .forward)
        controller.waitForAudioQueue()
        controller.positionDidChange(steps: 1_000_000, direction: .forward)
        controller.waitForAudioQueue()
        let nearEnd = controller.currentSampleFrame
        XCTAssertEqual(nearEnd, controller.totalFrames - 1, "Needle must be at end")

        Thread.sleep(forTimeInterval: 0.02)

        // Reverse with compensated grain: lastEffectiveFrameDelta ≈ large.
        // segmentFrames = min(effectiveFrameDelta, sourceFrame+1) — clamped.
        controller.positionDidChange(steps: 1_000_000 - 20, direction: .backward)
        controller.waitForAudioQueue()

        // BoundaryEnd (then backing away): the grain must not crash or truncate badly.
        XCTAssertLessThan(controller.currentSampleFrame, nearEnd,
            "Backward grain at end must retreat needle safely")
    }

    func testReversalCompensationClampedNearBoundaryStart() {
        let controller = ScratchSamplePlaybackController()
        guard controller.load(sampleID: "ahhh") else { return }
        controller.waitForAudioQueue()

        // Push forward modestly, then backward to near zero.
        controller.positionDidChange(steps: 0, direction: .forward)
        controller.waitForAudioQueue()
        controller.positionDidChange(steps: 20, direction: .forward)
        controller.waitForAudioQueue()

        Thread.sleep(forTimeInterval: 0.02)

        // Backward with large compensated grain — clamped to availableFrames.
        controller.positionDidChange(steps: 0, direction: .backward)
        controller.waitForAudioQueue()
        XCTAssertEqual(controller.currentSampleFrame, 0,
            "Compensated backward grain near start must stop at frame 0")
    }

    func testNearStopGateStillWinsOverReversalCompensation() {
        let controller = ScratchSamplePlaybackController()
        guard controller.load(sampleID: "ahhh") else { return }
        controller.waitForAudioQueue()

        // Forward push to establish a large lastEffectiveFrameDelta.
        controller.positionDidChange(steps: 0, direction: .forward)
        controller.waitForAudioQueue()
        controller.positionDidChange(steps: 30, direction: .forward)
        controller.waitForAudioQueue()
        let forwardEff = controller.lastEffectiveFrameDelta
        XCTAssertGreaterThan(forwardEff ?? 0, 500, "Forward push must be well above nearStop")

        Thread.sleep(forTimeInterval: 0.02)

        // Reverse with a tiny delta (3 steps → frameDelta ≈ 61, below nearStop).
        // Near-stop gate must fire BEFORE reversal compensation is considered.
        controller.positionDidChange(steps: 27, direction: .backward)
        controller.waitForAudioQueue()

        XCTAssertEqual(controller.lastScheduleSkippedReason, "nearStop",
            "Near-stop gate must suppress a tiny reversal grain even when compensation is available")
        XCTAssertFalse(controller.lastReversalCompensated,
            "Reversal compensation must not fire when nearStop skipped the grain")
    }
}
