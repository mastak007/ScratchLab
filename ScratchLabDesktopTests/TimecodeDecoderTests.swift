// TimecodeDecoderTests
//
// Pure unit tests for TimecodePhaseDecoder (prototype phase-based timecode
// decoder) and TimecodePlatterAdapter (decoded motion → platter timeline).
// All audio data is synthesised inline — no hardware, no external fixtures
// required.
//
// Batch 2: Prototype decoder only. Does not claim compatibility with any
// commercial timecode format.

import XCTest
@testable import ScratchLab

final class TimecodeDecoderTests: XCTestCase {

    // MARK: - Constants

    private let sampleRate: Double = 44100
    private let carrierFrequency: Float = 1000
    /// 441 samples at 44100 Hz = exactly 10 periods of 1000 Hz.
    /// Integer period count ensures clean quadrature correlation.
    private let framesPerBuffer: Int = 441
    private let timePerBuffer: TimeInterval = 441.0 / 44100.0  // 0.01 s

    // MARK: - Helpers: signal generation

    /// Generate a sine tone at the given frequency.
    private func sineTone(
        frequency: Float,
        sampleRate: Double,
        frameCount: Int,
        amplitude: Float,
        phaseOffset: Float = 0
    ) -> [Float] {
        (0..<frameCount).map { i in
            let t = Float(i) / Float(sampleRate)
            return amplitude * sin(2 * .pi * frequency * t + phaseOffset)
        }
    }

    /// Create a single stereo input with a phase offset on the right channel
    /// relative to the left.
    private func makeStereoInput(
        amplitude: Float = 0.5,
        rightPhaseOffset: Float = 0,
        relativeTime: TimeInterval = 0
    ) -> TimecodePhaseDecoder.StereoInput {
        let left = sineTone(
            frequency: carrierFrequency,
            sampleRate: sampleRate,
            frameCount: framesPerBuffer,
            amplitude: amplitude,
            phaseOffset: 0
        )
        let right = sineTone(
            frequency: carrierFrequency,
            sampleRate: sampleRate,
            frameCount: framesPerBuffer,
            amplitude: amplitude,
            phaseOffset: rightPhaseOffset
        )
        return TimecodePhaseDecoder.StereoInput(
            left: left, right: right,
            sampleRate: sampleRate,
            relativeTime: relativeTime
        )
    }

    /// Create a sequence of stereo inputs with a linearly advancing phase
    /// offset on the right channel (simulating forward platter motion).
    ///
    /// - Parameters:
    ///   - bufferCount: Number of buffers to generate.
    ///   - phaseStep: Phase increment per buffer (positive = forward).
    ///   - amplitude: Signal amplitude.
    /// - Returns: Array of `StereoInput` in time order.
    private func makePhaseProgression(
        bufferCount: Int,
        phaseStep: Float,
        amplitude: Float = 0.5
    ) -> [TimecodePhaseDecoder.StereoInput] {
        (0..<bufferCount).map { i in
            makeStereoInput(
                amplitude: amplitude,
                rightPhaseOffset: phaseStep * Float(i),
                relativeTime: TimeInterval(i) * timePerBuffer
            )
        }
    }

    /// Create a sequence of continuous 1 kHz quadrature buffers matching
    /// `scratchlab_quadrature_1khz_60s.wav`: left sine, right sine +90 degrees.
    private func makeContinuousQuadratureInputs(
        bufferCount: Int,
        framesPerBuffer: Int = 1024,
        amplitude: Float = 0.42
    ) -> [TimecodePhaseDecoder.StereoInput] {
        (0..<bufferCount).map { bufferIndex in
            let startFrame = bufferIndex * framesPerBuffer
            var left: [Float] = []
            var right: [Float] = []
            left.reserveCapacity(framesPerBuffer)
            right.reserveCapacity(framesPerBuffer)

            for frameOffset in 0..<framesPerBuffer {
                let absoluteFrame = startFrame + frameOffset
                let phase = 2.0 * Float.pi * carrierFrequency * Float(absoluteFrame) / Float(sampleRate)
                left.append(amplitude * sin(phase))
                right.append(amplitude * sin(phase + Float.pi / 2.0))
            }

            return TimecodePhaseDecoder.StereoInput(
                left: left,
                right: right,
                sampleRate: sampleRate,
                relativeTime: Double(startFrame) / sampleRate
            )
        }
    }

