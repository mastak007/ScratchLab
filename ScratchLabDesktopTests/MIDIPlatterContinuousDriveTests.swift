// MIDIPlatterContinuousDriveTests.swift
// Fixture-free, deterministic coverage of the pure MIDI continuous-drive
// velocity estimator: real-elapsed-time velocity, sanitization, long-stall
// catch-up prevention, high-rate coalescing, reversals, and CC6 wrap safety
// (combined with the real `ScratchPlatterTracker` unwrap logic).

import XCTest
@testable import ScratchLab

final class MIDIPlatterContinuousDriveTests: XCTestCase {

    // MARK: - Priming

    func testFirstTickPrimesWithoutAResult() {
        var drive = MIDIPlatterContinuousDrive()
        let result = drive.tick(accumulatedSteps: 100, now: 1.0)
        XCTAssertNil(result, "The first tick has no previous sample to diff against")
    }

    // MARK: - Forward / backward phase advancement (velocity sign)

    func testForwardMotionProducesPositiveVelocity() throws {
        var drive = MIDIPlatterContinuousDrive()
        _ = drive.tick(accumulatedSteps: 0, now: 0.0)
        let result = drive.tick(accumulatedSteps: 10, now: 0.1)
        XCTAssertEqual(result?.deltaSteps, 10)
        XCTAssertEqual(try XCTUnwrap(result?.velocity), 100, accuracy: 0.001, "10 steps / 0.1s = 100 steps/s")
        XCTAssertGreaterThan(result?.velocity ?? 0, 0)
    }

    func testBackwardMotionProducesNegativeVelocity() throws {
        var drive = MIDIPlatterContinuousDrive()
        _ = drive.tick(accumulatedSteps: 0, now: 0.0)
        let result = drive.tick(accumulatedSteps: -8, now: 0.1)
        XCTAssertEqual(result?.deltaSteps, -8)
        XCTAssertEqual(try XCTUnwrap(result?.velocity), -80, accuracy: 0.001)
        XCTAssertLessThan(result?.velocity ?? 0, 0)
    }

    // MARK: - Velocity from real elapsed time (not event count, not a fixed interval)

    func testVelocityUsesRealElapsedTimeNotAFixedInterval() throws {
        var drive = MIDIPlatterContinuousDrive()
        _ = drive.tick(accumulatedSteps: 0, now: 0.0)
        // Same step delta, two very different real elapsed windows — the
        // velocity must scale inversely with elapsed time, proving it is
        // not derived from a fixed guessed interval.
        let fast = drive.tick(accumulatedSteps: 20, now: 0.01)
        drive.reset()
        _ = drive.tick(accumulatedSteps: 0, now: 0.0)
        let slow = drive.tick(accumulatedSteps: 20, now: 0.2)
        XCTAssertEqual(try XCTUnwrap(fast?.velocity), 2000, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(slow?.velocity), 100, accuracy: 0.001)
        XCTAssertNotEqual(fast?.velocity, slow?.velocity)
    }

    func testVelocityIgnoresEventCountUsingOnlyStepDeltaAndTime() throws {
        // Whether 1 coalesced sample represents one raw CC6 event or five
        // hundred, only the net signed step delta and elapsed time matter
        // (elapsed kept within `maximumControlWindow` so this is a normal
        // tick, not the long-stall sanitization case covered separately).
        var drive = MIDIPlatterContinuousDrive()
        _ = drive.tick(accumulatedSteps: 0, now: 0.0)
        let manyEventsCoalesced = drive.tick(accumulatedSteps: 500, now: 0.1)
        XCTAssertEqual(manyEventsCoalesced?.deltaSteps, 500)
        XCTAssertEqual(try XCTUnwrap(manyEventsCoalesced?.velocity), 5000, accuracy: 0.001)
    }

    // MARK: - Sanitization: zero / negative / non-finite elapsed

    func testZeroElapsedSanitizesVelocityToZeroButKeepsDelta() {
        var drive = MIDIPlatterContinuousDrive()
        _ = drive.tick(accumulatedSteps: 0, now: 5.0)
        let result = drive.tick(accumulatedSteps: 12, now: 5.0)
        XCTAssertEqual(result?.deltaSteps, 12, "Real motion must never be lost even when velocity is sanitized")
        XCTAssertEqual(result?.velocity, 0)
    }

