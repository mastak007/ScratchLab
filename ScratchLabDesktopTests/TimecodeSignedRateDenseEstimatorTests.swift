import XCTest
@testable import ScratchLab

final class TimecodeSignedRateDenseEstimatorTests: XCTestCase {

    // MARK: - Synthetic quadrature signal generation
    //
    // A physically-consistent two-channel quadrature pair is generated from
    // a single instantaneous phase function θ(t): left = A cos θ(t),
    // right = A sin θ(t). Reversing direction is modeled as θ'(t) changing
    // sign (not as a phase-relationship flip), which is what a genuine
    // platter direction reversal does to a real two-channel carrier.

    private let sampleRate: Double = 44_100
    private let amplitude: Double = 0.5

    private func makeEstimator(
        nominalCarrierFrequency: Double = 1_000,
        minimumCarrierFrequency: Double = 50,
        maximumNormalizedSpeed: Double = 20,
        silenceEnvelopeFloor: Double = 0.001,
        envelopeTimeConstant: TimeInterval = 0.002,
        directionAmbiguityFraction: Double = 0.15
    ) -> TimecodeSignedRateDenseEstimator {
        TimecodeSignedRateDenseEstimator(configuration: .init(
            nominalCarrierFrequency: nominalCarrierFrequency,
            minimumCarrierFrequency: minimumCarrierFrequency,
            maximumNormalizedSpeed: maximumNormalizedSpeed,
            silenceEnvelopeFloor: silenceEnvelopeFloor,
            envelopeTimeConstant: envelopeTimeConstant,
            directionAmbiguityFraction: directionAmbiguityFraction
        ))
    }

    /// `angularVelocity(frameIndex)` in radians/sample; θ(n) is its running
    /// sum. Returns full-stream left/right arrays plus per-frame θ for
    /// reference, so callers can build one or many
    /// `TimecodeSignedRateDenseEstimatorInputBlock`s over the same
    /// underlying continuous waveform.
    private func synthesize(
        frameCount: Int,
        angularVelocity: (Int) -> Double
    ) -> (left: [Float], right: [Float]) {
        var left = [Float](repeating: 0, count: frameCount)
        var right = [Float](repeating: 0, count: frameCount)
        var theta = 0.0
        for i in 0..<frameCount {
            left[i] = Float(amplitude * cos(theta))
            right[i] = Float(amplitude * sin(theta))
            theta += angularVelocity(i)
        }
        return (left, right)
    }

    private func constantOmega(frequency: Double) -> Double {
        2 * Double.pi * frequency / sampleRate
    }

    /// Same phase-integration model as `synthesize`, but with a caller-
    /// supplied per-frame amplitude instead of the fixed `amplitude`
    /// constant — needed to exercise the envelope tracker under
    /// time-varying amplitude, which constant-amplitude fixtures cannot.
    private func synthesizeVariableAmplitude(
        frameCount: Int,
        angularVelocity: (Int) -> Double,
        amplitude: (Int) -> Double
    ) -> (left: [Float], right: [Float]) {
        var left = [Float](repeating: 0, count: frameCount)
        var right = [Float](repeating: 0, count: frameCount)
        var theta = 0.0
        for i in 0..<frameCount {
            let a = amplitude(i)
            left[i] = Float(a * cos(theta))
            right[i] = Float(a * sin(theta))
            theta += angularVelocity(i)
        }
        return (left, right)
    }

    private func blocks(
        left: [Float], right: [Float], chunkSize: Int, startFrameIndex: Int = 0
    ) -> [TimecodeSignedRateDenseEstimatorInputBlock] {
        var result: [TimecodeSignedRateDenseEstimatorInputBlock] = []
        var offset = 0
        while offset < left.count {
            let count = min(chunkSize, left.count - offset)
            result.append(TimecodeSignedRateDenseEstimatorInputBlock(
                left: Array(left[offset..<offset + count]),
                right: Array(right[offset..<offset + count]),
                sampleRate: sampleRate,
                startFrameIndex: startFrameIndex + offset
            ))
            offset += count
        }
        return result
    }

