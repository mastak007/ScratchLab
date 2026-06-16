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
            mode: TimecodeControlMode.disabled.rawValue,
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
        XCTAssertTrue(text.contains("NOT sent to notation"), "debugText must state not sent to notation")
        XCTAssertTrue(text.contains("usable"), "debugText must reflect signal health")
    }
}

#endif // DEBUG
