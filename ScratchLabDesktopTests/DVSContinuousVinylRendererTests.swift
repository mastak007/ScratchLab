// DVSContinuousVinylRendererTests.swift
// Deterministic, fixture-free coverage of the continuous DVS renderer:
// pure phase/sample-generation math on `DVSContinuousVinylRenderCore`,
// publication/sanitization on the `DVSContinuousVinylRenderer` wrapper,
// and controller-level path routing via the synthetic-sample seam (no
// bundled WAVs, so every test here also runs under the command-line
// harness that cannot resolve app-bundle fixtures).

import XCTest
import AVFoundation
@testable import ScratchLab

final class DVSContinuousVinylRendererTests: XCTestCase {

    private static let rate: Double = 44_100
    /// One nominal revolution at 33⅓ RPM (1.8 s) at 44.1 kHz.
    private static let revolutionFrames: Double = 79_380

    // MARK: - Core harness

    /// Owns the synthetic PCM allocations a core under test points into,
    /// simulates the control side (epoch counter), and renders into plain
    /// arrays. Everything is synchronous and deterministic.
    private final class CoreHarness {
        var core: DVSContinuousVinylRenderCore
        private var epoch: UInt64 = 0
        private var allocations: [UnsafeMutablePointer<Float>] = []
        private var sampleIdentity: UInt64 = 0

        init() {
            core = DVSContinuousVinylRenderCore(outputSampleRate: DVSContinuousVinylRendererTests.rate)
        }

        deinit {
            for allocation in allocations { allocation.deallocate() }
        }

