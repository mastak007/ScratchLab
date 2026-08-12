// DVSContinuousVinylRendererUserMixerGainTests.swift
// Deterministic, fixture-free coverage of the render-core's learned-mixer
// user gain (crossfader × right upfader), added alongside — and kept
// strictly independent of — the existing active/idle `gain` field.
//
// Mirrors `DVSContinuousVinylRendererTests.swift`'s own `CoreHarness`
// pattern: drives `DVSContinuousVinylRenderCore` directly, synchronously,
// with no AVAudioEngine. Does not modify that file or any of its tests.

import XCTest
import AVFoundation
@testable import ScratchLab

final class DVSContinuousVinylRendererUserMixerGainTests: XCTestCase {

    private static let rate: Double = 44_100
    private static let revolutionFrames: Double = 79_380

    // MARK: - Core harness (same shape as DVSContinuousVinylRendererTests)

    private final class CoreHarness {
        var core: DVSContinuousVinylRenderCore
        private var epoch: UInt64 = 0
        private var allocations: [UnsafeMutablePointer<Float>] = []
        private var sampleIdentity: UInt64 = 0

        init() {
            core = DVSContinuousVinylRenderCore(outputSampleRate: DVSContinuousVinylRendererUserMixerGainTests.rate)
        }

        deinit {
            for allocation in allocations { allocation.deallocate() }
        }

        func install(content: [Float], loopFrames: Double, fadeFrames: Int = 64) {
            let storage = UnsafeMutablePointer<Float>.allocate(capacity: content.count)
            for (i, v) in content.enumerated() { storage[i] = v }
            allocations.append(storage)
            sampleIdentity += 1
            core.ingest(table: DVSVinylSampleTable(
                identity: sampleIdentity,
                channel0: UnsafePointer(storage),
                channel1: nil,
                contentFrames: content.count,
                loopFrames: loopFrames,
                contentFadeFrames: Double(fadeFrames),
                sourceSampleRate: DVSContinuousVinylRendererUserMixerGainTests.rate
            ))
        }

        func publish(velocity: Double, authoritativePhase: Double, active: Bool = true) {
            epoch += 1
            core.ingest(snapshot: DVSVinylControlSnapshot(
                epoch: epoch,
                velocity: velocity,
                authoritativePhase: authoritativePhase,
                active: active
            ))
        }

        func publishUserMixerGain(_ gain: Double) {
            core.ingestUserMixerGain(gain)
        }

        @discardableResult
        func render(_ frames: Int) -> [Float] {
            var output = [Float](repeating: 0, count: frames)
            output.withUnsafeMutableBufferPointer { buffer in
                core.render(left: buffer.baseAddress!, right: nil, frameCount: frames)
            }
            return output
        }

        /// Publishes steady motion at the simulated 60 Hz cadence while
        /// rendering, so long renders never trip the staleness watchdog.
        @discardableResult
        func renderWithSteadyControl(
            velocity: Double,
            startAuthoritativePhase: Double,
            loopFrames: Double,
            frames: Int,
            framesPerTick: Int = 735,
            userMixerGainSchedule: ((Int) -> Double)? = nil
        ) -> [Float] {
            var output: [Float] = []
            output.reserveCapacity(frames)
            var rendered = 0
            var authoritative = startAuthoritativePhase
            while rendered < frames {
                let chunk = min(framesPerTick, frames - rendered)
                if let userMixerGainSchedule {
                    publishUserMixerGain(userMixerGainSchedule(rendered))
                }
                publish(velocity: velocity, authoritativePhase: authoritative, active: true)
                output.append(contentsOf: render(chunk))
                authoritative += velocity * Double(chunk) / DVSContinuousVinylRendererUserMixerGainTests.rate
                authoritative = authoritative.truncatingRemainder(dividingBy: loopFrames)
                if authoritative < 0 { authoritative += loopFrames }
                rendered += chunk
            }
            return output
        }
    }

    private func sineContent(frames: Int, period: Double = 100, amplitude: Float = 0.8) -> [Float] {
        (0..<frames).map { amplitude * Float(sin(2 * Double.pi * Double($0) / period)) }
    }

    private func maxAdjacentDelta(_ samples: [Float]) -> Float {
        guard samples.count > 1 else { return 0 }
        var maxDelta: Float = 0
        for i in 1..<samples.count {
            maxDelta = max(maxDelta, abs(samples[i] - samples[i - 1]))
        }
        return maxDelta
    }

    /// Adjacent-step bound for the standard sine content, matching the
    /// existing test file's bound: the sine's own per-sample step at
    /// 1.0x, with headroom for Catmull-Rom curvature and smoothed
    /// gain/velocity/user-mixer-gain transients.
    private var sineStepBound: Float {
        0.8 * Float(2 * Double.pi / 100) * 1.8
    }

    // MARK: - Regression #1: unmapped defaults to unity

    func testDefaultUserMixerGainIsUnityBeforeAnyPublish() {
        let harness = CoreHarness()
        XCTAssertEqual(harness.core.userMixerGain, 1.0)
        XCTAssertEqual(harness.core.targetUserMixerGain, 1.0)
    }

    // MARK: - Regression #6: finite/clamped for malformed input

    func testMalformedUserMixerGainInputFailsToSilenceNotFullVolume() {
        let harness = CoreHarness()
        harness.publishUserMixerGain(.nan)
        XCTAssertEqual(harness.core.targetUserMixerGain, 0,
            "non-finite input must fail toward silence, not full volume")

        harness.publishUserMixerGain(.infinity)
        XCTAssertEqual(harness.core.targetUserMixerGain, 0)

        harness.publishUserMixerGain(5.0)
        XCTAssertEqual(harness.core.targetUserMixerGain, 1.0, "above-range input clamps to 1")

        harness.publishUserMixerGain(-3.0)
        XCTAssertEqual(harness.core.targetUserMixerGain, 0.0, "below-range input clamps to 0")
    }

