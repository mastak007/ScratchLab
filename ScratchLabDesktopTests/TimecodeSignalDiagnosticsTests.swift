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
}
