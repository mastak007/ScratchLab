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

    // MARK: - Slice B: engine read-head diagnostic accessor (no DSP, engine not started)

    /// The drift-diagnostic accessor is readable on a freshly constructed engine without
    /// starting AVAudioEngine, and reads 0 before any rendering. A pure observation seam —
    /// confirms the accessor exists and is safe to read off the audio thread.
    func testDiagnosticRenderHeadIsZeroOnFreshEngine() {
        let engine = ScratchPlaybackLabEngine()
        XCTAssertEqual(engine.diagnosticRenderFrame, 0)
        XCTAssertEqual(engine.diagnosticRenderSeconds, 0)
    }

    // MARK: - Slice C: platter position correction controller (pure math, no hardware)

    private func makeCorrection(gain: Double = 6.0, maxRate: Double = 0.5) -> ScratchPositionCorrectionController {
        ScratchPositionCorrectionController(gainPerSecond: gain, maxCorrectionRate: maxRate)
    }

    func testCorrectionZeroErrorReturnsBaseRate() {
        let c = makeCorrection()
        let r = c.correctedRate(baseRate: 0.3, targetSeconds: 0.5, audioSeconds: 0.5, sampleDuration: 1.0)
        XCTAssertEqual(r, 0.3, accuracy: 1e-12)
    }

    func testCorrectionPositiveErrorAddsCorrection() {
        let c = makeCorrection()           // error = +0.01 s → +0.06 within ±0.5 clamp
        let r = c.correctedRate(baseRate: 0.2, targetSeconds: 0.51, audioSeconds: 0.50, sampleDuration: 1.0)
        XCTAssertEqual(r, 0.2 + 0.01 * 6.0, accuracy: 1e-12)
        XCTAssertGreaterThan(r, 0.2)
    }

    func testCorrectionNegativeErrorSubtractsCorrection() {
        let c = makeCorrection()           // error = -0.02 s → -0.12 within clamp
        let r = c.correctedRate(baseRate: 0.2, targetSeconds: 0.48, audioSeconds: 0.50, sampleDuration: 1.0)
        XCTAssertEqual(r, 0.2 + (-0.02) * 6.0, accuracy: 1e-12)
        XCTAssertLessThan(r, 0.2)
    }

    func testCorrectionClampsAtMaxRate() {
        let c = makeCorrection()           // huge error (0.4 s × 6 = 2.4) clamps to +0.5
        let r = c.correctedRate(baseRate: 0.1, targetSeconds: 0.9, audioSeconds: 0.5, sampleDuration: 10.0)
        XCTAssertEqual(r, 0.1 + 0.5, accuracy: 1e-12)
    }

    func testCorrectionNeverExceedsClampOverSweptErrors() {
        let c = makeCorrection()
        for i in -200...200 {
            let target = Double(i) * 0.01     // -2.0 ... 2.0 s
            let r = c.correctedRate(baseRate: 0.25, targetSeconds: target, audioSeconds: 0, sampleDuration: 1000)
            XCTAssertLessThanOrEqual(abs(r - 0.25), 0.5 + 1e-12)
        }
    }

    func testCorrectionWrapFoldsToShortestPath() {
        let c = makeCorrection()
        // target near 0, audio near end of a 1 s sample → shortest path is a small +error,
        // NOT a large negative one. With audio=0.98, target=0.02, raw diff = -0.96 but the
        // folded error is +0.04 → a small POSITIVE correction.
        let r = c.correctedRate(baseRate: 0.0, targetSeconds: 0.02, audioSeconds: 0.98, sampleDuration: 1.0)
        XCTAssertEqual(r, 0.04 * 6.0, accuracy: 1e-9)
        XCTAssertGreaterThan(r, 0)
    }

    func testCorrectionConvergesTowardTarget() {
        let c = makeCorrection()
        let target = 0.5, dt = 0.001, D = 1.0
        var audio = 0.20
        var lastError = abs(target - audio)
        for _ in 0..<2000 {
            let rate = c.correctedRate(baseRate: 0, targetSeconds: target, audioSeconds: audio, sampleDuration: D)
            audio += rate * dt
            let err = abs(target - audio)
            XCTAssertLessThanOrEqual(err, lastError + 1e-9, "error must not grow (no overshoot blow-up)")
            lastError = err
        }
        XCTAssertLessThan(lastError, 1e-3, "should settle very close to the target")
    }

    func testPlatterPositionCorrectionFlagDefaultsOff() {
        // Default (no env override) must be OFF in both release and debug so the default
        // playback path is unchanged until the experiment is explicitly enabled.
        XCTAssertFalse(FeatureFlags.isOn("PLATTER_POSITION_CORRECTION",
                                         releaseDefault: false, debugDefault: false,
                                         environment: [:]))
    }

    // MARK: - Calibration: one physical revolution plays the sample once (not 2×)

    /// The default sensitivity must map one platter revolution (~3,932 CC6 steps) onto
    /// roughly ONE sample pass (~1 s), not two. With the old literal 0.5 this product was
    /// ≈1.97 (≈2× → the "ahhh plays twice per rotation" bug); the calibrated 0.266 gives ≈1.05.
    @MainActor
    func testDefaultSensitivityMapsOneRevolutionToOneSamplePass() {
        let perStep = ScratchPlaybackLabModel.defaultSampleSecondsPer1000Ticks / 1000.0
        let secondsPerRevolution = perStep * Double(ScratchPlatterPlayheadMapper.defaultStepsPerRevolution)
        XCTAssertEqual(secondsPerRevolution, 1.0, accuracy: 0.1,
                       "one revolution should advance ~one ~1 s sample pass")
        XCTAssertLessThan(secondsPerRevolution, 1.5,
                          "regression guard: must NOT be ~2× (the old 0.5 default)")
    }

    /// The calibrated default is the documented ~0.266 (single source of truth), so the
    /// comment and value can't drift apart again.
    @MainActor
    func testDefaultSensitivityConstantIsCalibratedValue() {
        XCTAssertEqual(ScratchPlaybackLabModel.defaultSampleSecondsPer1000Ticks, 0.266, accuracy: 1e-9)
    }

    /// A freshly constructed model starts at the calibrated default (not the old 0.5).
    @MainActor
    func testFreshModelUsesCalibratedDefaultSensitivity() {
        let model = ScratchPlaybackLabModel()
        XCTAssertEqual(model.sampleSecondsPer1000Ticks,
                       ScratchPlaybackLabModel.defaultSampleSecondsPer1000Ticks, accuracy: 1e-9)
    }

    // MARK: - Scratch-zone phase mapper (12→4 o'clock plays once, 4→12 silent)

    private func makeZone(arcDegrees: Double = 120) -> ScratchZonePhaseMapper {
        ScratchZonePhaseMapper(activeFraction: arcDegrees / 360.0)
    }

    func testZonePhaseZeroMapsToSampleStartAudible() {
        let z = makeZone().map(phase: 0.0, sampleDuration: 1.0)
        XCTAssertEqual(z.samplePositionSeconds, 0.0, accuracy: 1e-12)
        XCTAssertTrue(z.audible)
    }

    func testZoneInsideArcMapsLinearly() {
        let active = 120.0 / 360.0
        let z = makeZone().map(phase: active / 2, sampleDuration: 1.0)   // halfway through the arc
        XCTAssertEqual(z.samplePositionSeconds, 0.5, accuracy: 1e-9)
        XCTAssertTrue(z.audible)
    }

    func testZoneNearArcEndMapsToSampleEndAudible() {
        let active = 120.0 / 360.0
        let z = makeZone().map(phase: active - 1e-4, sampleDuration: 1.0)
        XCTAssertEqual(z.samplePositionSeconds, 1.0, accuracy: 2e-3)
        XCTAssertTrue(z.audible)
    }

    func testZoneOutsideArcIsSilent() {
        let z = makeZone().map(phase: 0.5, sampleDuration: 1.0)   // 180° — past 4 o'clock
        XCTAssertFalse(z.audible)
        let z2 = makeZone().map(phase: 0.95, sampleDuration: 1.0) // ~342° — still silent
        XCTAssertFalse(z2.audible)
    }

    func testZoneReverseInsideArcDecreasesPosition() {
        let zm = makeZone()
        let forward = zm.map(phase: 0.20, sampleDuration: 1.0)
        let backToward = zm.map(phase: 0.10, sampleDuration: 1.0)
        XCTAssertLessThan(backToward.samplePositionSeconds, forward.samplePositionSeconds)
        XCTAssertTrue(forward.audible)
        XCTAssertTrue(backToward.audible)
    }

    func testFullRevolutionIsOneAudiblePassThenSilence_NotThreeRepeats() {
        let zm = makeZone()
        var audibleSteps = 0, transitions = 0, prevAudible = false
        var lastPos = -1.0, monotonicInZone = true
        for deg in 0..<360 {
            let z = zm.map(phase: Double(deg) / 360.0, sampleDuration: 1.0)
            if z.audible {
                audibleSteps += 1
                if z.samplePositionSeconds < lastPos - 1e-9 { monotonicInZone = false }
                lastPos = z.samplePositionSeconds
            }
            if z.audible != prevAudible { transitions += 1; prevAudible = z.audible }
        }
        XCTAssertEqual(audibleSteps, 120, "≈120° of the revolution should be audible")
        // Exactly one contiguous audible block (0→1 transition then 1→0) — NOT three repeats.
        XCTAssertEqual(transitions, 2, "one audible region per revolution, not multiple")
        XCTAssertTrue(monotonicInZone, "the single pass advances forward through the sample")
    }

    func testZoneReentryThroughPhaseWrapResetsToStart() {
        let zm = makeZone()
        XCTAssertFalse(zm.map(phase: 0.99, sampleDuration: 1.0).audible)       // before 12
        let reentry = zm.map(phase: 1.0, sampleDuration: 1.0)                  // wraps to 0
        XCTAssertEqual(reentry.samplePositionSeconds, 0.0, accuracy: 1e-12)
        XCTAssertTrue(reentry.audible)
    }

    // MARK: - Scratch-zone smoothing (in-zone audio routed through cc6AudioDrive)

    /// Constant hand speed delivered with bursty CoreMIDI timing (dt alternating ~1 ms/12 ms)
    /// would swing a raw per-event moved/dt rate ~12×. Routed through the windowed drive the
    /// in-zone rate must stay tightly bounded (the pitch-instability fix).
    func testZoneSmoothingStabilizesRateUnderBurstyTiming() {
        let zm = makeZone()
        var drive = ScratchPlatterAudioDrive()
        var phase = 0.0, t = 0.0, lastPos = 0.0, seeded = false
        var rates: [Double] = []
        for i in 0..<400 {
            phase += 0.0005                                   // stays within the 1/3 zone
            let pos = zm.map(phase: phase, sampleDuration: 1.0).samplePositionSeconds
            let moved = pos - lastPos; lastPos = pos
            t += (i % 2 == 0) ? 0.001 : 0.012                 // bursty delivery
            if case .glide(let r) = drive.ingest(moved: moved, at: t), seeded { rates.append(r) }
            seeded = true
        }
        let warm = Array(rates.suffix(150))
        let lo = try! XCTUnwrap(warm.min()), hi = try! XCTUnwrap(warm.max())
        XCTAssertGreaterThan(lo, 0, "steady forward → positive rate")
        XCTAssertLessThan(hi / lo, 4.0, "windowed rate must not swing ~12× like raw per-event moved/dt")
    }

    /// Zone entry anchors (no boundary spike), then glides on subsequent steady events.
    func testZoneEntryDriveAnchorsThenGlides() {
        var drive = ScratchPlatterAudioDrive()
        XCTAssertEqual(drive.ingest(moved: 0.002, at: 0.0), .anchor)   // first event after reset
        var sawGlide = false, t = 0.0
        for _ in 0..<20 {
            t += 0.005
            if case .glide = drive.ingest(moved: 0.002, at: t) { sawGlide = true }
        }
        XCTAssertTrue(sawGlide, "steady in-zone motion should produce a glide rate after entry")
    }

    /// Zone exit resets the drive so the next entry re-anchors rather than inheriting a stale
    /// cross-boundary rate (prevents a spike/click crossing 12 o'clock).
    func testZoneExitResetReanchorsNextEntry() {
        var drive = ScratchPlatterAudioDrive()
        var t = 0.0
        _ = drive.ingest(moved: 0.002, at: t)
        for _ in 0..<10 { t += 0.005; _ = drive.ingest(moved: 0.002, at: t) }  // gliding
        drive.reset()                                                          // zone exit
        XCTAssertEqual(drive.ingest(moved: 0.002, at: t + 0.005), .anchor)
    }

    /// Reverse motion inside the zone yields a negative smoothed rate.
    func testZoneReverseProducesNegativeSmoothedRate() {
        let zm = makeZone()
        var drive = ScratchPlatterAudioDrive()
        var phase = 0.30, t = 0.0
        var lastPos = zm.map(phase: phase, sampleDuration: 1.0).samplePositionSeconds
        _ = drive.ingest(moved: 0, at: t)                  // seed/anchor
        var lastRate = 0.0
        for _ in 0..<60 {
            phase -= 0.001                                 // reverse, staying inside the zone
            let pos = zm.map(phase: phase, sampleDuration: 1.0).samplePositionSeconds
            let moved = pos - lastPos; lastPos = pos
            t += 0.005
            if case .glide(let r) = drive.ingest(moved: moved, at: t) { lastRate = r }
        }
        XCTAssertLessThan(lastRate, 0, "reverse inside zone → negative smoothed rate")
    }

    // MARK: - Engine zone-audible gate (minimal hook)

    func testZoneGatedAudibleRequiresBothGates() {
        XCTAssertTrue(ScratchPlaybackLabEngine.zoneGatedAudible(zoneAudible: true, movementAudible: true))
        XCTAssertFalse(ScratchPlaybackLabEngine.zoneGatedAudible(zoneAudible: false, movementAudible: true))
        XCTAssertFalse(ScratchPlaybackLabEngine.zoneGatedAudible(zoneAudible: true, movementAudible: false))
        XCTAssertFalse(ScratchPlaybackLabEngine.zoneGatedAudible(zoneAudible: false, movementAudible: false))
    }

    func testSetZoneAudibleTogglesGateAndDefaultsOpen() {
        let engine = ScratchPlaybackLabEngine()
        XCTAssertTrue(engine.diagnosticZoneAudible, "default open → no effect unless driven")
        engine.setZoneAudible(false)
        XCTAssertFalse(engine.diagnosticZoneAudible)
        engine.setZoneAudible(true)
        XCTAssertTrue(engine.diagnosticZoneAudible)
    }

    func testRaneScratchZoneFlagDefaultsOff() {
        XCTAssertFalse(FeatureFlags.isOn("RANE_SCRATCH_ZONE",
                                         releaseDefault: false, debugDefault: false,
                                         environment: [:]))
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

    // MARK: - Velocity estimator (smooth scrub velocity across bursty MIDI)

    func testConstantForwardStepRateProducesStablePositiveVelocity() {
        var est = ScratchScrubVelocityEstimator(smoothing: 0.04, idleTimeout: 0.18)
        // +0.001 s of sample movement every 0.001 s of real time ⇒ velocity → 1.0.
        var t = 0.0
        est.ingest(sampleSeconds: 0.001, at: t)       // seed
        for _ in 0..<400 { t += 0.001; est.ingest(sampleSeconds: 0.001, at: t) }
        XCTAssertEqual(est.velocity, 1.0, accuracy: 0.02)
    }

    func testConstantReverseStepRateProducesStableNegativeVelocity() {
        var est = ScratchScrubVelocityEstimator(smoothing: 0.04, idleTimeout: 0.18)
        var t = 0.0
        est.ingest(sampleSeconds: -0.001, at: t)
        for _ in 0..<400 { t += 0.001; est.ingest(sampleSeconds: -0.001, at: t) }
        XCTAssertEqual(est.velocity, -1.0, accuracy: 0.02)
    }

    func testVelocityZeroesAfterIdleGapBetweenEvents() {
        var est = ScratchScrubVelocityEstimator(smoothing: 0.04, idleTimeout: 0.18)
        var t = 0.0
        est.ingest(sampleSeconds: 0.001, at: t)
        for _ in 0..<100 { t += 0.001; est.ingest(sampleSeconds: 0.001, at: t) }
        XCTAssertGreaterThan(est.velocity, 0)
        est.ingest(sampleSeconds: 0.001, at: t + 0.5)  // 0.5 s gap > idleTimeout
        XCTAssertEqual(est.velocity, 0, accuracy: 1e-12)
    }

    func testEstimatorResetClearsVelocityAndClock() {
        var est = ScratchScrubVelocityEstimator()
        est.ingest(sampleSeconds: 0.001, at: 0)
        est.ingest(sampleSeconds: 0.001, at: 0.001)
        est.reset()
        XCTAssertEqual(est.velocity, 0, accuracy: 1e-12)
        // After reset the next event re-seeds (no velocity from a single event).
        XCTAssertEqual(est.ingest(sampleSeconds: 0.001, at: 5.0), 0, accuracy: 1e-12)
    }

    // MARK: - Velocity integration in the render head

    func testVelocityAdvancesHeadForward() {
        // rate 1.0 (sampleRate == outputSampleRate) → +1 frame per output frame.
        let end = ScratchPlaybackLabEngine.advancedFrame(from: 0, velocity: 1.0, sampleRate: 1000,
                                                         outputSampleRate: 1000, frames: 100, total: 10000, loops: false)
        XCTAssertEqual(end, 100, accuracy: 1e-9)
    }

    func testVelocityContinuesAcrossNoEventGap() {
        // The head keeps advancing on successive quanta WITHOUT any new velocity update —
        // this is the anti-chop behaviour (smooth glide between MIDI bursts).
        var head = 0.0
        for _ in 0..<3 {
            head = ScratchPlaybackLabEngine.advancedFrame(from: head, velocity: 1.0, sampleRate: 1000,
                                                          outputSampleRate: 1000, frames: 100, total: 10000, loops: false)
        }
        XCTAssertEqual(head, 300, accuracy: 1e-9)
    }

    func testZeroVelocityHoldsHead() {
        let end = ScratchPlaybackLabEngine.advancedFrame(from: 250, velocity: 0, sampleRate: 1000,
                                                        outputSampleRate: 1000, frames: 100, total: 10000, loops: false)
        XCTAssertEqual(end, 250, accuracy: 1e-12)
    }

    func testLoopModeWrapsHeadContinuously() {
        let end = ScratchPlaybackLabEngine.advancedFrame(from: 9950, velocity: 1.0, sampleRate: 1000,
                                                        outputSampleRate: 1000, frames: 100, total: 10000, loops: true)
        XCTAssertEqual(end, 50, accuracy: 1e-9)   // 10050 wraps to 50
    }

    func testClampModeClampsHeadAtEnd() {
        let end = ScratchPlaybackLabEngine.advancedFrame(from: 9950, velocity: 1.0, sampleRate: 1000,
                                                        outputSampleRate: 1000, frames: 100, total: 10000, loops: false)
        XCTAssertEqual(end, 9999, accuracy: 1e-9) // clamps to total-1
    }

    func testAudibleTracksVelocityNotTarget() {
        let moving = ScratchPlaybackLabEngine.framesPerOutputFrame(velocity: 1.0, sampleRate: 1000, outputSampleRate: 1000)
        XCTAssertTrue(ScratchPlaybackLabEngine.isAudible(perFrame: moving, frames: 100, minDeltaFrames: 8))
        let stopped = ScratchPlaybackLabEngine.framesPerOutputFrame(velocity: 0, sampleRate: 1000, outputSampleRate: 1000)
        XCTAssertFalse(ScratchPlaybackLabEngine.isAudible(perFrame: stopped, frames: 100, minDeltaFrames: 8))
    }

    // MARK: - Audibility gate (hysteresis + hold)

    private static let bufferSeconds = 512.0 / 44_100.0   // ~11.6 ms render buffer

    func testGateOpensImmediatelyOnClearMovement() {
        var gate = ScratchPlaybackLabAudibilityGate()
        XCTAssertFalse(gate.isOpen)
        XCTAssertTrue(gate.update(movementFrames: 20, bufferSeconds: Self.bufferSeconds))
        XCTAssertTrue(gate.isOpen)
    }

    func testGateStaysClosedForBandMovementFromRest() {
        // Movement in the hysteresis band (between close and open) must not start audio.
        var gate = ScratchPlaybackLabAudibilityGate()  // open 8, close 2
        for _ in 0..<20 {
            XCTAssertFalse(gate.update(movementFrames: 5, bufferSeconds: Self.bufferSeconds))
        }
    }

    func testGateGlidesThroughBriefReversalDip() {
        // Open, then a short sub-close dip (a direction reversal) shorter than the hold
        // must NOT mute — this is the stutter the gate exists to prevent.
        var gate = ScratchPlaybackLabAudibilityGate(openDeltaFrames: 8, closeDeltaFrames: 2, holdSeconds: 0.08)
        XCTAssertTrue(gate.update(movementFrames: 40, bufferSeconds: Self.bufferSeconds))
        for _ in 0..<3 {   // ~35 ms below close, under the 80 ms hold
            XCTAssertTrue(gate.update(movementFrames: 0, bufferSeconds: Self.bufferSeconds))
        }
        XCTAssertTrue(gate.update(movementFrames: 40, bufferSeconds: Self.bufferSeconds))
    }

    func testGateMutesAfterSustainedStop() {
        var gate = ScratchPlaybackLabAudibilityGate(openDeltaFrames: 8, closeDeltaFrames: 2, holdSeconds: 0.08)
        XCTAssertTrue(gate.update(movementFrames: 40, bufferSeconds: Self.bufferSeconds))
        var open = true
        for _ in 0..<16 {   // well past 80 ms of stillness
            open = gate.update(movementFrames: 0, bufferSeconds: Self.bufferSeconds)
        }
        XCTAssertFalse(open)
        XCTAssertFalse(gate.isOpen)
    }

    func testGateHoldResetsWhenMovementRecoversBeforeMuting() {
        // A sub-close dip that recovers (even into the band) must clear the accumulated
        // quiet time, so a later short dip doesn't prematurely mute.
        var gate = ScratchPlaybackLabAudibilityGate(openDeltaFrames: 8, closeDeltaFrames: 2, holdSeconds: 0.08)
        XCTAssertTrue(gate.update(movementFrames: 40, bufferSeconds: Self.bufferSeconds))
        for _ in 0..<5 {
            XCTAssertTrue(gate.update(movementFrames: 0, bufferSeconds: Self.bufferSeconds))   // accumulate ~58 ms
            XCTAssertTrue(gate.update(movementFrames: 5, bufferSeconds: Self.bufferSeconds))   // band → reset hold
        }
        XCTAssertTrue(gate.isOpen)
    }

    func testGateResetClosesAndClearsHold() {
        var gate = ScratchPlaybackLabAudibilityGate()
        _ = gate.update(movementFrames: 40, bufferSeconds: Self.bufferSeconds)
        XCTAssertTrue(gate.isOpen)
        gate.reset()
        XCTAssertFalse(gate.isOpen)
    }

    func testFramesPerOutputFrameConvertsSampleRates() {
        // 1.0 sample-sec/sec at a 48k sample on a 44.1k output ⇒ >1 file frame/out frame.
        XCTAssertEqual(ScratchPlaybackLabEngine.framesPerOutputFrame(velocity: 1.0, sampleRate: 48000, outputSampleRate: 44100),
                       48000.0 / 44100.0, accuracy: 1e-9)
    }

    func testWrapAndClampFrameHelpers() {
        XCTAssertEqual(ScratchPlaybackLabEngine.wrapFrame(105, total: 100), 5, accuracy: 1e-9)
        XCTAssertEqual(ScratchPlaybackLabEngine.wrapFrame(-2, total: 100), 98, accuracy: 1e-9)
        XCTAssertEqual(ScratchPlaybackLabEngine.clampFrame(150, total: 100), 99, accuracy: 1e-9)
        XCTAssertEqual(ScratchPlaybackLabEngine.clampFrame(-5, total: 100), 0, accuracy: 1e-9)
        XCTAssertEqual(ScratchPlaybackLabEngine.clampFrame(50, total: 0), 0, accuracy: 1e-9)
    }

    // MARK: - Anti-aliased resampling (sampleSpan)

    /// Ramp buffer where sample[i] == i, so a point read at x returns x and a box-average
    /// over [a, b] returns the midpoint (a + b) / 2 — easy ground truth.
    private func withRamp(_ count: Int, _ body: (UnsafeBufferPointer<Float>) -> Void) {
        let ramp = (0..<count).map { Float($0) }
        ramp.withUnsafeBufferPointer(body)
    }

    func testSampleSpanAtOrBelowUnitRatePointSamplesAtHead() {
        withRamp(100) { buf in
            // width 0.5 (<1×) and exactly 1.0 (1×) both stay a point read at `from`.
            XCTAssertEqual(ScratchPlaybackLabEngine.sampleSpan(buf, from: 10, to: 10.5, total: 100, loops: true),
                           10.0, accuracy: 1e-5)
            XCTAssertEqual(ScratchPlaybackLabEngine.sampleSpan(buf, from: 10, to: 11, total: 100, loops: true),
                           10.0, accuracy: 1e-5)
        }
    }

    func testSampleSpanAboveUnitRateAveragesSpan() {
        withRamp(100) { buf in
            // width 10 (10×) → box-average of the ramp over [10,20] ≈ 15, NOT the point 10.
            let v = ScratchPlaybackLabEngine.sampleSpan(buf, from: 10, to: 20, total: 100, loops: true)
            XCTAssertEqual(v, 15.0, accuracy: 0.01)
            XCTAssertNotEqual(v, 10.0, accuracy: 1.0)   // proves it is not point-sampling at the head
        }
    }

    func testSampleSpanReverseAveragesSameSpanSymmetrically() {
        withRamp(100) { buf in
            let forward = ScratchPlaybackLabEngine.sampleSpan(buf, from: 10, to: 20, total: 100, loops: true)
            let reverse = ScratchPlaybackLabEngine.sampleSpan(buf, from: 20, to: 10, total: 100, loops: true)
            XCTAssertEqual(forward, reverse, accuracy: 1e-6)   // direction-symmetric
        }
    }

    func testSampleSpanAcrossLoopSeamIsFiniteAndInBounds() {
        withRamp(100) { buf in
            // span 98 → 104 crosses the wrap; must not read out of bounds or NaN.
            let v = ScratchPlaybackLabEngine.sampleSpan(buf, from: 98, to: 104, total: 100, loops: true)
            XCTAssertTrue(v.isFinite)
            XCTAssertGreaterThanOrEqual(v, 0)
            XCTAssertLessThanOrEqual(v, 99)
        }
    }

    func testSampleSpanFastClampModeStaysInBounds() {
        withRamp(100) { buf in
            // clamp mode, fast read past the end: clamps, stays finite/in-bounds.
            let v = ScratchPlaybackLabEngine.sampleSpan(buf, from: 95, to: 130, total: 100, loops: false)
            XCTAssertTrue(v.isFinite)
            XCTAssertLessThanOrEqual(v, 99)
        }
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