    // MARK: - 1. Steady one-way motion produces dense, stable signed output

    func testSteadyOneWayMotionProducesDenseStableSignedOutput() {
        let omega = constantOmega(frequency: 1_000)
        let frameCount = 4_410 // 0.1s
        let (left, right) = synthesize(frameCount: frameCount) { _ in omega }

        var estimator = makeEstimator()
        var allSamples: [TimecodeSignedRateSample] = []
        for block in blocks(left: left, right: right, chunkSize: 512) {
            allSamples.append(contentsOf: estimator.consume(block).samples)
        }

        let duration = Double(frameCount) / sampleRate
        let density = Double(allSamples.count) / duration
        XCTAssertGreaterThan(density, 1_000, "Dense output should exceed the ~10-43Hz windowed-decoder baseline by orders of magnitude")

        let available = allSamples.filter { $0.signalState == .available }
        XCTAssertGreaterThan(available.count, allSamples.count / 2)
        for sample in available {
            XCTAssertEqual(sample.signedRate, 1.0, accuracy: 0.05)
        }
    }

    // MARK: - 2. Forward and backward signs remain distinct

    func testForwardAndBackwardSignsRemainDistinct() {
        let omega = constantOmega(frequency: 1_000)

        let (fwdLeft, fwdRight) = synthesize(frameCount: 2_205) { _ in omega }
        var forwardEstimator = makeEstimator()
        let forwardSamples = blocks(left: fwdLeft, right: fwdRight, chunkSize: 512)
            .flatMap { forwardEstimator.consume($0).samples }
        let forwardAvailable = forwardSamples.filter { $0.signalState == .available }
        XCTAssertFalse(forwardAvailable.isEmpty)
        XCTAssertTrue(forwardAvailable.allSatisfy { $0.signedRate > 0 })

        let (bwdLeft, bwdRight) = synthesize(frameCount: 2_205) { _ in -omega }
        var backwardEstimator = makeEstimator()
        let backwardSamples = blocks(left: bwdLeft, right: bwdRight, chunkSize: 512)
            .flatMap { backwardEstimator.consume($0).samples }
        let backwardAvailable = backwardSamples.filter { $0.signalState == .available }
        XCTAssertFalse(backwardAvailable.isEmpty)
        XCTAssertTrue(backwardAvailable.allSatisfy { $0.signedRate < 0 })
    }

    // MARK: - 3. Legitimate rapid reversals remain observable

    func testRapidReversalWithinASingleProductionWindowRemainsObservable() {
        // 20ms total, well inside a single 1024-frame (~23ms) decode window
        // used elsewhere in this repo's offline audits — the whole point of
        // "dense" is to observe motion a coarse per-window decoder discards.
        let omega = constantOmega(frequency: 1_000)
        let totalFrames = Int(0.020 * sampleRate)
        let reversalFrame = totalFrames / 2
        let (left, right) = synthesize(frameCount: totalFrames) { i in
            i < reversalFrame ? omega : -omega
        }

        var estimator = makeEstimator()
        let samples = blocks(left: left, right: right, chunkSize: totalFrames)
            .flatMap { estimator.consume($0).samples }
        let available = samples.filter { $0.signalState == .available }

        XCTAssertTrue(available.contains { $0.signedRate > 0 })
        XCTAssertTrue(available.contains { $0.signedRate < 0 })

        // The direction observed late in the stream must be negative and
        // the direction observed early must be positive — proving the
        // reversal itself was tracked, not just that both signs appear.
        guard let firstAvailable = available.first, let lastAvailable = available.last else {
            return XCTFail("Expected available samples on both sides of the reversal")
        }
        XCTAssertGreaterThan(firstAvailable.signedRate, 0)
        XCTAssertLessThan(lastAvailable.signedRate, 0)
    }

    // MARK: - 4. Stop/catch and needle-lift intervals do not fabricate motion

