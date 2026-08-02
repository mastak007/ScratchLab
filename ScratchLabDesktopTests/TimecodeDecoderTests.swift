// TimecodeDecoderTests
//
// Pure unit tests for TimecodePhaseDecoder (phase-offset-based timecode
// decoder) and TimecodePlatterAdapter (decoded motion → platter timeline).
// All audio data is synthesised inline — no hardware, no external fixtures.
//
// Decoder architecture under test:
// - Direction from direct cross-channel phase offset sign
// - Speed from ZCR carrier frequency ratio (measured frequency / nominal
//   carrier frequency)
//
// Physical contract (established against 15 real Rane ONE MKII hardware
// captures — see AI_HANDOFF.md/DEV_LOG.md 2026-08-02): a sustained,
// near-nominal carrier with a stable quadrature phase relationship
// represents genuine ~1x platter motion, not a stationary platter. A real
// stationary/no-motion platter produces no usable carrier at all — it
// decodes as silence, not as a decoded near-zero rate. Speed scales with
// measured carrier frequency; direction comes from quadrature polarity.
// Tests below assert this measured contract, not the removed "constant
// quadrature ⇒ near-zero rate" assumption from an earlier, purely-synthetic
// prototype convention (`phaseStep`-per-buffer progression with frequency
// pinned at nominal) that real hardware evidence falsified.

import XCTest
@testable import ScratchLab

final class TimecodeDecoderTests: XCTestCase {

    // MARK: - Constants

    private let sampleRate: Double = 44100
    private let carrierFrequency: Float = 1000
    /// 441 samples at 44100 Hz = exactly 10 periods of 1000 Hz.
    private let framesPerBuffer: Int = 441
    private let timePerBuffer: TimeInterval = 441.0 / 44100.0  // 0.01 s

    /// Phase offset for forward motion (~ -80° from hardware evidence).
    private let forwardPhaseRad: Float = -80 * Float.pi / 180  // ≈ -1.396
    /// Phase offset for backward motion (~ +80°).
    private let backwardPhaseRad: Float = 80 * Float.pi / 180   // ≈ +1.396

    // MARK: - Helpers: signal generation

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

    /// Stereo pair with a phase offset on the right channel, at carrierFrequency.
    private func makeStereoInput(
        frequency: Float = 1000,
        amplitude: Float = 0.5,
        rightPhaseOffset: Float = 0,
        relativeTime: TimeInterval = 0
    ) -> TimecodePhaseDecoder.StereoInput {
        let left = sineTone(
            frequency: frequency, sampleRate: sampleRate,
            frameCount: framesPerBuffer, amplitude: amplitude
        )
        let right = sineTone(
            frequency: frequency, sampleRate: sampleRate,
            frameCount: framesPerBuffer, amplitude: amplitude,
            phaseOffset: rightPhaseOffset
        )
        return TimecodePhaseDecoder.StereoInput(
            left: left, right: right,
            sampleRate: sampleRate,
            relativeTime: relativeTime
        )
    }

    /// Multiple buffers with the same phase offset (stable direction).
    private func makeStableDirectionInputs(
        bufferCount: Int,
        frequency: Float = 1000,
        amplitude: Float = 0.5,
        rightPhaseOffset: Float = 0
    ) -> [TimecodePhaseDecoder.StereoInput] {
        (0..<bufferCount).map { i in
            makeStereoInput(
                frequency: frequency,
                amplitude: amplitude,
                rightPhaseOffset: rightPhaseOffset,
                relativeTime: TimeInterval(i) * timePerBuffer
            )
        }
    }

    private func makeSilentInput(relativeTime: TimeInterval = 0) -> TimecodePhaseDecoder.StereoInput {
        let zeros = [Float](repeating: 0, count: framesPerBuffer)
        return TimecodePhaseDecoder.StereoInput(
            left: zeros, right: zeros,
            sampleRate: sampleRate,
            relativeTime: relativeTime
        )
    }

    private func makeClippedInput(relativeTime: TimeInterval = 0) -> TimecodePhaseDecoder.StereoInput {
        makeStereoInput(amplitude: 1.0, relativeTime: relativeTime)
    }

    // MARK: - Helpers: decode + adapt