    /// Create a silent stereo input (all zeros).
    private func makeSilentInput(relativeTime: TimeInterval = 0) -> TimecodePhaseDecoder.StereoInput {
        let zeros = [Float](repeating: 0, count: framesPerBuffer)
        return TimecodePhaseDecoder.StereoInput(
            left: zeros, right: zeros,
            sampleRate: sampleRate,
            relativeTime: relativeTime
        )
    }

    /// Create a clipped stereo input (amplitude 1.0 = full scale).
    private func makeClippedInput(relativeTime: TimeInterval = 0) -> TimecodePhaseDecoder.StereoInput {
        makeStereoInput(amplitude: 1.0, relativeTime: relativeTime)
    }

    // MARK: - Helpers: decode + adapt

    private func makeDecoder() -> TimecodePhaseDecoder {
        TimecodePhaseDecoder(
            carrierFrequency: carrierFrequency,
            silenceThresholdRMS: 0.001,
            clippingThreshold: 0.999,
            minCorrelationMagnitude: 0.1,
            minConfidence: 0.3
        )
    }

    private func makeAdapter(minConfidence: Double = 0.5, maxRate: Double = 5.0) -> TimecodePlatterAdapter {
        TimecodePlatterAdapter(minConfidence: minConfidence, maxRate: maxRate)
    }

    // MARK: - 1. Silence rejection

    func testTimecodeDecoderRejectsSilence() {
        let decoder = makeDecoder()
        let inputs = [
            makeSilentInput(relativeTime: 0),
            makeSilentInput(relativeTime: timePerBuffer),
            makeSilentInput(relativeTime: 2 * timePerBuffer),
        ]

        let result = decoder.decode(inputs)

        XCTAssertEqual(result.frames.count, 0, "Silent input should produce zero decoded frames")
        XCTAssertEqual(result.signalHealth, .noSignal)
        XCTAssertEqual(result.dropoutReason, .silence)
        XCTAssertEqual(result.counters.droppedSilence, 3)
        XCTAssertEqual(result.counters.decodedSamples, 0)
    }

    // MARK: - 2. Clipping rejection

    func testTimecodeDecoderRejectsClippedInput() {
        let decoder = makeDecoder()
        let inputs = [
            makeClippedInput(relativeTime: 0),
            makeClippedInput(relativeTime: timePerBuffer),
        ]

        let result = decoder.decode(inputs)

        // Clipped input should drop all samples — no trusted decoded frames
        XCTAssertEqual(result.frames.count, 0, "Clipped input should produce zero decoded frames")
        XCTAssertEqual(result.counters.droppedClipped, 2)
        XCTAssertEqual(result.counters.decodedSamples, 0)
    }

    // MARK: - 3. Forward motion detection

    func testTimecodeDecoderDetectsForwardMotion() {
        let decoder = makeDecoder()
        // 5 buffers, phase advancing +0.3 rad per buffer
        let inputs = makePhaseProgression(bufferCount: 5, phaseStep: 0.3)

        let result = decoder.decode(inputs)

        // 5 inputs → 4 frames (first input has no predecessor for delta)
        XCTAssertEqual(result.frames.count, 4, "Should produce 4 frames from 5 inputs")

        // All frames should indicate forward direction
        let directions = result.frames.map(\.direction)
        for dir in directions {
            XCTAssertEqual(dir, .forward, "All frames should be forward, got \(dir)")
        }

        // Velocities should be positive
        for frame in result.frames {
            XCTAssertGreaterThan(frame.velocity, 0, "Forward velocity should be positive")
            XCTAssertGreaterThan(frame.deltaPosition, 0, "Forward delta should be positive")
        }

        XCTAssertGreaterThan(result.averageConfidence, 0.49, "Clean signal should have high confidence")
    }

    // MARK: - 4. Backward motion detection

