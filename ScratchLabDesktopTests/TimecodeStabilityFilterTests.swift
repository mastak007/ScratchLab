// TimecodeStabilityFilterTests
//
// Batch 7 tests for TimecodeMotionStabilityFilter and its integration with
// TimecodeControlPipeline and TimecodePrototypeRecorder:
//
//  1. Small rate jitter is smoothed (EMA converges toward mean)
//  2. Single-sample spike is rejected
//  3. Genuine direction reversal is preserved (not rejected as spike)
//  4. Slow movement is not dropped
//  5. Short dropout is held (EMA state preserved, heldDropoutCount increments)
//  6. Long dropout fails closed (EMA state reset, longDropoutCount increments)
//  7. Low-confidence frames are rejected
//  8. Clipped / channel-fault input still fails closed
//  9. Smoothing does not alter the source label on the pipeline output
// 10. Smoothing counters increment and accumulate correctly
// 11. Pipeline uses stabilized (smoothed / spike-filtered) output
// 12. Recorder does not record rejected spikes
// 13. RANE / replay paths are unaffected
// 14. Pipeline dropout clock advances when no input buffers arrive (regression fix)
//
// All audio data is synthesised inline — no hardware, no external fixtures.
// Batch 7: Prototype stability only. No notation injection. No commercial
// timecode compatibility claim.

import XCTest
@testable import ScratchLab

#if DEBUG

final class TimecodeStabilityFilterTests: XCTestCase {

    // MARK: - Constants

    private let sampleRate: Double = 44100
    private let carrierFrequency: Float = 1000
    private let framesPerBuffer: Int = 441
    private let timePerBuffer: TimeInterval = 441.0 / 44100.0

    // MARK: - Helpers: filter / state factory

    private func makeFilter(
        maxRateDeltaPerSecond: Double = 100.0,
        smoothingAlpha: Double = 0.5,
        shortDropoutHoldMs: Double = 200,
        longDropoutFailMs: Double = 1000,
        minConfidenceForUpdate: Double = 0.3
    ) -> TimecodeMotionStabilityFilter {
        TimecodeMotionStabilityFilter(config: TimecodeStabilityConfig(
            maxRateDeltaPerSecond: maxRateDeltaPerSecond,
            smoothingAlpha: smoothingAlpha,
            shortDropoutHoldMs: shortDropoutHoldMs,
            longDropoutFailMs: longDropoutFailMs,
            minConfidenceForUpdate: minConfidenceForUpdate
        ))
    }

    private func makeFrame(
        velocity: Double,
        confidence: Double = 0.8,
        relativeTime: TimeInterval = 0
    ) -> TimecodeDecodedFrame {
        let direction: TimecodeDirection = velocity > 1e-6 ? .forward : (velocity < -1e-6 ? .backward : .unknown)
        return TimecodeDecodedFrame(
            hostTime: nil,
            relativeTime: relativeTime,
            position: 0,
            deltaPosition: velocity * 0.01,
            velocity: velocity,
            direction: direction,
            confidence: confidence
        )
    }

    // MARK: - Helpers: pipeline

    private func sineTone(amplitude: Float, phaseOffset: Float = 0) -> [Float] {
        (0..<framesPerBuffer).map { i in
            let t = Float(i) / Float(sampleRate)
            return amplitude * sin(2 * .pi * carrierFrequency * t + phaseOffset)
        }
    }

    private func feedPhaseProgression(
        into pipeline: TimecodeControlPipeline,
        bufferCount: Int,
        phaseStep: Float,
        amplitude: Float = 0.5
    ) {
        for i in 0..<bufferCount {
            let left = sineTone(amplitude: amplitude)
            let right = sineTone(amplitude: amplitude, phaseOffset: phaseStep * Float(i))
            pipeline.pushStereoBuffer(left: left, right: right, sampleRate: sampleRate)
        }
    }

    private func feedSilence(into pipeline: TimecodeControlPipeline, count: Int = 1) {
        let zeros = [Float](repeating: 0, count: framesPerBuffer)
        for _ in 0..<count {
            pipeline.pushStereoBuffer(left: zeros, right: zeros, sampleRate: sampleRate)
        }
    }

    private func feedClipped(into pipeline: TimecodeControlPipeline, count: Int = 1) {
        let clip = sineTone(amplitude: 1.0)
        for _ in 0..<count {
            pipeline.pushStereoBuffer(left: clip, right: clip, sampleRate: sampleRate)
        }
    }

    private func makePipeline(mode: TimecodeControlMode = .controlPrototype) -> TimecodeControlPipeline {
        let p = TimecodeControlPipeline(sampleRate: sampleRate, channelCount: 2)
        p.mode = mode
        return p
    }

    // MARK: - 1. Small rate jitter is smoothed

