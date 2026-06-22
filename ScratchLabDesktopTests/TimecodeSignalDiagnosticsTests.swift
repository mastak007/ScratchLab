// TimecodeSignalDiagnosticsTests
//
// Pure unit tests for TimecodeInputTap, TimecodeSignalDiagnostics,
// TimecodeAudioBuffer, and TimecodeInputSample — no hardware required.
// All audio data is synthesised inline.
//
// Batch 1: Diagnostics-only foundation. No decoder, no commercial
// timecode compatibility claim.

import XCTest
@testable import ScratchLab

final class TimecodeSignalDiagnosticsTests: XCTestCase {

    // MARK: - Helpers

    /// Create a sine tone at the given frequency, sample rate, frame count, and amplitude.
    private func sineTone(
        frequency: Float,
        sampleRate: Double,
        frameCount: Int,
        amplitude: Float
    ) -> [Float] {
        (0..<frameCount).map { i in
            let t = Float(i) / Float(sampleRate)
            return amplitude * sin(2 * .pi * frequency * t)
        }
    }

    /// Push a stereo sine buffer through a tap and drain the result.
    private func pushStereo(
        to tap: TimecodeInputTap,
        frequency: Float = 1200,
        sampleRate: Double = 44100,
        frameCount: Int = 1024,
        amplitude: Float = 0.3,
        hostTime: UInt64? = nil
    ) {
        let left = sineTone(frequency: frequency, sampleRate: sampleRate, frameCount: frameCount, amplitude: amplitude)
        let right = sineTone(frequency: frequency, sampleRate: sampleRate, frameCount: frameCount, amplitude: amplitude)
        tap.push(samplesLeft: left, samplesRight: right, hostTime: hostTime, frameCount: frameCount)
        tap.drain()
    }

    /// Push a stereo sine buffer through a tap WITHOUT draining.
    private func pushStereoNoDrain(
        to tap: TimecodeInputTap,
        frequency: Float = 1200,
        sampleRate: Double = 44100,
        frameCount: Int = 1024,
        amplitude: Float = 0.3,
        hostTime: UInt64? = nil
    ) {
        let left = sineTone(frequency: frequency, sampleRate: sampleRate, frameCount: frameCount, amplitude: amplitude)
        let right = sineTone(frequency: frequency, sampleRate: sampleRate, frameCount: frameCount, amplitude: amplitude)
        tap.push(samplesLeft: left, samplesRight: right, hostTime: hostTime, frameCount: frameCount)
    }

    /// Run diagnostics on a tap's latest buffer.
    private func diagnose(_ tap: TimecodeInputTap) -> TimecodeSignalDiagnostics.Diagnosis {
        TimecodeSignalDiagnostics().diagnose(tap.latestBuffer)
    }

    // MARK: - TimecodeInputSample

    func testTimecodeInputSampleStoresAllFields() {
        let sample = TimecodeInputSample(
            hostTime: 12345,
            relativeTime: 0.5,
            sampleRate: 48000,
            channelCount: 2,
            frameCount: 512,
            leftRMS: 0.3,
            rightRMS: 0.3,
            leftPeak: 0.7,
            rightPeak: 0.7,
            isClipping: false,
            isSilent: false,
            isSingleSided: false
        )

        XCTAssertEqual(sample.hostTime, 12345)
        XCTAssertEqual(sample.relativeTime, 0.5)
        XCTAssertEqual(sample.sampleRate, 48000)
        XCTAssertEqual(sample.channelCount, 2)
        XCTAssertEqual(sample.frameCount, 512)
        XCTAssertEqual(sample.leftRMS, 0.3)
        XCTAssertEqual(sample.rightRMS, 0.3)
        XCTAssertEqual(sample.leftPeak, 0.7)
        XCTAssertEqual(sample.rightPeak, 0.7)
        XCTAssertFalse(sample.isClipping)
        XCTAssertFalse(sample.isSilent)
        XCTAssertFalse(sample.isSingleSided)
    }