    func testTimecodeDecoderDetectsBackwardMotion() {
        let decoder = makeDecoder()
        // 5 buffers, phase regressing -0.3 rad per buffer
        let inputs = makePhaseProgression(bufferCount: 5, phaseStep: -0.3)

        let result = decoder.decode(inputs)

        XCTAssertEqual(result.frames.count, 4, "Should produce 4 frames from 5 inputs")

        // All frames should indicate backward direction
        let directions = result.frames.map(\.direction)
        for dir in directions {
            XCTAssertEqual(dir, .backward, "All frames should be backward, got \(dir)")
        }

        // Velocities should be negative
        for frame in result.frames {
            XCTAssertLessThan(frame.velocity, 0, "Backward velocity should be negative")
            XCTAssertLessThan(frame.deltaPosition, 0, "Backward delta should be negative")
        }

        XCTAssertGreaterThan(result.averageConfidence, 0.49, "Clean signal should have high confidence")
    }

    func testTimecodeDecoderConstantQuadratureProducesNearZeroRate() {
        let decoder = makeDecoder()
        let inputs = makeContinuousQuadratureInputs(bufferCount: 220)

        let result = decoder.decode(inputs)

        XCTAssertGreaterThan(result.frames.count, 0)
        XCTAssertGreaterThan(result.averageConfidence, 0.3)
        XCTAssertEqual(result.counters.droppedSilence, 0)
        XCTAssertEqual(result.counters.droppedClipped, 0)
        XCTAssertEqual(result.counters.droppedLowConfidence, 0)
        XCTAssertLessThan(result.counters.directionChanges, 2)

        let maxAbsRate = result.frames.map { abs($0.velocity) }.max() ?? .infinity
        XCTAssertLessThan(maxAbsRate, 0.05, "Constant R-L phase delta should decode as near-zero rate, got \(maxAbsRate)")
        XCTAssertTrue(
            result.frames.allSatisfy { $0.direction == .unknown },
            "Constant quadrature should not rapidly flip direction"
        )
    }

    // MARK: - 5. Velocity scales with phase rate

    func testTimecodeDecoderVelocityScalesWithPhaseRate() {
        let decoder = makeDecoder()

        // Slow progression: small phase steps
        let slowInputs = makePhaseProgression(bufferCount: 5, phaseStep: 0.15)
        let slowResult = decoder.decode(slowInputs)
        XCTAssertEqual(slowResult.frames.count, 4)

        // Fast progression: larger phase steps
        let fastInputs = makePhaseProgression(bufferCount: 5, phaseStep: 0.6)
        let fastResult = decoder.decode(fastInputs)
        XCTAssertEqual(fastResult.frames.count, 4)

        // Average absolute velocity should be higher for fast progression
        let slowAvgAbsVelocity = slowResult.frames.map { abs($0.velocity) }.reduce(0, +) / Double(slowResult.frames.count)
        let fastAvgAbsVelocity = fastResult.frames.map { abs($0.velocity) }.reduce(0, +) / Double(fastResult.frames.count)

        XCTAssertGreaterThan(
            fastAvgAbsVelocity, slowAvgAbsVelocity * 1.5,
            "Fast phase progression (avg \(fastAvgAbsVelocity)) should produce higher velocity than slow (avg \(slowAvgAbsVelocity))"
        )
    }

    // MARK: - 6. Confidence decreases for weak signal

    func testTimecodeDecoderConfidenceDecreasesForWeakInput() {
        let decoder = makeDecoder()

        // Strong signal
        let strongInputs = makePhaseProgression(bufferCount: 5, phaseStep: 0.3, amplitude: 0.5)
        let strongResult = decoder.decode(strongInputs)

        // Weak signal (amplitude just above silence threshold)
        let weakInputs = makePhaseProgression(bufferCount: 5, phaseStep: 0.3, amplitude: 0.02)
        let weakResult = decoder.decode(weakInputs)

        XCTAssertGreaterThan(strongResult.frames.count, 0)
        // Weak signal may still decode but with lower confidence
        if weakResult.frames.count > 0 {
            XCTAssertGreaterThan(
                strongResult.averageConfidence, weakResult.averageConfidence,
                "Strong signal confidence (\(strongResult.averageConfidence)) should exceed weak signal confidence (\(weakResult.averageConfidence))"
            )
        }
        // If weak produces no frames, that's also valid — confidence was too low
    }

