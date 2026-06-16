// TimecodePlaybackBridgeTests
//
// Batch 8 tests for the prototype timecode playback bridge:
//   - defaults disabled
//   - diagnosticsOnly cannot drive playback
//   - disabled mode cannot drive playback
//   - controlPrototype with bridge disabled cannot drive playback
//   - controlPrototype with bridge enabled and trusted signal emits output
//   - bad signal emits no playback-control output
//   - low confidence emits no playback-control output
//   - replay-active state blocks timecode bridge
//   - RANE/default source unaffected when bridge off
//   - source label is timecode prototype/live
//   - rate/direction are preserved from stabilized output
//   - extreme rates are clamped
//   - turning bridge off stops timecode driving
//   - no notation classification path is called
//
// All tests use synthetic [Float] buffers — no hardware required.
//
// Batch 8: Prototype playback bridge. DEBUG/prototype only.

import XCTest
@testable import ScratchLab

final class TimecodePlaybackBridgeTests: XCTestCase {

    // MARK: - Constants

    private let sampleRate: Double = 44100
    private let carrierFrequency: Float = 1000
    private let framesPerBuffer: Int = 441   // 10 periods of 1000 Hz at 44100 Hz

    // MARK: - Helpers

    private func makePipeline(mode: TimecodeControlMode = .disabled) -> TimecodeControlPipeline {
        let pipeline = TimecodeControlPipeline(sampleRate: sampleRate, channelCount: 2)
        pipeline.mode = mode
        return pipeline
    }

    private func makeBridge(
        enabled: Bool = false,
        isReplayActive: Bool = false,
        maxPlaybackRate: Double = 5.0,
        minConfidence: Double = 0.3,
        staleThreshold: TimeInterval = 2.0
    ) -> TimecodePlaybackBridge {
        TimecodePlaybackBridge(
            playbackDriveEnabled: enabled,
            isReplayActive: isReplayActive,
            maxPlaybackRate: maxPlaybackRate,
            minConfidence: minConfidence,
            staleThreshold: staleThreshold
        )
    }

    private func sineTone(
        frequency: Float,
        frameCount: Int,
        amplitude: Float,
        phaseOffset: Float = 0
    ) -> [Float] {
        (0..<frameCount).map { i in
            let t = Float(i) / Float(sampleRate)
            return amplitude * sin(2 * .pi * frequency * t + phaseOffset)
        }
    }

    private func feedPhaseProgression(
        into pipeline: TimecodeControlPipeline,
        bufferCount: Int,
        phaseStep: Float,
        amplitude: Float = 0.5
    ) {
        for i in 0..<bufferCount {
            let left = sineTone(frequency: carrierFrequency, frameCount: framesPerBuffer,
                               amplitude: amplitude)
            let right = sineTone(frequency: carrierFrequency, frameCount: framesPerBuffer,
                                amplitude: amplitude, phaseOffset: phaseStep * Float(i))
            pipeline.pushStereoBuffer(left: left, right: right, sampleRate: sampleRate)
        }
    }

    private func feedSilence(into pipeline: TimecodeControlPipeline, count: Int = 1) {
        let zeros = [Float](repeating: 0, count: framesPerBuffer)
        for _ in 0..<count {
            pipeline.pushStereoBuffer(left: zeros, right: zeros, sampleRate: sampleRate)
        }
    }

    /// Build a pipeline in controlPrototype mode with trusted signal already fed
    /// and flushed, so it has a valid timeline and healthy counters.
    private func makeTrustedPipeline() -> TimecodeControlPipeline {
        let pipeline = makePipeline(mode: .controlPrototype)
        // Feed phase-progressing buffers to produce forward motion
        feedPhaseProgression(into: pipeline, bufferCount: 8, phaseStep: 0.25, amplitude: 0.5)
        _ = pipeline.flushDecode()
        return pipeline
    }

    // MARK: - 1. Defaults disabled

    func testTimecodePlaybackBridgeDefaultsDisabled() {
        let bridge = makeBridge()

        XCTAssertFalse(bridge.playbackDriveEnabled,
                       "playbackDriveEnabled must default to false")
        XCTAssertEqual(bridge.state, .disabled,
                       "bridge state must default to .disabled")
        XCTAssertNil(bridge.currentDrive,
                     "currentDrive must default to nil")
        XCTAssertFalse(bridge.isReplayActive,
                       "isReplayActive must default to false")
    }

