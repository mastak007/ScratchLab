// TimecodeValidationTests
//
// Batch 6 tests for timecode prototype validation snapshot and status
// classification:
//   1. no live buffer → noSignal
//   2. stale buffer age → stale
//   3. clipped signal health → clipped
//   4. channel fault → channelFault
//   5. good signal + accepted samples → usablePrototypeControl
//   6. drops > 0 + no accepted samples → decodingButDropping
//   7. recent buffer + no decode output → receivingButNoDecode
//   8. snapshot preserves source label
//   9. resetCounters clears counters but does not change mode
//  10. snapshot / status does not claim final commercial compatibility
//
// Batch 6: Validation visibility only. DEBUG-only test file.
// No decoder rewrite. No notation injection. No commercial compatibility claim.

import XCTest
@testable import ScratchLab

#if DEBUG

final class TimecodeValidationTests: XCTestCase {

    // MARK: - Helpers: snapshot factory

    private func makeSnapshot(
        mode: TimecodeControlMode = .disabled,
        hasRecentBuffer: Bool = false,
        lastBufferAge: TimeInterval? = nil,
        signalHealth: SignalHealth = .noSignal,
        acceptedMotionSamples: Int = 0,
        droppedSilence: Int = 0,
        droppedClipped: Int = 0,
        droppedChannelFault: Int = 0,
        droppedWeakSignal: Int = 0,
        droppedLowConfidence: Int = 0,
        sourceLabel: String = "timecode_live"
    ) -> TimecodeValidationSnapshot {
        let status = TimecodeValidationSnapshot.classify(
            hasRecentBuffer: hasRecentBuffer,
            lastBufferAge: lastBufferAge,
            signalHealth: signalHealth,
            acceptedMotionSamples: acceptedMotionSamples,
            droppedSilence: droppedSilence,
            droppedClipped: droppedClipped,
            droppedChannelFault: droppedChannelFault,
            droppedWeakSignal: droppedWeakSignal,
            droppedLowConfidence: droppedLowConfidence
        )
        return TimecodeValidationSnapshot(
            mode: mode.rawValue,
            liveTapEnabled: false,
            hasRecentBuffer: hasRecentBuffer,
            lastBufferAge: lastBufferAge,
            signalHealth: signalHealth,
            leftRMS: 0,
            rightRMS: 0,
            leftPeak: 0,
            rightPeak: 0,
            decodedDirection: TimecodeDirection.unknown.rawValue,
            decodedRate: 0,
            decoderConfidence: 0,
            acceptedMotionSamples: acceptedMotionSamples,
            recordedSamples: 0,
            droppedSilence: droppedSilence,
            droppedClipped: droppedClipped,
            droppedChannelFault: droppedChannelFault,
            droppedWeakSignal: droppedWeakSignal,
            droppedLowConfidence: droppedLowConfidence,
            directionChanges: 0,
            maxAbsRate: 0,
            averageConfidence: 0,
            lastDropReason: "",
            sourceLabel: sourceLabel,
            validationStatus: status
        )
    }

    // MARK: - Pipeline helpers

    private func makePipeline(mode: TimecodeControlMode = .controlPrototype) -> TimecodeControlPipeline {
        let p = TimecodeControlPipeline(sampleRate: 44100, channelCount: 2)
        p.mode = mode
        return p
    }

    // MARK: - 1. No live buffer → noSignal

    func testTimecodeValidationNoSignal() {
        let snap = makeSnapshot(hasRecentBuffer: false, lastBufferAge: nil, signalHealth: .noSignal)
        XCTAssertEqual(snap.validationStatus, .noSignal,
                       "no buffer received must produce noSignal status")
    }

    // MARK: - 2. Stale buffer age → stale

    func testTimecodeValidationStaleBuffer() {
        let staleAge = TimecodeValidationSnapshot.staleThreshold + 1.0
        let snap = makeSnapshot(
            hasRecentBuffer: false,
            lastBufferAge: staleAge,
            signalHealth: .usable,
            acceptedMotionSamples: 0
        )
        XCTAssertEqual(snap.validationStatus, .stale,
                       "buffer age exceeding stale threshold must produce stale status")
    }

    func testTimecodeValidationFreshBufferIsNotStale() {
        let freshAge = TimecodeValidationSnapshot.staleThreshold - 0.5
        let snap = makeSnapshot(
            hasRecentBuffer: true,
            lastBufferAge: freshAge,
            signalHealth: .usable,
            acceptedMotionSamples: 5
        )
        XCTAssertNotEqual(snap.validationStatus, .stale,
                          "buffer age below stale threshold must not produce stale status")
    }