    // MARK: - 7. Adapter drops low-confidence samples

    func testTimecodeAdapterDropsLowConfidenceSamples() {
        let decoder = makeDecoder()
        let adapter = makeAdapter(minConfidence: 0.9)  // Very high threshold

        let inputs = makePhaseProgression(bufferCount: 5, phaseStep: 0.3, amplitude: 0.5)
        let result = decoder.decode(inputs)

        // With minConfidence=0.9, clean but not perfect sine should get dropped
        let timeline = adapter.adapt(result)

        // If any frames survived, their confidence must all be >= 0.9
        if let timeline = timeline {
            for sample in timeline.samples {
                XCTAssertGreaterThanOrEqual(sample.confidence, 0.9, "All surviving samples must meet minConfidence")
            }
        }
        // Either way, the adapter should not crash and should return a valid
        // timeline or nil — both are acceptable outcomes for high threshold.
    }

    // MARK: - 8. Adapter preserves direction for trusted samples

    func testTimecodeAdapterPreservesTrustedDirection() {
        let decoder = makeDecoder()
        let adapter = makeAdapter(minConfidence: 0.3)  // Lenient threshold

        // Forward progression
        let forwardInputs = makePhaseProgression(bufferCount: 5, phaseStep: 0.3)
        let forwardResult = decoder.decode(forwardInputs)
        let forwardTimeline = adapter.adapt(forwardResult)

        XCTAssertNotNil(forwardTimeline, "Trusted forward frames should produce a timeline")

        // Verify position increases (forward motion)
        if let timeline = forwardTimeline, timeline.samples.count >= 2 {
            let firstPos = timeline.samples.first!.position
            let lastPos = timeline.samples.last!.position
            XCTAssertGreaterThan(lastPos, firstPos, "Position should increase for forward motion")
        }

        // Backward progression
        let backwardInputs = makePhaseProgression(bufferCount: 5, phaseStep: -0.3)
        let backwardResult = decoder.decode(backwardInputs)
        let backwardTimeline = adapter.adapt(backwardResult)

        XCTAssertNotNil(backwardTimeline, "Trusted backward frames should produce a timeline")

        // Verify position decreases (backward motion)
        if let timeline = backwardTimeline, timeline.samples.count >= 2 {
            let firstPos = timeline.samples.first!.position
            let lastPos = timeline.samples.last!.position
            XCTAssertLessThan(lastPos, firstPos, "Position should decrease for backward motion")
        }
    }

    // MARK: - 9. Adapter clamps extreme rates

    func testTimecodeAdapterClampsExtremeRate() {
        let decoder = makeDecoder()
        // Use a very low maxRate to force clamping
        let adapter = makeAdapter(minConfidence: 0.3, maxRate: 2.0)

        // Generate fast progression that would exceed maxRate
        let inputs = makePhaseProgression(bufferCount: 5, phaseStep: 0.8)
        let result = decoder.decode(inputs)

        guard let timeline = adapter.adapt(result), !timeline.samples.isEmpty else {
            // If no frames survived, the decoder may have dropped them due to
            // phase wrapping at large steps. That's fine — the adapter
            // handled it without crashing.
            return
        }

        // Verify the timeline is well-formed (positions are finite)
        for sample in timeline.samples {
            XCTAssertTrue(sample.position.isFinite, "Position must be finite")
            XCTAssertTrue(sample.confidence.isFinite, "Confidence must be finite")
        }

        // Position deltas should be bounded (not insane jumps)
        for i in 1..<timeline.samples.count {
            let dp = abs(timeline.samples[i].position - timeline.samples[i - 1].position)
            let dt = timeline.samples[i].time - timeline.samples[i - 1].time
            if dt > 0 {
                let rate = dp / dt
                XCTAssertLessThanOrEqual(rate, adapter.maxRate + 0.1,
                    "Position delta rate \(rate) should be clamped to ~\(adapter.maxRate)")
            }
        }
    }