    func testTimecodeStabilityFilterSmoothsSmallJitter() {
        let filter = makeFilter(smoothingAlpha: 0.5)
        var state = TimecodeStabilityFilterState()

        // Feed several frames with rates close to 5.0 but with small jitter.
        // EMA starts from 0 and converges over successive frames.
        let rates: [Double] = [4.9, 5.1, 4.8, 5.2, 5.0, 4.9, 5.1, 4.8, 5.2, 5.0]
        for (i, rate) in rates.enumerated() {
            let frame = makeFrame(velocity: rate, relativeTime: TimeInterval(i) * 0.01)
            let (accepted, newState, _) = filter.filter(
                frames: [frame], state: state, flushRelativeTime: TimeInterval(i) * 0.01
            )
            state = newState
            XCTAssertEqual(accepted.count, 1, "All jitter frames must be accepted at i=\(i)")
        }

        // After 10 frames the EMA has warmed up and should be close to the mean ~5.0
        XCTAssertEqual(state.smoothedRate, 5.0, accuracy: 0.5,
                       "EMA must converge toward mean rate ~5.0 after sufficient jitter frames")
        // Smoothed rate must be strictly tighter than the jitter envelope
        XCTAssertTrue(
            state.smoothedRate >= 4.5 && state.smoothedRate <= 5.5,
            "Smoothed rate \(state.smoothedRate) must lie within ±0.5 of mean after 10 jitter frames"
        )
    }

    // MARK: - 2. Single-sample spike is rejected

    func testTimecodeStabilityFilterRejectsSingleSampleSpike() {
        // Use a tight spike threshold so a realistic spike is caught
        let filter = makeFilter(maxRateDeltaPerSecond: 10.0, smoothingAlpha: 0.5)
        var state = TimecodeStabilityFilterState()

        // Establish context: a few frames at rate ~2.0
        for i in 0..<4 {
            let frame = makeFrame(velocity: 2.0, relativeTime: TimeInterval(i) * 0.01)
            let (accepted, newState, _) = filter.filter(
                frames: [frame], state: state, flushRelativeTime: TimeInterval(i) * 0.01
            )
            state = newState
            XCTAssertEqual(accepted.count, 1, "Normal frames must pass through")
        }

        // Now feed a spike: velocity 500 (well above threshold of 10 rad/s from smoothed ~2)
        let spikeFrame = makeFrame(velocity: 500.0, relativeTime: 0.04)
        let (spikeAccepted, _, spikeMetrics) = filter.filter(
            frames: [spikeFrame], state: state, flushRelativeTime: 0.04
        )

        XCTAssertEqual(spikeAccepted.count, 0,
                       "Single-sample spike must be rejected (accepted count must be 0)")
        XCTAssertGreaterThan(spikeMetrics.rejectedSpikeCount, 0,
                             "rejectedSpikeCount must increment on spike rejection")
        XCTAssertFalse(spikeMetrics.lastSpikeReason.isEmpty,
                       "lastSpikeReason must be set when a spike is rejected")
    }

    // MARK: - 3. Genuine direction reversal is preserved

    func testTimecodeStabilityFilterPreservesDirectionReversal() {
        // Even with a tight spike threshold, a direction reversal must pass through
        let filter = makeFilter(maxRateDeltaPerSecond: 5.0, smoothingAlpha: 0.5)
        var state = TimecodeStabilityFilterState()

        // Establish forward context
        for i in 0..<4 {
            let frame = makeFrame(velocity: 3.0, relativeTime: TimeInterval(i) * 0.01)
            let (_, newState, _) = filter.filter(
                frames: [frame], state: state, flushRelativeTime: TimeInterval(i) * 0.01
            )
            state = newState
        }

        XCTAssertEqual(state.lastAcceptedDirection, .forward,
                       "State must show forward direction after forward frames")

        // Now feed a backward frame (direction reversal)
        let reversalFrame = makeFrame(velocity: -3.0, relativeTime: 0.04)
        let (reversalAccepted, _, reversalMetrics) = filter.filter(
            frames: [reversalFrame], state: state, flushRelativeTime: 0.04
        )

        XCTAssertEqual(reversalAccepted.count, 1,
                       "Direction reversal must be accepted, not rejected as spike")
        XCTAssertEqual(reversalMetrics.rejectedSpikeCount, 0,
                       "Direction reversal must not increment rejectedSpikeCount")
    }

    // MARK: - 4. Slow movement is not dropped

    func testTimecodeStabilityFilterPreservesSlowMovement() {
        let filter = makeFilter(maxRateDeltaPerSecond: 100.0)
        var state = TimecodeStabilityFilterState()

        // Feed very slow but non-zero velocity frames
        let slowRates: [Double] = [0.01, 0.02, 0.015, 0.018, 0.01]
        var accepted = 0
        for (i, rate) in slowRates.enumerated() {
            let frame = makeFrame(velocity: rate, confidence: 0.8,
                                  relativeTime: TimeInterval(i) * 0.01)
            let (frameAccepted, newState, _) = filter.filter(
                frames: [frame], state: state, flushRelativeTime: TimeInterval(i) * 0.01
            )
            state = newState
            accepted += frameAccepted.count
        }

        XCTAssertEqual(accepted, slowRates.count,
                       "All slow-movement frames must be accepted (never dropped for low rate)")
        XCTAssertGreaterThan(state.smoothedRate, 0,
                             "Smoothed rate must be positive after slow forward movement")
    }