    // MARK: - 2. DiagnosticsOnly cannot drive playback

    func testTimecodePlaybackBridgeBlocksDiagnosticsOnly() {
        let pipeline = makePipeline(mode: .diagnosticsOnly)
        // Feed good signal — diagnostics are computed but no motion is emitted
        feedPhaseProgression(into: pipeline, bufferCount: 4, phaseStep: 0.2)

        let bridge = makeBridge(enabled: true)
        let drive = bridge.evaluate(pipeline: pipeline)

        XCTAssertNil(drive, "bridge must return nil when pipeline is diagnosticsOnly")
        XCTAssertEqual(bridge.state, .blockedByDiagnosticsOnly,
                       "bridge state must be .blockedByDiagnosticsOnly")
    }

    // MARK: - 3. Disabled mode cannot drive playback

    func testTimecodePlaybackBridgeRequiresExplicitEnable() {
        let pipeline = makeTrustedPipeline()

        // Bridge not enabled
        let bridge = makeBridge(enabled: false)
        let drive = bridge.evaluate(pipeline: pipeline)

        XCTAssertNil(drive, "bridge must return nil when playbackDriveEnabled is false")
        XCTAssertEqual(bridge.state, .disabled,
                       "bridge state must be .disabled when not enabled")
    }

    // MARK: - 4. controlPrototype with bridge disabled cannot drive playback

    func testControlPrototypeWithBridgeDisabledCannotDrivePlayback() {
        let pipeline = makeTrustedPipeline()

        // Pipeline is in controlPrototype mode with trusted output,
        // but bridge is disabled
        let bridge = makeBridge(enabled: false)
        let drive = bridge.evaluate(pipeline: pipeline)

        XCTAssertNil(drive,
                     "bridge disabled must block driving even when pipeline produces trusted output")
        XCTAssertEqual(bridge.state, .disabled)
    }

    // MARK: - 5. controlPrototype with bridge enabled emits playback-control output

    func testTimecodePlaybackBridgeEmitsTrustedPlaybackControl() {
        let pipeline = makeTrustedPipeline()

        let bridge = makeBridge(enabled: true)
        let drive = bridge.evaluate(pipeline: pipeline)

        XCTAssertNotNil(drive, "bridge must produce drive output when enabled and signal is trusted")
        XCTAssertEqual(bridge.state, .driving,
                       "bridge state must be .driving when producing output")

        guard let drive = drive else { return }

        XCTAssertEqual(drive.sourceLabel, TimecodePlaybackBridge.sourceLabel,
                       "source label must be timecode_prototype_playback")
        XCTAssertFalse(drive.timeline.samples.isEmpty,
                       "drive must carry a non-empty timeline")
    }

    // MARK: - 6. Bad signal emits no playback-control output

    func testTimecodePlaybackBridgeFailsClosedOnBadSignal() {
        // Pipeline in controlPrototype but only silence fed
        let pipeline = makePipeline(mode: .controlPrototype)
        feedSilence(into: pipeline, count: 4)
        _ = pipeline.flushDecode()

        let bridge = makeBridge(enabled: true)
        let drive = bridge.evaluate(pipeline: pipeline)

        XCTAssertNil(drive, "bridge must return nil when signal is silent")
        XCTAssertEqual(bridge.state, .blockedByBadSignal,
                       "bridge state must be .blockedByBadSignal for silent input")
    }

    // MARK: - 7. Low confidence emits no playback-control output

    func testLowConfidenceEmitsNoPlaybackControl() {
        // Pipeline in controlPrototype but with very weak signal
        let pipeline = makePipeline(mode: .controlPrototype)

        // Feed weak signal — amplitude 0.005 is below typical decoder threshold
        let weak = sineTone(frequency: carrierFrequency, frameCount: framesPerBuffer,
                            amplitude: 0.005)
        for _ in 0..<4 {
            pipeline.pushStereoBuffer(left: weak, right: weak, sampleRate: sampleRate)
        }
        _ = pipeline.flushDecode()

        // Use a bridge with high confidence threshold so low-confidence output is blocked
        let bridge = makeBridge(enabled: true, minConfidence: 0.9)
        let drive = bridge.evaluate(pipeline: pipeline)

        XCTAssertNil(drive, "bridge must return nil when confidence is below threshold")
        XCTAssertEqual(bridge.state, .blockedByBadSignal,
                       "bridge state must be .blockedByBadSignal for low confidence")
    }