    private func makeDecoder() -> TimecodePhaseDecoder {
        TimecodePhaseDecoder(
            carrierFrequency: carrierFrequency,
            silenceThresholdRMS: 0.001,
            clippingThreshold: 0.999,
            minCorrelationMagnitude: 0.1
        )
    }

    private func makeAdapter(minConfidence: Double = 0.5, maxRate: Double = 5.0) -> TimecodePlatterAdapter {
        TimecodePlatterAdapter(minConfidence: minConfidence, maxRate: maxRate)
    }

    // MARK: - 1. Silence rejection

    func testRejectsSilence() {
        let decoder = makeDecoder()
        let inputs = (0..<3).map { makeSilentInput(relativeTime: timePerBuffer * TimeInterval($0)) }
        let result = decoder.decode(inputs)

        XCTAssertEqual(result.frames.count, 0)
        XCTAssertEqual(result.signalHealth, .noSignal)
        XCTAssertEqual(result.counters.droppedSilence, 3)
        XCTAssertEqual(result.counters.decodedSamples, 0)
    }

    // MARK: - 2. Clipping rejection

    func testRejectsClippedInput() {
        let decoder = makeDecoder()
        let inputs = (0..<2).map { makeClippedInput(relativeTime: timePerBuffer * TimeInterval($0)) }
        let result = decoder.decode(inputs)

        XCTAssertEqual(result.frames.count, 0)
        XCTAssertEqual(result.counters.droppedClipped, 2)
        XCTAssertEqual(result.counters.decodedSamples, 0)
    }

    // MARK: - 3. Steady forward at normal speed

    func testForwardDirection() {
        let decoder = makeDecoder()
        let inputs = makeStableDirectionInputs(
            bufferCount: 5, rightPhaseOffset: forwardPhaseRad
        )
        let result = decoder.decode(inputs)

        XCTAssertEqual(result.frames.count, 5)
        for frame in result.frames {
            XCTAssertEqual(frame.direction, .forward,
                           "Forward phase offset must produce forward direction")
            XCTAssertGreaterThan(frame.velocity, 0,
                                 "Forward velocity must be positive")
        }
    }

    // MARK: - 4. Steady backward at normal speed

    func testBackwardDirection() {
        let decoder = makeDecoder()
        let inputs = makeStableDirectionInputs(
            bufferCount: 5, rightPhaseOffset: backwardPhaseRad
        )
        let result = decoder.decode(inputs)

        XCTAssertEqual(result.frames.count, 5)
        for frame in result.frames {
            XCTAssertEqual(frame.direction, .backward,
                           "Backward phase offset must produce backward direction")
            XCTAssertLessThan(frame.velocity, 0,
                              "Backward velocity must be negative")
        }
    }

    // MARK: - 5. Constant phase offset does not produce direction changes

    func testStableOffsetNoDirectionChanges() {
        let decoder = makeDecoder()
        let inputs = makeStableDirectionInputs(
            bufferCount: 20, rightPhaseOffset: forwardPhaseRad
        )
        let result = decoder.decode(inputs)

        XCTAssertEqual(result.counters.directionChanges, 0,
                       "Constant phase offset must not produce direction changes")
        let allForward = result.frames.allSatisfy { $0.direction == .forward }
        XCTAssertTrue(allForward, "All frames must be forward")
    }

    // MARK: - 6. Small phase jitter within same sign does not flip

    func testSmallJitterNoFlip() {
        let decoder = makeDecoder()
        // Phase offsets varying between -70° and -90° (all negative = forward)
        let offsets: [Float] = [-70, -80, -90, -75, -85].map { $0 * Float.pi / 180 }
        let inputs: [TimecodePhaseDecoder.StereoInput] = offsets.enumerated().map { (i, off) in
            makeStereoInput(rightPhaseOffset: off, relativeTime: timePerBuffer * TimeInterval(i))
        }
        let result = decoder.decode(inputs)

        let allForward = result.frames.allSatisfy { $0.direction == .forward }
        XCTAssertTrue(allForward, "All frames with negative phase offset must be forward")
        XCTAssertEqual(result.counters.directionChanges, 0)
    }

    // MARK: - 7. Phase dead-band produces unknown

