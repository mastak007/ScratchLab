import XCTest
@testable import ScratchLab

/// Scratch Playback Lab — render-thread amplitude envelope.
///
/// `ScratchPlaybackLabRenderEnvelope` exists to stop the lab's `AVAudioSourceNode`
/// from snapping between silence (`0`) and an arbitrary `ahhh.wav` sample value
/// when the platter starts/stops or MIDI jitters around rest — that discontinuity
/// is the click/static the fix targets. These tests pin the pure DSP behaviour
/// (no AVFoundation, no MIDI, no UI). The macOS test target is the only place this
/// `#if os(macOS)` struct is reachable, so no platform guard is needed here.
///
/// Test geometry: `sampleRate = 1000`, `rampDuration = 0.004` → 4 ramp frames →
/// `rampStep = 0.25`, so gain moves in clean quarters (0.25, 0.5, 0.75, 1.0).
final class ScratchPlaybackLabRenderEnvelopeTests: XCTestCase {

    private let accuracy: Float = 1.0e-6

    private func makeEnvelope() -> ScratchPlaybackLabRenderEnvelope {
        ScratchPlaybackLabRenderEnvelope(sampleRate: 1000, rampDuration: 0.004)
    }

    // MARK: - Fade-in

    func testFadeInRampsGainInQuartersToFull() {
        var env = makeEnvelope()
        XCTAssertEqual(env.gain, 0, accuracy: accuracy)

        let outputs = (0..<4).map { _ in env.process(1.0, audible: true) }

        let expected: [Float] = [0.25, 0.5, 0.75, 1.0]
        XCTAssertEqual(outputs.count, expected.count)
        for (out, exp) in zip(outputs, expected) {
            XCTAssertEqual(out, exp, accuracy: accuracy)
        }
        XCTAssertEqual(env.gain, 1.0, accuracy: accuracy)
    }

    func testFadeInIsMonotonicNonDecreasing() {
        var env = makeEnvelope()
        var previous: Float = -1
        for _ in 0..<8 {
            let out = env.process(1.0, audible: true)
            XCTAssertGreaterThanOrEqual(out, previous)
            previous = out
        }
        XCTAssertEqual(env.gain, 1.0, accuracy: accuracy)
    }

    // MARK: - No full-amplitude jump on the first audible frame (click suppression)

    func testFirstAudibleFrameDoesNotJumpToFullAmplitude() {
        var env = makeEnvelope()
        let first = env.process(1.0, audible: true)
        // The whole point of the fix: the boundary frame is attenuated, not the
        // raw sample value, so there is no 0 -> 1.0 step discontinuity.
        XCTAssertLessThan(first, 1.0)
        XCTAssertEqual(first, 0.25, accuracy: accuracy)
    }

    // MARK: - No accidental mute before a valid signal

    func testAudibleNonZeroSampleIsNeverFullyMuted() {
        var env = makeEnvelope()
        // Every frame of a valid (non-zero) audible signal must carry some signal —
        // the envelope attenuates the leading edge but never zeroes a live sample.
        for _ in 0..<8 {
            let out = env.process(0.8, audible: true)
            XCTAssertGreaterThan(out, 0)
        }
    }

    // MARK: - Fade-out

    func testFadeOutRampsDownToSilenceHoldingLastSample() {
        var env = makeEnvelope()
        // Ramp fully up on a +1.0 sample first.
        for _ in 0..<4 { _ = env.process(1.0, audible: true) }
        XCTAssertEqual(env.gain, 1.0, accuracy: accuracy)
        XCTAssertEqual(env.lastAudibleSample, 1.0, accuracy: accuracy)

        // Now go silent. Source is the held last sample, so output decays smoothly
        // from 0.75 -> 0 rather than snapping straight to 0.
        let outputs = (0..<4).map { _ in env.process(0, audible: false) }
        let expected: [Float] = [0.75, 0.5, 0.25, 0.0]
        XCTAssertEqual(outputs.count, expected.count)
        for (out, exp) in zip(outputs, expected) {
            XCTAssertEqual(out, exp, accuracy: accuracy)
        }
        XCTAssertEqual(env.gain, 0, accuracy: accuracy)
    }