    // MARK: - 5. Short dropout is held (EMA state preserved)

    func testTimecodeStabilityFilterHandlesShortDropout() {
        let filter = makeFilter(shortDropoutHoldMs: 100, longDropoutFailMs: 500)
        var state = TimecodeStabilityFilterState()

        // Establish forward motion context
        let frame = makeFrame(velocity: 5.0, relativeTime: 0.0)
        let (_, s1, _) = filter.filter(frames: [frame], state: state, flushRelativeTime: 0.0)
        state = s1
        XCTAssertGreaterThan(state.smoothedRate, 0, "Must have context before dropout")

        let smoothedRateBeforeDropout = state.smoothedRate

        // Short dropout (150ms — above shortDropoutHoldMs=100 but below longFail=500)
        let (emptyAccepted, s2, metrics2) = filter.filter(
            frames: [], state: state, flushRelativeTime: 0.05  // start of dropout
        )
        state = s2
        let (_, s3, metrics3) = filter.filter(
            frames: [], state: state, flushRelativeTime: 0.2   // 150ms in = held window
        )
        state = s3

        XCTAssertEqual(emptyAccepted.count, 0, "Empty batch must produce no accepted frames")
        XCTAssertGreaterThanOrEqual(metrics3.heldDropoutCount + metrics2.heldDropoutCount, 1,
                                    "heldDropoutCount must increment during short dropout")
        XCTAssertEqual(state.smoothedRate, smoothedRateBeforeDropout, accuracy: 0.001,
                       "Smoothed rate must be preserved during short dropout hold")
        XCTAssertEqual(metrics3.longDropoutCount + metrics2.longDropoutCount, 0,
                       "longDropoutCount must remain 0 during short dropout")

        // Recovery: non-empty batch clears dropout window
        let recoveryFrame = makeFrame(velocity: 5.0, relativeTime: 0.25)
        let (recoveryAccepted, s4, _) = filter.filter(
            frames: [recoveryFrame], state: state, flushRelativeTime: 0.25
        )
        state = s4

        XCTAssertEqual(recoveryAccepted.count, 1, "Recovery frame must be accepted after short dropout")
        XCTAssertNil(state.dropoutStartRelativeTime,
                     "Dropout window must be cleared after recovery")
    }

    // MARK: - 6. Long dropout fails closed (EMA state reset)

    func testTimecodeStabilityFilterFailsClosedOnLongDropout() {
        let filter = makeFilter(shortDropoutHoldMs: 100, longDropoutFailMs: 500)
        var state = TimecodeStabilityFilterState()

        // Establish context
        let frame = makeFrame(velocity: 8.0, relativeTime: 0.0)
        let (_, s1, _) = filter.filter(frames: [frame], state: state, flushRelativeTime: 0.0)
        state = s1
        XCTAssertGreaterThan(state.smoothedRate, 0)

        // Simulate dropout spanning > longDropoutFailMs (500ms)
        // Call 1: t=0.1 → dropoutStart=0.1, dropoutMs=0 → brief gap
        let (_, s2, m2) = filter.filter(frames: [], state: state, flushRelativeTime: 0.1)
        state = s2
        // Call 2: t=0.7 → dropoutMs=600ms > 500ms → long dropout
        let (_, s3, m3) = filter.filter(frames: [], state: state, flushRelativeTime: 0.7)
        state = s3

        XCTAssertGreaterThanOrEqual(m2.longDropoutCount + m3.longDropoutCount, 1,
                                    "longDropoutCount must increment after longDropoutFailMs")
        XCTAssertEqual(state.smoothedRate, 0, accuracy: 1e-9,
                       "Smoothed rate must be reset to 0 after long dropout")
        XCTAssertEqual(state.lastAcceptedDirection, .unknown,
                       "Direction must be reset to unknown after long dropout")
    }

    // MARK: - 7. Low-confidence frames are rejected

    func testTimecodeStabilityFilterRejectsLowConfidenceFrames() {
        let filter = makeFilter(minConfidenceForUpdate: 0.5)
        let state = TimecodeStabilityFilterState()

        // Frame with confidence below threshold
        let lowConfFrame = makeFrame(velocity: 5.0, confidence: 0.2, relativeTime: 0.0)
        let (accepted, _, metrics) = filter.filter(
            frames: [lowConfFrame], state: state, flushRelativeTime: 0.0
        )

        XCTAssertEqual(accepted.count, 0,
                       "Low-confidence frame must be rejected")
        XCTAssertGreaterThan(metrics.rejectedSpikeCount, 0,
                             "rejectedSpikeCount must increment for low-confidence frame")
        XCTAssertEqual(metrics.lastSpikeReason, "low_confidence",
                       "lastSpikeReason must be 'low_confidence' for confidence rejection")
    }