    func testPhaseDeadBandProducesUnknown() {
        let decoder = makeDecoder()
        // Phase offsets inside ±30° dead-band
        let offsets: [Float] = [-20, -10, 0, 10, 20].map { $0 * Float.pi / 180 }
        let inputs: [TimecodePhaseDecoder.StereoInput] = offsets.enumerated().map { (i, off) in
            makeStereoInput(rightPhaseOffset: off, relativeTime: timePerBuffer * TimeInterval(i))
        }
        let result = decoder.decode(inputs)

        for frame in result.frames {
            XCTAssertEqual(frame.direction, .unknown,
                           "Phase offset within ±30° dead-band must give unknown direction")
            XCTAssertEqual(frame.velocity, 0,
                           "Velocity must be 0 for unknown direction")
        }
    }

    // MARK: - 8. Genuine forward-to-backward reversal

    func testReversalChangesDirection() {
        let decoder = makeDecoder()
        var inputs: [TimecodePhaseDecoder.StereoInput] = []
        // 3 forward buffers
        for i in 0..<3 {
            inputs.append(makeStereoInput(
                rightPhaseOffset: forwardPhaseRad,
                relativeTime: timePerBuffer * TimeInterval(i)
            ))
        }
        // 3 backward buffers
        for i in 3..<6 {
            inputs.append(makeStereoInput(
                rightPhaseOffset: backwardPhaseRad,
                relativeTime: timePerBuffer * TimeInterval(i)
            ))
        }
        let result = decoder.decode(inputs)

        let forwardFrames = result.frames.filter { $0.direction == .forward }
        let backwardFrames = result.frames.filter { $0.direction == .backward }
        XCTAssertGreaterThan(forwardFrames.count, 0, "Must have forward frames")
        XCTAssertGreaterThan(backwardFrames.count, 0, "Must have backward frames")
        XCTAssertGreaterThanOrEqual(result.counters.directionChanges, 1,
                                    "Must detect at least one direction change")
    }

    // MARK: - 9. Phase wrap normalization

    func testPhaseWrapNormalization() {
        let decoder = makeDecoder()
        // Phase offsets near ±180° should wrap correctly.
        // -179° (negative, close to -π) → forward after normalization.
        let nearNegPi: Float = -179 * Float.pi / 180
        let nearPosPi: Float = 179 * Float.pi / 180
        let inputs = [
            makeStereoInput(rightPhaseOffset: nearNegPi, relativeTime: 0),
            makeStereoInput(rightPhaseOffset: nearPosPi, relativeTime: timePerBuffer),
        ]
        let result = decoder.decode(inputs)

        // The raw delta = right - left is computed by extractPhaseDelta
        // and then wrapped to [-π, π]. Both -179° and +179° should produce
        // clear direction (not unknown).
        for frame in result.frames {
            XCTAssertNotEqual(frame.direction, .unknown,
                              "Phase offset near ±π must not be ambiguous")
        }
    }

    // MARK: - 10. Mismatched L/R frequency fails closed

    func testInvalidFrequencyFailsClosed() {
        let decoder = makeDecoder()
        // Right channel carries a completely different frequency (no phase
        // relationship to left). Correlation magnitude will be low → dropped.
        let inputs: [TimecodePhaseDecoder.StereoInput] = (0..<5).map { i in
            let left = sineTone(
                frequency: 1000, sampleRate: sampleRate,
                frameCount: framesPerBuffer, amplitude: 0.5
            )
            let right = sineTone(
                frequency: 200, sampleRate: sampleRate,
                frameCount: framesPerBuffer, amplitude: 0.5
            )
            return TimecodePhaseDecoder.StereoInput(
                left: left, right: right,
                sampleRate: sampleRate,
                relativeTime: timePerBuffer * TimeInterval(i)
            )
        }
        let result = decoder.decode(inputs)

        // May produce 0 frames (low correlation) or frames with low confidence
        // — either way, must not crash or produce garbage direction changes.
        let unknownCount = result.frames.filter { $0.direction == .unknown }.count
        XCTAssertEqual(unknownCount, result.frames.count,
                       "All frames from mismatched frequencies must be unknown")
    }

    // MARK: - 11. Stable near-nominal carrier ⇒ confirmed ~1x motion
    //
    // Reconciles the removed `testTimecodeDecoderConstantQuadratureProducesNearZeroRate`.
    // Real Rane ONE MKII hardware evidence (15-fixture measurement,
    // `steady_normal` + `position_start/middle/end`, all ground-truth
    // confirmed steady forward motion) shows a sustained, unchanging
    // near-1 kHz quadrature carrier is genuine ~1x motion, not a stationary
    // platter — a stationary platter instead produces no usable carrier at
    // all (see `testRejectsSilence`). This is the physically correct
    // replacement for the old synthetic assumption.