    func testTimecodeInputSampleNilRightForMono() {
        let sample = TimecodeInputSample(
            hostTime: nil,
            relativeTime: 0,
            sampleRate: 44100,
            channelCount: 1,
            frameCount: 256,
            leftRMS: 0.5,
            rightRMS: nil,
            leftPeak: 0.8,
            rightPeak: nil,
            isClipping: false,
            isSilent: false,
            isSingleSided: false
        )

        XCTAssertNil(sample.rightRMS)
        XCTAssertNil(sample.rightPeak)
        XCTAssertEqual(sample.channelCount, 1)
    }

    // MARK: - TimecodeAudioBuffer

    func testTimecodeBufferPreservesFormatMetadata() {
        let tap = TimecodeInputTap(sampleRate: 48000, channelCount: 2)
        pushStereoNoDrain(to: tap, sampleRate: 48000, frameCount: 512)
        pushStereoNoDrain(to: tap, sampleRate: 48000, frameCount: 512)
        tap.drain()

        let buffer = tap.latestBuffer

        XCTAssertEqual(buffer.sampleRate, 48000)
        XCTAssertEqual(buffer.channelCount, 2)
        XCTAssertEqual(buffer.totalFrameCount, 1024)
        XCTAssertEqual(buffer.samples.count, 2)
        XCTAssertGreaterThan(buffer.duration, 0)
    }

    func testTimecodeBufferEmptyHasZeroDuration() {
        let empty = TimecodeAudioBuffer.empty(sampleRate: 44100, channelCount: 2)

        XCTAssertEqual(empty.samples.count, 0)
        XCTAssertEqual(empty.duration, 0)
        XCTAssertEqual(empty.sampleRate, 44100)
        XCTAssertEqual(empty.channelCount, 2)
    }

    func testTimecodeBufferDurationIsCorrect() {
        // 44100 samples at 44100 Hz = exactly 1.0 second
        let tap = TimecodeInputTap(sampleRate: 44100, channelCount: 2)
        pushStereoNoDrain(to: tap, sampleRate: 44100, frameCount: 22050)
        pushStereoNoDrain(to: tap, sampleRate: 44100, frameCount: 22050)
        tap.drain()

        let buffer = tap.latestBuffer
        XCTAssertEqual(buffer.totalFrameCount, 44100)
        XCTAssertEqual(buffer.duration, 1.0, accuracy: 0.001)
    }

    // MARK: - Diagnostics — silence

    func testTimecodeDiagnosticsDetectsSilence() {
        let tap = TimecodeInputTap(sampleRate: 44100, channelCount: 2)
        let silence = [Float](repeating: 0, count: 1024)
        tap.push(samplesLeft: silence, samplesRight: silence)
        tap.drain()

        let diag = diagnose(tap)

        XCTAssertTrue(diag.isSilent)
        XCTAssertEqual(diag.health, .noSignal)
        XCTAssertEqual(diag.leftRMS, 0, accuracy: 0.001)
        XCTAssertEqual(diag.rightRMS ?? 0, 0, accuracy: 0.001)
    }

    // MARK: - Diagnostics — usable stereo

    func testTimecodeDiagnosticsDetectsUsableStereoSignal() {
        let tap = TimecodeInputTap(sampleRate: 44100, channelCount: 2)
        pushStereo(to: tap, amplitude: 0.3)

        let diag = diagnose(tap)

        XCTAssertFalse(diag.isSilent)
        XCTAssertFalse(diag.isClipping)
        XCTAssertFalse(diag.isChannelImbalanced)
        XCTAssertFalse(diag.isMonoSuspect)
        XCTAssertTrue(diag.isStereo)
        XCTAssertEqual(diag.health, .usable)
        XCTAssertGreaterThan(diag.leftRMS, 0.1)
        XCTAssertGreaterThan(diag.rightRMS ?? 0, 0.1)
        XCTAssertGreaterThan(diag.leftPeak, 0.01)
        XCTAssertGreaterThan(diag.rightPeak ?? 0, 0.01)
    }

    // MARK: - Diagnostics — clipping

    func testTimecodeDiagnosticsDetectsClipping() {
        let tap = TimecodeInputTap(sampleRate: 44100, channelCount: 2)
        pushStereo(to: tap, amplitude: 1.0)

        let diag = diagnose(tap)

        XCTAssertTrue(diag.isClipping)
        XCTAssertFalse(diag.isSilent)
        XCTAssertEqual(diag.health, .clipped)
    }