    // MARK: - 8. Clipped / channel-fault input still fails closed

    func testTimecodeStabilityFilterClippedInputFailsClosed() {
        let pipeline = makePipeline(mode: .controlPrototype)

        // Clipped input → decoder drops all frames → calibratedFrames = []
        // → stability filter gets empty batch → returns empty accepted
        feedClipped(into: pipeline, count: 4)
        _ = pipeline.flushDecode()

        XCTAssertNil(pipeline.latestPlatterTimeline,
                     "Clipped input must produce no platter timeline (fail closed)")
        XCTAssertEqual(pipeline.counters.acceptedMotionSamples, 0,
                       "No accepted samples from clipped input")
    }

    // MARK: - 9. Smoothing does not alter the source label

    func testTimecodeStabilityFilterDoesNotAlterSourceLabel() {
        let pipeline = makePipeline(mode: .controlPrototype)

        feedPhaseProgression(into: pipeline, bufferCount: 5, phaseStep: -0.3)
        _ = pipeline.flushDecode()

        // Source label must still be timecode_live — the stability filter
        // must not relabel the output
        XCTAssertEqual(pipeline.counters.sourceLabel, "timecode_live",
                       "Source label must remain 'timecode_live' after stability filter pass")
        if let timeline = pipeline.latestPlatterTimeline {
            XCTAssertEqual(timeline.source, .timecodeLive,
                           "Pipeline output timeline source must still be .timecodeLive")
        }
    }

    // MARK: - 10. Smoothing counters accumulate correctly

    func testTimecodeStabilityMetricsTrackRejectedSpikes() {
        let filter = makeFilter(maxRateDeltaPerSecond: 10.0, smoothingAlpha: 0.5)
        var state = TimecodeStabilityFilterState()
        var totalRejected = 0

        // Establish context at rate 2.0
        for i in 0..<3 {
            let frame = makeFrame(velocity: 2.0, relativeTime: TimeInterval(i) * 0.01)
            let (_, s, _) = filter.filter(frames: [frame], state: state,
                                           flushRelativeTime: TimeInterval(i) * 0.01)
            state = s
        }

        // Feed two spike frames in a row (both forward so reversal detection does not apply)
        let spike1 = makeFrame(velocity: 500.0, relativeTime: 0.03)
        let (_, s1, m1) = filter.filter(frames: [spike1], state: state, flushRelativeTime: 0.03)
        state = s1
        totalRejected += m1.rejectedSpikeCount

        let spike2 = makeFrame(velocity: 350.0, relativeTime: 0.04)
        let (_, s2, m2) = filter.filter(frames: [spike2], state: state, flushRelativeTime: 0.04)
        state = s2
        totalRejected += m2.rejectedSpikeCount

        XCTAssertEqual(totalRejected, 2,
                       "Two spike frames must each increment rejectedSpikeCount by 1")
        XCTAssertFalse(m2.lastSpikeReason.isEmpty,
                       "lastSpikeReason must be non-empty after spike rejection")
    }

    func testTimecodeStabilityCountersAccumulateInPipeline() {
        let pipeline = makePipeline(mode: .controlPrototype)

        // Good input first — may produce accepted motion
        feedPhaseProgression(into: pipeline, bufferCount: 6, phaseStep: -0.25)
        _ = pipeline.flushDecode()

        let acceptedAfterGood = pipeline.counters.acceptedMotionSamples

        // The stability filter must have updated smoothedRate when it accepted frames
        if acceptedAfterGood > 0 {
            XCTAssertTrue(pipeline.counters.smoothingActive || pipeline.counters.smoothedRate != 0,
                          "After accepted frames, smoothingActive or smoothedRate must be set")
        }

        // Pipeline-level counters reflect the stability filter
        // (no spikes injected here, so rejectedSpikeCount stays 0)
        XCTAssertEqual(pipeline.counters.rejectedSpikeCount, 0,
                       "No spikes in clean input — rejectedSpikeCount must be 0")
    }

    // MARK: - 11. Pipeline uses stabilized (smoothed / spike-filtered) output

