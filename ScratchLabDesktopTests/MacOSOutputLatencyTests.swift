import XCTest
@testable import ScratchLab

/// Locks the contract of `MacOSOutputLatency`: a pure compute helper
/// that turns raw Core Audio readings (device latency, buffer frame
/// size, sample rate) into a seconds value used by
/// `DemoAudioClock.outputLatency` to pull back the notation playhead
/// to match what the listener hears.
///
/// Also covers the conservative fallback that the runtime query uses
/// when Core Audio errors and the live-query smoke test that the
/// query path returns a finite, non-negative value when run on a
/// real macOS host.
final class MacOSOutputLatencyTests: XCTestCase {

    // MARK: - 1. Pure compute: typical 44.1 kHz / 512-frame buffer

    func testComputeReturnsExpectedLatencyForTypicalDevice() {
        // 64 frames device latency + 512 buffer @ 44100 Hz =
        // 576 / 44100 ≈ 0.01306 s.
        let latency = MacOSOutputLatency.compute(
            deviceLatencyFrames: 64,
            bufferFrameSize: 512,
            sampleRate: 44100
        )
        XCTAssertEqual(latency, 576.0 / 44100.0, accuracy: 1e-9)
    }

    // MARK: - 2. Pure compute: 48 kHz / 1024 buffer

    func testComputeReturnsExpectedLatencyForLargerBuffer() {
        let latency = MacOSOutputLatency.compute(
            deviceLatencyFrames: 256,
            bufferFrameSize: 1024,
            sampleRate: 48000
        )
        XCTAssertEqual(latency, 1280.0 / 48000.0, accuracy: 1e-9)
    }

    // MARK: - 3. Pure compute: zero device latency + small buffer

    func testComputeReturnsBufferLatencyWhenDeviceLatencyZero() {
        let latency = MacOSOutputLatency.compute(
            deviceLatencyFrames: 0,
            bufferFrameSize: 256,
            sampleRate: 44100
        )
        XCTAssertEqual(latency, 256.0 / 44100.0, accuracy: 1e-9)
    }

    // MARK: - 4. Pure compute: zero sample rate → fallback

    func testComputeFallsBackOnZeroSampleRate() {
        let latency = MacOSOutputLatency.compute(
            deviceLatencyFrames: 64,
            bufferFrameSize: 512,
            sampleRate: 0
        )
        XCTAssertEqual(latency, MacOSOutputLatency.fallback, accuracy: 1e-9)
    }

    // MARK: - 5. Pure compute: non-finite sample rate → fallback

    func testComputeFallsBackOnNonFiniteSampleRate() {
        XCTAssertEqual(
            MacOSOutputLatency.compute(
                deviceLatencyFrames: 64,
                bufferFrameSize: 512,
                sampleRate: .nan
            ),
            MacOSOutputLatency.fallback
        )
        XCTAssertEqual(
            MacOSOutputLatency.compute(
                deviceLatencyFrames: 64,
                bufferFrameSize: 512,
                sampleRate: .infinity
            ),
            MacOSOutputLatency.fallback
        )
    }

    // MARK: - 6. Fallback constant is conservative

    /// The fallback must be small enough that it doesn't overcorrect
    /// the playhead on built-in speakers (where real latency is
    /// ~10-25 ms) and large enough that some compensation happens
    /// when the Core Audio query fails entirely.
    func testFallbackIsInConservativeRange() {
        XCTAssertGreaterThan(MacOSOutputLatency.fallback, 0)
        XCTAssertLessThan(MacOSOutputLatency.fallback, 0.050)
    }

    // MARK: - 7. Live query returns a finite, non-negative value

    /// Smoke test against the running macOS host. Asserts that the
    /// Core Audio query path returns *some* finite value — either a
    /// real latency reading or the fallback. Skipped on iOS because
    /// the macOS query path is `#if !canImport(UIKit)`.
    func testLiveQueryReturnsFiniteValue() {
        #if !canImport(UIKit)
        let latency = MacOSOutputLatency.query()
        XCTAssertTrue(latency.isFinite, "live query returned non-finite latency: \(latency)")
        XCTAssertGreaterThanOrEqual(latency, 0, "live query returned negative latency: \(latency)")
        // Sanity-bound: no real audio device has > 1 s of output
        // latency. If we see one, the query is reading the wrong
        // property.
        XCTAssertLessThan(latency, 1.0)
        #else
        throw XCTSkip("MacOSOutputLatency.query is macOS-only")
        #endif
    }

    // MARK: - 8. DemoAudioClock subtracts whatever latency value it receives

    /// Regression on the existing `DemoAudioClock.currentTime`
    /// contract: whatever value `outputLatency` carries gets
    /// subtracted from the interpolated time, never producing a
    /// negative result.
    func testDemoAudioClockSubtractsOutputLatency() {
        var clock = DemoAudioClock(outputLatency: 0.080)
        clock.ingest(playerTime: 5.0, isPlaying: true, hostTime: 100.0)
        // Drive forward 0.2 s on the host clock and assert the
        // returned time is (interpolated - 0.080).
        let returned = clock.currentTime(hostTime: 100.2)
        XCTAssertEqual(returned, 5.0 + 0.2 - 0.080, accuracy: 1e-9)
    }

    func testDemoAudioClockNeverReturnsNegativeAfterLatencySubtraction() {
        var clock = DemoAudioClock(outputLatency: 0.080)
        clock.ingest(playerTime: 0.0, isPlaying: true, hostTime: 100.0)
        // At hostTime == anchorHostTime the interpolated time is 0,
        // and 0 - 0.080 = -0.080 — clamped to 0.
        let returned = clock.currentTime(hostTime: 100.0)
        XCTAssertEqual(returned, 0)
    }
}