        func install(
            content: [Float],
            loopFrames: Double,
            fadeFrames: Int = 64,
            sourceRate: Double = DVSContinuousVinylRendererTests.rate
        ) {
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
                sourceSampleRate: sourceRate
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

        func publishSnapping(velocity: Double, authoritativePhase: Double) {
            epoch += 1
            core.ingest(snapshot: DVSVinylControlSnapshot(
                epoch: epoch,
                velocity: velocity,
                authoritativePhase: authoritativePhase,
                active: true,
                snapPhase: true
            ))
        }

        func publishIdle() {
            epoch += 1
            core.ingest(snapshot: DVSVinylControlSnapshot(
                epoch: epoch,
                velocity: 0,
                authoritativePhase: core.controlAuthoritativePhase,
                active: false
            ))
        }

        @discardableResult
        func render(_ frames: Int) -> [Float] {
            var output = [Float](repeating: 0, count: frames)
            output.withUnsafeMutableBufferPointer { buffer in
                core.render(left: buffer.baseAddress!, right: nil, frameCount: frames)
            }
            return output
        }

        /// Publishes at the simulated 60 Hz cadence while rendering, so
        /// long renders never trip the staleness watchdog (matching the
        /// real control loop). Authoritative phase advances by the exact
        /// velocity integral — the same "anchor integrates real deltas"
        /// contract the controller provides.
        @discardableResult
        func renderWithSteadyControl(
            velocity: Double,
            startAuthoritativePhase: Double,
            loopFrames: Double,
            frames: Int,
            framesPerTick: Int = 735
        ) -> [Float] {
            var output: [Float] = []
            output.reserveCapacity(frames)
            var rendered = 0
            var authoritative = startAuthoritativePhase
            while rendered < frames {
                let chunk = min(framesPerTick, frames - rendered)
                publish(velocity: velocity, authoritativePhase: authoritative, active: true)
                output.append(contentsOf: render(chunk))
                authoritative += velocity * Double(chunk) / DVSContinuousVinylRendererTests.rate
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

    /// Adjacent-step bound for the standard sine content: the sine's own
    /// per-sample step at 1.0x, with headroom for Catmull-Rom curvature
    /// and the smoothed gain/velocity transients.
    private var sineStepBound: Float {
        0.8 * Float(2 * Double.pi / 100) * 1.8
    }

    // MARK: - 1 & 2: signed phase advancement

    func testForwardPhaseAdvancesAtPublishedVelocity() {
        let harness = CoreHarness()
        harness.install(content: sineContent(frames: 46_000), loopFrames: Self.revolutionFrames)
        harness.publish(velocity: Self.rate, authoritativePhase: 0)

        harness.render(2_000) // velocity/gain warm-up
        let phase0 = harness.core.phase
        harness.render(1_000)
        let advanced = harness.core.phase - phase0

        XCTAssertEqual(advanced, 1_000, accuracy: 0.5,
            "At 1.0x (source-rate velocity) phase must advance one source frame per output frame")
    }

    func testBackwardPhaseAdvancesAndWrapsIntoValidRange() {
        let harness = CoreHarness()
        let loop = Self.revolutionFrames
        harness.install(content: sineContent(frames: 46_000), loopFrames: loop)
        harness.publish(velocity: -Self.rate, authoritativePhase: 0)

        harness.render(2_000)
        let phase0 = harness.core.phase
        XCTAssertGreaterThanOrEqual(phase0, 0)
        XCTAssertLessThan(phase0, loop, "Backward motion from phase 0 must wrap into [0, loop)")
        XCTAssertGreaterThan(phase0, loop - 3_000, "Backward motion must land near the top of the loop")

        harness.render(1_000)
        let delta = DVSContinuousVinylRenderCore.wrappedSignedDelta(harness.core.phase - phase0, loop: loop)
        XCTAssertEqual(delta, -1_000, accuracy: 0.5,
            "At -1.0x phase must retreat one source frame per output frame")
    }

    // MARK: - 3 & 4: reversal continuity (generation-level)

    func testForwardToBackwardReversalIsContinuous() {
        let harness = CoreHarness()
        harness.install(content: sineContent(frames: 3_000), loopFrames: 4_000)
        harness.publish(velocity: Self.rate, authoritativePhase: 0)
        harness.render(1_200) // settle inside content at full gain

        var stream = harness.render(300)
        harness.publish(velocity: -Self.rate, authoritativePhase: harness.core.phase, active: true)
        stream.append(contentsOf: harness.render(1_200))

        XCTAssertLessThan(harness.core.velocity, 0, "Velocity must have crossed to backward")
        XCTAssertLessThanOrEqual(maxAdjacentDelta(stream), sineStepBound,
            "A forward→backward reversal must be sample-continuous (no click/step beyond ordinary waveform motion)")
    }

    func testBackwardToForwardReversalIsContinuous() {
        let harness = CoreHarness()
        harness.install(content: sineContent(frames: 3_000), loopFrames: 4_000)
        harness.publish(velocity: Self.rate, authoritativePhase: 0)
        harness.render(1_200)
        harness.publish(velocity: -Self.rate, authoritativePhase: harness.core.phase)
        harness.render(600)

        var stream = harness.render(300)
        harness.publish(velocity: Self.rate, authoritativePhase: harness.core.phase, active: true)
        stream.append(contentsOf: harness.render(1_200))

        XCTAssertGreaterThan(harness.core.velocity, 0, "Velocity must have crossed to forward")
        XCTAssertLessThanOrEqual(maxAdjacentDelta(stream), sineStepBound,
            "A backward→forward reversal must be sample-continuous")
    }

    // MARK: - 5: fractional-phase interpolation

    func testFractionalPhaseInterpolationReproducesLinearContentExactly() {
        let harness = CoreHarness()
        let slope: Float = 1e-4
        let content = (0..<3_000).map { Float($0) * slope }
        harness.install(content: content, loopFrames: 4_000)

        // 0.37x — every output frame lands on a fractional source phase.
        let velocity = Self.rate * 0.37
        harness.publish(velocity: velocity, authoritativePhase: 0)
        harness.render(2_000) // settle: gain ≈ 1, velocity ≈ target
        XCTAssertEqual(harness.core.gain, 1, accuracy: 1e-4)

        let phase0 = harness.core.phase
        XCTAssertGreaterThan(phase0, 200, "Test must sample away from the content-edge fade")
        let increment = velocity / Self.rate
        let output = harness.render(500)
        for i in 0..<500 {
            let expectedPhase = phase0 + Double(i + 1) * increment
            XCTAssertEqual(
                output[i],
                Float(expectedPhase) * slope,
                accuracy: 2e-4,
                "Catmull-Rom over linear content must reproduce the ramp exactly at fractional phases (frame \(i))"
            )
        }
    }

    // MARK: - 6: loop wrap in both directions

    func testLoopWrapForwardAndBackwardStaysInRangeAndContinuous() {
        let loop: Double = 600
        let harness = CoreHarness()
        harness.install(content: sineContent(frames: 400), loopFrames: loop, fadeFrames: 32)

        harness.publish(velocity: Self.rate, authoritativePhase: 0)
        harness.render(400) // warm-up
        var forward: [Float] = []
        for _ in 0..<6 { // several complete loops, phase checked per chunk
            forward.append(contentsOf: harness.render(300))
            XCTAssertGreaterThanOrEqual(harness.core.phase, 0)
            XCTAssertLessThan(harness.core.phase, loop, "Forward wrap must keep phase in [0, loop)")
        }
        XCTAssertLessThanOrEqual(maxAdjacentDelta(forward), sineStepBound,
            "Forward loop wraps must be continuous (content edges fade to silence)")

        harness.publish(velocity: -Self.rate, authoritativePhase: harness.core.phase)
        harness.render(400)
        var backward: [Float] = []
        for _ in 0..<6 {
            backward.append(contentsOf: harness.render(300))
            XCTAssertGreaterThanOrEqual(harness.core.phase, 0)
            XCTAssertLessThan(harness.core.phase, loop, "Backward wrap must keep phase in [0, loop)")
        }
        XCTAssertLessThanOrEqual(maxAdjacentDelta(backward), sineStepBound,
            "Backward loop wraps must be continuous")
    }

    // MARK: - 7: exactly one content play per physical revolution

    func testExactlyOneContentRegionPerRevolution() {
        let harness = CoreHarness()
        let contentFrames = 40_000
        let loop = Self.revolutionFrames
        // Constant-amplitude content: interior is never zero, so
        // silence↔content transitions are unambiguous.
        harness.install(content: [Float](repeating: 0.5, count: contentFrames), loopFrames: loop)

        let stream = harness.renderWithSteadyControl(
            velocity: Self.rate,
            startAuthoritativePhase: 0,
            loopFrames: loop,
            frames: Int(loop) * 2
        )

        // Count sustained silence→content transitions (runs ≥ 100 frames).
        var transitions = 0
        var inContent = false
        var runLength = 0
        for sample in stream {
            let loud = abs(sample) > 1e-4
            if loud == inContent {
                runLength += 1
                continue
            }
            runLength += 1
            if runLength >= 100 || transitions == 0 {
                if loud && !inContent { transitions += 1 }
                inContent = loud
                runLength = 0
            }
        }
        XCTAssertEqual(transitions, 2,
            "Two revolutions must contain exactly two content passes — one 'ahh' per physical revolution, got \(transitions)")

        // The tail of each revolution (past the content) must be true silence.
        let silenceStart = contentFrames + 800
        let silenceEnd = Int(loop) - 800
        for i in silenceStart..<silenceEnd where stream[i] != 0 {
            XCTFail("Silence region of the revolution contained audio at frame \(i): \(stream[i])")
            break
        }
    }

    // MARK: - 8: repeated equal baby scratches return to the same phase

    func testTenEqualBabyScratchesReturnToSamePhase() {
        let harness = CoreHarness()
        let loop = Self.revolutionFrames
        harness.install(content: sineContent(frames: 46_000), loopFrames: loop)

        let tickFrames = 735 // one 60 Hz control tick of output
        let velocity = Self.rate * 0.6
        var authoritative = 0.0
        func runTicks(_ count: Int, _ signedVelocity: Double) {
            for _ in 0..<count {
                harness.publish(velocity: signedVelocity, authoritativePhase: authoritative)
                harness.render(tickFrames)
                authoritative += signedVelocity * Double(tickFrames) / Self.rate
                authoritative = authoritative.truncatingRemainder(dividingBy: loop)
                if authoritative < 0 { authoritative += loop }
            }
        }

        for _ in 0..<10 { // ten equal forward/backward cycles
            runTicks(4, velocity)
            runTicks(4, -velocity)
        }
        XCTAssertEqual(authoritative, 0, accuracy: 1e-6,
            "Sanity: equal-and-opposite control motion must net the authoritative anchor back to the start")

        harness.publishIdle()
        harness.render(4_410) // settle

        let residual = DVSContinuousVinylRenderCore.wrappedSignedDelta(harness.core.phase - 0, loop: loop)
        XCTAssertLessThan(abs(residual), 200,
            "Ten equal baby scratches must return the render phase to the start (residual \(residual) frames ≈ \(residual / Self.rate * 1000) ms)")
    }

    // MARK: - 9 & 10: stop settles to silence without phase reset; restart is immediate

    func testIdleSettlesToSilenceWithoutResettingPhaseAndRestartsImmediately() {
        let harness = CoreHarness()
        harness.install(content: sineContent(frames: 46_000), loopFrames: Self.revolutionFrames)
        harness.publish(velocity: Self.rate * 0.8, authoritativePhase: 0)
        harness.render(3_000)
        let phaseAtStop = harness.core.phase
        XCTAssertGreaterThan(phaseAtStop, 1_000, "Sanity: motion must have advanced into content")

        // 9: explicit idle → click-free settle to true silence, phase retained.
        harness.publishIdle()
        let decay = harness.render(4_410) // 100 ms
        XCTAssertLessThanOrEqual(maxAdjacentDelta(decay), sineStepBound,
            "The settle to silence must itself be click-free")
        XCTAssertTrue(decay.suffix(500).allSatisfy { $0 == 0 },
            "Idle must reach exact silence")
        XCTAssertLessThan(harness.core.gain, 1e-4)
        let phaseAfterDecay = harness.core.phase
        XCTAssertEqual(phaseAfterDecay, phaseAtStop, accuracy: 300,
            "Stopping settles the velocity, never resets or relocates the phase")
        harness.render(4_410)
        XCTAssertEqual(harness.core.phase, phaseAfterDecay, accuracy: 1,
            "Once settled, an idle renderer's phase is frozen")

        // 10: restart resumes from the retained phase, promptly.
        harness.publish(velocity: Self.rate * 0.3, authoritativePhase: phaseAfterDecay, active: true)
        let resume = harness.render(1_323) // 30 ms
        let firstAudible = resume.firstIndex { abs($0) > 1e-3 }
        XCTAssertNotNil(firstAudible, "Restart must produce audio within 30 ms")
        if let firstAudible {
            XCTAssertLessThan(firstAudible, 882, "Restart must be prompt (< 20 ms), not delayed")
        }
        let expectedPhase = phaseAfterDecay + Self.rate * 0.3 * 1_323 / Self.rate
        XCTAssertEqual(harness.core.phase, expectedPhase, accuracy: 250,
            "Restart must continue from the retained phase, not a reset one")
    }

    // MARK: - 11: extreme/invalid inputs stay finite and in range

    func testExtremeAndInvalidInputsProduceFiniteBoundedOutput() {
        let harness = CoreHarness()
        let loop = Self.revolutionFrames
        harness.install(content: sineContent(frames: 46_000), loopFrames: loop)

        let cases: [(velocity: Double, phase: Double)] = [
            (Double.nan, 0),
            (Double.infinity, 100),
            (-Double.infinity, 100),
            (1e18, Double.nan),
            (-1e18, Double.infinity),
            (Self.rate * 8, 500),   // max supported forward rate
            (-Self.rate * 8, 500),  // max supported backward rate
        ]
        for testCase in cases {
            harness.publish(velocity: testCase.velocity, authoritativePhase: testCase.phase)
            let output = harness.render(2_048)
            XCTAssertTrue(output.allSatisfy { $0.isFinite }, "Output must stay finite for velocity \(testCase.velocity)")
            XCTAssertTrue(output.allSatisfy { abs($0) < 4 }, "Output must stay bounded for velocity \(testCase.velocity)")
            XCTAssertTrue(harness.core.phase.isFinite)
            XCTAssertGreaterThanOrEqual(harness.core.phase, 0)
            XCTAssertLessThan(harness.core.phase, loop, "Phase must remain in the loop domain")
            XCTAssertLessThanOrEqual(abs(harness.core.velocity), DVSContinuousVinylRenderCore.maxVelocityRatio * Self.rate)
        }
    }

    // MARK: - 12: authoritative-phase correction is bounded and convergent

    func testAuthoritativePhaseCorrectionIsBoundedSmoothAndConvergent() {
        let harness = CoreHarness()
        let loop = Self.revolutionFrames
        harness.install(content: sineContent(frames: 46_000), loopFrames: loop)

        // Establish steady 1.0x motion, then inject a 500-frame anchor
        // offset (far larger than any real tick jitter).
        harness.publish(velocity: Self.rate, authoritativePhase: 0)
        harness.render(2_000)
        var authoritative = harness.core.phase + 500

        // Per-frame boundedness: no single frame may advance more than the
        // velocity increment plus the 2% correction cap.
        harness.publish(velocity: Self.rate, authoritativePhase: authoritative)
        var previousPhase = harness.core.phase
        for _ in 0..<2_000 {
            harness.render(1)
            let delta = harness.core.phase - previousPhase
            XCTAssertLessThanOrEqual(delta, 1.0 * (1 + DVSContinuousVinylRenderCore.maxPhaseCorrectionRatio) + 1e-9,
                "Phase correction must never exceed \(DVSContinuousVinylRenderCore.maxPhaseCorrectionRatio * 100)% of the velocity advance")
            XCTAssertGreaterThanOrEqual(delta, -1e-9, "Correction must not run the phase backwards during forward motion")
            previousPhase = harness.core.phase
            authoritative += 1
        }

        // Convergence: with the anchor advancing at the same velocity, the
        // error must shrink to a few frames within ~1.5 s.
        var rendered = 2_000
        while rendered < 66_150 {
            authoritative = authoritative.truncatingRemainder(dividingBy: loop)
            harness.publish(velocity: Self.rate, authoritativePhase: authoritative)
            harness.render(735)
            authoritative += 735
            rendered += 735
        }
        let finalError = DVSContinuousVinylRenderCore.wrappedSignedDelta(
            authoritative.truncatingRemainder(dividingBy: loop) - harness.core.phase,
            loop: loop
        )
        XCTAssertLessThan(abs(finalError), 5,
            "Bounded correction must converge the render phase onto the authoritative anchor (residual \(finalError))")
    }

    func testIntentionalCueBoundarySnapsExactlyToAuthoritativePhase() {
        let harness = CoreHarness()
        let loop = Self.revolutionFrames
        harness.install(content: sineContent(frames: 46_000), loopFrames: loop)

        harness.publish(velocity: Self.rate, authoritativePhase: 0)
        harness.render(8_000)
        XCTAssertGreaterThan(harness.core.phase, 1_000)

        let cueOnset = 11_880.0
        harness.publishSnapping(velocity: Self.rate, authoritativePhase: cueOnset)

        XCTAssertEqual(
            harness.core.phase,
            cueOnset,
            accuracy: 1e-9,
            "A physical cue-loop boundary must put the render head exactly at the 12-o'clock cue onset"
        )
        XCTAssertEqual(harness.core.pendingPhaseCorrection, 0, accuracy: 1e-9)
    }

    // MARK: - Sample swap resets phase to the new sample's origin

    func testSampleSwapResetsRenderState() {
        let harness = CoreHarness()
        harness.install(content: sineContent(frames: 3_000), loopFrames: 4_000)
        harness.publish(velocity: Self.rate, authoritativePhase: 0)
        harness.render(1_500)
        XCTAssertGreaterThan(harness.core.phase, 0)

        harness.install(content: sineContent(frames: 2_000), loopFrames: 4_000)
        XCTAssertEqual(harness.core.phase, 0, "A sample swap (reload) resets the phase to the loop origin")
        XCTAssertEqual(harness.core.gain, 0)
        XCTAssertEqual(harness.core.velocity, 0)
        let output = harness.render(500)
        XCTAssertTrue(output.allSatisfy { $0 == 0 },
            "After a swap the renderer stays silent until the control side publishes again")
    }

    // MARK: - 14: generation-level discontinuity check across a scripted run

    func testNoLargeAdjacentSampleJumpsAcrossMotionReversalWrapAndStop() {
        let harness = CoreHarness()
        let loop: Double = 4_000
        harness.install(content: sineContent(frames: 3_000), loopFrames: loop)

        var stream: [Float] = []
        // Steady forward at 1.0x (several loop wraps included).
        stream.append(contentsOf: harness.renderWithSteadyControl(
            velocity: Self.rate, startAuthoritativePhase: 0, loopFrames: loop, frames: 9_000))
        // Reversal, backward through the wrap.
        harness.publish(velocity: -Self.rate, authoritativePhase: harness.core.phase)
        stream.append(contentsOf: harness.render(735))
        stream.append(contentsOf: harness.renderWithSteadyControl(
            velocity: -Self.rate, startAuthoritativePhase: harness.core.phase, loopFrames: loop, frames: 6_000))
        // Slow forward.
        stream.append(contentsOf: harness.renderWithSteadyControl(
            velocity: Self.rate * 0.15, startAuthoritativePhase: harness.core.phase, loopFrames: loop, frames: 3_000))
        // Final stop.
        harness.publishIdle()
        stream.append(contentsOf: harness.render(4_410))

        XCTAssertTrue(stream.suffix(500).allSatisfy { $0 == 0 }, "The scripted run must end in true silence")
        XCTAssertLessThanOrEqual(maxAdjacentDelta(stream), sineStepBound,
            "No stage of normal motion, reversal, loop wrap, or final stop may produce an adjacent-sample jump beyond ordinary waveform motion")
    }

    // MARK: - Publication sanitization (wrapper)

    func testWrapperPublicationSanitizesNonFiniteAndExtremeValues() throws {
        let renderer = DVSContinuousVinylRenderer()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_000))
        buffer.frameLength = 4_000
        for i in 0..<4_000 { buffer.floatChannelData![0][i] = 0.5 }
        XCTAssertTrue(renderer.installSample(from: buffer, loopFrames: Self.revolutionFrames, contentFadeFrames: 64))

        renderer.publish(velocity: .nan, authoritativePhase: 100, active: true)
        XCTAssertEqual(renderer.lastPublishedVelocity, 0, "NaN velocity must sanitize to 0")

        renderer.publish(velocity: .infinity, authoritativePhase: 100, active: true)
        XCTAssertEqual(renderer.lastPublishedVelocity, 0, "Infinite velocity must sanitize to 0")

        let limit = DVSContinuousVinylRenderCore.maxVelocityRatio * Self.rate
        renderer.publish(velocity: 1e18, authoritativePhase: 100, active: true)
        XCTAssertEqual(renderer.lastPublishedVelocity, limit, "Extreme velocity must clamp to +\(limit)")
        renderer.publish(velocity: -1e18, authoritativePhase: 100, active: true)
        XCTAssertEqual(renderer.lastPublishedVelocity, -limit, "Extreme velocity must clamp to -\(limit)")

        // A non-finite phase publish must not poison the mailbox.
        renderer.publish(velocity: Self.rate, authoritativePhase: .nan, active: true)
        var left = [Float](repeating: 0, count: 1_024)
        var right = [Float](repeating: 0, count: 1_024)
        left.withUnsafeMutableBufferPointer { leftBuffer in
            right.withUnsafeMutableBufferPointer { rightBuffer in
                renderer.testOnly_render(
                    left: leftBuffer.baseAddress!,
                    right: rightBuffer.baseAddress!,
                    frameCount: 1_024
                )
            }
        }
        XCTAssertTrue(left.allSatisfy { $0.isFinite } && right.allSatisfy { $0.isFinite })
        XCTAssertTrue(renderer.testOnly_corePhase.isFinite)
    }

    // MARK: - Bounded concurrent publish/render stress (wrapper)

    /// Publishes from a background thread while rendering through the
    /// exact production mailbox path on this thread. Bounded iterations;
    /// asserts no crash and no non-finite/unbounded output under real
    /// concurrency. This checks behavior — it is NOT claimed as a proof of
    /// real-time safety.
    func testBoundedConcurrentPublishAndRenderStaysFiniteAndCrashFree() throws {
        let renderer = DVSContinuousVinylRenderer()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
        buffer.frameLength = 8_000
        for i in 0..<8_000 { buffer.floatChannelData![0][i] = 0.8 * Float(sin(Double(i) * 2 * .pi / 100)) }
        XCTAssertTrue(renderer.installSample(from: buffer, loopFrames: Self.revolutionFrames, contentFadeFrames: 64))

        let publishIterations = 20_000
        let renderIterations = 2_000
        let publisherDone = expectation(description: "publisher finished")
        Thread.detachNewThread {
            var value = 0.0
            for i in 0..<publishIterations {
                value += 1
                if i % 97 == 0 {
                    renderer.publishIdle()
                } else {
                    renderer.publish(
                        velocity: (i % 2 == 0 ? 1 : -1) * value.truncatingRemainder(dividingBy: 2) * Self.rate,
                        authoritativePhase: value.truncatingRemainder(dividingBy: Self.revolutionFrames),
                        active: true
                    )
                }
            }
            publisherDone.fulfill()
        }

        var left = [Float](repeating: 0, count: 256)
        var right = [Float](repeating: 0, count: 256)
        var sawNonFinite = false
        var sawUnbounded = false
        for _ in 0..<renderIterations {
            left.withUnsafeMutableBufferPointer { leftBuffer in
                right.withUnsafeMutableBufferPointer { rightBuffer in
                    renderer.testOnly_render(
                        left: leftBuffer.baseAddress!,
                        right: rightBuffer.baseAddress!,
                        frameCount: 256
                    )
                }
            }
            for value in left where !value.isFinite { sawNonFinite = true }
            for value in right where !value.isFinite { sawNonFinite = true }
            for value in left where abs(value) > 8 { sawUnbounded = true }
            for value in right where abs(value) > 8 { sawUnbounded = true }
        }
        wait(for: [publisherDone], timeout: 30)
        XCTAssertFalse(sawNonFinite, "Concurrent publish/render must never yield non-finite output")
        XCTAssertFalse(sawUnbounded, "Concurrent publish/render must never yield unbounded output")
        XCTAssertTrue(renderer.testOnly_corePhase.isFinite)
        XCTAssertGreaterThanOrEqual(renderer.testOnly_corePhase, 0)
    }

    // MARK: - 13 & routing: controller integration via the synthetic seam

    private func makeSyntheticLoopBuffer(frames: Int = 8_000) throws -> AVAudioPCMBuffer {
        // Stereo, matching the player-node graph the legacy grain path
        // schedules onto (a mono buffer trips AVAudioPlayerNode's
        // channel-count precondition).
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            let value = 0.8 * Float(sin(Double(i) * 2 * .pi / 100))
            buffer.floatChannelData![0][i] = value
            buffer.floatChannelData![1][i] = value
        }
        return buffer
    }