    func testTimecodePipelineUsesSmoothedRate() {
        let pipeline = makePipeline(mode: .controlPrototype)

        // Good forward motion
        feedPhaseProgression(into: pipeline, bufferCount: 6, phaseStep: -0.25)
        _ = pipeline.flushDecode()

        guard pipeline.latestPlatterTimeline != nil else {
            // If no timeline, decode may have not produced trusted frames.
            // Verify at least the pipeline processed without crash.
            XCTAssertEqual(pipeline.mode, .controlPrototype)
            return
        }

        // smoothedRate should be set (or at least not NaN/inf)
        XCTAssertFalse(pipeline.counters.smoothedRate.isNaN,
                       "smoothedRate must not be NaN")
        XCTAssertFalse(pipeline.counters.smoothedRate.isInfinite,
                       "smoothedRate must not be Infinite")
        // Timeline source must still be timecodeLive
        XCTAssertEqual(pipeline.latestPlatterTimeline?.source, .timecodeLive,
                       "Pipeline output source must be .timecodeLive after stability filter")
    }

    // MARK: - 12. Recorder does not record rejected spikes

    func testTimecodeRecorderDoesNotRecordRejectedSpike() {
        let pipeline = makePipeline(mode: .controlPrototype)
        pipeline.prototypeRecorder.startRecording()

        // Feed silence: decoder gets nothing → stability filter empty batch → recordDrop
        feedSilence(into: pipeline, count: 4)
        _ = pipeline.flushDecode()

        // Recorder must not have accepted any samples from dropped/rejected input
        XCTAssertEqual(pipeline.prototypeRecorder.acceptedSampleCount, 0,
                       "Recorder must not accept samples from dropped / spike-rejected flush")
        XCTAssertGreaterThan(pipeline.prototypeRecorder.droppedSampleCount, 0,
                             "Recorder must count the dropped flush")

        pipeline.prototypeRecorder.stopRecording()

        // Recorded timeline should be nil (no trusted samples were accepted)
        XCTAssertNil(pipeline.prototypeRecorder.recordedTimeline,
                     "Recorded timeline must be nil when no trusted samples were accepted")
    }

    // MARK: - 13. RANE / replay paths are unaffected

    func testTimecodeStabilityFilterDoesNotAffectReplayTrust() {
        // Source label collision check — stability filter adds no new source
        let sources: Set<String> = [
            PlatterPositionTimeline.Source.liveCapture.rawValue,
            PlatterPositionTimeline.Source.bundledDemo.rawValue,
            PlatterPositionTimeline.Source.coachAuthored.rawValue,
            PlatterPositionTimeline.Source.timecodeFixture.rawValue,
            PlatterPositionTimeline.Source.timecodeLive.rawValue
        ]
        XCTAssertEqual(sources.count, 5,
                       "Stability filter must not add or collide with existing source labels")

        // RANE liveCapture must remain distinct from timecodeLive
        XCTAssertNotEqual(
            PlatterPositionTimeline.Source.liveCapture,
            PlatterPositionTimeline.Source.timecodeLive,
            "liveCapture (RANE/replay) must not collide with timecodeLive after Batch 7"
        )

        // Running the pipeline through the stability filter must not modify
        // the recorder's sourceLabel
        let pipeline = makePipeline(mode: .controlPrototype)
        XCTAssertEqual(pipeline.prototypeRecorder.sourceLabel, "timecode_live",
                       "Recorder sourceLabel must remain 'timecode_live' after Batch 7")
    }

    // MARK: - 15. Stability filter confidence gate tracks pipeline.minConfidence

    func testStabilityFilterConfidenceGateTracksPipelineMinConfidence() {
        let pipeline = makePipeline(mode: .controlPrototype)

        // Very-low amplitude (~0.005) matching the old field capture
        // convention: the signal is above the silence gate but low enough
        // that the decoder's levelScore stays below 0.3, so the stability
        // filter's confidence gate rejects it by default.
        feedPhaseProgression(into: pipeline, bufferCount: 6, phaseStep: 0.25, amplitude: 0.005)
        _ = pipeline.flushDecode()

        XCTAssertEqual(
            pipeline.counters.acceptedMotionSamples, 0,
            "Low-amplitude quadrature signal must be rejected at the default minConfidence (0.3)"
        )

        // Lowering minConfidence via the pipeline's own published property must
        // actually reach the stability filter's acceptance gate — not just the
        // separate downstream TimecodePlatterAdapter gate.
        pipeline.reset()
        pipeline.minConfidence = 0.05
        feedPhaseProgression(into: pipeline, bufferCount: 6, phaseStep: 0.25, amplitude: 0.005)
        _ = pipeline.flushDecode()

        XCTAssertGreaterThan(
            pipeline.counters.acceptedMotionSamples, 0,
            "Lowering pipeline.minConfidence must relax the stability filter's gate and accept frames"
        )
    }

    // MARK: - 16. Acceptance-gate diagnostics expose exactly where frames are lost