    func testNormalCarrierSpeed() {
        let decoder = makeDecoder()
        let inputs = makeStableDirectionInputs(
            bufferCount: 5, frequency: 1000, rightPhaseOffset: forwardPhaseRad
        )
        let result = decoder.decode(inputs)

        XCTAssertGreaterThan(result.frames.count, 0)
        let avgVel = result.frames.map(\.velocity).reduce(0, +) / Double(result.frames.count)
        // 1000 Hz / 1000 Hz = speed 1.0, direction forward = +1.0
        XCTAssertEqual(avgVel, 1.0, accuracy: 0.2,
                       "1000 Hz at forward phase should give velocity ≈ 1.0")
    }

    // MARK: - 12. Slow/normal/fast carrier frequencies produce proportional rates

    func testSpeedScalesWithFrequency() {
        let decoder = makeDecoder()
        let slowResult = decoder.decode(makeStableDirectionInputs(
            bufferCount: 4, frequency: 400, rightPhaseOffset: forwardPhaseRad
        ))
        let normalResult = decoder.decode(makeStableDirectionInputs(
            bufferCount: 4, frequency: 1000, rightPhaseOffset: forwardPhaseRad
        ))
        let fastResult = decoder.decode(makeStableDirectionInputs(
            bufferCount: 4, frequency: 3000, rightPhaseOffset: forwardPhaseRad
        ))

        XCTAssertGreaterThan(slowResult.frames.count, 0, "Slow carrier must produce at least one frame")
        XCTAssertGreaterThan(normalResult.frames.count, 0, "Normal carrier must produce at least one frame")
        XCTAssertGreaterThan(fastResult.frames.count, 0, "Fast carrier must produce at least one frame")

        let slowAvgVel = slowResult.frames.map(\.velocity).reduce(0, +) / Double(slowResult.frames.count)
        let normalAvgVel = normalResult.frames.map(\.velocity).reduce(0, +) / Double(normalResult.frames.count)
        let fastAvgVel = fastResult.frames.map(\.velocity).reduce(0, +) / Double(fastResult.frames.count)

        XCTAssertTrue(slowAvgVel.isFinite, "Slow average velocity must be finite, got \(slowAvgVel)")
        XCTAssertTrue(normalAvgVel.isFinite, "Normal average velocity must be finite, got \(normalAvgVel)")
        XCTAssertTrue(fastAvgVel.isFinite, "Fast average velocity must be finite, got \(fastAvgVel)")

        // Matches the measured hardware ordering across the three speed
        // tiers (slow ~300-450 Hz, normal ~950-1050 Hz, fast ~1500-2300 Hz).
        XCTAssertLessThan(slowAvgVel, normalAvgVel,
                          "Slow carrier must produce lower velocity than normal")
        XCTAssertLessThan(normalAvgVel, fastAvgVel,
                          "Normal carrier must produce lower velocity than fast")

        XCTAssertTrue(slowResult.frames.allSatisfy { $0.direction == .forward },
                      "Slow measured carrier must retain forward phase lock")
        XCTAssertTrue(normalResult.frames.allSatisfy { $0.direction == .forward },
                      "Normal measured carrier must retain forward phase lock")
        XCTAssertTrue(fastResult.frames.allSatisfy { $0.direction == .forward },
                      "Fast measured carrier must retain forward phase lock")
    }

    // MARK: - 13. Opposite quadrature polarity ⇒ opposite raw direction, same magnitude