    func testSilentIntervalReportsNoSignalWithoutFabricatingMotion() {
        let omega = constantOmega(frequency: 1_000)
        let (motionLeft, motionRight) = synthesize(frameCount: 2_205) { _ in omega }
        let silence = (left: [Float](repeating: 0, count: 2_205), right: [Float](repeating: 0, count: 2_205))

        var estimator = makeEstimator()
        let motionBlocks = blocks(left: motionLeft, right: motionRight, chunkSize: 512)
        for block in motionBlocks {
            _ = estimator.consume(block)
        }

        let nextStart = motionBlocks.reduce(0) { max($0, $1.startFrameIndex + $1.frameCount) }
        let silentBlock = TimecodeSignedRateDenseEstimatorInputBlock(
            left: silence.left, right: silence.right,
            sampleRate: sampleRate, startFrameIndex: nextStart
        )
        let result = estimator.consume(silentBlock)

        XCTAssertEqual(result.status, .processed)
        XCTAssertEqual(result.samples.count, 1)
        XCTAssertEqual(result.samples.first?.signalState, .noSignal)
        XCTAssertEqual(result.samples.first?.signedRate, 0)
    }

    // MARK: - 5. Irregular timing uses actual elapsed time

    func testIrregularBlockChunkingUsesActualElapsedTimeNotBlockCount() {
        let omega = constantOmega(frequency: 1_000)
        let frameCount = 4_410
        let (left, right) = synthesize(frameCount: frameCount) { _ in omega }

        var evenEstimator = makeEstimator()
        let evenSamples = blocks(left: left, right: right, chunkSize: 441)
            .flatMap { evenEstimator.consume($0).samples }

        var irregularEstimator = makeEstimator()
        let irregularChunks: [Int] = [37, 903, 5, 1_200, 40, 2_225]
        var irregularBlocks: [TimecodeSignedRateDenseEstimatorInputBlock] = []
        var offset = 0
        for size in irregularChunks {
            let count = min(size, frameCount - offset)
            guard count > 0 else { break }
            irregularBlocks.append(TimecodeSignedRateDenseEstimatorInputBlock(
                left: Array(left[offset..<offset + count]),
                right: Array(right[offset..<offset + count]),
                sampleRate: sampleRate, startFrameIndex: offset
            ))
            offset += count
        }
        let irregularSamples = irregularBlocks.flatMap { irregularEstimator.consume($0).samples }

        let evenAvailable = evenSamples.filter { $0.signalState == .available }
        let irregularAvailable = irregularSamples.filter { $0.signalState == .available }

        // Chunking is an implementation detail of the caller, not a source
        // of real elapsed time; both chunkings observe the same underlying
        // continuous waveform and must produce the same crossing timestamps
        // and rates regardless of how the caller sliced it into blocks.
        XCTAssertEqual(evenAvailable.count, irregularAvailable.count)
        for (evenSample, irregularSample) in zip(evenAvailable, irregularAvailable) {
            XCTAssertEqual(evenSample.timestamp, irregularSample.timestamp, accuracy: 1e-9)
            XCTAssertEqual(evenSample.signedRate, irregularSample.signedRate, accuracy: 1e-9)
        }
    }

    // MARK: - 6. Block boundaries preserve valid continuity

    func testBlockBoundariesPreserveValidContinuityAgainstSingleBlockBaseline() {
        let omega = constantOmega(frequency: 1_000)
        let frameCount = 4_410
        let (left, right) = synthesize(frameCount: frameCount) { _ in omega }

        var singleBlockEstimator = makeEstimator()
        let singleBlockResult = singleBlockEstimator.consume(
            TimecodeSignedRateDenseEstimatorInputBlock(
                left: left, right: right, sampleRate: sampleRate, startFrameIndex: 0
            )
        )

        // Extreme chunking: one sample per block, forcing every crossing to
        // straddle a block boundary.
        var perSampleEstimator = makeEstimator()
        var perSampleSamples: [TimecodeSignedRateSample] = []
        for i in 0..<frameCount {
            let block = TimecodeSignedRateDenseEstimatorInputBlock(
                left: [left[i]], right: [right[i]], sampleRate: sampleRate, startFrameIndex: i
            )
            perSampleSamples.append(contentsOf: perSampleEstimator.consume(block).samples)
        }

        XCTAssertEqual(singleBlockResult.samples.count, perSampleSamples.count)
        for (whole, perSample) in zip(singleBlockResult.samples, perSampleSamples) {
            XCTAssertEqual(whole.timestamp, perSample.timestamp, accuracy: 1e-9)
            XCTAssertEqual(whole.signedRate, perSample.signedRate, accuracy: 1e-9)
            XCTAssertEqual(whole.signalState, perSample.signalState)
        }
        XCTAssertGreaterThan(singleBlockResult.samples.count, 0)
    }