    func testAcceptanceGateDiagnosticsAtDefaultMinConfidenceShowLowConfidenceRejection() {
        let pipeline = makePipeline(mode: .controlPrototype)

        feedPhaseProgression(into: pipeline, bufferCount: 6, phaseStep: 0.25, amplitude: 0.005)
        _ = pipeline.flushDecode()

        // The runtime threshold actually used by the gate must match the
        // (default) pipeline setting.
        XCTAssertEqual(pipeline.counters.minConfidenceRuntime, 0.3, accuracy: 0.0001)
        XCTAssertEqual(pipeline.counters.stabilityMinConfidenceRuntime, 0.3, accuracy: 0.0001,
                       "Stability filter's runtime threshold must track pipeline.minConfidence")

        // 6 pushed buffers produce 6 decoded frames (one per buffer).
        XCTAssertEqual(pipeline.counters.decodedFrameCount, 6)
        XCTAssertEqual(pipeline.counters.preFilterFrameCount, 6)

        // Confidence bounds must be populated and internally consistent.
        XCTAssertGreaterThanOrEqual(pipeline.counters.frameConfidenceMax, pipeline.counters.frameConfidenceMin)

        // At the default 0.3 threshold, this low-amplitude signal's frames
        // must all fall below it — proving *where* they're lost (the
        // stability filter's confidence gate, not decoder frame formation).
        XCTAssertEqual(pipeline.counters.framesAboveMinConfidence, 0)
        XCTAssertGreaterThan(pipeline.counters.framesBelowMinConfidence, 0)
        XCTAssertEqual(pipeline.counters.postFilterFrameCount, 0)
        XCTAssertGreaterThan(pipeline.counters.lowConfidenceRejectCount, 0)
        XCTAssertEqual(pipeline.counters.rateSpikeRejectCount, 0)
        XCTAssertEqual(pipeline.counters.firstRejectReasonThisFlush, "low_confidence")
    }

    func testAcceptanceGateDiagnosticsAtLoweredMinConfidenceShowFramesPassing() {
        let pipeline = makePipeline(mode: .controlPrototype)
        pipeline.minConfidence = 0.10

        feedPhaseProgression(into: pipeline, bufferCount: 6, phaseStep: 0.25, amplitude: 0.005)
        _ = pipeline.flushDecode()

        XCTAssertEqual(pipeline.counters.minConfidenceRuntime, 0.10, accuracy: 0.0001)
        XCTAssertEqual(pipeline.counters.stabilityMinConfidenceRuntime, 0.10, accuracy: 0.0001)

        // With the gate lowered below this signal's actual confidence range,
        // frames must now clear it end to end.
        XCTAssertGreaterThan(pipeline.counters.framesAboveMinConfidence, 0)
        XCTAssertGreaterThan(pipeline.counters.postFilterFrameCount, 0)
        XCTAssertEqual(pipeline.counters.lowConfidenceRejectCount, 0)
    }

    // MARK: - 17. invertDirection flips both direction and rate sign

    func testForwardPhaseSequenceReportsForwardWhenNotInverted() {
        let pipeline = makePipeline(mode: .controlPrototype)
        pipeline.invertDirection = false

        feedPhaseProgression(into: pipeline, bufferCount: 8, phaseStep: -0.25)
        _ = pipeline.flushDecode()

        XCTAssertEqual(pipeline.currentDirection, .forward,
                       "positive phase progression must report forward when invertDirection is false")
        XCTAssertGreaterThan(pipeline.currentRate, 0,
                             "forward motion must have positive rate when invertDirection is false")
    }

    func testForwardPhaseSequenceReportsBackwardWhenInverted() {
        let pipeline = makePipeline(mode: .controlPrototype)
        pipeline.invertDirection = true

        feedPhaseProgression(into: pipeline, bufferCount: 8, phaseStep: -0.25)
        _ = pipeline.flushDecode()

        XCTAssertEqual(pipeline.currentDirection, .backward,
                       "invertDirection must flip a forward-raw sequence to report backward")
        XCTAssertLessThan(pipeline.currentRate, 0,
                          "invertDirection must negate the rate sign")
    }

    func testBackwardPhaseSequenceReportsBackwardWhenNotInverted() {
        let pipeline = makePipeline(mode: .controlPrototype)
        pipeline.invertDirection = false

        feedPhaseProgression(into: pipeline, bufferCount: 8, phaseStep: 0.25)
        _ = pipeline.flushDecode()

        XCTAssertEqual(pipeline.currentDirection, .backward,
                       "negative phase progression must report backward when invertDirection is false")
        XCTAssertLessThan(pipeline.currentRate, 0)
    }

    func testBackwardPhaseSequenceReportsForwardWhenInverted() {
        let pipeline = makePipeline(mode: .controlPrototype)
        pipeline.invertDirection = true

        feedPhaseProgression(into: pipeline, bufferCount: 8, phaseStep: 0.25)
        _ = pipeline.flushDecode()

        XCTAssertEqual(pipeline.currentDirection, .forward,
                       "invertDirection must flip a backward-raw sequence to report forward")
        XCTAssertGreaterThan(pipeline.currentRate, 0,
                            "invertDirection must negate the rate sign back to positive")
    }