    func testMIDIPathStillUsesGrainSchedulingAndNeverTouchesTheRenderer() throws {
        let controller = ScratchSamplePlaybackController()
        controller.testOnly_installSyntheticSample(try makeSyntheticLoopBuffer(), sampleID: "synthetic")

        // MIDI entry point: no segmentWindow.
        controller.positionDidChange(steps: 0, direction: .forward)
        controller.waitForAudioQueue()
        controller.positionDidChange(steps: 40, direction: .forward)
        controller.waitForAudioQueue()

        let diagnostics = controller.diagnosticsSnapshot()
        XCTAssertEqual(diagnostics.forwardScheduleCount, 1,
            "MIDI motion must still schedule through the legacy grain path")
        XCTAssertEqual(controller.dvsContinuousRenderer.publishCount, 0,
            "The MIDI path must never publish to the continuous renderer")
        XCTAssertNotNil(controller.lastScheduledSourceFrame)
    }

    func testDVSTickPublishesVelocityToRendererInsteadOfSchedulingGrains() throws {
        let controller = ScratchSamplePlaybackController()
        XCTAssertTrue(controller.dvsUsesContinuousRenderer, "Continuous renderer must be the production default")
        controller.testOnly_installSyntheticSample(try makeSyntheticLoopBuffer(), sampleID: "synthetic")

        var scheduledGrains = 0
        controller.scheduledGrainObserver = { _ in scheduledGrains += 1 }
        defer { controller.scheduledGrainObserver = nil }

        let window = 1.0 / 60.0
        controller.positionDidChangeContinuous(steps: 0, direction: .forward, segmentWindow: window)
        controller.waitForAudioQueue()
        controller.positionDidChangeContinuous(steps: 40, direction: .forward, segmentWindow: window)
        controller.waitForAudioQueue()

        XCTAssertEqual(scheduledGrains, 0, "DVS ticks must not schedule grain PCM anymore")
        XCTAssertEqual(controller.dvsContinuousRenderer.publishCount, 1,
            "Each DVS motion tick must publish exactly one velocity snapshot")
        XCTAssertEqual(controller.diagnosticsSnapshot().forwardScheduleCount, 1,
            "The scalar diagnostics keep counting DVS render updates")

        // Velocity value: deltaSteps × framesPerStep ÷ window, signed.
        let framesPerStep = controller.dvsLoopFrames / 3_932.0
        let expectedVelocity = 40 * framesPerStep / window
        XCTAssertEqual(try XCTUnwrap(controller.dvsContinuousRenderer.lastPublishedVelocity),
                       expectedVelocity, accuracy: expectedVelocity * 1e-9)
        XCTAssertEqual(controller.dvsContinuousRenderer.lastPublishedActive, true)

        // Backward tick: negative velocity, backward counter.
        controller.positionDidChangeContinuous(steps: 10, direction: .backward, segmentWindow: window)
        controller.waitForAudioQueue()
        let backwardVelocity = try XCTUnwrap(controller.dvsContinuousRenderer.lastPublishedVelocity)
        XCTAssertLessThan(backwardVelocity, 0, "Backward motion must publish a negative signed velocity")
        XCTAssertEqual(controller.diagnosticsSnapshot().backwardScheduleCount, 1)

        // Published anchor matches the controller's authoritative phase.
        XCTAssertEqual(
            try XCTUnwrap(controller.dvsContinuousRenderer.lastPublishedAuthoritativePhase),
            Double(controller.currentSampleFrame),
            accuracy: 1,
            "The published anchor must be the controller's own cue-defining loop phase"
        )
    }