    // MARK: - 7. Dropouts reset or suspend evidence without extrapolation

    func testGapAfterMotionSuspendsEvidenceWithoutExtrapolatingAcrossIt() {
        let omega = constantOmega(frequency: 1_000)
        let (left, right) = synthesize(frameCount: 2_205) { _ in omega }

        var estimator = makeEstimator()
        var lastEnd = 0
        for block in blocks(left: left, right: right, chunkSize: 512) {
            _ = estimator.consume(block)
            lastEnd = block.startFrameIndex + block.frameCount
        }

        // Jump far ahead (a real gap), then supply under one full carrier
        // cycle of fresh motion — too little to have produced two
        // same-channel crossings on its own, so any resulting sample would
        // only be possible by illegitimately reusing a pre-gap crossing
        // timestamp across the gap.
        let gapFrames = 20_000
        let freshFrameCount = 15 // well under one 44.1 cycle at 1kHz
        let (freshLeft, freshRight) = synthesize(frameCount: freshFrameCount) { _ in omega }
        let postGapStart = lastEnd + gapFrames
        let postGapBlock = TimecodeSignedRateDenseEstimatorInputBlock(
            left: freshLeft, right: freshRight, sampleRate: sampleRate, startFrameIndex: postGapStart
        )
        let result = estimator.consume(postGapBlock)

        guard case .gapDetected(let duration) = result.status else {
            return XCTFail("Expected a detected gap, got \(result.status)")
        }
        XCTAssertEqual(duration, Double(gapFrames) / sampleRate, accuracy: 1e-9)
        XCTAssertTrue(
            result.samples.isEmpty,
            "No sample should be produced from evidence spanning a detected gap: \(result.samples)"
        )
    }

    // MARK: - 8. Non-finite and non-monotonic input fails safely

    func testNonFiniteSamplesFailSafely() {
        for invalidValue: Float in [.nan, .infinity, -.infinity] {
            var estimator = makeEstimator()
            var left = [Float](repeating: 0.1, count: 8)
            left[3] = invalidValue
            let block = TimecodeSignedRateDenseEstimatorInputBlock(
                left: left, right: [Float](repeating: 0.1, count: 8),
                sampleRate: sampleRate, startFrameIndex: 0
            )
            let result = estimator.consume(block)
            XCTAssertEqual(result.status, .invalidBlock)
            XCTAssertTrue(result.samples.isEmpty)
        }
    }

    func testNonMonotonicFrameIndexFailsSafely() {
        let omega = constantOmega(frequency: 1_000)
        let (left, right) = synthesize(frameCount: 1_024) { _ in omega }

        var estimator = makeEstimator()
        let first = TimecodeSignedRateDenseEstimatorInputBlock(
            left: left, right: right, sampleRate: sampleRate, startFrameIndex: 100
        )
        _ = estimator.consume(first)

        let rewound = TimecodeSignedRateDenseEstimatorInputBlock(
            left: left, right: right, sampleRate: sampleRate, startFrameIndex: 50
        )
        let result = estimator.consume(rewound)
        XCTAssertEqual(result.status, .nonMonotonicFrameIndex)
        XCTAssertTrue(result.samples.isEmpty)

        // Recovery: a fresh, forward-only stream afterward is accepted
        // rather than permanently wedged.
        let recovery = TimecodeSignedRateDenseEstimatorInputBlock(
            left: left, right: right, sampleRate: sampleRate, startFrameIndex: 0
        )
        XCTAssertEqual(estimator.consume(recovery).status, .processed)
    }