    // MARK: - 3. Clipped signal health → clipped

    func testTimecodeValidationClipped() {
        let snap = makeSnapshot(
            hasRecentBuffer: true,
            lastBufferAge: 0.1,
            signalHealth: .clipped,
            acceptedMotionSamples: 0
        )
        XCTAssertEqual(snap.validationStatus, .clipped,
                       "clipped signal health must produce clipped status")
    }

    // MARK: - 4. Channel fault → channelFault

    func testTimecodeValidationChannelFault() {
        let snap = makeSnapshot(
            hasRecentBuffer: true,
            lastBufferAge: 0.1,
            signalHealth: .channelFault,
            acceptedMotionSamples: 0
        )
        XCTAssertEqual(snap.validationStatus, .channelFault,
                       "channelFault signal health must produce channelFault status")
    }

    func testTimecodeValidationChannelFaultTakesPriorityOverClipped() {
        // channelFault must take priority over clipped in classification
        // (cannot co-occur in SignalHealth, but if we call classify directly
        // with .channelFault it must beat .clipped ordering)
        let status = TimecodeValidationSnapshot.classify(
            hasRecentBuffer: true,
            lastBufferAge: 0.1,
            signalHealth: .channelFault,
            acceptedMotionSamples: 0,
            droppedSilence: 0,
            droppedClipped: 5,
            droppedChannelFault: 5,
            droppedWeakSignal: 0,
            droppedLowConfidence: 0
        )
        XCTAssertEqual(status, .channelFault)
    }

    // MARK: - 5. Good signal + accepted samples → usablePrototypeControl

    func testTimecodeValidationUsablePrototypeControl() {
        let snap = makeSnapshot(
            hasRecentBuffer: true,
            lastBufferAge: 0.05,
            signalHealth: .usable,
            acceptedMotionSamples: 10
        )
        XCTAssertEqual(snap.validationStatus, .usablePrototypeControl,
                       "usable signal with accepted motion samples must produce usablePrototypeControl")
    }

    // MARK: - 6. Drops increasing + no accepted samples → decodingButDropping

    func testTimecodeValidationDecodingButDropping() {
        let snap = makeSnapshot(
            hasRecentBuffer: true,
            lastBufferAge: 0.1,
            signalHealth: .usable,
            acceptedMotionSamples: 0,
            droppedLowConfidence: 8
        )
        XCTAssertEqual(snap.validationStatus, .decodingButDropping,
                       "drops accumulating with no accepted samples must produce decodingButDropping")
    }

    func testTimecodeValidationDecodingButDroppingWithSilenceDrops() {
        let snap = makeSnapshot(
            hasRecentBuffer: true,
            lastBufferAge: 0.1,
            signalHealth: .weak,
            acceptedMotionSamples: 0,
            droppedSilence: 4,
            droppedWeakSignal: 2
        )
        XCTAssertEqual(snap.validationStatus, .decodingButDropping,
                       "any drop type with no accepted samples must produce decodingButDropping")
    }

    // MARK: - 7. Recent buffer + no decode → receivingButNoDecode

    func testTimecodeValidationReceivingButNoDecode() {
        let snap = makeSnapshot(
            hasRecentBuffer: true,
            lastBufferAge: 0.1,
            signalHealth: .usable,
            acceptedMotionSamples: 0,
            droppedSilence: 0,
            droppedClipped: 0,
            droppedChannelFault: 0,
            droppedWeakSignal: 0,
            droppedLowConfidence: 0
        )
        XCTAssertEqual(snap.validationStatus, .receivingButNoDecode,
                       "usable signal with no decode output and no drops must produce receivingButNoDecode")
    }

    // MARK: - 8. Snapshot preserves source label

    func testTimecodeValidationSnapshotPreservesSourceLabel() {
        let snap = makeSnapshot(sourceLabel: "timecode_live")
        XCTAssertEqual(snap.sourceLabel, "timecode_live",
                       "snapshot must preserve source label")
    }

    func testTimecodeValidationSnapshotSourceLabelFromPipeline() {
        let pipeline = makePipeline(mode: .controlPrototype)
        let snap = pipeline.makeValidationSnapshot()
        XCTAssertEqual(snap.sourceLabel, "timecode_live",
                       "pipeline snapshot must carry timecode_live source label")
    }

    // MARK: - 9. resetCounters clears counters but does not change mode