    // MARK: - Diagnostics — single channel fault

    func testTimecodeDiagnosticsDetectsSingleChannelFault() {
        let tap = TimecodeInputTap(sampleRate: 44100, channelCount: 2)

        // Left channel healthy, right channel silent
        let left = sineTone(frequency: 1200, sampleRate: 44100, frameCount: 1024, amplitude: 0.3)
        let right = [Float](repeating: 0, count: 1024)
        tap.push(samplesLeft: left, samplesRight: right)
        tap.drain()

        let diag = diagnose(tap)

        XCTAssertEqual(diag.health, .channelFault)
        XCTAssertTrue(diag.isMonoSuspect)
        XCTAssertTrue(diag.isChannelImbalanced)
    }

    // MARK: - Diagnostics — weak signal

    func testTimecodeDiagnosticsDetectsWeakSignal() {
        let tap = TimecodeInputTap(sampleRate: 44100, channelCount: 2)

        // Very low amplitude — below weakThresholdRMS (0.02) but above silence (0.001)
        let weak = sineTone(frequency: 1200, sampleRate: 44100, frameCount: 1024, amplitude: 0.005)
        tap.push(samplesLeft: weak, samplesRight: weak)
        tap.drain()

        let diag = diagnose(tap)

        XCTAssertEqual(diag.health, .weak)
        XCTAssertFalse(diag.isSilent)
        XCTAssertFalse(diag.isClipping)
    }

    // MARK: - Diagnostics — balanced stereo (not mono fault)

    func testTimecodeDiagnosticsBalancedStereoNotMonoFault() {
        let tap = TimecodeInputTap(sampleRate: 44100, channelCount: 2)
        pushStereo(to: tap, amplitude: 0.3)

        let diag = diagnose(tap)

        XCTAssertFalse(diag.isMonoSuspect)
        XCTAssertFalse(diag.isChannelImbalanced)
    }

    // MARK: - Tap — metadata tracking

    func testTimecodeTapTracksBufferCountAndFrames() {
        let tap = TimecodeInputTap(sampleRate: 44100, channelCount: 2)

        XCTAssertEqual(tap.bufferCount, 0)
        XCTAssertEqual(tap.totalFrameCount, 0)

        pushStereo(to: tap, frameCount: 512)
        XCTAssertEqual(tap.bufferCount, 1)
        XCTAssertEqual(tap.totalFrameCount, 512)

        pushStereo(to: tap, frameCount: 512)
        XCTAssertEqual(tap.bufferCount, 2)
        XCTAssertEqual(tap.totalFrameCount, 1024)
    }

    func testTimecodeTapResetClearsState() {
        let tap = TimecodeInputTap(sampleRate: 44100, channelCount: 2)
        pushStereo(to: tap, frameCount: 512)

        tap.reset()

        XCTAssertEqual(tap.bufferCount, 0)
        XCTAssertEqual(tap.totalFrameCount, 0)
        XCTAssertNil(tap.latestSample)
        XCTAssertEqual(tap.latestBuffer.samples.count, 0)
    }

    func testTimecodeTapDrainAndDiagnose() {
        let tap = TimecodeInputTap(sampleRate: 44100, channelCount: 2)
        pushStereoNoDrain(to: tap, amplitude: 0.3)
        pushStereoNoDrain(to: tap, amplitude: 0.3)

        let diag = tap.drainAndDiagnose()

        XCTAssertEqual(diag.health, .usable)
        // After drain, the latest buffer should still be the drained one
        XCTAssertEqual(tap.latestBuffer.samples.count, 2)
    }

    // MARK: - SignalHealth enum

    func testSignalHealthAllCasesExist() {
        let cases = SignalHealth.allCases
        XCTAssertEqual(cases.count, 5)
        XCTAssertTrue(cases.contains(.noSignal))
        XCTAssertTrue(cases.contains(.weak))
        XCTAssertTrue(cases.contains(.usable))
        XCTAssertTrue(cases.contains(.clipped))
        XCTAssertTrue(cases.contains(.channelFault))
    }

    // MARK: - TimecodeSourceState