    // MARK: - 8b. Non-monotonic rejection does not leak a stale envelope into recovery

    func testNonMonotonicFrameIndexAfterHighAmplitudeMotionDoesNotInheritStaleEnvelopeOrFabricateDirection() {
        let omega = constantOmega(frequency: 1_000)
        let (loudLeft, loudRight) = synthesize(frameCount: 4_410) { _ in omega } // amplitude 0.5

        var estimator = makeEstimator()
        for block in blocks(left: loudLeft, right: loudRight, chunkSize: 512) {
            _ = estimator.consume(block)
        }

        // An overlapping/rewound block breaks stream continuity exactly like
        // a forward gap does, and per this fix must be rejected without
        // leaving the loud pre-error envelope alive for whatever unrelated
        // frame origin the next accepted recovery stream happens to use.
        let rewound = TimecodeSignedRateDenseEstimatorInputBlock(
            left: loudLeft, right: loudRight, sampleRate: sampleRate, startFrameIndex: 10
        )
        let rejection = estimator.consume(rewound)
        XCTAssertEqual(rejection.status, .nonMonotonicFrameIndex)
        XCTAssertTrue(rejection.samples.isEmpty)

        // A short fresh recovery stream, deliberately much shorter than the
        // envelope time constant, so a leftover pre-error envelope (the bug)
        // could barely move under the old per-call blend and would mask
        // honest no-signal reporting.
        let recoveryFrameCount = 8
        let silentRecovery = TimecodeSignedRateDenseEstimatorInputBlock(
            left: [Float](repeating: 0, count: recoveryFrameCount),
            right: [Float](repeating: 0, count: recoveryFrameCount),
            sampleRate: sampleRate, startFrameIndex: 0
        )
        let recoveryResult = estimator.consume(silentRecovery)
        XCTAssertEqual(recoveryResult.status, .processed)
        XCTAssertFalse(
            recoveryResult.samples.contains { $0.signalState == .available },
            "Fresh recovery evidence must never report an available direction inherited from a pre-rejection envelope"
        )
        XCTAssertEqual(
            recoveryResult.samples.count, 1,
            "A short fresh silent recovery block must honestly report no signal from its own evidence, not silently drop to empty output because a pre-rejection envelope survived"
        )
        XCTAssertEqual(recoveryResult.samples.first?.signalState, .noSignal)
        XCTAssertEqual(recoveryResult.samples.first?.signedRate, 0)
    }

    func testInvalidConfigurationFailsSafely() {
        var estimator = TimecodeSignedRateDenseEstimator(configuration: .init(
            nominalCarrierFrequency: -1
        ))
        let block = TimecodeSignedRateDenseEstimatorInputBlock(
            left: [0.1, -0.1, 0.1], right: [0.1, 0.1, -0.1],
            sampleRate: sampleRate, startFrameIndex: 0
        )
        let result = estimator.consume(block)
        XCTAssertEqual(result.status, .invalidConfiguration)
        XCTAssertTrue(result.samples.isEmpty)
    }

    // MARK: - 9. Identical input produces identical output

    func testIdenticalInputProducesIdenticalOutput() {
        let omega = constantOmega(frequency: 1_000)
        let totalFrames = Int(0.030 * sampleRate)
        let reversalFrame = totalFrames / 3
        let (left, right) = synthesize(frameCount: totalFrames) { i in
            i < reversalFrame ? omega : -omega
        }
        let inputBlocks = blocks(left: left, right: right, chunkSize: 400)

        var first = makeEstimator()
        let firstRun = inputBlocks.map { first.consume($0) }

        var second = makeEstimator()
        let secondRun = inputBlocks.map { second.consume($0) }

        XCTAssertEqual(firstRun, secondRun)
    }

    // MARK: - 10. Dense output can feed the excursion stabilizer offline