    func testNegativeElapsedSanitizesVelocityToZero() {
        var drive = MIDIPlatterContinuousDrive()
        _ = drive.tick(accumulatedSteps: 0, now: 5.0)
        // A clock regression (should not happen with a monotonic clock, but
        // must not crash or produce a bogus/infinite velocity).
        let result = drive.tick(accumulatedSteps: 12, now: 4.5)
        XCTAssertEqual(result?.deltaSteps, 12)
        XCTAssertEqual(result?.velocity, 0)
    }

    func testNonFiniteNowSanitizesVelocityToZero() {
        var drive = MIDIPlatterContinuousDrive()
        _ = drive.tick(accumulatedSteps: 0, now: 0.0)
        let result = drive.tick(accumulatedSteps: 7, now: .nan)
        XCTAssertEqual(result?.deltaSteps, 7)
        XCTAssertEqual(result?.velocity, 0)
        XCTAssertFalse(result?.velocity.isNaN ?? true, "A non-finite `now` must never propagate into a NaN velocity")
    }

    func testNoMotionTickReturnsZeroVelocityAndZeroDelta() {
        var drive = MIDIPlatterContinuousDrive()
        _ = drive.tick(accumulatedSteps: 42, now: 0.0)
        let result = drive.tick(accumulatedSteps: 42, now: 0.1)
        XCTAssertEqual(result?.deltaSteps, 0)
        XCTAssertEqual(result?.velocity, 0)
    }

    // MARK: - Long-stall / catch-up prevention

    func testAbnormallyLongElapsedPreventsCatchUpVelocityButKeepsDelta() {
        var drive = MIDIPlatterContinuousDrive()
        _ = drive.tick(accumulatedSteps: 0, now: 0.0)
        // A large real gap (well past `maximumControlWindow`) with a large
        // accumulated step delta — naively dividing would either produce an
        // enormous velocity (if elapsed were clamped short) or a very high
        // one anyway; the estimator must instead treat this as a stall and
        // publish no velocity for this tick, while never discarding the
        // real physical step delta.
        let result = drive.tick(accumulatedSteps: 4000, now: 3.0)
        XCTAssertEqual(result?.deltaSteps, 4000, "Phase-anchor-relevant motion must never be dropped")
        XCTAssertEqual(result?.velocity, 0, "A stale window must never be converted into a catch-up velocity")
    }

    func testElapsedExactlyAtMaximumControlWindowStillProducesVelocity() throws {
        var drive = MIDIPlatterContinuousDrive()
        _ = drive.tick(accumulatedSteps: 0, now: 0.0)
        let result = drive.tick(
            accumulatedSteps: 100,
            now: MIDIPlatterContinuousDrive.maximumControlWindow
        )
        XCTAssertEqual(
            try XCTUnwrap(result?.velocity),
            100 / MIDIPlatterContinuousDrive.maximumControlWindow,
            accuracy: 0.01
        )
    }

    // MARK: - Reversals

    func testRapidForwardThenBackwardReversal() {
        var drive = MIDIPlatterContinuousDrive()
        _ = drive.tick(accumulatedSteps: 0, now: 0.0)
        let forward = drive.tick(accumulatedSteps: 15, now: 0.05)
        let backward = drive.tick(accumulatedSteps: 5, now: 0.1)
        XCTAssertEqual(forward?.deltaSteps, 15)
        XCTAssertGreaterThan(forward?.velocity ?? 0, 0)
        XCTAssertEqual(backward?.deltaSteps, -10)
        XCTAssertLessThan(backward?.velocity ?? 0, 0)
    }

    func testRapidBackwardThenForwardReversal() {
        var drive = MIDIPlatterContinuousDrive()
        _ = drive.tick(accumulatedSteps: 0, now: 0.0)
        let backward = drive.tick(accumulatedSteps: -20, now: 0.05)
        let forward = drive.tick(accumulatedSteps: -5, now: 0.1)
        XCTAssertEqual(backward?.deltaSteps, -20)
        XCTAssertLessThan(backward?.velocity ?? 0, 0)
        XCTAssertEqual(forward?.deltaSteps, 15)
        XCTAssertGreaterThan(forward?.velocity ?? 0, 0)
    }

    // MARK: - reset() — no stale resume