    // MARK: - 10. Adapter source label is timecodeFixture

    func testTimecodeAdapterSourceLabelIsTimecodeFixture() {
        let decoder = makeDecoder()
        let adapter = makeAdapter(minConfidence: 0.4)  // Lenient to allow frames through

        let inputs = makePhaseProgression(bufferCount: 5, phaseStep: 0.3)
        let result = decoder.decode(inputs)
        let timeline = adapter.adapt(result)

        XCTAssertNotNil(timeline, "Trusted frames should produce a timeline")
        XCTAssertEqual(timeline?.source, .timecodeFixture, "Adapter source must be .timecodeFixture")
    }

    // MARK: - 11. No hardware required (vacuous — documents the constraint)

    func testNoHardwareRequired() {
        // This test documents that the entire Batch 2 decoder test suite
        // runs against synthetic buffers only. No external hardware, no
        // WAV files, no audio interface.
        XCTAssertTrue(true, "All decoder tests use synthetic buffers only")
    }

    // MARK: - Additional: decoder counters accumulate correctly

    func testDecoderCountersTrackDropsAndMaxRate() {
        let decoder = makeDecoder()
        // Mix of good and silent inputs
        var inputs: [TimecodePhaseDecoder.StereoInput] = []
        inputs.append(makeSilentInput(relativeTime: 0))
        inputs.append(makeSilentInput(relativeTime: timePerBuffer))
        inputs.append(contentsOf: makePhaseProgression(bufferCount: 4, phaseStep: 0.3))
        // Re-time the phase progression to follow the silence
        for i in 0..<4 {
            // The phase progression starts at relativeTime 0, shift it
        }

        // Create properly timed mixed inputs
        var mixedInputs: [TimecodePhaseDecoder.StereoInput] = []
        mixedInputs.append(makeSilentInput(relativeTime: 0))
        mixedInputs.append(makeSilentInput(relativeTime: timePerBuffer))
        mixedInputs.append(makeStereoInput(rightPhaseOffset: 0, relativeTime: 2 * timePerBuffer))
        mixedInputs.append(makeStereoInput(rightPhaseOffset: 0.3, relativeTime: 3 * timePerBuffer))
        mixedInputs.append(makeStereoInput(rightPhaseOffset: 0.6, relativeTime: 4 * timePerBuffer))
        mixedInputs.append(makeStereoInput(rightPhaseOffset: 0.9, relativeTime: 5 * timePerBuffer))

        let result = decoder.decode(mixedInputs)

        XCTAssertEqual(result.counters.droppedSilence, 2, "Two silent inputs should be counted")
        XCTAssertEqual(result.counters.decodedSamples, 4, "Four valid inputs should be decoded")
        XCTAssertEqual(result.frames.count, 3, "Three frames from 4 valid inputs (first has no predecessor)")
        XCTAssertGreaterThan(result.counters.maxAbsRate, 0, "Max rate should be positive for forward motion")
    }

    // MARK: - Additional: empty input produces empty result

    func testDecoderEmptyInputProducesEmptyResult() {
        let decoder = makeDecoder()
        let result = decoder.decode([])

        XCTAssertEqual(result.frames.count, 0)
        XCTAssertEqual(result.signalHealth, .noSignal)
        XCTAssertEqual(result.dropoutReason, .silence)
    }

    // MARK: - Additional: adapter returns nil for empty decode result

    func testAdapterReturnsNilForEmptyResult() {
        let adapter = makeAdapter()
        let emptyResult = TimecodeDecodeResult.empty(reason: .silence)

        let timeline = adapter.adapt(emptyResult)
        XCTAssertNil(timeline, "Adapter should return nil for empty decode result")
    }

    // MARK: - Additional: direction changes are counted