    func testTimecodeValidationResetClearsCounters() {
        let pipeline = makePipeline(mode: .controlPrototype)

        // Manually set counter values to something non-default
        // by feeding silence (which increments droppedSilence via diagnostics)
        let zeros = [Float](repeating: 0, count: 441)
        pipeline.pushStereoBuffer(left: zeros, right: zeros, sampleRate: 44100)

        let modeBeforeReset = pipeline.mode
        pipeline.resetCounters()

        XCTAssertEqual(pipeline.counters.droppedSilence, 0,
                       "resetCounters must zero droppedSilence")
        XCTAssertEqual(pipeline.counters.droppedClipped, 0,
                       "resetCounters must zero droppedClipped")
        XCTAssertEqual(pipeline.counters.acceptedMotionSamples, 0,
                       "resetCounters must zero acceptedMotionSamples")
        XCTAssertEqual(pipeline.counters.droppedLowConfidence, 0,
                       "resetCounters must zero droppedLowConfidence")
        XCTAssertTrue(pipeline.counters.lastDropReason.isEmpty,
                      "resetCounters must empty lastDropReason")

        XCTAssertEqual(pipeline.mode, modeBeforeReset,
                       "resetCounters must not change pipeline mode")
    }

    func testTimecodeValidationResetCountersClearsMaxAbsRate() {
        let pipeline = makePipeline(mode: .controlPrototype)
        pipeline.resetCounters()
        XCTAssertEqual(pipeline.counters.maxAbsRate, 0,
                       "resetCounters must zero maxAbsRate")
    }

    // MARK: - 10. No final commercial compatibility claim in snapshot

    func testTimecodeValidationNoFinalCompatibilityClaim() {
        let pipeline = makePipeline(mode: .controlPrototype)
        let snap = pipeline.makeValidationSnapshot()

        // Source label must not claim commercial format compatibility
        let forbiddenSubstrings = ["serato", "sdj", "traktor", "rane_timecode",
                                    "final", "compatible", "licensed"]
        for forbidden in forbiddenSubstrings {
            XCTAssertFalse(snap.sourceLabel.lowercased().contains(forbidden),
                           "sourceLabel must not contain '\(forbidden)' — prototype only")
        }

        // Status labels must not claim commercial compatibility
        for status in TimecodeValidationStatus.allCases {
            XCTAssertFalse(status.label.lowercased().contains("serato"),
                           "status label '\(status.label)' must not claim Serato compatibility")
            XCTAssertFalse(status.label.lowercased().contains("sdj"),
                           "status label '\(status.label)' must not claim SDJ compatibility")
        }

        // Debug text must include prototype disclaimer
        XCTAssertTrue(snap.debugText.lowercased().contains("prototype"),
                      "debugText must include 'prototype' disclaimer")
        XCTAssertTrue(snap.debugText.lowercased().contains("not sent to notation"),
                      "debugText must clarify signal is not sent to notation")
    }

    // MARK: - Pipeline snapshot: counters populated from pipeline state

    func testTimecodeValidationSnapshotFromPipelineDefaultsNoSignal() {
        let pipeline = makePipeline(mode: .disabled)
        let snap = pipeline.makeValidationSnapshot()
        XCTAssertFalse(snap.hasRecentBuffer,
                       "pipeline with no buffers must report no recent buffer")
        XCTAssertNil(snap.lastBufferAge,
                     "pipeline with no buffers must report nil lastBufferAge")
        XCTAssertEqual(snap.validationStatus, .noSignal,
                       "fresh pipeline with no buffers must produce noSignal")
    }

    func testTimecodeValidationSnapshotStaleAfterThreshold() {
        let pipeline = makePipeline(mode: .diagnosticsOnly)

        pipeline.pushStereoBuffer(
            left: [Float](repeating: 0.3, count: 441),
            right: [Float](repeating: 0.3, count: 441),
            sampleRate: 44100
        )

        // Override: simulate a stale age by snapshotting with a future reference time
        let futureNow = Date().addingTimeInterval(TimecodeValidationSnapshot.staleThreshold + 2.0)
        let snap = pipeline.makeValidationSnapshot(now: futureNow)
        XCTAssertEqual(snap.validationStatus, .stale,
                       "snapshot taken well after last buffer must report stale")
    }

    // MARK: - debugText sanity

    func testTimecodeValidationDebugTextContainsRequiredFields() {
        let snap = makeSnapshot(
            mode: .controlPrototype,
            hasRecentBuffer: true,
            lastBufferAge: 1.23,
            signalHealth: .usable,
            acceptedMotionSamples: 5,
            droppedSilence: 2,
            sourceLabel: "timecode_live"
        )
        let text = snap.debugText
        XCTAssertTrue(text.contains("timecode_live"), "debugText must contain source label")
        XCTAssertTrue(text.contains("prototype"), "debugText must carry prototype disclaimer")
        XCTAssertTrue(text.contains("not routed to notation"), "debugText must clarify notation routing for controlPrototype with accepted samples")
        XCTAssertTrue(text.contains("usable"), "debugText must reflect signal health")
    }