    func testFadeOutIsMonotonicNonIncreasing() {
        var env = makeEnvelope()
        for _ in 0..<4 { _ = env.process(1.0, audible: true) }

        var previous: Float = .greatestFiniteMagnitude
        for _ in 0..<6 {
            let out = env.process(0, audible: false)
            XCTAssertLessThanOrEqual(out, previous)
            previous = out
        }
        XCTAssertEqual(env.gain, 0, accuracy: accuracy)
    }

    func testGainSaturatesAtZeroAndStaysSilent() {
        var env = makeEnvelope()
        for _ in 0..<4 { _ = env.process(1.0, audible: true) }
        for _ in 0..<10 { _ = env.process(0, audible: false) }

        XCTAssertEqual(env.gain, 0, accuracy: accuracy)
        XCTAssertEqual(env.lastAudibleSample, 0, accuracy: accuracy)
        // Further silent frames stay exactly silent (no DC, no drift).
        XCTAssertEqual(env.process(0, audible: false), 0, accuracy: accuracy)
    }

    // MARK: - Gate-edge / chatter behaviour

    func testGateFlippingMidRampReversesTowardSilence() {
        var env = makeEnvelope()
        // Partial fade-in: two audible frames -> gain 0.5.
        _ = env.process(1.0, audible: true)
        _ = env.process(1.0, audible: true)
        XCTAssertEqual(env.gain, 0.5, accuracy: accuracy)

        // Gate closes before full gain — should ramp back down, never jump.
        let out = env.process(0, audible: false)
        XCTAssertEqual(env.gain, 0.25, accuracy: accuracy)
        XCTAssertEqual(out, 0.25, accuracy: accuracy) // held sample (1.0) * gain 0.25
    }

    func testGainStartsRisingImmediatelyWhenGateReopens() {
        var env = makeEnvelope()
        // Briefly audible then silent, then audible again — gain resumes from where
        // it is rather than resetting, so reopening does not re-introduce a click.
        _ = env.process(1.0, audible: true)        // gain 0.25
        _ = env.process(0, audible: false)         // gain 0.0
        let resumed = env.process(0.6, audible: true)
        XCTAssertEqual(env.gain, 0.25, accuracy: accuracy)
        XCTAssertEqual(resumed, 0.6 * 0.25, accuracy: accuracy)
    }

    // MARK: - Boundary: reset

    func testResetClearsGainAndHeldSample() {
        var env = makeEnvelope()
        for _ in 0..<4 { _ = env.process(1.0, audible: true) }
        XCTAssertEqual(env.gain, 1.0, accuracy: accuracy)

        env.reset()
        XCTAssertEqual(env.gain, 0, accuracy: accuracy)
        XCTAssertEqual(env.lastAudibleSample, 0, accuracy: accuracy)

        // After reset the next audible frame ramps from zero again.
        XCTAssertEqual(env.process(1.0, audible: true), 0.25, accuracy: accuracy)
    }

    // MARK: - Boundary: degenerate ramp length

    func testSubFrameRampDurationStillReachesFullGainInOneFrame() {
        // sampleRate * rampDuration < 1 → frames clamps to 1 → step 1.0 (no crash,
        // no divide-by-zero, instant gain).
        var env = ScratchPlaybackLabRenderEnvelope(sampleRate: 1, rampDuration: 0.004)
        let out = env.process(0.5, audible: true)
        XCTAssertEqual(env.gain, 1.0, accuracy: accuracy)
        XCTAssertEqual(out, 0.5, accuracy: accuracy)
    }

    func testZeroSampleRateDoesNotCrashAndRampsInOneFrame() {
        var env = ScratchPlaybackLabRenderEnvelope(sampleRate: 0, rampDuration: 0.004)
        let out = env.process(1.0, audible: true)
        XCTAssertEqual(env.gain, 1.0, accuracy: accuracy)
        XCTAssertEqual(out, 1.0, accuracy: accuracy)
    }
}