    func testDenseOutputFeedsExcursionStabilizerOfflineWithoutTouchingProduction() {
        let omega = constantOmega(frequency: 1_000)
        let totalFrames = Int(0.050 * sampleRate)
        let reversalFrame = totalFrames / 2
        let (left, right) = synthesize(frameCount: totalFrames) { i in
            i < reversalFrame ? omega : -omega
        }

        var estimator = makeEstimator()
        let denseSamples = blocks(left: left, right: right, chunkSize: 512)
            .flatMap { estimator.consume($0).samples }
        XCTAssertFalse(denseSamples.isEmpty)

        var stabilizer = TimecodeSignedRateExcursionStabilizer(configuration: .init(
            reversalAreaThreshold: 0.001,
            maximumIntegrationGap: 0.05
        ))

        var sawReversal = false
        for sample in denseSamples {
            if case .reversal = stabilizer.consume(sample) {
                sawReversal = true
            }
        }
        XCTAssertTrue(sawReversal, "Dense estimator output should be directly consumable by the offline stabilizer")
    }

    // MARK: - 11. Variable-amplitude chunking invariance (exposes the former block-dependent RMS blend)

    func testVariableAmplitudeContinuousWaveformProducesIdenticalOutputRegardlessOfBlockChunking() {
        let omega = constantOmega(frequency: 1_000)
        let frameCount = 4_410 // 0.1s
        // Amplitude varies smoothly within and across arbitrary block
        // boundaries. Every other chunking-invariance test in this file
        // uses constant amplitude, which cannot expose a block-dependent
        // envelope smoothing formula: the old implementation blended a
        // block-aggregate RMS once per call using that call's own block
        // duration, producing different envelope trajectories (and
        // therefore different ambiguity-floor decisions) for the same
        // underlying audio depending on how it was chunked.
        let amplitude: (Int) -> Double = { i in 0.3 + 0.2 * sin(2 * Double.pi * Double(i) / 900.0) }
        let (left, right) = synthesizeVariableAmplitude(
            frameCount: frameCount, angularVelocity: { _ in omega }, amplitude: amplitude
        )

        var oneBlockEstimator = makeEstimator()
        let oneBlockSamples = oneBlockEstimator.consume(
            TimecodeSignedRateDenseEstimatorInputBlock(
                left: left, right: right, sampleRate: sampleRate, startFrameIndex: 0
            )
        ).samples

        var irregularEstimator = makeEstimator()
        let irregularChunkSizes: [Int] = [17, 401, 3, 900, 55, 2_000, 1_034]
        var irregularBlocks: [TimecodeSignedRateDenseEstimatorInputBlock] = []
        var offset = 0
        for size in irregularChunkSizes {
            guard offset < frameCount else { break }
            let count = min(size, frameCount - offset)
            irregularBlocks.append(TimecodeSignedRateDenseEstimatorInputBlock(
                left: Array(left[offset..<offset + count]),
                right: Array(right[offset..<offset + count]),
                sampleRate: sampleRate, startFrameIndex: offset
            ))
            offset += count
        }
        let irregularSamples = irregularBlocks.flatMap { irregularEstimator.consume($0).samples }

        var perSampleEstimator = makeEstimator()
        var perSampleSamples: [TimecodeSignedRateSample] = []
        for i in 0..<frameCount {
            let block = TimecodeSignedRateDenseEstimatorInputBlock(
                left: [left[i]], right: [right[i]], sampleRate: sampleRate, startFrameIndex: i
            )
            perSampleSamples.append(contentsOf: perSampleEstimator.consume(block).samples)
        }

        XCTAssertGreaterThan(oneBlockSamples.count, 0)
        XCTAssertEqual(oneBlockSamples.count, irregularSamples.count)
        XCTAssertEqual(oneBlockSamples.count, perSampleSamples.count)

        for (whole, irregular) in zip(oneBlockSamples, irregularSamples) {
            XCTAssertEqual(whole.timestamp, irregular.timestamp, accuracy: 1e-9)
            XCTAssertEqual(whole.signedRate, irregular.signedRate, accuracy: 1e-9)
            XCTAssertEqual(whole.signalState, irregular.signalState)
        }
        for (whole, perSample) in zip(oneBlockSamples, perSampleSamples) {
            XCTAssertEqual(whole.timestamp, perSample.timestamp, accuracy: 1e-9)
            XCTAssertEqual(whole.signedRate, perSample.signedRate, accuracy: 1e-9)
            XCTAssertEqual(whole.signalState, perSample.signalState)
        }

        // Final estimator state (including the persisted envelope) must
        // also be identical, not just the emitted sample sequence.
        XCTAssertEqual(oneBlockEstimator, irregularEstimator)
        XCTAssertEqual(oneBlockEstimator, perSampleEstimator)
    }