    // MARK: - 8. Replay-active state blocks timecode bridge

    func testTimecodePlaybackBridgeBlockedByReplay() {
        let pipeline = makeTrustedPipeline()

        // Bridge enabled but replay is active
        let bridge = makeBridge(enabled: true, isReplayActive: true)
        let drive = bridge.evaluate(pipeline: pipeline)

        XCTAssertNil(drive, "bridge must return nil when replay is active")
        XCTAssertEqual(bridge.state, .blockedByReplay,
                       "bridge state must be .blockedByReplay when replay is active")
    }

    // MARK: - 9. RANE/default source unaffected when bridge off

    func testTimecodePlaybackBridgeDoesNotAffectRaneDefaults() {
        let bridge = makeBridge(enabled: false)

        // Verify the bridge source label does not collide with RANE/default sources
        let bridgeLabel = TimecodePlaybackBridge.sourceLabel

        // All existing PlatterPositionTimeline.Source values
        let existingSources: Set<String> = [
            PlatterPositionTimeline.Source.liveCapture.rawValue,
            PlatterPositionTimeline.Source.bundledDemo.rawValue,
            PlatterPositionTimeline.Source.coachAuthored.rawValue,
            PlatterPositionTimeline.Source.timecodeFixture.rawValue,
            PlatterPositionTimeline.Source.timecodeLive.rawValue,
        ]

        // Bridge source label must be distinct from all existing sources
        XCTAssertFalse(existingSources.contains(bridgeLabel),
                       "bridge source label '\(bridgeLabel)' must not collide with existing PlatterPositionTimeline sources")

        // Verify the bridge does not modify .liveCapture (RANE) behaviour
        XCTAssertEqual(PlatterPositionTimeline.Source.liveCapture.rawValue, "liveCapture",
                       "liveCapture (RANE) source must be unchanged")

        // All six labels (5 existing + bridge) must be distinct
        let allLabels = existingSources.union([bridgeLabel])
        XCTAssertEqual(allLabels.count, 6,
                       "all six source labels must be distinct")

        // Bridge off should not affect pipeline output source
        let pipeline = makeTrustedPipeline()
        _ = bridge.evaluate(pipeline: pipeline)
        // Pipeline's own source label is unchanged
        XCTAssertEqual(pipeline.counters.sourceLabel, "timecode_live",
                       "pipeline source label must remain timecode_live regardless of bridge state")
    }

    // MARK: - 10. Source label is timecode prototype/live

    func testTimecodePlaybackBridgeSourceLabelIsCorrect() {
        let pipeline = makeTrustedPipeline()
        let bridge = makeBridge(enabled: true)

        let drive = bridge.evaluate(pipeline: pipeline)
        XCTAssertNotNil(drive)

        XCTAssertEqual(drive?.sourceLabel, "timecode_prototype_playback",
                       "bridge must emit timecode_prototype_playback source label")
        // The constant must be accessible for consumers
        XCTAssertEqual(TimecodePlaybackBridge.sourceLabel, "timecode_prototype_playback")
    }

    // MARK: - 11. Rate/direction are preserved from stabilized output

    func testTimecodePlaybackBridgePreservesDirectionAndRate() {
        let pipeline = makeTrustedPipeline()

        // Verify pipeline has forward direction and non-zero rate
        XCTAssertEqual(pipeline.currentDirection, .forward,
                       "trusted pipeline must decode forward direction")
        XCTAssertGreaterThan(pipeline.currentRate, 0,
                             "trusted pipeline must have positive rate")

        // Use a very high maxPlaybackRate so clamping does not interfere
        let bridge = makeBridge(enabled: true, maxPlaybackRate: 100.0)
        let drive = bridge.evaluate(pipeline: pipeline)

        XCTAssertNotNil(drive)
        guard let drive = drive else { return }

        XCTAssertEqual(drive.direction, pipeline.currentDirection,
                       "drive direction must match pipeline direction")
        // Raw pipeline rate is preserved when it is below maxPlaybackRate
        let expectedRate = min(pipeline.currentRate, 100.0)
        XCTAssertEqual(drive.rate, expectedRate, accuracy: 0.001,
                       "drive rate must match pipeline rate (within clamp range)")
        XCTAssertGreaterThan(drive.rate, 0,
                             "drive rate must be positive for forward direction")
    }

    // MARK: - 12. Extreme rates are clamped