    func testTimecodeSourceStateInactive() {
        let state = TimecodeSourceState.inactive
        XCTAssertFalse(state.isActive)
        XCTAssertNil(state.formatSummary)
        XCTAssertEqual(state.displayLabel, "Inactive")
    }

    func testTimecodeSourceStateActiveHasFormatSummary() {
        let state = TimecodeSourceState.active(name: "Test Source", sampleRate: 48000, channelCount: 2)
        XCTAssertTrue(state.isActive)
        XCTAssertEqual(state.formatSummary, "48.0 kHz · 2ch")
        XCTAssertEqual(state.displayLabel, "Test Source")
    }

    // MARK: - Custom thresholds

    func testTimecodeDiagnosticsCustomThresholds() {
        let custom = TimecodeSignalDiagnostics(
            silenceThresholdRMS: 0.01,
            weakThresholdRMS: 0.1,
            clippingThreshold: 0.9,
            channelImbalanceThreshold: 0.5
        )

        let tap = TimecodeInputTap(sampleRate: 44100, channelCount: 2)
        // Amplitude 0.05 — should be "weak" under custom thresholds (above 0.01 silence,
        // below 0.1 weak)
        let low = sineTone(frequency: 1200, sampleRate: 44100, frameCount: 1024, amplitude: 0.05)
        tap.push(samplesLeft: low, samplesRight: low)
        tap.drain()

        let diag = custom.diagnose(tap.latestBuffer)
        XCTAssertEqual(diag.health, .weak)
    }

    // MARK: - Empty buffer

    func testTimecodeDiagnosticsEmptyBufferIsNoSignal() {
        let tap = TimecodeInputTap(sampleRate: 44100, channelCount: 2)
        // Don't push anything — drain empty
        tap.drain()

        let diag = diagnose(tap)
        XCTAssertEqual(diag.health, .noSignal)
        XCTAssertTrue(diag.isSilent)
    }

    // MARK: - Host time tracking

    func testTimecodeTapTracksHostTime() {
        let tap = TimecodeInputTap(sampleRate: 44100, channelCount: 2)

        let left = sineTone(frequency: 1200, sampleRate: 44100, frameCount: 512, amplitude: 0.3)
        let right = sineTone(frequency: 1200, sampleRate: 44100, frameCount: 512, amplitude: 0.3)

        tap.push(samplesLeft: left, samplesRight: right, hostTime: 100)
        XCTAssertEqual(tap.latestHostTime, 100)

        tap.push(samplesLeft: left, samplesRight: right, hostTime: 200)
        XCTAssertEqual(tap.latestHostTime, 200)
    }

    // MARK: - Batch 13: Signal modulation classification

    /// Helper: create a quadrature stereo pair at the given frequency and
    /// amplitude with a 90° phase offset (R leads L by 90°).
    private func quadraturePair(
        frequency: Float,
        sampleRate: Double,
        frameCount: Int,
        amplitude: Float
    ) -> (left: [Float], right: [Float]) {
        var left = [Float]()
        var right = [Float]()
        left.reserveCapacity(frameCount)
        right.reserveCapacity(frameCount)
        for i in 0..<frameCount {
            let t = Float(i) / Float(sampleRate)
            let phase = 2 * .pi * frequency * t
            left.append(amplitude * sin(phase))
            right.append(amplitude * sin(phase + .pi / 2))
        }
        return (left, right)
    }

    /// Helper: create a frequency-disparate stereo pair where L and R carry different frequencies.
    private func frequencyDisparatePair(
        freqLeft: Float,
        freqRight: Float,
        sampleRate: Double,
        frameCount: Int,
        amplitude: Float
    ) -> (left: [Float], right: [Float]) {
        let left = sineTone(frequency: freqLeft, sampleRate: sampleRate, frameCount: frameCount, amplitude: amplitude)
        let right = sineTone(frequency: freqRight, sampleRate: sampleRate, frameCount: frameCount, amplitude: amplitude)
        return (left, right)
    }