    func testOppositeQuadraturePolarityProducesOppositeDirectionSameMagnitude() {
        let decoder = makeDecoder()
        let fwdResult = decoder.decode(makeStableDirectionInputs(
            bufferCount: 5, frequency: 1000, rightPhaseOffset: forwardPhaseRad
        ))
        let bwdResult = decoder.decode(makeStableDirectionInputs(
            bufferCount: 5, frequency: 1000, rightPhaseOffset: backwardPhaseRad
        ))

        XCTAssertTrue(fwdResult.frames.allSatisfy { $0.direction == .forward })
        XCTAssertTrue(bwdResult.frames.allSatisfy { $0.direction == .backward })

        let fwdAvgVel = fwdResult.frames.map(\.velocity).reduce(0, +) / Double(fwdResult.frames.count)
        let bwdAvgVel = bwdResult.frames.map(\.velocity).reduce(0, +) / Double(bwdResult.frames.count)

        XCTAssertGreaterThan(fwdAvgVel, 0)
        XCTAssertLessThan(bwdAvgVel, 0)
        XCTAssertEqual(abs(fwdAvgVel), abs(bwdAvgVel), accuracy: 0.1,
                       "Only quadrature polarity should flip; the same carrier frequency must produce the same rate magnitude in both directions")
    }

    // MARK: - 14. InvertDirection (via pipeline, not decoder)

    func testInvertDirectionAppliedOnce() {
        // The decoder itself does not invert — direction comes from raw
        // phase offset. invertDirection is applied in TimecodeControlPipeline
        // calibration (frame.velocity * sign, frame.direction.inverted).
        // This test confirms the decoder's raw direction is correct.
        let decoder = makeDecoder()

        let fwdInputs = makeStableDirectionInputs(
            bufferCount: 3, rightPhaseOffset: forwardPhaseRad
        )
        let fwdResult = decoder.decode(fwdInputs)
        XCTAssertTrue(fwdResult.frames.allSatisfy { $0.direction == .forward })

        let revInputs = makeStableDirectionInputs(
            bufferCount: 3, rightPhaseOffset: backwardPhaseRad
        )
        let revResult = decoder.decode(revInputs)
        XCTAssertTrue(revResult.frames.allSatisfy { $0.direction == .backward })
    }

    // MARK: - 15. Adapter preserves direction

    func testAdapterPreservesDirection() {
        let decoder = makeDecoder()
        let adapter = makeAdapter(minConfidence: 0.3)

        let fwdInputs = makeStableDirectionInputs(
            bufferCount: 5, rightPhaseOffset: forwardPhaseRad
        )
        let fwdResult = decoder.decode(fwdInputs)
        guard let fwdTimeline = adapter.adapt(fwdResult), fwdTimeline.samples.count >= 2 else {
            XCTFail("Forward frames should produce a timeline with at least two samples")
            return
        }
        XCTAssertGreaterThan(
            fwdTimeline.samples.last!.position, fwdTimeline.samples.first!.position,
            "Position must actually increase for forward motion, not merely produce a non-nil timeline"
        )

        let revInputs = makeStableDirectionInputs(
            bufferCount: 5, rightPhaseOffset: backwardPhaseRad
        )
        let revResult = decoder.decode(revInputs)
        guard let revTimeline = adapter.adapt(revResult), revTimeline.samples.count >= 2 else {
            XCTFail("Backward frames should produce a timeline with at least two samples")
            return
        }
        XCTAssertLessThan(
            revTimeline.samples.last!.position, revTimeline.samples.first!.position,
            "Position must actually decrease for backward motion, not merely produce a non-nil timeline"
        )
    }

    // MARK: - 16. Adapter drops low-confidence samples

    func testAdapterDropsLowConfidenceSamples() {
        // Deterministic constructed frames straddling the threshold, rather
        // than decoded synthetic audio whose confidence could land anywhere
        // — this proves the adapter actually filters, instead of merely
        // tolerating whatever the decoder happened to produce.
        let confidences: [Double] = [0.95, 0.85, 0.92, 0.5, 0.99]
        let frames = confidences.enumerated().map { (index, confidence) in
            TimecodeDecodedFrame(
                hostTime: nil,
                relativeTime: TimeInterval(index) * timePerBuffer,
                position: 0,
                deltaPosition: 0.01,
                velocity: 1,
                direction: .forward,
                confidence: confidence
            )
        }
        let result = TimecodeDecodeResult(
            frames: frames,
            averageConfidence: confidences.reduce(0, +) / Double(confidences.count),
            signalHealth: .usable,
            dropoutReason: nil,
            counters: .init()
        )
        let adapter = makeAdapter(minConfidence: 0.9)

        guard let timeline = adapter.adapt(result) else {
            XCTFail("Three of the five constructed frames meet minConfidence and must produce a timeline")
            return
        }

        XCTAssertEqual(
            timeline.samples.count, 3,
            "Only the 0.95/0.92/0.99-confidence frames should survive a 0.9 threshold, got \(timeline.samples.count)"
        )
        for sample in timeline.samples {
            XCTAssertGreaterThanOrEqual(sample.confidence, 0.9, "All surviving samples must meet minConfidence")
        }
    }