    // MARK: - debugText notation-output wording per mode

    func testDebugTextNotationLine_diagnosticsOnly() {
        let snap = makeSnapshot(mode: .diagnosticsOnly)
        XCTAssertTrue(snap.debugText.contains("Not sent to notation — diagnostics only"),
                      "diagnosticsOnly must produce exact diagnostics-only notation line")
    }

    func testDebugTextNotationLine_controlPrototype_noSamples() {
        let snap = makeSnapshot(mode: .controlPrototype, acceptedMotionSamples: 0)
        XCTAssertTrue(snap.debugText.contains("Not sent to notation — no prototype motion samples yet"),
                      "controlPrototype with 0 accepted samples must say no prototype motion samples yet")
    }

    func testDebugTextNotationLine_controlPrototype_withSamples() {
        let snap = makeSnapshot(mode: .controlPrototype, acceptedMotionSamples: 3)
        XCTAssertTrue(snap.debugText.contains("Notation output: prototype motion is decoded but not routed to notation here"),
                      "controlPrototype with accepted samples must produce decoded-but-not-routed notation line")
    }

    func testDebugTextNotationLine_disabled_fallback() {
        let snap = makeSnapshot(mode: .disabled)
        let text = snap.debugText
        XCTAssertTrue(text.contains("Not sent to notation"),
                      "disabled mode must include not-sent-to-notation line")
        XCTAssertFalse(text.contains("diagnostics only"),
                       "disabled mode must not include diagnostics-only wording")
        XCTAssertFalse(text.contains("no prototype motion samples yet"),
                       "disabled mode must not include prototype-samples wording")
        XCTAssertFalse(text.contains("not routed to notation"),
                       "disabled mode must not include not-routed-to-notation wording")
    }

    // MARK: - Deterministic pipeline validation (Batch 11)

