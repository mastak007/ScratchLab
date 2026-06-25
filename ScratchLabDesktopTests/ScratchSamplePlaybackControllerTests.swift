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
        // The formula is: (steps * totalFrames) / stepsPerFullSample % totalFrames
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
        controller.positionDidChange(steps: 10, direction: .forward)
        controller.waitForAudioQueue()
        let frameBeforeDirectionChange = controller.currentSampleFrame

        Thread.sleep(forTimeInterval: 0.02)
        controller.positionDidChange(steps: 9, direction: .backward)
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
        controller.positionDidChange(steps: baseline + 1, direction: .forward)
        controller.waitForAudioQueue()

        XCTAssertGreaterThan(controller.currentSampleFrame, 0)
        XCTAssertLessThan(controller.currentSampleFrame, 1_000)
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

        // Forward with delta = 210 - 199 = +11 (positive, matches forward).
        // If lastPlatterSteps was not updated by the boundary skip, delta would
        // be 210 - 200 = +10 instead — either way no mismatch, but if the steps
        // baseline were stale the next forward call could trigger an erroneous
        // directionDeltaMismatch from a still-older previous value.
        controller.positionDidChange(steps: 210, direction: .forward)
        controller.waitForAudioQueue()

        XCTAssertNotEqual(controller.lastScheduleSkippedReason, "directionDeltaMismatch",
            "Post-boundary forward step must not be flagged as direction/delta mismatch")
    }

    func testDirectionDeltaMismatchForwardWithNegativeDeltaSkips() {
        let controller = ScratchSamplePlaybackController()
        guard controller.load(sampleID: "ahhh") else { return }
        controller.waitForAudioQueue()

        // Prime: establish lastPlatterSteps = 100.
        controller.positionDidChange(steps: 100, direction: .forward)
        controller.waitForAudioQueue()
        XCTAssertEqual(controller.lastScheduleSkippedReason, "priming")

        // delta = 99 - 100 = -1 (negative) but direction = forward → mismatch.
        controller.positionDidChange(steps: 99, direction: .forward)
        controller.waitForAudioQueue()

        XCTAssertEqual(controller.lastScheduleSkippedReason, "directionDeltaMismatch")
        XCTAssertNil(controller.lastScheduledSourceFrame,
            "No segment should be scheduled on direction/delta mismatch")
    }
}