    /// Run signal classification on raw samples.
    private func classify(
        left: [Float],
        right: [Float],
        sampleRate: Double = 44100
    ) -> TimecodeSignalDiagnostics.Diagnosis {
        let engine = TimecodeSignalDiagnostics()
        // First run diagnose to get health
        let tap = TimecodeInputTap(sampleRate: sampleRate, channelCount: 2)
        tap.push(samplesLeft: left, samplesRight: right)
        tap.drain()
        let health = engine.diagnose(tap.latestBuffer).health
        return engine.classifySignal(
            left: left, right: right,
            sampleRate: sampleRate,
            health: health,
            isStereo: true
        )
    }

    func testQuadratureLikeClassifiedAsCandidate() {
        let (left, right) = quadraturePair(
            frequency: 1000, sampleRate: 44100, frameCount: 4096, amplitude: 0.5
        )
        let result = classify(left: left, right: right)

        XCTAssertEqual(result.signalClass, .quadratureCandidate,
                       "1 kHz quadrature pair must classify as quadratureCandidate, got \(result.signalClass.rawValue)")
        XCTAssertTrue(result.isQuadratureLike,
                      "1 kHz quadrature pair must be quadrature-like")
        XCTAssertFalse(result.isFrequencyDisparate,
                       "1 kHz quadrature pair must NOT be frequency-disparate")

        // Phase offset should be near 90°
        if let po = result.estimatedPhaseOffset {
            XCTAssertEqual(abs(po), 90, accuracy: 35,
                           "Phase offset for 90° quadrature should be near 90°, got \(po)°")
        }

        // ZCR frequency estimates should be near 1000 Hz for 1 kHz tones
        if let dfL = result.zcrFrequencyEstimateLeft {
            XCTAssertEqual(dfL, 1000, accuracy: 200,
                           "Left ZCR freq estimate should be near 1000 Hz, got \(dfL)")
        }
        if let dfR = result.zcrFrequencyEstimateRight {
            XCTAssertEqual(dfR, 1000, accuracy: 200,
                           "Right ZCR freq estimate should be near 1000 Hz, got \(dfR)")
        }

        // Correlation should be low for phase-shifted signals
        if let corr = result.channelCorrelation {
            XCTAssertLessThan(abs(corr), 0.5,
                              "Quadrature signals should have low channel correlation, got \(corr)")
        }
    }

    func testFrequencyDisparateStereoClassifiedAsUnsupportedNonQuadrature() {
        // Fixture: L = 1200 Hz, R = 2200 Hz — different ZCR frequency estimates.
        // This tests that a stereo pair whose ZCR-derived frequencies differ
        // noticeably is classified as unsupported non-quadrature.
        // NOTE: This does NOT test FSK detection. The classifier uses ZCR, not
        // spectral analysis, and makes no claim about FSK modulation.
        let (left, right) = frequencyDisparatePair(
            freqLeft: 1200, freqRight: 2200,
            sampleRate: 44100, frameCount: 4096, amplitude: 0.5
        )
        let result = classify(left: left, right: right)

        XCTAssertEqual(result.signalClass, .frequencyDisparateUnsupported,
                       "Frequency-disparate pair must classify as frequencyDisparateUnsupported, got \(result.signalClass.rawValue)")
        XCTAssertTrue(result.isFrequencyDisparate,
                      "Frequency-disparate pair must have isFrequencyDisparate == true")
        XCTAssertFalse(result.isQuadratureLike,
                       "Frequency-disparate pair must NOT be quadrature-like")

        // ZCR frequency estimates should differ noticeably
        if let dfL = result.zcrFrequencyEstimateLeft, let dfR = result.zcrFrequencyEstimateRight {
            let ratio = max(dfL, dfR) / max(min(dfL, dfR), 1.0)
            XCTAssertGreaterThan(ratio, 1.15,
                                 "ZCR frequency estimates should differ by >15%, got ratio \(ratio)")
        }

        // Rejection note must describe the non-quadrature evidence, not claim FSK
        XCTAssertNotNil(result.decoderRejectionNote)
        if let note = result.decoderRejectionNote {
            XCTAssertFalse(note.isEmpty,
                           "Non-quadrature classification must include a decoder rejection note")
            XCTAssertTrue(note.contains("non-quadrature") || note.contains("ZCR"),
                          "Rejection note must describe non-quadrature evidence, not claim FSK; got: \(note)")
        }
    }

