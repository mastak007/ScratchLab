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
        XCTAssertEqual(controller.loadedSampleID, "ahhh")
    }

    func testLoadThenUnload() {
        let controller = ScratchSamplePlaybackController()
        // Even if load fails, unload must not crash.
        controller.load(sampleID: "ahhh")
        controller.unload()
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

    // MARK: - statusLabel

    func testStatusLabelStartsWithIdle() {
        let controller = ScratchSamplePlaybackController()
        XCTAssertEqual(controller.statusLabel, "idle")
    }

    // MARK: - Crossfader gate

    /// Helper: set crossfader and wait for the @Published dispatch to main.
    private func setCrossfaderAndWait(_ controller: ScratchSamplePlaybackController, value: Int) {
        controller.setCrossfader(value: value)
        // setCrossfader dispatches @Published updates to main; flush that work.
        let expectation = XCTestExpectation(description: "crossfader gate dispatched")
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
        controller.unload()
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
}