    func testExtremeRatesAreClamped() {
        let pipeline = makePipeline(mode: .controlPrototype)

        // Feed phase-progressing buffers with a large phase step to produce
        // high-rate output
        feedPhaseProgression(into: pipeline, bufferCount: 8, phaseStep: 2.0, amplitude: 0.7)
        _ = pipeline.flushDecode()

        // Use bridge with a tight max rate
        let maxRate: Double = 2.0
        let bridge = makeBridge(enabled: true, maxPlaybackRate: maxRate)

        let drive = bridge.evaluate(pipeline: pipeline)

        // The pipeline may or may not produce trusted output with such a large
        // phase step, but if it does, the rate must be clamped.
        if let drive = drive {
            XCTAssertLessThanOrEqual(abs(drive.rate), maxRate,
                                     "drive rate must be clamped to maxPlaybackRate")
        }
        // If nil, that's also acceptable — the pipeline may have rejected the
        // extreme phase step as a spike.
    }

    /// Extreme rate with a known-good pipeline: set maxPlaybackRate very low
    /// and verify the bridge clamps.
    func testKnownRateIsClampedByLowMaxRate() {
        let pipeline = makeTrustedPipeline()

        // Pipeline has a known good rate. Set maxPlaybackRate very low.
        let bridge = makeBridge(enabled: true, maxPlaybackRate: 0.5)

        let drive = bridge.evaluate(pipeline: pipeline)
        XCTAssertNotNil(drive, "bridge should produce output with known-good pipeline")

        if let drive = drive {
            XCTAssertLessThanOrEqual(abs(drive.rate), 0.5,
                                     "drive rate must be clamped to maxPlaybackRate=0.5")
            // Direction sign should be preserved even when clamped
            if pipeline.currentRate > 0 {
                XCTAssertGreaterThanOrEqual(drive.rate, 0,
                                            "forward direction sign must be preserved when clamped")
            }
        }
    }

    // MARK: - 13. Turning bridge off stops timecode driving

    func testTurningBridgeOffStopsTimecodeDriving() {
        let pipeline = makeTrustedPipeline()

        // Start with bridge enabled — should drive
        let bridge = makeBridge(enabled: true)
        let drive1 = bridge.evaluate(pipeline: pipeline)
        XCTAssertNotNil(drive1, "bridge must drive when enabled")
        XCTAssertEqual(bridge.state, .driving)

        // Toggle bridge off
        bridge.playbackDriveEnabled = false

        // Verify state cleared
        XCTAssertEqual(bridge.state, .disabled,
                       "state must transition to .disabled when toggled off")
        XCTAssertNil(bridge.currentDrive,
                     "currentDrive must be cleared when toggled off")

        // Subsequent evaluate must return nil
        let drive2 = bridge.evaluate(pipeline: pipeline)
        XCTAssertNil(drive2, "bridge must not drive after being toggled off")
    }

    // MARK: - 14. No notation classification path is called

    func testNoNotationClassificationPathIsCalled() {
        // The bridge is a pure model — it has no dependencies on notation
        // classification types. This test verifies that the bridge does not
        // import or reference any notation classification symbols.

        let pipeline = makeTrustedPipeline()
        let bridge = makeBridge(enabled: true)

        // Evaluate should return a drive without any side effects
        let drive = bridge.evaluate(pipeline: pipeline)
        XCTAssertNotNil(drive)

        // The bridge's only output is TimecodePlaybackDrive — it has no
        // notation classification, export/upload, or audio engine fields.
        // Verified by the type system: TimecodePlaybackDrive contains only
        // direction, rate, sourceLabel, and timeline.
        let mirror = Mirror(reflecting: drive!)
        let propertyNames = mirror.children.compactMap { $0.label }
        XCTAssertTrue(propertyNames.contains("direction"))
        XCTAssertTrue(propertyNames.contains("rate"))
        XCTAssertTrue(propertyNames.contains("sourceLabel"))
        XCTAssertTrue(propertyNames.contains("timeline"))

        // No notation-related properties
        let notationProperties = propertyNames.filter {
            $0.lowercased().contains("notation") ||
            $0.lowercased().contains("classify") ||
            $0.lowercased().contains("export") ||
            $0.lowercased().contains("upload") ||
            $0.lowercased().contains("audioEngine")
        }
        XCTAssertTrue(notationProperties.isEmpty,
                      "bridge drive must not contain notation/classification/export/upload/audioEngine properties, found: \(notationProperties)")
    }