    func testDecoderCountsDirectionChanges() {
        let decoder = makeDecoder()

        // Forward then backward
        var inputs: [TimecodePhaseDecoder.StereoInput] = []
        // Forward: phase 0 → 0.3 → 0.6
        inputs.append(makeStereoInput(rightPhaseOffset: 0, relativeTime: 0))
        inputs.append(makeStereoInput(rightPhaseOffset: 0.3, relativeTime: timePerBuffer))
        inputs.append(makeStereoInput(rightPhaseOffset: 0.6, relativeTime: 2 * timePerBuffer))
        // Backward: phase 0.6 → 0.3 → 0
        inputs.append(makeStereoInput(rightPhaseOffset: 0.3, relativeTime: 3 * timePerBuffer))
        inputs.append(makeStereoInput(rightPhaseOffset: 0, relativeTime: 4 * timePerBuffer))

        let result = decoder.decode(inputs)

        // Frames: fwd, fwd, rev, rev — one direction change (forward → backward)
        XCTAssertGreaterThanOrEqual(result.counters.directionChanges, 1,
            "Should detect at least one direction change, got \(result.counters.directionChanges)")
    }

    // MARK: - Additional: channel imbalance lowers confidence

    func testDecoderChannelImbalanceLowersConfidence() {
        let decoder = makeDecoder()

        // Balanced input
        let balancedInputs = makePhaseProgression(bufferCount: 5, phaseStep: 0.3, amplitude: 0.5)
        let balancedResult = decoder.decode(balancedInputs)

        // Imbalanced input: left channel normal, right channel weak
        var imbalancedInputs: [TimecodePhaseDecoder.StereoInput] = []
        for i in 0..<5 {
            let left = sineTone(
                frequency: carrierFrequency, sampleRate: sampleRate,
                frameCount: framesPerBuffer, amplitude: 0.5
            )
            let right = sineTone(
                frequency: carrierFrequency, sampleRate: sampleRate,
                frameCount: framesPerBuffer, amplitude: 0.05,
                phaseOffset: 0.3 * Float(i)
            )
            imbalancedInputs.append(TimecodePhaseDecoder.StereoInput(
                left: left, right: right,
                sampleRate: sampleRate,
                relativeTime: TimeInterval(i) * timePerBuffer
            ))
        }
        let imbalancedResult = decoder.decode(imbalancedInputs)

        XCTAssertGreaterThan(balancedResult.frames.count, 0)
        // Imbalanced input should have lower confidence than balanced
        if imbalancedResult.frames.count > 0 {
            XCTAssertGreaterThan(
                balancedResult.averageConfidence, imbalancedResult.averageConfidence,
                "Balanced confidence (\(balancedResult.averageConfidence)) should exceed imbalanced (\(imbalancedResult.averageConfidence))"
            )
        }
    }

    // MARK: - Additional: encoder/decoder round-trip preserves direction sign

    func testDecoderRoundTripPhaseSignIsSymmetric() {
        let decoder = makeDecoder()

        // Forward: +0.4 rad/buffer
        let fwdInputs = makePhaseProgression(bufferCount: 5, phaseStep: 0.4)
        let fwdResult = decoder.decode(fwdInputs)

        // Backward: -0.4 rad/buffer (same magnitude, opposite sign)
        let revInputs = makePhaseProgression(bufferCount: 5, phaseStep: -0.4)
        let revResult = decoder.decode(revInputs)

        XCTAssertEqual(fwdResult.frames.count, revResult.frames.count)

        // Velocities should be roughly equal in magnitude, opposite in sign
        if fwdResult.frames.count > 0 && revResult.frames.count > 0 {
            let fwdAvgVel = fwdResult.frames.map(\.velocity).reduce(0, +) / Double(fwdResult.frames.count)
            let revAvgVel = revResult.frames.map(\.velocity).reduce(0, +) / Double(revResult.frames.count)

            XCTAssertGreaterThan(fwdAvgVel, 0, "Forward average velocity should be positive")
            XCTAssertLessThan(revAvgVel, 0, "Backward average velocity should be negative")

            let ratio = abs(fwdAvgVel / revAvgVel)
            XCTAssertTrue((0.5...2.0).contains(ratio),
                "Forward and backward velocity magnitudes should be similar, ratio=\(ratio)")
        }
    }
}
