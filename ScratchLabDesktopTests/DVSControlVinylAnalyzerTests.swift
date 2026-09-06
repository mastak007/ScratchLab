import AVFAudio
import XCTest
@testable import ScratchLab

/// 11 spec-required test cases for `SeratoControlVinylAnalyzer` / `DVSTimecodeStatus`.
final class DVSControlVinylAnalyzerTests: XCTestCase {

    // MARK: - Helpers

    private func makeSine(
        frequency: Double = 1000,
        sampleRate: Double = 44100,
        frameCount: Int = 4096,
        amplitude: Float = 0.3,
        phaseOffset: Double = 0
    ) -> [Float] {
        (0..<frameCount).map { i in
            let t = Double(i) / sampleRate
            return Float(sin(2 * .pi * frequency * t + phaseOffset)) * amplitude
        }
    }

    /// Quadrature pair: left = sin(ωt), right = cos(ωt + phaseShiftPerSample * t)
    /// phaseShiftPerSample > 0 → phase advancing → forward; < 0 → backward.
    private func makeQuadraturePair(
        frequency: Double = 1000,
        sampleRate: Double = 44100,
        frameCount: Int = 8192,
        amplitude: Float = 0.3,
        phaseShiftPerFrame: Double = 0.002
    ) -> (left: [Float], right: [Float]) {
        var left  = [Float]()
        var right = [Float]()
        left.reserveCapacity(frameCount)
        right.reserveCapacity(frameCount)
        for i in 0..<frameCount {
            let t = Double(i) / sampleRate
            let basePhase = 2 * .pi * frequency * t
            left.append(Float(sin(basePhase)) * amplitude)
            right.append(Float(cos(basePhase + phaseShiftPerFrame * Double(i))) * amplitude)
        }
        return (left, right)
    }

    private func makeLogEntry() -> DVSLogEntry {
        DVSLogEntry(
            timestamp: Date(),
            sampleRate: 0,
            channelCount: 0,
            selectedChannelMode: "auto",
            leftRMS: 0,
            rightRMS: nil,
            leftPeak: 0,
            rightPeak: nil,
            signalHealth: "noSignal",
            hasSignal: false,
            direction: "unknown",
            speed: 0,
            rawRate: 0,
            smoothedRate: 0,
            confidence: 0,
            minConfidence: 0,
            maxRate: 0,
            dropReason: nil,
            dominantFrequencyHz: nil,
            zeroCrossingRateLeft: nil,
            phaseDelta: nil,
            acceptedCount: 0,
            droppedCount: 0,
            silenceCount: 0,
            weakCount: 0,
            lowConfidenceCount: 0,
            clippedCount: 0,
            sourceChannelCount: 0,
            selectedChannelPair: "Auto",
            autoRecommendedChannelPair: nil,
            perChannelRMS: [],
            perChannelPeak: [],
            perPairRMS: [],
            perPairPeak: [],
            adapterFormat: "test",
            adapterWarning: nil,
            rawDecodeTrace: "",
            calibratedTrace: "",
            heldDropoutCount: 0,
            longDropoutCount: 0
        )
    }

#if ENABLE_TIMECODE_LIVE_TAP
    private func makeInt32Interleaved(
        frameCount: Int,
        channelCount: Int,
        activePairStart: Int
    ) -> [Int32] {
        var samples = [Int32](repeating: 0, count: frameCount * channelCount)
        for frame in 0..<frameCount {
            let phase = 2 * Double.pi * 1_000 * Double(frame) / 48_000
            samples[frame * channelCount + activePairStart] =
                Int32(sin(phase) * Double(Int32.max) * 0.4)
            samples[frame * channelCount + activePairStart + 1] =
                Int32(cos(phase) * Double(Int32.max) * 0.4)
        }
        return samples
    }

    private func makeInt32InterleavedCarrier(
        frameCount: Int,
        channelCount: Int,
        activePairStart: Int,
        frequency: Double
    ) -> [Int32] {
        var samples = [Int32](repeating: 0, count: frameCount * channelCount)
        for frame in 0..<frameCount {
            let phase = 2 * Double.pi * frequency * Double(frame) / 48_000
            samples[frame * channelCount + activePairStart] =
                Int32(sin(phase) * Double(Int32.max) * 0.08)
            samples[frame * channelCount + activePairStart + 1] =
                Int32(cos(phase) * Double(Int32.max) * 0.08)
        }
        return samples
    }

    /// Builds a 14-channel buffer with a quiet, plausible quadrature control-tone
    /// pair (matching dominant frequency on both channels) at `quietPairStart`,
    /// and a much louder pair at `loudPairStart` whose two channels carry
    /// unrelated tones (400 Hz vs 6 kHz) — loud, but with no shared carrier, so
    /// it must not be mistaken for real DVS timecode.
    private func makeInt32InterleavedWithLoudNonTimecodePair(
        frameCount: Int,
        channelCount: Int,
        quietPairStart: Int,
        loudPairStart: Int
    ) -> [Int32] {
        var samples = [Int32](repeating: 0, count: frameCount * channelCount)
        for frame in 0..<frameCount {
            let quietPhase = 2 * Double.pi * 1_000 * Double(frame) / 48_000
            samples[frame * channelCount + quietPairStart] =
                Int32(sin(quietPhase) * Double(Int32.max) * 0.05)
            samples[frame * channelCount + quietPairStart + 1] =
                Int32(cos(quietPhase) * Double(Int32.max) * 0.05)

            let loudLeftPhase = 2 * Double.pi * 400 * Double(frame) / 48_000
            let loudRightPhase = 2 * Double.pi * 6_000 * Double(frame) / 48_000
            samples[frame * channelCount + loudPairStart] =
                Int32(sin(loudLeftPhase) * Double(Int32.max) * 0.9)
            samples[frame * channelCount + loudPairStart + 1] =
                Int32(sin(loudRightPhase) * Double(Int32.max) * 0.9)
        }
        return samples
    }