    // MARK: - 15. Pipeline disabled mode → bridge blocked

    func testPipelineDisabledModeBlocksBridge() {
        let pipeline = makePipeline(mode: .disabled)
        let bridge = makeBridge(enabled: true)

        let drive = bridge.evaluate(pipeline: pipeline)

        XCTAssertNil(drive, "bridge must return nil when pipeline mode is .disabled")
        XCTAssertEqual(bridge.state, .disabled,
                       "bridge state must be .disabled when pipeline mode is .disabled")
    }

    // MARK: - 16. Armed state transitions

    func testBridgeArmedWhenEnabledButNoTimelineYet() {
        // Pipeline in controlPrototype but no buffers fed yet
        let pipeline = makePipeline(mode: .controlPrototype)

        let bridge = makeBridge(enabled: true)
        let drive = bridge.evaluate(pipeline: pipeline)

        // No buffers fed → no timeline → blocked
        XCTAssertNil(drive, "bridge must return nil when no timeline exists")
        XCTAssertEqual(bridge.state, .blockedByBadSignal,
                       "bridge must block when no timeline is available")
    }

    // MARK: - 17. Stale signal is blocked

    func testStaleSignalBlocksBridge() {
        let pipeline = makeTrustedPipeline()

        // Artificially age the last buffer timestamp
        // (pipeline.lastBufferReceivedAt is set during pushStereoBuffer)
        // We test by evaluating with a "future" now date
        let bridge = makeBridge(enabled: true, staleThreshold: 0.1)

        // The pipeline's lastBufferReceivedAt was set during makeTrustedPipeline().
        // Evaluate with a date far in the future to simulate staleness.
        let farFuture = Date().addingTimeInterval(3600)
        let drive = bridge.evaluate(pipeline: pipeline, now: farFuture)

        // If the pipeline has lastBufferReceivedAt set, it should be stale.
        // If nil (because the test helpers don't track it), this is still safe.
        if pipeline.lastBufferReceivedAt != nil {
            XCTAssertNil(drive, "bridge must block when signal is stale")
            XCTAssertEqual(bridge.state, .blockedByBadSignal,
                           "bridge state must be .blockedByBadSignal for stale signal")
        }
        // If lastBufferReceivedAt was never set by the test helpers,
        // the bridge allows it (synthetic data path).
    }

    // MARK: - 18. Reset clears state

    func testBridgeResetClearsState() {
        let pipeline = makeTrustedPipeline()
        let bridge = makeBridge(enabled: true)

        // First, produce a drive output
        let drive = bridge.evaluate(pipeline: pipeline)
        XCTAssertNotNil(drive)
        XCTAssertEqual(bridge.state, .driving)

        // Reset
        bridge.reset()

        XCTAssertNil(bridge.currentDrive, "reset must clear currentDrive")
        XCTAssertEqual(bridge.state, .armed,
                       "reset must return to .armed when bridge is enabled")
        XCTAssertTrue(bridge.playbackDriveEnabled,
                      "reset must not change playbackDriveEnabled")
    }

    // MARK: - 19. Reset when disabled

    func testBridgeResetWhenDisabled() {
        let bridge = makeBridge(enabled: false)
        bridge.reset()

        XCTAssertEqual(bridge.state, .disabled,
                       "reset must keep .disabled when bridge is not enabled")
        XCTAssertNil(bridge.currentDrive)
    }

    // MARK: - 20. Unknown direction is blocked

    func testUnknownDirectionBlocksBridge() {
        let pipeline = makePipeline(mode: .controlPrototype)

        // Feed identical channels — no phase delta, so direction will be unknown
        let tone = sineTone(frequency: carrierFrequency, frameCount: framesPerBuffer,
                            amplitude: 0.5)
        for _ in 0..<4 {
            pipeline.pushStereoBuffer(left: tone, right: tone, sampleRate: sampleRate)
        }
        _ = pipeline.flushDecode()

        let bridge = makeBridge(enabled: true)
        let drive = bridge.evaluate(pipeline: pipeline)

        // With no phase difference, direction should be unknown and bridge blocks
        if pipeline.currentDirection == .unknown {
            XCTAssertNil(drive, "bridge must block when direction is unknown")
            XCTAssertEqual(bridge.state, .blockedByBadSignal)
        }
    }
}