    // MARK: - 12. A gap after established motion, followed by silence, classifies from fresh evidence

    func testGapAfterHighAmplitudeMotionFollowedByShortSilenceReportsHonestNoSignal() {
        let omega = constantOmega(frequency: 1_000)
        let (loudLeft, loudRight) = synthesize(frameCount: 4_410) { _ in omega } // amplitude 0.5

        var estimator = makeEstimator()
        var lastEnd = 0
        for block in blocks(left: loudLeft, right: loudRight, chunkSize: 512) {
            _ = estimator.consume(block)
            lastEnd = block.startFrameIndex + block.frameCount
        }

        let gapFrames = 50_000
        // Deliberately short: much shorter than the envelope time constant,
        // so a leftover pre-gap envelope that survived the gap reset (the
        // bug) would barely move under a per-call blend, staying well above
        // the silence floor and failing to report no-signal honestly.
        let shortSilenceFrameCount = 8
        let silence = (
            left: [Float](repeating: 0, count: shortSilenceFrameCount),
            right: [Float](repeating: 0, count: shortSilenceFrameCount)
        )
        let postGapStart = lastEnd + gapFrames
        let postGapBlock = TimecodeSignedRateDenseEstimatorInputBlock(
            left: silence.left, right: silence.right, sampleRate: sampleRate, startFrameIndex: postGapStart
        )
        let result = estimator.consume(postGapBlock)

        guard case .gapDetected = result.status else {
            return XCTFail("Expected a detected gap, got \(result.status)")
        }
        XCTAssertEqual(
            result.samples.count, 1,
            "A short post-gap silent block must honestly report no signal from its own fresh evidence, not silently drop to empty output because a pre-gap envelope survived the gap reset"
        )
        XCTAssertEqual(result.samples.first?.signalState, .noSignal)
        XCTAssertEqual(result.samples.first?.signedRate, 0)
        XCTAssertFalse(result.samples.contains { $0.signalState == .available })

        // A subsequent silent block must also classify honestly, not
        // continue to ride out a stale envelope.
        let secondSilentBlock = TimecodeSignedRateDenseEstimatorInputBlock(
            left: [Float](repeating: 0, count: 2_205), right: [Float](repeating: 0, count: 2_205),
            sampleRate: sampleRate, startFrameIndex: postGapStart + shortSilenceFrameCount
        )
        let secondResult = estimator.consume(secondSilentBlock)
        XCTAssertEqual(secondResult.status, .processed)
        XCTAssertEqual(secondResult.samples.count, 1)
        XCTAssertEqual(secondResult.samples.first?.signalState, .noSignal)
    }

    // MARK: - 13. A gap after established motion, followed by low-amplitude input, does not inherit stale envelope or fabricate direction