    /// Full pipeline validation using synthetic 1 kHz stereo quadrature.
    ///
    /// Generates a normal-speed forward signal in memory (left = sine,
    /// right = sine - 90°), feeds it through the
    /// `TimecodeControlPipeline` in `.controlPrototype` mode, and asserts
    /// every metric that appears in the Copy Debug snapshot.
    ///
    /// This gives a repeatable, hardware-free regression gate for the
    /// prototype quadrature decode chain. No Loopback, VLC, or manual
    /// Copy Debug needed.
    ///
    /// **Batch 11:** Deterministic timecode validation automation.
    /// ScratchLab prototype quadrature only — not a Serato/SDJ claim.
    func testSyntheticQuadratureFullPipelineValidation() {
        let sampleRate: Double = 44100
        let carrierFrequency: Float = 1000
        let framesPerBuffer = 1024
        let amplitude: Float = 0.42
        let bufferCount = 220  // ~5.1 s of audio

        let pipeline = TimecodeControlPipeline(sampleRate: sampleRate, channelCount: 2)
        pipeline.mode = .controlPrototype

        // Generate and push continuous quadrature buffers.
        // Left = sine(carrier), Right = sine(carrier - 90°).
        // Phase-continuous across buffer boundaries.
        for bufferIndex in 0..<bufferCount {
            let startFrame = bufferIndex * framesPerBuffer
            var left = [Float](repeating: 0, count: framesPerBuffer)
            var right = [Float](repeating: 0, count: framesPerBuffer)

            for frameOffset in 0..<framesPerBuffer {
                let absoluteFrame = startFrame + frameOffset
                let phase = 2.0 * Float.pi * carrierFrequency * Float(absoluteFrame) / Float(sampleRate)
                left[frameOffset] = amplitude * sin(phase)
                right[frameOffset] = amplitude * sin(phase - Float.pi / 2.0)
            }

            pipeline.pushStereoBuffer(
                left: left, right: right,
                sampleRate: sampleRate,
                frameCount: framesPerBuffer
            )
        }

        // Flush accumulated buffers through the full chain:
        // decoder → calibration → stability filter → platter adapter.
        let timeline = pipeline.flushDecode()
        XCTAssertNotNil(timeline, "Synthetic quadrature must produce a trusted platter timeline")

        let c = pipeline.counters

        // ── Signal health ──
        XCTAssertEqual(c.signalHealth, SignalHealth.usable.rawValue,
                       "Signal health must be usable for clean quadrature")

        // ── Drop counters: all zero for clean synthetic quadrature ──
        XCTAssertEqual(c.droppedSilence, 0,
                       "droppedSilence must be 0 — clean quadrature is not silent")
        XCTAssertEqual(c.droppedClipped, 0,
                       "droppedClipped must be 0 — amplitude \(amplitude) is below 0.999")
        XCTAssertEqual(c.droppedChannelFault, 0,
                       "droppedChannelFault must be 0 — L/R channels are balanced")
        XCTAssertEqual(c.droppedWeakSignal, 0,
                       "droppedWeakSignal must be 0 — phase lock is strong")
        XCTAssertEqual(c.droppedLowConfidence, 0,
                       "droppedLowConfidence must be 0 — confidence exceeds adapter threshold")

        // ── Accepted samples ──
        XCTAssertGreaterThan(c.acceptedMotionSamples, 0,
                             "Must have accepted motion samples for clean quadrature")

        // ── Confidence ──
        XCTAssertGreaterThan(c.averageConfidence, 0.3,
                             "Average confidence must exceed 0.3, got \(c.averageConfidence)")

        // ── Rate: 1 kHz carrier is normal (1x) platter speed ──
        let rateEpsilon: Double = 0.05
        XCTAssertEqual(c.currentRate, 1.0, accuracy: rateEpsilon)
        XCTAssertEqual(c.smoothedRate, 1.0, accuracy: rateEpsilon)
        XCTAssertEqual(c.maxAbsRate, 1.0, accuracy: rateEpsilon)
        XCTAssertEqual(c.maxAbsSmoothedRate, 1.0, accuracy: rateEpsilon)

        // ── Stability ──
        XCTAssertEqual(c.rejectedSpikeCount, 0,
                       "rejectedSpikeCount must be 0 — no rate spikes in stationary signal")
        XCTAssertEqual(c.heldDropoutCount, 0,
                       "heldDropoutCount must be 0 — no consecutive empty flushes")
        XCTAssertEqual(c.longDropoutCount, 0,
                       "longDropoutCount must be 0 — no long dropout windows")
        XCTAssertEqual(c.lastDropoutDuration, 0,
                       "lastDropoutDuration must be 0 — no dropout window opened")

        // ── Direction: negative phase is forward on measured hardware ──
        XCTAssertEqual(c.directionChanges, 0,
                       "directionChanges must be 0 — no direction flips")
        XCTAssertEqual(c.currentDirection, TimecodeDirection.forward.rawValue)

        // ── Drop/spike reasons: empty ──
        XCTAssertTrue(c.lastDropReason.isEmpty,
                      "lastDropReason must be empty, got '\(c.lastDropReason)'")
        XCTAssertTrue(c.lastSpikeReason.isEmpty,
                      "lastSpikeReason must be empty, got '\(c.lastSpikeReason)'")

        // ── Validation snapshot ──
        let snap = pipeline.makeValidationSnapshot()

        XCTAssertEqual(snap.validationStatus, .usablePrototypeControl,
                       "Status must be usablePrototypeControl, got \(snap.validationStatus.rawValue)")
        XCTAssertEqual(snap.signalHealth, .usable)
        XCTAssertTrue(snap.hasRecentBuffer,
                      "Snapshot must report a recent buffer (diagnostics ran on first push)")

        // L/R RMS present and balanced
        XCTAssertGreaterThan(snap.leftRMS, 0, "Left RMS must be > 0")
        XCTAssertGreaterThan(snap.rightRMS, 0, "Right RMS must be > 0")
        let rmsRatio = Double(snap.leftRMS) / Double(max(snap.rightRMS, 0.0001))
        XCTAssertGreaterThan(rmsRatio, 0.85, "L/R RMS ratio \(rmsRatio) must be near 1.0")
        XCTAssertLessThan(rmsRatio, 1.15, "L/R RMS ratio \(rmsRatio) must be near 1.0")

        // Snapshot direction / rate mirror pipeline counters
        XCTAssertEqual(snap.decodedDirection, TimecodeDirection.forward.rawValue)
        XCTAssertEqual(snap.directionChanges, 0)
        XCTAssertEqual(snap.decodedRate, 1.0, accuracy: rateEpsilon)

        // Debug text sanity
        let debugText = snap.debugText
        XCTAssertTrue(debugText.contains("prototype"),
                      "debugText must carry prototype disclaimer")
        XCTAssertTrue(debugText.contains("not routed to notation"),
                      "debugText must clarify notation routing for controlPrototype with accepted samples")
        XCTAssertTrue(debugText.contains("usablePrototypeControl"),
                      "debugText must include validation status")

        // Source label
        XCTAssertEqual(snap.sourceLabel, "timecode_live",
                       "Source label must be timecode_live")
    }
}

#endif // DEBUG