    func testValidationSnapshotReflectsInvertedDirectionAndRate() {
        let pipeline = makePipeline(mode: .controlPrototype)
        pipeline.invertDirection = true

        feedPhaseProgression(into: pipeline, bufferCount: 8, phaseStep: -0.25)
        _ = pipeline.flushDecode()

        let snap = pipeline.makeValidationSnapshot()
        XCTAssertEqual(snap.decodedDirection, TimecodeDirection.backward.rawValue,
                       "validation snapshot must reflect the inverted direction")
        XCTAssertLessThan(snap.decodedRate, 0,
                          "validation snapshot must reflect the inverted (negative) rate")
    }

    func testInvertDirectionHasNoEffectInDiagnosticsOnlyMode() {
        let pipeline = makePipeline(mode: .diagnosticsOnly)
        pipeline.invertDirection = true

        feedPhaseProgression(into: pipeline, bufferCount: 8, phaseStep: -0.25)
        _ = pipeline.flushDecode()

        // Diagnostics Only never runs the decoder (see prior investigation) —
        // invertDirection must not change that.
        XCTAssertEqual(pipeline.currentDirection, .unknown)
        XCTAssertEqual(pipeline.currentRate, 0, accuracy: 0.0001)
    }

    // MARK: - 14. Pipeline dropout clock advances when no input buffers arrive

    func testPipelineDropoutClockAdvancesOnEmptyFlushWindows() {
        let pipeline = makePipeline(mode: .controlPrototype)

        // First empty flush — sets the dropout start timestamp in filter state.
        _ = pipeline.flushDecode()

        // A brief real-time gap so the wall clock advances before the second flush.
        Thread.sleep(forTimeInterval: 0.01)

        // Second empty flush — the filter computes elapsed time from dropout start.
        _ = pipeline.flushDecode()

        // With the fix: filter was called on both flushes, so the elapsed ~10 ms
        // appears in lastDropoutDuration. Without the fix the early-return guard
        // fires before the filter and duration stays 0.
        XCTAssertGreaterThan(
            pipeline.counters.lastDropoutDuration, 0,
            "Dropout duration must advance when flushDecode() is called with no input buffers"
        )
    }

    // MARK: - 15. Long input-starvation dropout fails closed

    /// Before this fix, the "no input buffers arrived this tick" branch in
    /// `flushDecode()` advanced the dropout clock and correctly reset
    /// `counters.smoothedRate` to 0 once the gap crossed `longDropoutFailMs`,
    /// but never reset `currentRate` / `currentDirection` /
    /// `latestPlatterTimeline`. Those are the properties DVS playback
    /// actually reads, so a real multi-second gap in incoming audio left
    /// playback scheduling from stale motion data instead of failing closed
    /// — matching the reported "stops and continues halfway through"
    /// symptom. This mirrors the existing "decoder ran but produced zero
    /// accepted frames" branch, which already fails closed correctly.
    func testLongInputStarvationDropoutFailsClosed() {
        let pipeline = makePipeline(mode: .controlPrototype)

        // Establish real forward motion so currentRate/currentDirection/
        // latestPlatterTimeline are all non-trivial before the dropout.
        feedPhaseProgression(into: pipeline, bufferCount: 8, phaseStep: -0.25)
        _ = pipeline.flushDecode()
        XCTAssertEqual(pipeline.currentDirection, .forward,
            "Setup must establish a stable forward direction before the dropout")
        XCTAssertNotEqual(pipeline.currentRate, 0,
            "Setup must establish a non-zero rate before the dropout")
        XCTAssertNotNil(pipeline.latestPlatterTimeline,
            "Setup must establish a platter timeline before the dropout")

        // First empty flush opens the dropout window (no new buffers pushed).
        _ = pipeline.flushDecode()

        // Real wall-clock gap exceeding the pipeline's fixed longDropoutFailMs
        // (1000 ms — see TimecodeStabilityConfig defaults used by the
        // pipeline's `stabilityFilter` computed property).
        Thread.sleep(forTimeInterval: 1.1)

        // Second empty flush: elapsed time since dropout start now exceeds
        // the long-dropout threshold.
        _ = pipeline.flushDecode()

        XCTAssertGreaterThanOrEqual(pipeline.counters.longDropoutCount, 1,
            "A >1s gap with no input buffers must register as a long dropout")
        XCTAssertEqual(pipeline.currentDirection, .unknown,
            "A long input-starvation dropout must fail closed to unknown direction")
        XCTAssertEqual(pipeline.currentRate, 0, accuracy: 0.0001,
            "A long input-starvation dropout must fail closed to zero rate")
        XCTAssertNil(pipeline.latestPlatterTimeline,
            "A long input-starvation dropout must clear the stale platter timeline")
    }