    // MARK: - 17. Adapter clamps extreme rates

    func testAdapterClampsExtremeRate() {
        let decoder = makeDecoder()
        // Low maxRate forces clamping.
        let adapter = makeAdapter(minConfidence: 0.3, maxRate: 2.0)

        // 8x nominal carrier frequency decodes to velocity ≈ 8.0, well above
        // the adapter's 2.0 clamp.
        let inputs = makeStableDirectionInputs(bufferCount: 5, frequency: 8000, rightPhaseOffset: forwardPhaseRad)
        let result = decoder.decode(inputs)

        guard let timeline = adapter.adapt(result), !timeline.samples.isEmpty else {
            XCTFail("A clean, high-confidence 8x carrier must produce a timeline")
            return
        }

        for sample in timeline.samples {
            XCTAssertTrue(sample.position.isFinite, "Position must be finite")
            XCTAssertTrue(sample.confidence.isFinite, "Confidence must be finite")
        }

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

    // MARK: - 18. Adapter source label is .timecodeFixture

    func testAdapterSourceLabelIsTimecodeFixture() {
        let decoder = makeDecoder()
        let adapter = makeAdapter(minConfidence: 0.4)

        let inputs = makeStableDirectionInputs(bufferCount: 5, rightPhaseOffset: forwardPhaseRad)
        let result = decoder.decode(inputs)
        let timeline = adapter.adapt(result)

        XCTAssertNotNil(timeline, "Trusted frames should produce a timeline")
        XCTAssertEqual(timeline?.source, .timecodeFixture, "Adapter source must be .timecodeFixture")
    }

    // MARK: - 19. Adapter returns nil for an empty decode result

    func testAdapterReturnsNilForEmptyResult() {
        let adapter = makeAdapter()
        let emptyResult = TimecodeDecodeResult.empty(reason: .silence)

        let timeline = adapter.adapt(emptyResult)
        XCTAssertNil(timeline, "Adapter should return nil for empty decode result")
    }

    // MARK: - 20. Displacement uses the actual input audio duration

    func testDecoderUsesActualInputAudioDurationForDisplacement() throws {
        let decoder = makeDecoder()
        let input = makeStereoInput(
            rightPhaseOffset: forwardPhaseRad,
            relativeTime: 0
        )

        let frame = try XCTUnwrap(decoder.decode([input]).frames.first)
        XCTAssertEqual(
            frame.deltaPosition,
            frame.velocity * timePerBuffer,
            accuracy: 0.000_001,
            "Displacement must integrate velocity over the input's real 10 ms of audio"
        )
        XCTAssertNotEqual(
            frame.deltaPosition,
            frame.velocity * 0.1,
            accuracy: 0.000_001,
            "The decoder must not assume every source callback lasts 100 ms"
        )
    }

    // MARK: - 21. Adapter carries a starting position into the next timeline

    func testAdapterCarriesAStartingPositionIntoTheNextTimeline() throws {
        let frame = TimecodeDecodedFrame(
            hostTime: nil,
            relativeTime: 1,
            position: 0,
            deltaPosition: 0.25,
            velocity: 1,
            direction: .forward,
            confidence: 1
        )
        let result = TimecodeDecodeResult(
            frames: [frame],
            averageConfidence: 1,
            signalHealth: .usable,
            dropoutReason: nil,
            counters: .init()
        )

        let timeline = try XCTUnwrap(
            makeAdapter().adapt(result, startingPosition: 1.5)
        )
        let position = try XCTUnwrap(timeline.samples.first?.position)
        XCTAssertEqual(position, 1.75, accuracy: 0.000_001)
    }

    // MARK: - 22. Empty input produces empty result

    func testEmptyInputProducesEmptyResult() {
        let decoder = makeDecoder()
        let result = decoder.decode([])
        XCTAssertEqual(result.frames.count, 0)
        XCTAssertEqual(result.signalHealth, .noSignal)
        XCTAssertEqual(result.dropoutReason, .silence)
    }

    // MARK: - 23. Confidence decreases for weak (noise-degraded) signal

    func testConfidenceDecreasesForWeakInput() {
        let decoder = makeDecoder()

        let cleanInputs = makeStableDirectionInputs(
            bufferCount: 5, amplitude: 0.5, rightPhaseOffset: forwardPhaseRad
        )
        let cleanResult = decoder.decode(cleanInputs)

        // Degraded: contaminated with noise
        let degradedInputs: [TimecodePhaseDecoder.StereoInput] = (0..<5).map { i in
            let base = makeStereoInput(
                amplitude: 0.5, rightPhaseOffset: forwardPhaseRad,
                relativeTime: timePerBuffer * TimeInterval(i)
            )
            let noise = sineTone(
                frequency: 275, sampleRate: sampleRate,
                frameCount: framesPerBuffer, amplitude: 0.4
            )
            return TimecodePhaseDecoder.StereoInput(
                left: zip(base.left, noise).map(+),
                right: zip(base.right, noise).map(+),
                sampleRate: sampleRate,
                relativeTime: base.relativeTime
            )
        }
        let degradedResult = decoder.decode(degradedInputs)

        XCTAssertGreaterThan(cleanResult.frames.count, 0)
        XCTAssertGreaterThan(
            degradedResult.frames.count, 0,
            "The noise-contaminated signal must still phase-lock enough to compare confidence, not silently decode nothing"
        )
        XCTAssertGreaterThan(
            cleanResult.averageConfidence, degradedResult.averageConfidence,
            "Clean signal confidence (\(cleanResult.averageConfidence)) should exceed noise-degraded signal confidence (\(degradedResult.averageConfidence))"
        )
    }

    // MARK: - 24. Channel imbalance lowers confidence

    func testDecoderChannelImbalanceLowersConfidence() {
        let decoder = makeDecoder()

        let balancedInputs = makeStableDirectionInputs(
            bufferCount: 5, amplitude: 0.5, rightPhaseOffset: forwardPhaseRad
        )
        let balancedResult = decoder.decode(balancedInputs)

        // Imbalanced input: left channel normal, right channel weak. Distinct
        // from testConfidenceDecreasesForWeakInput (noise contamination) —
        // this exercises the channel-balance term of the confidence formula.
        var imbalancedInputs: [TimecodePhaseDecoder.StereoInput] = []
        for i in 0..<5 {
            let left = sineTone(
                frequency: carrierFrequency, sampleRate: sampleRate,
                frameCount: framesPerBuffer, amplitude: 0.5
            )
            let right = sineTone(
                frequency: carrierFrequency, sampleRate: sampleRate,
                frameCount: framesPerBuffer, amplitude: 0.05,
                phaseOffset: forwardPhaseRad
            )
            imbalancedInputs.append(TimecodePhaseDecoder.StereoInput(
                left: left, right: right,
                sampleRate: sampleRate,
                relativeTime: TimeInterval(i) * timePerBuffer
            ))
        }
        let imbalancedResult = decoder.decode(imbalancedInputs)

        XCTAssertGreaterThan(balancedResult.frames.count, 0)
        XCTAssertGreaterThan(
            imbalancedResult.frames.count, 0,
            "The imbalanced signal must still phase-lock enough to compare confidence, not silently decode nothing"
        )
        XCTAssertGreaterThan(
            balancedResult.averageConfidence, imbalancedResult.averageConfidence,
            "Balanced confidence (\(balancedResult.averageConfidence)) should exceed imbalanced (\(imbalancedResult.averageConfidence))"
        )
    }

    // MARK: - 25. Counters correctly attribute drops vs. decodes within one mixed batch

    func testDecoderCountersTrackMixedDropsAndDecodes() {
        let decoder = makeDecoder()
        var inputs: [TimecodePhaseDecoder.StereoInput] = []
        inputs.append(makeSilentInput(relativeTime: 0))
        inputs.append(makeSilentInput(relativeTime: timePerBuffer))
        inputs.append(contentsOf: (0..<3).map { i in
            makeStereoInput(
                rightPhaseOffset: forwardPhaseRad,
                relativeTime: TimeInterval(i + 2) * timePerBuffer
            )
        })

        let result = decoder.decode(inputs)

        XCTAssertEqual(result.counters.droppedSilence, 2, "Two silent inputs should be counted")
        XCTAssertEqual(result.counters.decodedSamples, 3, "Three valid inputs should be decoded")
        XCTAssertEqual(result.frames.count, 3, "Each decoded input produces one frame")
        XCTAssertGreaterThan(result.counters.maxAbsRate, 0, "Max rate should be positive for forward motion")
    }

    // MARK: - 26. Correlation gate is amplitude-independent
    //
    // Guards a real historical bug: before a units fix, `extractPhaseDelta`
    // compared a raw fitted carrier *amplitude* against an absolute
    // threshold rather than a true amplitude-independent goodness-of-fit, so
    // a realistic ~0.033 RMS DVS line-level signal (matching a real Rane
    // hardware snapshot) never cleared the gate regardless of how cleanly it
    // phase-locked.

    func testCorrelationGateIsAmplitudeIndependent() {
        let decoder = makeDecoder()
        let loudInputs = makeStableDirectionInputs(
            bufferCount: 10, amplitude: 0.5, rightPhaseOffset: forwardPhaseRad
        )
        let quietInputs = makeStableDirectionInputs(
            bufferCount: 10, amplitude: 0.033, rightPhaseOffset: forwardPhaseRad
        )

        let loudResult = decoder.decode(loudInputs)
        let quietResult = decoder.decode(quietInputs)

        XCTAssertGreaterThan(loudResult.frames.count, 0)
        XCTAssertGreaterThan(quietResult.frames.count, 0,
            "A quiet but clean signal must decode just as reliably as a loud one")
        XCTAssertNotEqual(quietResult.dropoutReason, .noPhaseLock)
        XCTAssertEqual(quietResult.signalHealth, .usable)

        // Amplitude independence means the two must actually match, not just
        // both individually clear zero — same accepted-frame count, and
        // confidence within a tight tolerance. Both signals sit well above
        // the signal-level-score ceiling (10x silenceThresholdRMS = 0.01
        // RMS; loud ≈0.354 RMS, quiet ≈0.023 RMS), so `levelScore` saturates
        // to 1.0 for both and `channelBalance` is ≈1.0 for both (identical
        // L/R amplitude) — the only remaining term, `correlationMagnitude`,
        // is the normalized goodness-of-fit this test exists to prove is
        // amplitude-independent, so it should differ only by floating-point
        // noise.
        XCTAssertEqual(
            loudResult.frames.count, quietResult.frames.count,
            "Loud and quiet accepted-frame counts must match — amplitude alone must not change how many windows decode"
        )
        XCTAssertEqual(
            loudResult.averageConfidence, quietResult.averageConfidence, accuracy: 0.05,
            "Loud (\(loudResult.averageConfidence)) and quiet (\(quietResult.averageConfidence)) confidence must match within a tight tolerance, not merely both exceed zero"
        )
    }

    // MARK: - 27. Mismatched frequency still rejected at the same realistic amplitude
    //
    // Companion to the amplitude-independence test above: proves the fix
    // corrected the units without loosening or disabling the gate — a right
    // channel with no real carrier at the reference frequency must still be
    // rejected at the exact amplitude the true quadrature pair passes at.

    func testMismatchedFrequencyStillRejectedAtSameRealisticAmplitude() {
        let decoder = makeDecoder()
        let amplitude: Float = 0.033
        let otherFrequency: Float = 200   // unrelated to the 1 kHz carrier

        let inputs = (0..<10).map { i -> TimecodePhaseDecoder.StereoInput in
            let relativeTime = TimeInterval(i) * timePerBuffer
            let left = sineTone(
                frequency: carrierFrequency, sampleRate: sampleRate,
                frameCount: framesPerBuffer, amplitude: amplitude
            )
            let right = sineTone(
                frequency: otherFrequency, sampleRate: sampleRate,
                frameCount: framesPerBuffer, amplitude: amplitude
            )
            return TimecodePhaseDecoder.StereoInput(
                left: left, right: right,
                sampleRate: sampleRate, relativeTime: relativeTime
            )
        }

        let result = decoder.decode(inputs)

        XCTAssertEqual(result.frames.count, 0,
            "A right channel with no real carrier at the reference frequency must still be rejected, even at an amplitude the true quadrature pair passes")
        XCTAssertEqual(result.dropoutReason, .noPhaseLock)
    }
}