    func testSilenceClassifiedAsSilent() {
        let silence = [Float](repeating: 0, count: 1024)
        let result = classify(left: silence, right: silence)

        XCTAssertEqual(result.signalClass, .silent,
                       "Silent buffer must classify as silent, got \(result.signalClass.rawValue)")
        XCTAssertFalse(result.isQuadratureLike)
        XCTAssertFalse(result.isFrequencyDisparate)
        XCTAssertEqual(result.zeroCrossingRateLeft, 0, accuracy: 0.1)
        XCTAssertEqual(result.zeroCrossingRateRight, 0, accuracy: 0.1)
        XCTAssertNil(result.zcrFrequencyEstimateLeft)
        XCTAssertNil(result.zcrFrequencyEstimateRight)
    }

    func testValidNonZeroAudioNotMislabeledAsSilence() {
        let left = sineTone(frequency: 440, sampleRate: 44100, frameCount: 2048, amplitude: 0.3)
        let right = sineTone(frequency: 440, sampleRate: 44100, frameCount: 2048, amplitude: 0.3)
        let result = classify(left: left, right: right)

        XCTAssertNotEqual(result.signalClass, .silent,
                          "Active audio must NOT be classified as silent")
        XCTAssertNotEqual(result.signalClass, .weak,
                          "0.3 amplitude audio must NOT be classified as weak")

        // Zero-crossing rate should be non-zero for active audio
        XCTAssertGreaterThan(result.zeroCrossingRateLeft, 10,
                             "Active audio must have non-zero ZCR")
    }

    func testDiagnosticsOnlyDoesNotSendMotion() {
        // Verify that diagnosticsOnly mode:
        //  - classifies the signal (signalClass populated)
        //  - does NOT flush or accumulate decode output
        //  - reports the correct mode-aware status
        //  - leaves all drop and spike counters at zero
        let pipeline = TimecodeControlPipeline(sampleRate: 44100, channelCount: 2)
        pipeline.mode = .diagnosticsOnly

        let (left, right) = quadraturePair(
            frequency: 1000, sampleRate: 44100, frameCount: 1024, amplitude: 0.5
        )
        pipeline.pushStereoBuffer(left: left, right: right, sampleRate: 44100)

        // flushDecode must return nil — decoder is never called by design
        let timeline = pipeline.flushDecode()
        XCTAssertNil(timeline, "diagnosticsOnly must produce nil timeline (no motion)")

        let snapshot = pipeline.makeValidationSnapshot()

        // Classification must have run and produced the expected class
        XCTAssertEqual(snapshot.signalClass, SignalClass.quadratureCandidate.rawValue,
                       "1 kHz quadrature input must classify as quadratureCandidate in diagnosticsOnly mode")

        // Mode-aware status: not a decode failure — decode is intentionally disabled
        XCTAssertEqual(snapshot.validationStatus, .diagnosticsOnlyReceiving,
                       "diagnosticsOnly with active signal must report .diagnosticsOnlyReceiving, not .receivingButNoDecode")

        // No decode output
        XCTAssertEqual(snapshot.acceptedMotionSamples, 0,
                       "diagnosticsOnly must emit zero accepted motion samples")
        XCTAssertEqual(snapshot.decoderConfidence, 0,
                       "diagnosticsOnly must report zero decoder confidence")
        XCTAssertEqual(snapshot.recordedSamples, 0,
                       "diagnosticsOnly must report zero recorded samples")

        // Drop counters must all remain zero — decoder never ran, nothing to drop
        XCTAssertEqual(snapshot.droppedSilence, 0,      "droppedSilence must be 0 in diagnosticsOnly")
        XCTAssertEqual(snapshot.droppedClipped, 0,      "droppedClipped must be 0 in diagnosticsOnly")
        XCTAssertEqual(snapshot.droppedChannelFault, 0, "droppedChannelFault must be 0 in diagnosticsOnly")
        XCTAssertEqual(snapshot.droppedWeakSignal, 0,   "droppedWeakSignal must be 0 in diagnosticsOnly")
        XCTAssertEqual(snapshot.droppedLowConfidence, 0,"droppedLowConfidence must be 0 in diagnosticsOnly")
        XCTAssertEqual(snapshot.rejectedSpikeCount, 0,  "rejectedSpikeCount must be 0 in diagnosticsOnly")
        XCTAssertEqual(snapshot.heldDropoutCount, 0,    "heldDropoutCount must be 0 in diagnosticsOnly")
        XCTAssertEqual(snapshot.longDropoutCount, 0,    "longDropoutCount must be 0 in diagnosticsOnly")
    }

