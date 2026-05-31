import XCTest
@testable import ScratchLab

final class KidScrubSmoothingTests: XCTestCase {

    // MARK: - Ramp up / down

    func testRampsUpTowardOne() {
        var ramp = KidGainRamp(step: 0.1, initialGain: 0)
        for _ in 0..<5 { ramp.advance(toward: 1.0) }
        XCTAssertGreaterThan(ramp.gain, 0)
        XCTAssertLessThanOrEqual(ramp.gain, 1.0)
        XCTAssertEqual(ramp.gain, 0.5, accuracy: 1e-9)
    }

    func testRampsDownTowardZero() {
        var ramp = KidGainRamp(step: 0.1, initialGain: 1.0)
        for _ in 0..<5 { ramp.advance(toward: 0.0) }
        XCTAssertLessThan(ramp.gain, 1.0)
        XCTAssertGreaterThanOrEqual(ramp.gain, 0.0)
        XCTAssertEqual(ramp.gain, 0.5, accuracy: 1e-9)
    }

    // MARK: - No overshoot / monotonic

    func testNoOvershootGoingUp() {
        var ramp = KidGainRamp(step: 0.3, initialGain: 0)
        for _ in 0..<100 {
            ramp.advance(toward: 1.0)
            XCTAssertLessThanOrEqual(ramp.gain, 1.0)
            XCTAssertGreaterThanOrEqual(ramp.gain, 0.0)
        }
        XCTAssertEqual(ramp.gain, 1.0, accuracy: 1e-12)
    }

    func testNoOvershootGoingDown() {
        var ramp = KidGainRamp(step: 0.3, initialGain: 1.0)
        for _ in 0..<100 {
            ramp.advance(toward: 0.0)
            XCTAssertLessThanOrEqual(ramp.gain, 1.0)
            XCTAssertGreaterThanOrEqual(ramp.gain, 0.0)
        }
        XCTAssertEqual(ramp.gain, 0.0, accuracy: 1e-12)
    }

    func testMonotonicTowardTarget() {
        var ramp = KidGainRamp(step: 0.05, initialGain: 0)
        var previous = ramp.gain
        for _ in 0..<30 {
            let next = ramp.advance(toward: 1.0)
            XCTAssertGreaterThanOrEqual(next, previous)
            previous = next
        }
    }

    // MARK: - Snap-to-target (true silence)

    func testReachesExactTargetWithinOneStep() {
        var ramp = KidGainRamp(step: 0.1, initialGain: 0.05)
        ramp.advance(toward: 0.0)
        XCTAssertEqual(ramp.gain, 0.0)   // exact, not "near zero"
    }

    func testRepeatedIdleReachesExactlyZero() {
        var ramp = KidGainRamp(step: 0.02, initialGain: 1.0)
        for _ in 0..<200 { ramp.advance(toward: 0.0) }
        XCTAssertEqual(ramp.gain, 0.0)
    }

    // MARK: - Clamping / finite safety

    func testClampsTargetAboveOne() {
        var ramp = KidGainRamp(step: 1.0, initialGain: 0)
        ramp.advance(toward: 5.0)
        XCTAssertEqual(ramp.gain, 1.0)
    }

    func testClampsTargetBelowZero() {
        var ramp = KidGainRamp(step: 1.0, initialGain: 1.0)
        ramp.advance(toward: -5.0)
        XCTAssertEqual(ramp.gain, 0.0)
    }

    func testNaNTargetDoesNotCorruptGain() {
        var ramp = KidGainRamp(step: 0.1, initialGain: 0.5)
        ramp.advance(toward: .nan)
        XCTAssertTrue(ramp.gain.isFinite)
        XCTAssertGreaterThanOrEqual(ramp.gain, 0.0)
        XCTAssertLessThanOrEqual(ramp.gain, 1.0)
    }

    func testInfiniteTargetIsHandledSafely() {
        // Non-finite targets (NaN/±inf) are treated as the fail-safe silence
        // target (0.0), never leaving the valid range or producing NaN/inf.
        // The real caller only ever passes exactly 0.0 or 1.0, so this path is
        // purely defensive.
        var positive = KidGainRamp(step: 1.0, initialGain: 0.5)
        positive.advance(toward: .infinity)
        XCTAssertTrue(positive.gain.isFinite)
        XCTAssertGreaterThanOrEqual(positive.gain, 0.0)
        XCTAssertLessThanOrEqual(positive.gain, 1.0)
        XCTAssertEqual(positive.gain, 0.0)

        var negative = KidGainRamp(step: 1.0, initialGain: 0.5)
        negative.advance(toward: -.infinity)
        XCTAssertEqual(negative.gain, 0.0)
    }

    func testInvalidStepFallsBackToInstant() {
        let nan = KidGainRamp(step: .nan)
        XCTAssertEqual(nan.step, 1.0)
        let negative = KidGainRamp(step: -0.5)
        XCTAssertEqual(negative.step, 1.0)
        let zero = KidGainRamp(step: 0)
        XCTAssertEqual(zero.step, 1.0)
    }

    func testInitialGainIsClamped() {
        XCTAssertEqual(KidGainRamp(step: 0.1, initialGain: 9).gain, 1.0)
        XCTAssertEqual(KidGainRamp(step: 0.1, initialGain: -9).gain, 0.0)
        XCTAssertEqual(KidGainRamp(step: 0.1, initialGain: .nan).gain, 0.0)
    }

    // MARK: - Fade-length construction (5–8 ms at 44.1 kHz)

    func testFadeReachesFullWithinExpectedSamples() {
        let sampleRate = 44_100.0
        let fadeSeconds = 0.006
        var ramp = KidGainRamp(fadeSeconds: fadeSeconds, sampleRate: sampleRate, initialGain: 0)
        let expectedSamples = Int((fadeSeconds * sampleRate).rounded(.up)) // ~265
        for _ in 0..<expectedSamples { ramp.advance(toward: 1.0) }
        XCTAssertEqual(ramp.gain, 1.0, accuracy: 1e-9)
    }

    func testFadeIsNotInstantForRealisticLength() {
        // A 6 ms fade must take clearly more than one sample (otherwise it would
        // not de-click). After a single sample it should still be well below 1.
        var ramp = KidGainRamp(fadeSeconds: 0.006, sampleRate: 44_100, initialGain: 0)
        ramp.advance(toward: 1.0)
        XCTAssertLessThan(ramp.gain, 0.1)
        XCTAssertGreaterThan(ramp.gain, 0.0)
    }

    func testInvalidFadeArgsFallBackToInstant() {
        XCTAssertEqual(KidGainRamp(fadeSeconds: 0, sampleRate: 44_100).step, 1.0)
        XCTAssertEqual(KidGainRamp(fadeSeconds: -1, sampleRate: 44_100).step, 1.0)
        XCTAssertEqual(KidGainRamp(fadeSeconds: .nan, sampleRate: 44_100).step, 1.0)
        XCTAssertEqual(KidGainRamp(fadeSeconds: 0.006, sampleRate: 0).step, 1.0)
    }

    // MARK: - Determinism

    func testDeterministicForSameInputs() {
        var a = KidGainRamp(fadeSeconds: 0.006, sampleRate: 44_100)
        var b = KidGainRamp(fadeSeconds: 0.006, sampleRate: 44_100)
        for i in 0..<500 {
            let target: Double = (i / 50) % 2 == 0 ? 1.0 : 0.0
            a.advance(toward: target)
            b.advance(toward: target)
        }
        XCTAssertEqual(a, b)
    }
}
