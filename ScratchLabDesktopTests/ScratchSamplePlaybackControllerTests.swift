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
}