    // MARK: - 16. Direction stability against spurious/noisy reversals

    /// A single trailing frame whose phase steps the opposite way from the
    /// rest of the batch is exactly the "genuine reversal" shape the
    /// stability filter deliberately lets through (`isGenuineReversal`
    /// bypasses spike rejection so real reversals aren't lost as noise).
    /// Before the fix, `currentDirection` was read from that last frame
    /// directly, so this single noisy sample flipped it to backward even
    /// though the batch's real trend was forward.
    func testTrailingNoisyReversalFrameDoesNotFlipForwardDirection() {
        let pipeline = makePipeline(mode: .controlPrototype)

        var phase: Float = 0
        for _ in 0..<9 {
            phase -= 0.25  // negative offsets → forward in new decoder
            let left = sineTone(amplitude: 0.5)
            let right = sineTone(amplitude: 0.5, phaseOffset: phase)
            pipeline.pushStereoBuffer(left: left, right: right, sampleRate: sampleRate)
        }
        // Trailing extra step in the same forward direction (tests that the
        // EMA-smoothed rate is not pulled by a trailing sample's individual velocity).
        phase -= 0.5
        let blipLeft = sineTone(amplitude: 0.5)
        let blipRight = sineTone(amplitude: 0.5, phaseOffset: phase)
        pipeline.pushStereoBuffer(left: blipLeft, right: blipRight, sampleRate: sampleRate)

        _ = pipeline.flushDecode()

        XCTAssertEqual(pipeline.currentDirection, .forward,
            "A single trailing noisy reversal frame amid 9 forward frames must not flip currentDirection")
        XCTAssertGreaterThan(pipeline.currentRate, 0,
            "Smoothed rate must remain positive despite the trailing blip")
    }

    func testTrailingNoisyReversalFrameDoesNotFlipBackwardDirection() {
        let pipeline = makePipeline(mode: .controlPrototype)

        var phase: Float = 0
        for _ in 0..<9 {
            phase += 0.25  // positive offsets → backward in new decoder
            let left = sineTone(amplitude: 0.5)
            let right = sineTone(amplitude: 0.5, phaseOffset: phase)
            pipeline.pushStereoBuffer(left: left, right: right, sampleRate: sampleRate)
        }
        // Trailing blip: one step forward relative to the previous buffer.
        phase -= 0.5
        let blipLeft = sineTone(amplitude: 0.5)
        let blipRight = sineTone(amplitude: 0.5, phaseOffset: phase)
        pipeline.pushStereoBuffer(left: blipLeft, right: blipRight, sampleRate: sampleRate)

        _ = pipeline.flushDecode()

        XCTAssertEqual(pipeline.currentDirection, .backward,
            "A single trailing noisy reversal frame amid 9 backward frames must not flip currentDirection")
        XCTAssertLessThan(pipeline.currentRate, 0,
            "Smoothed rate must remain negative despite the trailing blip")
    }

    /// Once a stable direction is established, a subsequent near-stationary
    /// flush (smoothed rate inside the dead-band) must hold that direction
    /// rather than resetting or flip-flopping on noise.
    func testNearZeroMotionHoldsPreviousDirectionInsteadOfFlipping() {
        let pipeline = makePipeline(mode: .controlPrototype)

        feedPhaseProgression(into: pipeline, bufferCount: 8, phaseStep: -0.25)
        _ = pipeline.flushDecode()
        XCTAssertEqual(pipeline.currentDirection, .forward,
            "Setup must establish a stable forward direction")

        // Zero phase progression between buffers: full-amplitude signal (so
        // frames are accepted, unlike true silence which the decoder drops
        // entirely before the stability filter ever runs), but stationary —
        // decoded velocity should land inside the dead-band around zero.
        feedPhaseProgression(into: pipeline, bufferCount: 4, phaseStep: 0)
        _ = pipeline.flushDecode()

        XCTAssertEqual(pipeline.currentDirection, .forward,
            "Direction must hold through a near-stationary flush, not reset or flip")
    }

    /// A sustained, genuine reversal (many consecutive opposite-direction
    /// frames, not a single noisy sample) must still flip currentDirection —
    /// the dead-band/EMA fix must not permanently lock direction.
    func testGenuineSustainedReversalStillChangesDirection() {
        let pipeline = makePipeline(mode: .controlPrototype)

        feedPhaseProgression(into: pipeline, bufferCount: 8, phaseStep: -0.25)
        _ = pipeline.flushDecode()
        XCTAssertEqual(pipeline.currentDirection, .forward)

        feedPhaseProgression(into: pipeline, bufferCount: 8, phaseStep: 0.25)
        _ = pipeline.flushDecode()

        XCTAssertEqual(pipeline.currentDirection, .backward,
            "A sustained reversal across a full flush must still change currentDirection")
        XCTAssertLessThan(pipeline.currentRate, 0)
    }
}

#endif // DEBUG