    func testGapAfterHighAmplitudeMotionFollowedByLowAmplitudeInputDoesNotInheritStaleEnvelopeOrFabricateDirection() {
        let omega = constantOmega(frequency: 1_000)
        let (loudLeft, loudRight) = synthesize(frameCount: 4_410) { _ in omega } // amplitude 0.5

        var estimator = makeEstimator()
        var lastEnd = 0
        for block in blocks(left: loudLeft, right: loudRight, chunkSize: 512) {
            _ = estimator.consume(block)
            lastEnd = block.startFrameIndex + block.frameCount
        }

        // Post-gap input is real but far too weak to trust on its own: its
        // own envelope sits below the configured silence floor. Honest
        // behavior is to classify it as no-signal from its own fresh
        // evidence, never by inheriting the loud pre-gap envelope across
        // the gap (which would relax the silence/ambiguity gates using
        // amplitude this signal never actually carries).
        let gapFrames = 60_000
        let weakAmplitude = 0.0003 // well below the 0.001 silence floor
        let (weakLeft, weakRight) = synthesizeVariableAmplitude(
            frameCount: 100, angularVelocity: { _ in omega }, amplitude: { _ in weakAmplitude }
        )

        let postGapStart = lastEnd + gapFrames
        let postGapBlock = TimecodeSignedRateDenseEstimatorInputBlock(
            left: weakLeft, right: weakRight, sampleRate: sampleRate, startFrameIndex: postGapStart
        )
        let result = estimator.consume(postGapBlock)

        guard case .gapDetected = result.status else {
            return XCTFail("Expected a detected gap, got \(result.status)")
        }
        XCTAssertFalse(
            result.samples.contains { $0.signalState == .available },
            "A signal far below the silence floor must never report an available direction, regardless of a loud pre-gap envelope"
        )
        XCTAssertEqual(
            result.samples.count, 1,
            "Weak post-gap evidence must classify as a single honest no-signal marker from its own envelope, not a series of ambiguous samples gated by a stale, inherited pre-gap envelope"
        )
        XCTAssertEqual(result.samples.first?.signalState, .noSignal)
    }

    // MARK: - 14. No-signal marker count/timestamp are intentionally block-shaped (narrowed, tested guarantee)

    func testNoSignalMarkerCountAndTimestampAreIntentionallyShapedByCallerChunking() {
        // Crossings/rate/direction/state and the persisted envelope are
        // chunking-invariant (see tests above), but no-signal marker count
        // and timestamp are not: one marker is emitted per consume() call
        // whose block is, in aggregate, below the silence floor, stamped at
        // that call's own startFrameIndex. This test pins that exact,
        // narrowed, documented shape rather than leaving it implicit.
        let silenceFrameCount = 4_410
        let silenceLeft = [Float](repeating: 0, count: silenceFrameCount)
        let silenceRight = [Float](repeating: 0, count: silenceFrameCount)

        var oneCallEstimator = makeEstimator()
        let oneCallSamples = oneCallEstimator.consume(
            TimecodeSignedRateDenseEstimatorInputBlock(
                left: silenceLeft, right: silenceRight, sampleRate: sampleRate, startFrameIndex: 0
            )
        ).samples
        XCTAssertEqual(oneCallSamples.count, 1)
        XCTAssertEqual(oneCallSamples.first?.timestamp ?? .nan, 0, accuracy: 1e-9)

        var twoCallEstimator = makeEstimator()
        let firstHalf = twoCallEstimator.consume(
            TimecodeSignedRateDenseEstimatorInputBlock(
                left: Array(silenceLeft[0..<2_205]), right: Array(silenceRight[0..<2_205]),
                sampleRate: sampleRate, startFrameIndex: 0
            )
        ).samples
        let secondHalf = twoCallEstimator.consume(
            TimecodeSignedRateDenseEstimatorInputBlock(
                left: Array(silenceLeft[2_205..<4_410]), right: Array(silenceRight[2_205..<4_410]),
                sampleRate: sampleRate, startFrameIndex: 2_205
            )
        ).samples

        XCTAssertEqual(firstHalf.count, 1)
        XCTAssertEqual(firstHalf.first?.timestamp ?? .nan, 0, accuracy: 1e-9)
        XCTAssertEqual(secondHalf.count, 1)
        XCTAssertEqual(secondHalf.first?.timestamp ?? .nan, Double(2_205) / sampleRate, accuracy: 1e-9)

        // Identical underlying silent span; the caller's chunking into one
        // versus two calls intentionally produces one versus two markers.
        XCTAssertEqual(oneCallSamples.count, 1)
        XCTAssertEqual(firstHalf.count + secondHalf.count, 2)
    }
}