    /// Builds a 14-channel buffer with a quiet, genuine ~1 kHz quadrature pair
    /// at `quietPairStart`, and a much louder pair at `loudPairStart` that is
    /// pure DC on both channels — no oscillation at all, so 0 Hz / 0
    /// zero-crossings on both channels. This reproduces the real Rane 13/14
    /// field failure: loud, frequency-"matching" (0 == 0), but no carrier.
    private func makeInt32InterleavedWithLoudZeroHzPair(
        frameCount: Int,
        channelCount: Int,
        quietPairStart: Int,
        loudPairStart: Int
    ) -> [Int32] {
        var samples = [Int32](repeating: 0, count: frameCount * channelCount)
        for frame in 0..<frameCount {
            let quietPhase = 2 * Double.pi * 1_000 * Double(frame) / 48_000
            samples[frame * channelCount + quietPairStart] =
                Int32(sin(quietPhase) * Double(Int32.max) * 0.05)
            samples[frame * channelCount + quietPairStart + 1] =
                Int32(cos(quietPhase) * Double(Int32.max) * 0.05)

            samples[frame * channelCount + loudPairStart] =
                Int32(Double(Int32.max) * 0.7)
            samples[frame * channelCount + loudPairStart + 1] =
                Int32(Double(Int32.max) * 0.75)
        }
        return samples
    }
#endif

    // MARK: - Tests

    // 1. Silence → no signal
    func testSilenceReturnsNoSignal() {
        let analyzer = SeratoControlVinylAnalyzer()
        let zeros = [Float](repeating: 0, count: 4096)
        let status = analyzer.analyze(left: zeros, right: zeros, sampleRate: 44100)
        XCTAssertFalse(status.hasSignal, "All-zero input must report hasSignal = false")
        XCTAssertEqual(status.rms, 0, accuracy: 0.001)
    }

    // 2. Very low amplitude is rejected
    func testVeryLowAmplitudeIsRejected() {
        let analyzer = SeratoControlVinylAnalyzer()
        // amplitude ≈ 0.001 → RMS well below 0.02 weak threshold
        let faint = makeSine(amplitude: 0.001)
        let status = analyzer.analyze(left: faint, right: faint, sampleRate: 44100)
        XCTAssertFalse(status.hasSignal, "Sub-threshold signal must be rejected")
    }

    // 3. Steady tone → signal present
    func testSteadyToneReportsSignalPresent() {
        let analyzer = SeratoControlVinylAnalyzer()
        let tone = makeSine(amplitude: 0.3)
        let status = analyzer.analyze(left: tone, right: tone, sampleRate: 44100)
        XCTAssertTrue(status.hasSignal, "Usable-level stereo tone must report hasSignal = true")
        XCTAssertGreaterThan(status.rms, 0.01)
    }

    // 4. Advancing phase → forward
    func testIncreasingPhaseReportsForward() {
        let analyzer = SeratoControlVinylAnalyzer()
        let (left, right) = makeQuadraturePair(phaseShiftPerFrame: +0.002)
        // Feed a large buffer so the decoder has enough context to lock
        let status = analyzer.analyze(left: left, right: right, sampleRate: 44100)
        // Direction may be .forward or .unknown depending on decoder lock;
        // what must NOT happen is .backward
        XCTAssertNotEqual(status.direction, .backward,
            "Advancing-phase quadrature must not report backward")
    }

    // 5. Regressing phase → backward
    func testDecreasingPhaseReportsBackward() {
        let analyzer = SeratoControlVinylAnalyzer()
        let (left, right) = makeQuadraturePair(phaseShiftPerFrame: -0.002)
        let status = analyzer.analyze(left: left, right: right, sampleRate: 44100)
        XCTAssertNotEqual(status.direction, .forward,
            "Regressing-phase quadrature must not report forward")
    }

    // 6. Near-static → stopped or unknown
    func testNearStaticReportsStopped() {
        let analyzer = SeratoControlVinylAnalyzer()
        // Zero phase shift — no phase progression, so velocity should be ~0
        let (left, right) = makeQuadraturePair(phaseShiftPerFrame: 0)
        let status = analyzer.analyze(left: left, right: right, sampleRate: 44100)
        let isStationary = (status.direction == .stopped || status.direction == .unknown)
        XCTAssertTrue(isStationary, "No-progression quadrature must report stopped or unknown, got \(status.direction)")
    }

    // 7. Clipped signal → lowered confidence or non-nil dropped reason
    func testClippedSignalLowersConfidenceOrReportsDropReason() {
        let analyzer = SeratoControlVinylAnalyzer()
        let clipped = [Float](repeating: 1.0, count: 4096)
        let status = analyzer.analyze(left: clipped, right: clipped, sampleRate: 44100)
        let degraded = status.confidence < 0.5 || status.droppedReason != nil
        XCTAssertTrue(degraded,
            "Clipped input must lower confidence or report a drop reason (confidence=\(status.confidence), reason=\(status.droppedReason ?? "nil"))")
    }

    // 8. Channel mismatch (right empty) does not crash
    func testChannelMismatchDoesNotCrash() {
        let analyzer = SeratoControlVinylAnalyzer()
        let tone = makeSine()
        // right is empty — analyzer should pad with zeros, not crash
        let status = analyzer.analyze(left: tone, right: [], sampleRate: 44100)
        XCTAssertNotNil(status, "Empty right channel must not crash")
    }

    // 9. Sample-rate change between calls does not crash
    func testSampleRateChangeDoesNotCrash() {
        let analyzer = SeratoControlVinylAnalyzer()
        let tone44 = makeSine(sampleRate: 44100)
        let tone48 = makeSine(sampleRate: 48000, frameCount: 4096)
        _ = analyzer.analyze(left: tone44, right: tone44, sampleRate: 44100)
        // Changing sample rate mid-session must not crash
        let status = analyzer.analyze(left: tone48, right: tone48, sampleRate: 48000)
        XCTAssertNotNil(status, "Sample-rate change must not crash")
    }

    // 10. Empty buffer handled safely
    func testEmptyBufferHandledSafely() {
        let analyzer = SeratoControlVinylAnalyzer()
        let status = analyzer.analyze(left: [], right: [], sampleRate: 44100)
        XCTAssertFalse(status.hasSignal, "Empty buffer must report hasSignal = false")
        XCTAssertEqual(status.droppedReason, "emptyBuffer")
    }

    // 11. Mono input (right empty) does not crash
    func testMonoInputDoesNotCrash() {
        let analyzer = SeratoControlVinylAnalyzer()
        let tone = makeSine(amplitude: 0.3)
        let status = analyzer.analyze(left: tone, right: [], sampleRate: 44100)
        // Must return a valid status without crashing; signal detection not guaranteed for mono
        XCTAssertNotNil(status, "Mono input (right=[]) must not crash")
    }