    // MARK: - Ramp toward target

    func testPublishedUserMixerGainRampsTowardTarget() {
        let harness = CoreHarness()
        harness.install(content: sineContent(frames: 46_000), loopFrames: Self.revolutionFrames)
        harness.publish(velocity: Self.rate, authoritativePhase: 0)
        harness.render(100) // warm up at default unity

        harness.publishUserMixerGain(0)
        // userMixerGainSmoothingSeconds = 0.005s; ~10 time constants is
        // comfortably converged (>99.99%).
        harness.render(Int(0.05 * Self.rate))

        XCTAssertEqual(harness.core.userMixerGain, 0, accuracy: 0.001)
    }

    // MARK: - Regression #8 + #9: muting never resets phase/velocity;
    // reopening resumes from the retained position

    func testMutingUserMixerGainNeverResetsPhaseOrVelocity() {
        let harness = CoreHarness()
        harness.install(content: sineContent(frames: 46_000), loopFrames: Self.revolutionFrames)
        harness.publish(velocity: Self.rate, authoritativePhase: 0)
        harness.render(2_000) // warm up

        let phaseBeforeMute = harness.core.phase
        let velocityBeforeMute = harness.core.velocity

        harness.publishUserMixerGain(0)
        let muted = harness.renderWithSteadyControl(
            velocity: Self.rate,
            startAuthoritativePhase: phaseBeforeMute,
            loopFrames: Self.revolutionFrames,
            frames: 4_000
        )

        XCTAssertEqual(harness.core.userMixerGain, 0, accuracy: 0.001)
        // Skip the ramp-down transient at the start of `muted` — check
        // only the settled tail, once the click-free ramp has converged.
        XCTAssertTrue(muted.suffix(1_000).allSatisfy { abs($0) < 0.0005 },
            "output must be silent once muted")
        // Phase and velocity must have kept advancing throughout — muting
        // is an output-gain effect only, never a position/motion reset.
        XCTAssertGreaterThan(harness.core.phase, phaseBeforeMute)
        XCTAssertEqual(harness.core.velocity, velocityBeforeMute, accuracy: 1.0)

        let phaseWhileMuted = harness.core.phase

        // Reopening must immediately reveal audio at the position the
        // platter naturally reached while muted — not frame 0, not the
        // pre-mute position. Render enough frames for the ramp to settle
        // (userMixerGainSmoothingSeconds = 0.005s ≈ 220 frames; 3,000 is
        // ~13 time constants, fully converged) before checking.
        harness.publishUserMixerGain(1)
        harness.render(3_000)
        XCTAssertEqual(harness.core.userMixerGain, 1, accuracy: 0.01)
        XCTAssertGreaterThan(harness.core.phase, phaseWhileMuted,
            "phase must continue forward from where it was while muted, not reset")
    }

    // MARK: - Independence from the existing active/idle gain field

    func testUserMixerGainAndActiveIdleGainAreIndependentFields() {
        let harness = CoreHarness()
        harness.install(content: sineContent(frames: 46_000), loopFrames: Self.revolutionFrames)
        harness.publish(velocity: Self.rate, authoritativePhase: 0, active: true)
        harness.render(2_000) // let active/idle gain converge to ~1

        let activeIdleGainBefore = harness.core.gain
        harness.publishUserMixerGain(0)
        harness.render(2_000)

        // Closing the user mixer must not perturb the pipeline's own
        // active/idle gain state.
        XCTAssertEqual(harness.core.gain, activeIdleGainBefore, accuracy: 0.01)
        XCTAssertEqual(harness.core.userMixerGain, 0, accuracy: 0.001)
    }

    func testUserMixerGainCombinesMultiplicativelyWithActiveIdleGain() {
        let harness = CoreHarness()
        harness.install(content: sineContent(frames: 46_000, amplitude: 1.0), loopFrames: Self.revolutionFrames)
        harness.publishUserMixerGain(0.5)
        let output = harness.renderWithSteadyControl(
            velocity: Self.rate,
            startAuthoritativePhase: 10_000, // clear of the content edge fade
            loopFrames: Self.revolutionFrames,
            frames: 6_000
        )
        // After both gains converge (active/idle -> 1, user mixer -> 0.5),
        // peak output amplitude should be ~0.5x the 1.0-amplitude content.
        let tail = output.suffix(1_000)
        let peak = tail.map { abs($0) }.max() ?? 0
        XCTAssertEqual(Double(peak), 0.5, accuracy: 0.05)
    }

    // MARK: - Regression #10: rapid open/close cuts remain bounded and click-free

    func testRapidOpenCloseCutsRemainBoundedAndClickFree() {
        let harness = CoreHarness()
        harness.install(content: sineContent(frames: 46_000), loopFrames: Self.revolutionFrames)
        // Toggle the user mixer gain fully open/closed every 512 frames —
        // far faster than a human could move a fader — while rendering
        // continuously, and require every adjacent-sample step to stay
        // within the same bound the existing renderer tests already use
        // for click-freedom under gain/velocity transients.
        var toggled = false
        let output = harness.renderWithSteadyControl(
            velocity: Self.rate,
            startAuthoritativePhase: 10_000,
            loopFrames: Self.revolutionFrames,
            frames: 20_000,
            framesPerTick: 512,
            userMixerGainSchedule: { _ in
                toggled.toggle()
                return toggled ? 1.0 : 0.0
            }
        )
        let delta = maxAdjacentDelta(output)
        XCTAssertLessThanOrEqual(delta, sineStepBound,
            "rapid open/close cuts must never produce a hard step between adjacent samples")
    }
}