    func testCorrelatedStereoNotQuadrature() {
        // Same frequency, same phase (dual mono essentially) —
        // should not be classified as quadrature because correlation is high
        // and phase offset is near 0.
        let left = sineTone(frequency: 1000, sampleRate: 44100, frameCount: 4096, amplitude: 0.5)
        let right = sineTone(frequency: 1000, sampleRate: 44100, frameCount: 4096, amplitude: 0.5)
        let result = classify(left: left, right: right)

        // Should NOT be quadrature (same phase = high correlation, near 0° offset)
        XCTAssertNotEqual(result.signalClass, .quadratureCandidate,
                          "In-phase stereo must NOT classify as quadrature candidate")
        XCTAssertFalse(result.isQuadratureLike,
                       "In-phase stereo must NOT be quadrature-like")

        // Correlation should be near 1.0
        if let corr = result.channelCorrelation {
            XCTAssertGreaterThan(corr, 0.9,
                                 "In-phase identical signals should have correlation near 1.0, got \(corr)")
        }
    }

    func testSignalClassAllCasesExist() {
        let cases = SignalClass.allCases
        XCTAssertEqual(cases.count, 8)
        XCTAssertTrue(cases.contains(.quadratureCandidate))
        XCTAssertTrue(cases.contains(.frequencyDisparateUnsupported))
        XCTAssertTrue(cases.contains(.stereoAudioButNotQuadrature))
        XCTAssertTrue(cases.contains(.silent))
        XCTAssertTrue(cases.contains(.clipped))
        XCTAssertTrue(cases.contains(.channelFault))
        XCTAssertTrue(cases.contains(.weak))
        XCTAssertTrue(cases.contains(.unknown))
    }

    func testDiagnosticsOnlySilentBufferIsNotMaskedAsReceiving() {
        // Silent input in diagnosticsOnly must not be masked as "receiving."
        // Status must be noSignal; drop counters must remain zero.
        let pipeline = TimecodeControlPipeline(sampleRate: 44100, channelCount: 2)
        pipeline.mode = .diagnosticsOnly

        let silence = [Float](repeating: 0, count: 1024)
        pipeline.pushStereoBuffer(left: silence, right: silence, sampleRate: 44100)

        let snapshot = pipeline.makeValidationSnapshot()

        XCTAssertEqual(snapshot.signalClass, SignalClass.silent.rawValue,
                       "Silent input must classify as silent in diagnosticsOnly mode")
        XCTAssertEqual(snapshot.validationStatus, .noSignal,
                       "Silent signal in diagnosticsOnly must report .noSignal, got \(snapshot.validationStatus)")
        XCTAssertNotEqual(snapshot.validationStatus, .diagnosticsOnlyReceiving,
                          "Silent signal must NOT be masked as diagnosticsOnlyReceiving")

        XCTAssertEqual(snapshot.acceptedMotionSamples, 0)
        XCTAssertEqual(snapshot.decoderConfidence, 0)
        XCTAssertEqual(snapshot.droppedSilence, 0,       "droppedSilence must be 0 — no decoder ran")
        XCTAssertEqual(snapshot.droppedClipped, 0,       "droppedClipped must be 0 — no decoder ran")
        XCTAssertEqual(snapshot.droppedChannelFault, 0,  "droppedChannelFault must be 0 — no decoder ran")
        XCTAssertEqual(snapshot.droppedWeakSignal, 0,    "droppedWeakSignal must be 0 — no decoder ran")
        XCTAssertEqual(snapshot.droppedLowConfidence, 0, "droppedLowConfidence must be 0 — no decoder ran")
        XCTAssertEqual(snapshot.rejectedSpikeCount, 0)
        XCTAssertEqual(snapshot.heldDropoutCount, 0)
        XCTAssertEqual(snapshot.longDropoutCount, 0)
    }