    func testResetDiscardsHistorySoNextTickIsTreatedAsPriming() throws {
        var drive = MIDIPlatterContinuousDrive()
        _ = drive.tick(accumulatedSteps: 0, now: 0.0)
        _ = drive.tick(accumulatedSteps: 1000, now: 10.0)
        drive.reset()
        // Even though the underlying "position" jumped far away while this
        // estimator was tracking it, after reset the very next tick must
        // behave exactly like a fresh estimator's first call: no delta, no
        // velocity, no catch-up burst — just a new baseline capture.
        let result = drive.tick(accumulatedSteps: 5000, now: 100.0)
        XCTAssertNil(result, "Post-reset tick is priming, exactly like a brand-new estimator")
        let next = drive.tick(accumulatedSteps: 5010, now: 100.1)
        XCTAssertEqual(next?.deltaSteps, 10, "Only motion since the post-reset baseline counts")
        XCTAssertEqual(try XCTUnwrap(next?.velocity), 100, accuracy: 0.001)
    }

    // MARK: - CC6 wrap safety (combined with the real tracker's unwrap logic)

    func testForwardCC6WrapDoesNotCorruptDriveVelocity() {
        let tracker = ScratchPlatterTracker()
        var drive = MIDIPlatterContinuousDrive()
        // Prime the tracker and drive near the top of the CC6 ring.
        tracker.ingest(channel: ScratchPlatterTracker.rightChannel, value: 125)
        _ = drive.tick(accumulatedSteps: tracker.accumulatedSteps(for: ScratchPlatterTracker.rightChannel), now: 0.0)

        // Walk forward across the 127 -> 0 wrap boundary: 125, 126, 127, 0, 1.
        for raw in [126, 127, 0, 1] {
            tracker.ingest(channel: ScratchPlatterTracker.rightChannel, value: raw)
        }
        let steps = tracker.accumulatedSteps(for: ScratchPlatterTracker.rightChannel)
        let result = drive.tick(accumulatedSteps: steps, now: 0.1)

        XCTAssertEqual(steps, 4, "Tracker must have unwrapped the ring, not jumped by -123")
        XCTAssertEqual(result?.deltaSteps, 4)
        XCTAssertGreaterThan(result?.velocity ?? 0, 0, "A forward wrap must still read as forward motion")
    }

    func testBackwardCC6WrapDoesNotCorruptDriveVelocity() {
        let tracker = ScratchPlatterTracker()
        var drive = MIDIPlatterContinuousDrive()
        tracker.ingest(channel: ScratchPlatterTracker.rightChannel, value: 2)
        _ = drive.tick(accumulatedSteps: tracker.accumulatedSteps(for: ScratchPlatterTracker.rightChannel), now: 0.0)

        // Walk backward across the 0 -> 127 wrap boundary: 2, 1, 0, 127, 126.
        for raw in [1, 0, 127, 126] {
            tracker.ingest(channel: ScratchPlatterTracker.rightChannel, value: raw)
        }
        let steps = tracker.accumulatedSteps(for: ScratchPlatterTracker.rightChannel)
        let result = drive.tick(accumulatedSteps: steps, now: 0.1)

        XCTAssertEqual(steps, -4, "Tracker must have unwrapped the ring backward, not jumped by +123")
        XCTAssertEqual(result?.deltaSteps, -4)
        XCTAssertLessThan(result?.velocity ?? 0, 0, "A backward wrap must still read as backward motion")
    }

    // MARK: - High-rate coalescing without losing accumulated phase

    func testHighRateCC6BurstCoalescedIntoOneTickLosesNoSteps() {
        let tracker = ScratchPlatterTracker()
        var drive = MIDIPlatterContinuousDrive()
        tracker.ingest(channel: ScratchPlatterTracker.rightChannel, value: 0)
        _ = drive.tick(accumulatedSteps: tracker.accumulatedSteps(for: ScratchPlatterTracker.rightChannel), now: 0.0)

        // Simulate ~800 Hz raw CC6 events all coalesced into a single
        // ~16.7 ms (60 Hz) control tick: 13 raw +1 events land between two
        // reads of the tracker.
        for _ in 0..<13 {
            let current = tracker.accumulatedSteps(for: ScratchPlatterTracker.rightChannel)
            tracker.ingest(channel: ScratchPlatterTracker.rightChannel, value: (current + 1) % 128)
        }
        let steps = tracker.accumulatedSteps(for: ScratchPlatterTracker.rightChannel)
        let result = drive.tick(accumulatedSteps: steps, now: 1.0 / 60.0)

        XCTAssertEqual(steps, 13)
        XCTAssertEqual(result?.deltaSteps, 13, "None of the 13 coalesced raw events may be lost")
    }
}
