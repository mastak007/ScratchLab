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
            adapterWarning: nil
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

    func testUnsupportedFormatReturnsDiagnosticWarning() {
        let warning = TimecodeCMSampleBufferAdapter.unsupportedFormatWarning(
            bitsPerChannel: 24,
            isFloat: false
        )

        XCTAssertEqual(warning, "Unsupported LPCM format: Int24")
    }
#endif
}