    func testDiagnosticsOnlyClippedBufferIsNotMaskedAsReceiving() {
        // Clipped input in diagnosticsOnly must surface as clipped, not receiving.
        let pipeline = TimecodeControlPipeline(sampleRate: 44100, channelCount: 2)
        pipeline.mode = .diagnosticsOnly

        let clipped = [Float](repeating: 1.0, count: 1024)
        pipeline.pushStereoBuffer(left: clipped, right: clipped, sampleRate: 44100)

        let snapshot = pipeline.makeValidationSnapshot()

        XCTAssertEqual(snapshot.signalClass, SignalClass.clipped.rawValue,
                       "Clipped input must classify as clipped in diagnosticsOnly mode")
        XCTAssertEqual(snapshot.validationStatus, .clipped,
                       "Clipped signal in diagnosticsOnly must report .clipped, got \(snapshot.validationStatus)")
        XCTAssertNotEqual(snapshot.validationStatus, .diagnosticsOnlyReceiving,
                          "Clipped signal must NOT be masked as diagnosticsOnlyReceiving")

        XCTAssertEqual(snapshot.droppedSilence, 0,       "droppedSilence must be 0 — no decoder ran")
        XCTAssertEqual(snapshot.droppedClipped, 0,       "droppedClipped must be 0 — no decoder ran")
        XCTAssertEqual(snapshot.droppedChannelFault, 0,  "droppedChannelFault must be 0 — no decoder ran")
        XCTAssertEqual(snapshot.droppedWeakSignal, 0,    "droppedWeakSignal must be 0 — no decoder ran")
        XCTAssertEqual(snapshot.droppedLowConfidence, 0, "droppedLowConfidence must be 0 — no decoder ran")
        XCTAssertEqual(snapshot.rejectedSpikeCount, 0)
        XCTAssertEqual(snapshot.heldDropoutCount, 0)
        XCTAssertEqual(snapshot.longDropoutCount, 0)
    }

    func testDiagnosticsOnlyChannelFaultBufferIsNotMaskedAsReceiving() {
        // Channel-fault input (one dead channel) in diagnosticsOnly must surface
        // as channelFault, not as "receiving."
        let pipeline = TimecodeControlPipeline(sampleRate: 44100, channelCount: 2)
        pipeline.mode = .diagnosticsOnly

        let active = sineTone(frequency: 1000, sampleRate: 44100, frameCount: 1024, amplitude: 0.5)
        let dead = [Float](repeating: 0, count: 1024)
        pipeline.pushStereoBuffer(left: active, right: dead, sampleRate: 44100)

        let snapshot = pipeline.makeValidationSnapshot()

        XCTAssertEqual(snapshot.signalClass, SignalClass.channelFault.rawValue,
                       "Channel-fault input must classify as channelFault in diagnosticsOnly mode")
        XCTAssertEqual(snapshot.validationStatus, .channelFault,
                       "Channel-fault signal in diagnosticsOnly must report .channelFault, got \(snapshot.validationStatus)")
        XCTAssertNotEqual(snapshot.validationStatus, .diagnosticsOnlyReceiving,
                          "Channel-fault signal must NOT be masked as diagnosticsOnlyReceiving")

        XCTAssertEqual(snapshot.droppedSilence, 0,       "droppedSilence must be 0 — no decoder ran")
        XCTAssertEqual(snapshot.droppedClipped, 0,       "droppedClipped must be 0 — no decoder ran")
        XCTAssertEqual(snapshot.droppedChannelFault, 0,  "droppedChannelFault must be 0 — no decoder ran")
        XCTAssertEqual(snapshot.droppedWeakSignal, 0,    "droppedWeakSignal must be 0 — no decoder ran")
        XCTAssertEqual(snapshot.droppedLowConfidence, 0, "droppedLowConfidence must be 0 — no decoder ran")
        XCTAssertEqual(snapshot.rejectedSpikeCount, 0)
        XCTAssertEqual(snapshot.heldDropoutCount, 0)
        XCTAssertEqual(snapshot.longDropoutCount, 0)
    }
}