    func testDVSNoDirectionAndUnloadPublishIdleWithoutDisturbingAnchor() throws {
        let controller = ScratchSamplePlaybackController()
        controller.testOnly_installSyntheticSample(try makeSyntheticLoopBuffer(), sampleID: "synthetic")

        let window = 1.0 / 60.0
        controller.positionDidChangeContinuous(steps: 0, direction: .forward, segmentWindow: window)
        controller.waitForAudioQueue()
        controller.positionDidChangeContinuous(steps: 120, direction: .forward, segmentWindow: window)
        controller.waitForAudioQueue()
        let anchorBefore = controller.currentSampleFrame
        let idleBefore = controller.dvsContinuousRenderer.idlePublishCount

        controller.positionDidChangeContinuous(steps: 120, direction: nil, segmentWindow: window)
        controller.waitForAudioQueue()
        XCTAssertEqual(controller.dvsContinuousRenderer.idlePublishCount, idleBefore + 1,
            "A genuine no-direction tick must publish idle to the renderer")
        XCTAssertEqual(controller.currentSampleFrame, anchorBefore,
            "Stopping must not move the authoritative anchor")

        // Legacy pin: flag off routes DVS ticks back through the grain path.
        controller.dvsUsesContinuousRenderer = false
        let publishesBefore = controller.dvsContinuousRenderer.publishCount
        var legacyGrains = 0
        controller.scheduledGrainObserver = { _ in legacyGrains += 1 }
        defer { controller.scheduledGrainObserver = nil }
        controller.positionDidChangeContinuous(steps: 200, direction: .forward, segmentWindow: window)
        controller.waitForAudioQueue()
        XCTAssertEqual(controller.dvsContinuousRenderer.publishCount, publishesBefore,
            "With the rollback flag off, DVS ticks must not publish to the renderer")
        XCTAssertEqual(legacyGrains, 1, "With the rollback flag off, the legacy grain path must operate")
    }