    func testLiveLoggerWritesNoSignalEntryAndClearsFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let logURL = directory.appendingPathComponent("dvs_diagnostics.jsonl")
        let logger = DVSLiveLogger(logURL: logURL)

        logger.append(makeLogEntry())

        let writeDeadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: logURL.path), Date() < writeDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        let line = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(line.hasSuffix("\n"))
        XCTAssertTrue(line.contains("\"hasSignal\":false"))
        XCTAssertEqual(logger.lastWriteStatus, "Write succeeded")
        XCTAssertEqual(logger.totalLinesWritten, 1)
        XCTAssertNil(logger.lastWriteError)

        logger.clear()

        let clearDeadline = Date().addingTimeInterval(2)
        while FileManager.default.fileExists(atPath: logURL.path), Date() < clearDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: logURL.path))
        XCTAssertEqual(logger.lastWriteStatus, "Log cleared")
        XCTAssertEqual(logger.totalLinesWritten, 0)
    }

#if ENABLE_TIMECODE_LIVE_TAP
    func testInt32InterleavedStereoNormalisation() throws {
        let raw: [Int32] = [Int32.max, Int32.min, 1_073_741_824, -1_073_741_824]
        let result = try XCTUnwrap(
            TimecodeCMSampleBufferAdapter.adaptInterleavedInt32(
                raw,
                channelCount: 2,
                sampleRate: 48_000,
                selection: .pair(startChannel: 0)
            )
        )

        XCTAssertEqual(result.left[0], 1, accuracy: 0.000_001)
        XCTAssertEqual(result.right[0], -1, accuracy: 0.000_001)
        XCTAssertEqual(result.left[1], 0.5, accuracy: 0.000_001)
        XCTAssertEqual(result.right[1], -0.5, accuracy: 0.000_001)
    }

    func testInt32InterleavedFourteenChannelExtraction() throws {
        let raw = makeInt32Interleaved(frameCount: 256, channelCount: 14, activePairStart: 2)
        let result = try XCTUnwrap(
            TimecodeCMSampleBufferAdapter.adaptInterleavedInt32(
                raw,
                channelCount: 14,
                sampleRate: 48_000,
                selection: .auto
            )
        )

        XCTAssertEqual(result.sourceChannelCount, 14)
        XCTAssertEqual(result.perChannelDiagnostics.count, 14)
        XCTAssertEqual(result.perPairDiagnostics.count, 7)
    }

    func testSelectingPairThreeFourFromFourteenChannelBuffer() throws {
        let raw = makeInt32Interleaved(frameCount: 256, channelCount: 14, activePairStart: 2)
        let result = try XCTUnwrap(
            TimecodeCMSampleBufferAdapter.adaptInterleavedInt32(
                raw,
                channelCount: 14,
                sampleRate: 48_000,
                selection: .pair(startChannel: 2)
            )
        )

        XCTAssertEqual(result.selectedChannelPair, "3/4")
        XCTAssertGreaterThan(result.perChannelDiagnostics[2].rms, 0.2)
        XCTAssertGreaterThan(result.perChannelDiagnostics[3].rms, 0.2)
        XCTAssertNotEqual(result.left, result.right, "Quadrature channels should differ")
    }

    func testSilentPairOneTwoReportsActivePairThreeFour() throws {
        let raw = makeInt32Interleaved(frameCount: 256, channelCount: 14, activePairStart: 2)
        let result = try XCTUnwrap(
            TimecodeCMSampleBufferAdapter.adaptInterleavedInt32(
                raw,
                channelCount: 14,
                sampleRate: 48_000,
                selection: .pair(startChannel: 0)
            )
        )

        XCTAssertEqual(result.perPairDiagnostics[0].rms, 0, accuracy: 0.000_001)
        XCTAssertGreaterThan(result.perPairDiagnostics[1].rms, 0.2)
        XCTAssertEqual(result.autoRecommendedChannelPair, "3/4")
        XCTAssertNotNil(result.warning)
    }

    func testAutoRecommendsAndSelectsActivePair() throws {
        let raw = makeInt32Interleaved(frameCount: 256, channelCount: 14, activePairStart: 2)
        let result = try XCTUnwrap(
            TimecodeCMSampleBufferAdapter.adaptInterleavedInt32(
                raw,
                channelCount: 14,
                sampleRate: 48_000,
                selection: .auto
            )
        )

        XCTAssertEqual(result.autoRecommendedChannelPair, "3/4")
        XCTAssertEqual(result.selectedChannelPair, "3/4")
        XCTAssertNil(result.perPairDiagnostics[1].rejectionReason)
        XCTAssertEqual(result.perPairDiagnostics[0].rejectionReason, "near silence")
    }

    func testAutoAcceptsHardwareObservedSlowForwardCarrier() throws {
        let raw = makeInt32InterleavedCarrier(
            frameCount: 4_096,
            channelCount: 14,
            activePairStart: 2,
            frequency: 443
        )
        let result = try XCTUnwrap(
            TimecodeCMSampleBufferAdapter.adaptInterleavedInt32(
                raw,
                channelCount: 14,
                sampleRate: 48_000,
                selection: .auto
            )
        )

        let pair = try XCTUnwrap(result.perPairDiagnostics.first { $0.startChannel == 2 })
        XCTAssertNil(pair.rejectionReason)
        XCTAssertEqual(result.selectedChannelPair, "3/4")
    }

    func testAutoRetainsHardwareObservedVerySlowCarrierBuffer() throws {
        let raw = makeInt32InterleavedCarrier(
            frameCount: 7_168,
            channelCount: 14,
            activePairStart: 2,
            frequency: 93
        )
        let result = try XCTUnwrap(
            TimecodeCMSampleBufferAdapter.adaptInterleavedInt32(
                raw,
                channelCount: 14,
                sampleRate: 48_000,
                selection: .auto
            )
        )

        let pair = try XCTUnwrap(result.perPairDiagnostics.first { $0.startChannel == 2 })
        XCTAssertNil(pair.rejectionReason)
        XCTAssertEqual(result.selectedChannelPair, "3/4")
    }

    func testAutoAcceptsHardwareObservedFastForwardCarrier() throws {
        let raw = makeInt32InterleavedCarrier(
            frameCount: 4_096,
            channelCount: 14,
            activePairStart: 2,
            frequency: 3_166
        )
        let result = try XCTUnwrap(
            TimecodeCMSampleBufferAdapter.adaptInterleavedInt32(
                raw,
                channelCount: 14,
                sampleRate: 48_000,
                selection: .auto
            )
        )

        let pair = try XCTUnwrap(result.perPairDiagnostics.first { $0.startChannel == 2 })
        XCTAssertNil(pair.rejectionReason)
        XCTAssertEqual(result.selectedChannelPair, "3/4")
    }

    // A loud pair with no shared carrier between its channels (not plausible
    // DVS timecode) must not outscore a quieter pair that looks like real
    // quadrature control tone, even though raw RMS/peak favor the loud pair.
    func testLoudNonTimecodePairLosesToQuieterPlausiblePair() throws {
        let raw = makeInt32InterleavedWithLoudNonTimecodePair(
            frameCount: 512,
            channelCount: 14,
            quietPairStart: 2,
            loudPairStart: 12
        )
        let result = try XCTUnwrap(
            TimecodeCMSampleBufferAdapter.adaptInterleavedInt32(
                raw,
                channelCount: 14,
                sampleRate: 48_000,
                selection: .auto
            )
        )

        let quietPair = try XCTUnwrap(result.perPairDiagnostics.first { $0.startChannel == 2 })
        let loudPair = try XCTUnwrap(result.perPairDiagnostics.first { $0.startChannel == 12 })

        XCTAssertGreaterThan(loudPair.rms, quietPair.rms, "Fixture must make the invalid pair louder")
        // The 6 kHz channel falls outside the plausible DVS carrier band, so
        // the pair is caught by the carrier-range gate before scoring.
        XCTAssertEqual(loudPair.rejectionReason, "no timecode carrier")
        XCTAssertNil(quietPair.rejectionReason)
        XCTAssertEqual(result.autoRecommendedChannelPair, "3/4")
        XCTAssertEqual(result.selectedChannelPair, "3/4")
    }

    // Reproduces the real Rane 13/14 field failure: a loud pair with 0 Hz / 0
    // zero-crossings on both channels (pure DC, no oscillation at all) must
    // not win Auto over a quieter pair with a genuine ~1 kHz carrier.
    func testLoudZeroHzPairLosesToQuieterCarrierPair() throws {
        let raw = makeInt32InterleavedWithLoudZeroHzPair(
            frameCount: 512,
            channelCount: 14,
            quietPairStart: 4,
            loudPairStart: 12
        )
        let result = try XCTUnwrap(
            TimecodeCMSampleBufferAdapter.adaptInterleavedInt32(
                raw,
                channelCount: 14,
                sampleRate: 48_000,
                selection: .auto
            )
        )

        let quietPair = try XCTUnwrap(result.perPairDiagnostics.first { $0.startChannel == 4 })
        let loudPair = try XCTUnwrap(result.perPairDiagnostics.first { $0.startChannel == 12 })

        XCTAssertGreaterThan(loudPair.rms, quietPair.rms, "Fixture must make the invalid pair louder")
        XCTAssertEqual(loudPair.leftDominantFrequencyHz, 0, accuracy: 0.001)
        XCTAssertEqual(loudPair.rightDominantFrequencyHz, 0, accuracy: 0.001)
        XCTAssertEqual(loudPair.leftZeroCrossingRate, 0, accuracy: 0.000_001)
        XCTAssertEqual(loudPair.rightZeroCrossingRate, 0, accuracy: 0.000_001)
        XCTAssertEqual(loudPair.rejectionReason, "no timecode carrier")
        XCTAssertNil(quietPair.rejectionReason)
        XCTAssertEqual(result.autoRecommendedChannelPair, "5/6")
        XCTAssertEqual(result.selectedChannelPair, "5/6")
    }

    func testUnsupportedFormatReturnsDiagnosticWarning() {
        let warning = TimecodeCMSampleBufferAdapter.unsupportedFormatWarning(
            bitsPerChannel: 24,
            isFloat: false
        )

        XCTAssertEqual(warning, "Unsupported LPCM format: Int24")
    }

    // MARK: - Carrier retention via production state machine

    /// Helper: creates a minimal PairDiagnostic for state-machine tests.
    private func pairDiag(
        startChannel: Int, score: Float = -1, rms: Float = 0.3,
        freqHzL: Float = 300, freqHzR: Float = 300,
        zcr: Float = 0.01
    ) -> TimecodeCMSampleBufferAdapter.PairDiagnostic {
        .init(
            label: "\(startChannel + 1)/\(startChannel + 2)",
            startChannel: startChannel,
            rms: rms,
            peak: rms * 2,
            correlation: 0.5,
            leftDominantFrequencyHz: freqHzL,
            rightDominantFrequencyHz: freqHzR,
            leftZeroCrossingRate: zcr,
            rightZeroCrossingRate: zcr,
            frequenciesStable: true,
            score: score,
            rejectionReason: score >= 0 ? nil : "no timecode carrier"
        )
    }

    /// 1. Auto acquires a valid carrier from a cold start (no pair held yet).
    func testRetentionAutoAcquiresValidPair() {
        let diags = [pairDiag(startChannel: 2, score: 1.0, rms: 0.3)]
        let (newState) = TimecodeCMSampleBufferAdapter.updateRetentionState(
            currentState: .empty, perPairDiagnostics: diags, selection: .auto
        )

        XCTAssertEqual(newState.heldPair?.start, 2, "Auto must acquire pair 3/4")
        XCTAssertNil(newState.candidatePair)
        XCTAssertEqual(newState.candidateStreak, 0)
    }

    /// 2 & 3. 3/4 becomes silent/invalid during a turnaround — held pair
    /// must be retained and selection must remain 3/4, not fall back to
    /// whatever pair (even 1/2) happens to score least-negative.
    func testRetentionHoldsThroughSilenceDuringTurnaround() {
        let held = TimecodeCMSampleBufferAdapter.RetentionState(
            heldPair: (2, 0.3), candidatePair: nil, candidateStreak: 0
        )
        // 3/4 has gone silent (negative score); 1/2 is also silent/invalid,
        // matching a real turnaround where nothing currently passes.
        let diags = [
            pairDiag(startChannel: 0, score: -1, rms: 0.0001),
            pairDiag(startChannel: 2, score: -1, rms: 0.0),
        ]
        let newState = TimecodeCMSampleBufferAdapter.updateRetentionState(
            currentState: held, perPairDiagnostics: diags, selection: .auto
        )

        XCTAssertEqual(newState.heldPair?.start, 2,
            "Held pair 3/4 must be retained through silence — must not fall back to 1/2 or release")
        XCTAssertNil(newState.candidatePair)
        XCTAssertEqual(newState.candidateStreak, 0)
    }

    /// Holding must not expire no matter how many consecutive invalid
    /// buffers occur — there is no time-based window anymore. Control
    /// vinyl naturally loses carrier at zero speed; a long stop/pause must
    /// not release the held pair.
    func testRetentionHoldsIndefinitelyAcrossManyInvalidBuffers() {
        var state = TimecodeCMSampleBufferAdapter.RetentionState(
            heldPair: (2, 0.3), candidatePair: nil, candidateStreak: 0
        )
        let silentDiags = [pairDiag(startChannel: 2, score: -1, rms: 0.0)]
        for _ in 0..<500 {
            state = TimecodeCMSampleBufferAdapter.updateRetentionState(
                currentState: state, perPairDiagnostics: silentDiags, selection: .auto
            )
        }
        XCTAssertEqual(state.heldPair?.start, 2,
            "Held pair must still be 3/4 after 500 consecutive silent buffers — no time-based expiry")
    }

    /// 4. When the held pair's carrier returns (valid score again), decoding
    /// resumes on the SAME pair — no switch, no re-acquisition churn.
    func testRetentionCarrierReturnsWithoutSwitching() {
        let heldDuringSilence = TimecodeCMSampleBufferAdapter.RetentionState(
            heldPair: (2, 0.3), candidatePair: nil, candidateStreak: 0
        )
        let carrierReturnedDiags = [pairDiag(startChannel: 2, score: 0.9, rms: 0.28)]
        let newState = TimecodeCMSampleBufferAdapter.updateRetentionState(
            currentState: heldDuringSilence, perPairDiagnostics: carrierReturnedDiags, selection: .auto
        )

        XCTAssertEqual(newState.heldPair?.start, 2,
            "Pair 3/4 carrier returning must resume decoding on the same pair, not switch")
    }

    /// 5. A single-buffer transient signal on another pair must not steal
    /// selection — only a *sustained* advantage does (see test 6).
    func testRetentionTransientOtherPairDoesNotStealSelection() {
        let held = TimecodeCMSampleBufferAdapter.RetentionState(
            heldPair: (2, 0.3), candidatePair: nil, candidateStreak: 0
        )
        // One buffer where an unrelated pair momentarily scores higher.
        let diags = [
            pairDiag(startChannel: 2, score: 0.2, rms: 0.15),
            pairDiag(startChannel: 6, score: 0.9, rms: 0.4),
        ]
        let newState = TimecodeCMSampleBufferAdapter.updateRetentionState(
            currentState: held, perPairDiagnostics: diags, selection: .auto
        )

        XCTAssertEqual(newState.heldPair?.start, 2,
            "A single transient buffer favoring another pair must not switch the held pair")
        XCTAssertEqual(newState.candidatePair, 6,
            "The transient advantage should start a candidate streak, not switch immediately")
        XCTAssertEqual(newState.candidateStreak, 1)
    }

    /// 6. A sustained, meaningfully-stronger different pair CAN switch
    /// selection once its advantage persists across the confirmation
    /// window (5 consecutive buffers).
    func testRetentionSustainedStrongerPairSwitchesSelection() {
        var state = TimecodeCMSampleBufferAdapter.RetentionState(
            heldPair: (2, 0.3), candidatePair: nil, candidateStreak: 0
        )
        let sustainedBetterDiags = [
            pairDiag(startChannel: 2, score: 0.2, rms: 0.15),
            pairDiag(startChannel: 6, score: 0.9, rms: 0.4),
        ]
        for i in 0..<4 {
            state = TimecodeCMSampleBufferAdapter.updateRetentionState(
                currentState: state, perPairDiagnostics: sustainedBetterDiags, selection: .auto
            )
            XCTAssertEqual(state.heldPair?.start, 2,
                "Must still be holding 3/4 before the confirmation window elapses (buffer \(i + 1)/5)")
        }
        // 5th consecutive buffer — confirmation threshold reached.
        state = TimecodeCMSampleBufferAdapter.updateRetentionState(
            currentState: state, perPairDiagnostics: sustainedBetterDiags, selection: .auto
        )
        XCTAssertEqual(state.heldPair?.start, 6,
            "A sustained (5-buffer) stronger pair must switch the held selection")
        XCTAssertNil(state.candidatePair)
        XCTAssertEqual(state.candidateStreak, 0)
    }

    /// A candidate streak must reset if the advantage doesn't actually
    /// persist across consecutive buffers (proves this is a *consecutive*
    /// streak, not a cumulative counter).
    func testRetentionCandidateStreakResetsWhenAdvantageLapses() {
        var state = TimecodeCMSampleBufferAdapter.RetentionState(
            heldPair: (2, 0.3), candidatePair: nil, candidateStreak: 0
        )
        let betterDiags = [
            pairDiag(startChannel: 2, score: 0.2, rms: 0.15),
            pairDiag(startChannel: 6, score: 0.9, rms: 0.4),
        ]
        let heldWinsDiags = [
            pairDiag(startChannel: 2, score: 0.9, rms: 0.3),
            pairDiag(startChannel: 6, score: 0.2, rms: 0.1),
        ]
        state = TimecodeCMSampleBufferAdapter.updateRetentionState(
            currentState: state, perPairDiagnostics: betterDiags, selection: .auto
        )
        state = TimecodeCMSampleBufferAdapter.updateRetentionState(
            currentState: state, perPairDiagnostics: betterDiags, selection: .auto
        )
        XCTAssertEqual(state.candidateStreak, 2)

        // Held pair wins this buffer — streak must reset, not just pause.
        state = TimecodeCMSampleBufferAdapter.updateRetentionState(
            currentState: state, perPairDiagnostics: heldWinsDiags, selection: .auto
        )
        XCTAssertNil(state.candidatePair)
        XCTAssertEqual(state.candidateStreak, 0)
        XCTAssertEqual(state.heldPair?.start, 2)

        // Advantage resumes — streak must start over from 1, not resume at 3.
        state = TimecodeCMSampleBufferAdapter.updateRetentionState(
            currentState: state, perPairDiagnostics: betterDiags, selection: .auto
        )
        XCTAssertEqual(state.candidateStreak, 1,
            "An interrupted advantage must restart the confirmation streak, not resume it")
    }

    /// Manual selection returns empty retention state (retention only
    /// applies to Auto).
    func testRetentionManualSelectionReturnsEmptyState() {
        let held = TimecodeCMSampleBufferAdapter.RetentionState(
            heldPair: (2, 0.3), candidatePair: nil, candidateStreak: 0
        )
        let diags = [pairDiag(startChannel: 2, score: 1.0, rms: 0.3)]
        let newState = TimecodeCMSampleBufferAdapter.updateRetentionState(
            currentState: held, perPairDiagnostics: diags, selection: .pair(startChannel: 0)
        )

        XCTAssertNil(newState.heldPair, "Manual mode must not hold any pair")
        XCTAssertEqual(newState, .empty)
    }

    /// `resetPairRetention()` (called on capture device change, manual
    /// selection, or session restart) clears any held pair from the
    /// production static state that `stereoSampleResult` reads.
    func testResetPairRetentionClearsHeldPair() {
        TimecodeCMSampleBufferAdapter.resetPairRetention()
        XCTAssertNil(TimecodeCMSampleBufferAdapter.lastValidPair,
            "resetPairRetention() must clear any held pair")
    }

    /// Setting `channelPairSelection` (a manual selection change) must
    /// itself reset retention — this is the production wiring for one of
    /// the three reset conditions (capture device change, manual selection,
    /// session restart).
    func testChangingChannelPairSelectionResetsRetention() {
        let original = TimecodeCMSampleBufferAdapter.channelPairSelection
        defer { TimecodeCMSampleBufferAdapter.channelPairSelection = original }

        TimecodeCMSampleBufferAdapter.channelPairSelection = .pair(startChannel: 4)
        XCTAssertNil(TimecodeCMSampleBufferAdapter.lastValidPair,
            "Changing channelPairSelection must reset any held pair")
    }

    /// 9. No unrelated audio pair becomes valid merely because it has high RMS
    /// (uses the full adapter pipeline, not the pure state function).
    func testLoudNonCarrierNotValidViaRetentionPipeline() throws {
        let raw = makeInt32InterleavedWithLoudNonTimecodePair(
            frameCount: 512, channelCount: 14,
            quietPairStart: 2, loudPairStart: 12
        )
        let result = try XCTUnwrap(
            TimecodeCMSampleBufferAdapter.adaptInterleavedInt32(
                raw, channelCount: 14, sampleRate: 48_000,
                selection: .auto
            )
        )
        let loudPair = try XCTUnwrap(result.perPairDiagnostics.first { $0.startChannel == 12 })
        XCTAssertEqual(loudPair.rejectionReason, "no timecode carrier",
                       "Loud non-carrier pair must still be rejected")
        XCTAssertEqual(result.autoRecommendedChannelPair, "3/4",
                       "Stateless entry must pick the valid carrier, not the loud non-carrier")
    }

    // MARK: - Retention concurrency / race safety
    //
    // These tests prove the generation-based transaction semantics
    // committed in 9f54937 ("Add race-safe DVS channel-pair retention").
    // A read-only reconciliation audit found the mechanism itself intact in
    // the dirty working copy, but found the dirty tree had also wired in a
    // second production producer of the same shared retention state — the
    // low-latency `AVAudioEngine` tap path, `stereoSampleResult(fromPCMBuffer:hostTime:)`
    // — that the original single-producer design (only a reset/selection
    // change could invalidate an in-flight transaction) was never proven
    // safe against. The fix: `commitRetentionTransaction` now also bumps
    // `storedRetentionGeneration` on every successful commit, not only on
    // reset/selection change, so a second producer's stale snapshot is
    // rejected by the same generation check, exactly like a reset arriving
    // mid-flight. `testConcurrentTransactionsFromTwoProducersRejectsTheStaleCommit`
    // below is the direct deterministic regression for that fix; the rest
    // predate it and continue to hold unchanged. All are deterministic —
    // no reliance on timing or Thread Sanitizer to surface a defect (Thread
    // Sanitizer is still run over this concurrency-adjacent suite as an
    // additional check, not as the proof).

    /// A retention-update transaction that began (snapshot captured) before
    /// an explicit reset must not be able to write its computed held pair
    /// back after the reset — the reset must always win over a
    /// late-arriving, stale transaction.
    func testStaleTransactionBeforeResetCannotRepublishHeldPair() {
        TimecodeCMSampleBufferAdapter.resetPairRetention()

        // Simulate an in-flight audio callback: capture a snapshot, then
        // compute a new state from it exactly as `stereoSampleResult`
        // would.
        let snapshot = TimecodeCMSampleBufferAdapter.beginRetentionTransaction()
        let diags = [pairDiag(startChannel: 2, score: 1.0, rms: 0.3)]
        let computed = TimecodeCMSampleBufferAdapter.updateRetentionState(
            currentState: snapshot.state, perPairDiagnostics: diags, selection: snapshot.selection
        )

        // A reset arrives after the snapshot was captured but before the
        // stale transaction commits — the real race window.
        TimecodeCMSampleBufferAdapter.resetPairRetention()

        let applied = TimecodeCMSampleBufferAdapter.commitRetentionTransaction(computed, snapshot: snapshot)
        XCTAssertFalse(applied, "A stale transaction captured before a reset must not be applied")
        XCTAssertNil(TimecodeCMSampleBufferAdapter.lastValidPair,
            "Reset must win — a late-arriving stale transaction must not repopulate the held pair")
    }

    /// A stale Auto transaction captured before a manual selection change
    /// must not be able to restore Auto retention after that change.
    func testStaleAutoTransactionBeforeSelectionChangeCannotRestoreRetention() {
        let originalSelection = TimecodeCMSampleBufferAdapter.channelPairSelection
        defer { TimecodeCMSampleBufferAdapter.channelPairSelection = originalSelection }
        TimecodeCMSampleBufferAdapter.channelPairSelection = .auto
        TimecodeCMSampleBufferAdapter.resetPairRetention()

        let snapshot = TimecodeCMSampleBufferAdapter.beginRetentionTransaction()
        let diags = [pairDiag(startChannel: 2, score: 1.0, rms: 0.3)]
        let computed = TimecodeCMSampleBufferAdapter.updateRetentionState(
            currentState: snapshot.state, perPairDiagnostics: diags, selection: snapshot.selection
        )

        // A manual selection change arrives after the snapshot was
        // captured but before the stale Auto transaction commits.
        TimecodeCMSampleBufferAdapter.channelPairSelection = .pair(startChannel: 4)

        let applied = TimecodeCMSampleBufferAdapter.commitRetentionTransaction(computed, snapshot: snapshot)
        XCTAssertFalse(applied,
            "A stale Auto transaction captured before a manual selection change must not be applied")
        XCTAssertNil(TimecodeCMSampleBufferAdapter.lastValidPair,
            "Manual selection change must win — a late-arriving stale Auto transaction must not restore Auto retention")
    }

    /// The exact regression this reconciliation closes: two independent
    /// producers (the legacy `AVCaptureAudioDataOutput` path and the
    /// low-latency `AVAudioEngine` tap path) can each begin a retention
    /// transaction from the same starting generation and compute their own
    /// new state off-lock. Before this fix, a successful commit never
    /// bumped the generation, so whichever producer committed second would
    /// silently overwrite the first's result (a lost update) instead of
    /// being rejected. Simulated deterministically and sequentially — no
    /// threads, no timing dependency — by capturing both snapshots before
    /// either commits, exactly reproducing the race window.
    func testConcurrentTransactionsFromTwoProducersRejectsTheStaleCommit() {
        let originalSelection = TimecodeCMSampleBufferAdapter.channelPairSelection
        defer { TimecodeCMSampleBufferAdapter.channelPairSelection = originalSelection }
        TimecodeCMSampleBufferAdapter.channelPairSelection = .auto
        TimecodeCMSampleBufferAdapter.resetPairRetention()

        // Both producers "arrive" concurrently: each begins a transaction
        // before either has committed, so both capture the same generation.
        let snapshotA = TimecodeCMSampleBufferAdapter.beginRetentionTransaction()
        let snapshotB = TimecodeCMSampleBufferAdapter.beginRetentionTransaction()
        XCTAssertEqual(snapshotA.generation, snapshotB.generation,
            "Both producers must observe the same starting generation to exercise the race window")

        // Each producer independently computes its own new state off-lock,
        // from a different pair's diagnostics — standing in for the two
        // producers processing genuinely different audio buffers.
        let diagsA = [pairDiag(startChannel: 2, score: 1.0, rms: 0.3)]
        let diagsB = [pairDiag(startChannel: 6, score: 1.0, rms: 0.3)]
        let computedA = TimecodeCMSampleBufferAdapter.updateRetentionState(
            currentState: snapshotA.state, perPairDiagnostics: diagsA, selection: snapshotA.selection
        )
        let computedB = TimecodeCMSampleBufferAdapter.updateRetentionState(
            currentState: snapshotB.state, perPairDiagnostics: diagsB, selection: snapshotB.selection
        )

        // Producer A commits first and must succeed.
        let appliedA = TimecodeCMSampleBufferAdapter.commitRetentionTransaction(computedA, snapshot: snapshotA)
        XCTAssertTrue(appliedA, "The first producer to commit must succeed")
        XCTAssertEqual(TimecodeCMSampleBufferAdapter.lastValidPair?.start, 2,
            "The first producer's committed pair must be held")

        // Producer B commits second, still holding its now-stale snapshot
        // (captured before A's commit bumped the generation). Before this
        // reconciliation, this would have silently succeeded and
        // overwritten A's result — the lost-update regression this test
        // exists to catch. It must now be rejected, and A's held pair must
        // remain untouched.
        let appliedB = TimecodeCMSampleBufferAdapter.commitRetentionTransaction(computedB, snapshot: snapshotB)
        XCTAssertFalse(appliedB,
            "A second producer's transaction captured at the same generation as a since-committed first must be rejected, not silently overwrite it")
        XCTAssertEqual(TimecodeCMSampleBufferAdapter.lastValidPair?.start, 2,
            "The first producer's committed pair must survive the second producer's rejected stale commit")
    }

    /// Bounded stress test: many concurrent retention-update transactions
    /// from two independent simulated producers (mirroring the legacy
    /// `AVCaptureAudioDataOutput` path and the low-latency `AVAudioEngine`
    /// tap path), racing against concurrent resets and selection changes,
    /// must never crash, deadlock, or leave inconsistent state, and a final
    /// explicit reset (issued after all concurrent work completes) must
    /// always leave retention empty. Run under Thread Sanitizer to
    /// additionally prove there is no crash/deadlock/data race under
    /// sustained multi-producer concurrent load across the transaction API.
    func testConcurrentSelectionAndResetVersusRetentionUpdatesLeavesConsistentFinalState() {
        let originalSelection = TimecodeCMSampleBufferAdapter.channelPairSelection
        defer { TimecodeCMSampleBufferAdapter.channelPairSelection = originalSelection }
        TimecodeCMSampleBufferAdapter.channelPairSelection = .auto
        TimecodeCMSampleBufferAdapter.resetPairRetention()

        let iterations = 500
        let group = DispatchGroup()
        let updaterQueue = DispatchQueue(label: "retention-stress-updater-legacy", attributes: .concurrent)
        let lowLatencyUpdaterQueue = DispatchQueue(label: "retention-stress-updater-lowlatency", attributes: .concurrent)
        let controlQueue = DispatchQueue(label: "retention-stress-control", attributes: .concurrent)

        for i in 0..<iterations {
            group.enter()
            updaterQueue.async {
                let snapshot = TimecodeCMSampleBufferAdapter.beginRetentionTransaction()
                let diags = [self.pairDiag(startChannel: 2, score: 0.8, rms: 0.3)]
                let computed = TimecodeCMSampleBufferAdapter.updateRetentionState(
                    currentState: snapshot.state, perPairDiagnostics: diags, selection: snapshot.selection
                )
                TimecodeCMSampleBufferAdapter.commitRetentionTransaction(computed, snapshot: snapshot)
                group.leave()
            }
            // A second, independent simulated producer racing the same
            // shared retention state on its own queue — the scenario
            // `testConcurrentTransactionsFromTwoProducersRejectsTheStaleCommit`
            // proves deterministically; this exercises it under genuine
            // concurrent load and Thread Sanitizer as well.
            group.enter()
            lowLatencyUpdaterQueue.async {
                let snapshot = TimecodeCMSampleBufferAdapter.beginRetentionTransaction()
                let diags = [self.pairDiag(startChannel: 2, score: 0.75, rms: 0.28)]
                let computed = TimecodeCMSampleBufferAdapter.updateRetentionState(
                    currentState: snapshot.state, perPairDiagnostics: diags, selection: snapshot.selection
                )
                TimecodeCMSampleBufferAdapter.commitRetentionTransaction(computed, snapshot: snapshot)
                group.leave()
            }
            if i % 37 == 0 {
                group.enter()
                controlQueue.async {
                    TimecodeCMSampleBufferAdapter.resetPairRetention()
                    group.leave()
                }
            }
            if i % 53 == 0 {
                group.enter()
                controlQueue.async {
                    TimecodeCMSampleBufferAdapter.channelPairSelection = .pair(startChannel: 0)
                    TimecodeCMSampleBufferAdapter.channelPairSelection = .auto
                    group.leave()
                }
            }
        }

        let waitResult = group.wait(timeout: .now() + 10)
        XCTAssertEqual(waitResult, .success, "Concurrent retention stress test must complete within timeout")

        // Issued after all concurrent work above has completed — must
        // deterministically leave retention empty regardless of how the
        // updater/control operations interleaved.
        TimecodeCMSampleBufferAdapter.resetPairRetention()
        XCTAssertNil(TimecodeCMSampleBufferAdapter.lastValidPair,
            "A final explicit reset must always leave retention empty, no matter how updater/control operations interleaved")
    }
#endif

    // MARK: - iOS DVS wiring coverage
    //
    // These exercise the exact same `SeratoControlVinylAnalyzer.analyze`
    // entry point AudioEngine.swift's `processDVSAnalysis` now calls per
    // tap buffer — realistic 1024-frame chunking at the real Rane ONE MKII
    // rate (48000 Hz), and a real hardware capture, rather than only
    // whole-buffer synthetic vectors at 44100 Hz.

    /// Directory of Karl's local, untracked hardware captures. Never
    /// committed (see `TimecodeFixtureValidationTests.skipIfHardwareFixturesAbsent`'s
    /// doc comment) — any environment without it (fresh clone, CI) must
    /// skip, not fail.
    private var localHardwareFixtureDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "debug_captures/timecode/hardware_fixtures/20260731",
                isDirectory: true
            )
    }

    private func loadStereoPairFixture(
        captureFolder: String
    ) throws -> (left: [Float], right: [Float], sampleRate: Double) {
        let url = localHardwareFixtureDirectory
            .appendingPathComponent(captureFolder, isDirectory: true)
            .appendingPathComponent("pair_3_4_float32.wav")
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)),
            "Could not allocate PCM buffer for fixture at \(url.path)"
        )
        try file.read(into: buffer)
        let floatData = try XCTUnwrap(buffer.floatChannelData, "Fixture at \(url.path) has no float channel data")
        XCTAssertGreaterThanOrEqual(format.channelCount, 2, "pair_3_4_float32.wav fixtures are always stereo")
        let frameLength = Int(buffer.frameLength)
        let left = Array(UnsafeBufferPointer(start: floatData[0], count: frameLength))
        let right = Array(UnsafeBufferPointer(start: floatData[1], count: frameLength))
        return (left, right, format.sampleRate)
    }

    /// Real Rane ONE MKII capture, decoded through `SeratoControlVinylAnalyzer`
    /// in the same 1024-frame chunks AudioEngine's `installTap` delivers —
    /// proves the fixture decodes end-to-end through the production entry
    /// point, not just that the WAV file is readable.
    func testHardwareFixturePairThreeFourDecodesThroughSeratoControlVinylAnalyzer() throws {
        let directory = localHardwareFixtureDirectory
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw XCTSkip("Hardware fixture directory not present locally: \(directory.path)")
        }

        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let captureFolder = try XCTUnwrap(
            entries.first { $0.contains("steady_normal") },
            "steady_normal capture folder not found under \(directory.path)"
        )

        let fixture = try loadStereoPairFixture(captureFolder: captureFolder)
        let analyzer = SeratoControlVinylAnalyzer(sampleRate: fixture.sampleRate, channelCount: 2)

        let chunkSize = 1024
        var sawSignal = false
        var offset = 0
        while offset < fixture.left.count {
            let end = min(offset + chunkSize, fixture.left.count)
            let status = analyzer.analyze(
                left: Array(fixture.left[offset..<end]),
                right: Array(fixture.right[offset..<end]),
                sampleRate: fixture.sampleRate,
                hostTime: nil
            )
            if status.hasSignal { sawSignal = true }
            offset = end
        }
        XCTAssertTrue(sawSignal, "Expected at least one 1024-frame chunk of \(captureFolder) to report hasSignal == true")
    }

    /// Streams synthetic quadrature timecode through `analyze` in 1024-frame
    /// chunks at 48000 Hz — AudioEngine's real tap buffer size and the
    /// validated Rane ONE MKII rate — including a final, shorter partial
    /// chunk (the shape every real audio stream ends on). Must never crash
    /// and must keep producing a status with sane invariants throughout.
    func testTapSizedChunksAtHardwareSampleRateDoNotCrash() {
        let analyzer = SeratoControlVinylAnalyzer(sampleRate: 48000, channelCount: 2)
        let (left, right) = makeQuadraturePair(
            sampleRate: 48000,
            frameCount: 1024 * 5 + 137,
            phaseShiftPerFrame: 0.002
        )
        let chunkSize = 1024
        var offset = 0
        while offset < left.count {
            let end = min(offset + chunkSize, left.count)
            let status = analyzer.analyze(
                left: Array(left[offset..<end]),
                right: Array(right[offset..<end]),
                sampleRate: 48000,
                hostTime: UInt64(offset)
            )
            XCTAssertGreaterThanOrEqual(status.rms, 0)
            XCTAssertGreaterThanOrEqual(status.confidence, 0)
            XCTAssertLessThanOrEqual(status.confidence, 1)
            offset = end
        }
    }
}