    func testDVSSettleHysteresisSuppressesWobblePublishesButKeepsAnchorAdvancing() throws {
        let controller = ScratchSamplePlaybackController()
        controller.testOnly_installSyntheticSample(try makeSyntheticLoopBuffer(), sampleID: "synthetic")
        let window = 1.0 / 60.0

        // Motion, then a genuine stop (engine not running in this harness,
        // so the stop marks `dvsDefinitivelyStopped` directly).
        controller.positionDidChangeContinuous(steps: 0, direction: .forward, segmentWindow: window)
        controller.waitForAudioQueue()
        controller.positionDidChangeContinuous(steps: 100, direction: .forward, segmentWindow: window)
        controller.waitForAudioQueue()
        controller.positionDidChangeContinuous(steps: 100, direction: nil, segmentWindow: window)
        controller.waitForAudioQueue()

        let publishesAfterStop = controller.dvsContinuousRenderer.publishCount
        var steps = 100.0

        // Isolated settling wobble (±1 step alternating with nil ticks)
        // must not publish audible motion — but the anchor keeps moving.
        for cycle in 0..<4 {
            steps += Double(cycle % 2 == 0 ? 1 : -1)
            controller.positionDidChangeContinuous(
                steps: steps,
                direction: cycle % 2 == 0 ? .forward : .backward,
                segmentWindow: window
            )
            controller.waitForAudioQueue()
            XCTAssertEqual(controller.diagnosticsSnapshot().lastScheduleSkippedReason, "settleSuppress")
            controller.positionDidChangeContinuous(steps: steps, direction: nil, segmentWindow: window)
            controller.waitForAudioQueue()
        }
        XCTAssertEqual(controller.dvsContinuousRenderer.publishCount, publishesAfterStop,
            "Settling wobble must not publish isolated motion snapshots (the burst source)")

        // Deliberate large motion resumes immediately.
        controller.positionDidChangeContinuous(steps: steps + 40, direction: .forward, segmentWindow: window)
        controller.waitForAudioQueue()
        XCTAssertEqual(controller.dvsContinuousRenderer.publishCount, publishesAfterStop + 1,
            "Deliberate motion at/above the audible threshold must resume publishing immediately")
    }
}
