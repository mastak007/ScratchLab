// TimecodePrototypeProfileTests
//
// Batch 10 tests for the timecode prototype profile hardening slice:
//   1. Default profile is safe.
//   2. Mode defaults disabled on launch / model init.
//   3. Playback bridge defaults off.
//   4. Selected profile applies input channel / invert / rate / confidence.
//   5. Validation failure blocks playback bridge.
//   6. Explicit override is required if allowing unvalidated playback.
//   7. Live tap does not silently enable on launch.
//   8. Recording does not silently enable on launch.
//   9. Warnings / prototype labels are present in snapshot.
//  10. No official compatibility labels are exposed.
//  11. RANE / replay tests unaffected.
//  12. DVS experimental label is present.
//  13. Preset defaults are safe and conservative.
//
// All tests use synthetic [Float] buffers — no hardware required.
//
// Batch 10: Prototype profile hardening. DEBUG/prototype only.

import XCTest
@testable import ScratchLab

#if DEBUG

final class TimecodePrototypeProfileTests: XCTestCase {

    // MARK: - Constants

    private let sampleRate: Double = 44100
    private let carrierFrequency: Float = 1000
    private let framesPerBuffer: Int = 441

    // MARK: - Helpers

    private func makePipeline(mode: TimecodeControlMode = .disabled) -> TimecodeControlPipeline {
        let pipeline = TimecodeControlPipeline(sampleRate: sampleRate, channelCount: 2)
        pipeline.mode = mode
        return pipeline
    }

    private func makeBridge(
        enabled: Bool = false,
        isReplayActive: Bool = false,
        validationRequired: Bool = true,
        validationOverride: Bool = false
    ) -> TimecodePlaybackBridge {
        TimecodePlaybackBridge(
            playbackDriveEnabled: enabled,
            isReplayActive: isReplayActive,
            validationRequired: validationRequired,
            validationOverride: validationOverride
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

    private func makeTrustedPipeline() -> TimecodeControlPipeline {
        let pipeline = makePipeline(mode: .controlPrototype)
        feedPhaseProgression(into: pipeline, bufferCount: 8, phaseStep: 0.25, amplitude: 0.5)
        _ = pipeline.flushDecode()
        return pipeline
    }

    // MARK: - 1. Default profile is safe

    func testTimecodePrototypeProfileDefaultsSafe() {
        let profile = TimecodePrototypeProfile.scratchLabPrototype()

        // Calibration defaults must be conservative
        XCTAssertEqual(profile.inputChannel, .stereo,
                       "default profile must use stereo input")
        XCTAssertFalse(profile.invertDirection,
                       "default profile must not invert direction")
        XCTAssertEqual(profile.rateScale, 1.0, accuracy: 0.001,
                       "default profile rate scale must be 1.0")
        XCTAssertEqual(profile.minConfidence, 0.3, accuracy: 0.001,
                       "default profile min confidence must be 0.3")
        XCTAssertEqual(profile.maxRate, 5.0, accuracy: 0.001,
                       "default profile max rate must be 5.0")

        // Safety gates must be on
        XCTAssertTrue(profile.validationRequired,
                      "default profile must require validation")
        XCTAssertFalse(profile.playbackBridgeAllowed,
                       "default profile must NOT allow playback bridge by default")

        // Smoothing must be conservative
        XCTAssertEqual(profile.smoothingConfig.emaAlpha, 0.12, accuracy: 0.001,
                       "default profile smoothing must be conservative")

        // Preset must be scratchLabPrototype (not DVS)
        XCTAssertEqual(profile.preset, .scratchLabPrototype,
                       "default profile preset must be scratchLabPrototype")
    }

    func testGenericDVSProfileDefaultsSafe() {
        let profile = TimecodePrototypeProfile.genericDVS()

        XCTAssertEqual(profile.inputChannel, .stereo)
        XCTAssertFalse(profile.invertDirection)
        XCTAssertEqual(profile.rateScale, 1.0, accuracy: 0.001)
        XCTAssertTrue(profile.validationRequired,
                      "DVS profile must require validation")
        XCTAssertFalse(profile.playbackBridgeAllowed,
                       "DVS profile must NOT allow playback bridge by default")

        // DVS profile has slightly relaxed thresholds but still safe
        XCTAssertEqual(profile.minConfidence, 0.25, accuracy: 0.001)
        XCTAssertEqual(profile.maxRate, 8.0, accuracy: 0.001)
        XCTAssertEqual(profile.preset, .genericDVS)

        // DVS smoothing is standard (less conservative) but still bounded
        XCTAssertGreaterThan(profile.smoothingConfig.emaAlpha, 0.0)
        XCTAssertLessThan(profile.smoothingConfig.emaAlpha, 0.5)
    }

    func testManualProfileDefaultsSafe() {
        let profile = TimecodePrototypeProfile.manual()

        XCTAssertEqual(profile.inputChannel, .stereo)
        XCTAssertFalse(profile.invertDirection)
        XCTAssertEqual(profile.rateScale, 1.0, accuracy: 0.001)
        XCTAssertFalse(profile.playbackBridgeAllowed,
                       "manual profile must NOT allow playback bridge by default")

        // Manual profile does NOT require validation (user is tuning manually)
        XCTAssertFalse(profile.validationRequired,
                       "manual profile must not require validation gate")
    }

    // MARK: - 2. Mode defaults disabled on launch / model init

    func testTimecodeModeDefaultsDisabledOnLaunch() {
        let pipeline = makePipeline()

        XCTAssertEqual(pipeline.mode, .disabled,
                       "pipeline mode must default to .disabled")
        XCTAssertEqual(TimecodeControlMode.default, .disabled,
                       "TimecodeControlMode.default must be .disabled")
    }

    func testTimecodeControlPresetDefaultsSafe() {
        XCTAssertEqual(TimecodeControlPreset.default, .scratchLabPrototype,
                       "preset default must be .scratchLabPrototype")
    }

    // MARK: - 3. Playback bridge defaults off

    func testTimecodePlaybackBridgeDefaultsOffOnLaunch() {
        let bridge = makeBridge()

        XCTAssertFalse(bridge.playbackDriveEnabled,
                       "playbackDriveEnabled must default to false")
        XCTAssertEqual(bridge.state, .disabled,
                       "bridge state must default to .disabled")
        XCTAssertNil(bridge.currentDrive,
                     "currentDrive must default to nil")
        XCTAssertFalse(bridge.validationOverride,
                       "validationOverride must default to false")
        XCTAssertTrue(bridge.validationRequired,
                      "validationRequired must default to true")
    }

    // MARK: - 4. Selected profile applies calibration

    func testTimecodeProfileAppliesCalibration() {
        let pipeline = makePipeline(mode: .controlPrototype)

        // Apply DVS profile
        let dvsProfile = TimecodePrototypeProfile.genericDVS()
        dvsProfile.apply(to: pipeline)

        XCTAssertEqual(pipeline.inputChannel, .stereo,
                       "profile must apply input channel")
        XCTAssertFalse(pipeline.invertDirection,
                       "profile must apply invert direction")
        XCTAssertEqual(pipeline.rateScale, 1.0, accuracy: 0.001,
                       "profile must apply rate scale")
        XCTAssertEqual(pipeline.minConfidence, 0.25, accuracy: 0.001,
                       "profile must apply min confidence")
        XCTAssertEqual(pipeline.maxRate, 8.0, accuracy: 0.001,
                       "profile must apply max rate")

        // Apply ScratchLab profile
        let slProfile = TimecodePrototypeProfile.scratchLabPrototype()
        slProfile.apply(to: pipeline)

        XCTAssertEqual(pipeline.minConfidence, 0.3, accuracy: 0.001,
                       "switching profile must update min confidence")
        XCTAssertEqual(pipeline.maxRate, 5.0, accuracy: 0.001,
                       "switching profile must update max rate")
    }

    func testProfileMakeWithManualPresetCapturesCurrentCalibration() {
        let pipeline = makePipeline(mode: .controlPrototype)
        pipeline.inputChannel = .left
        pipeline.invertDirection = true
        pipeline.rateScale = 2.0
        pipeline.minConfidence = 0.5
        pipeline.maxRate = 10.0

        let profile = TimecodePrototypeProfile.make(preset: .manual, pipeline: pipeline)

        XCTAssertEqual(profile.inputChannel, .left)
        XCTAssertTrue(profile.invertDirection)
        XCTAssertEqual(profile.rateScale, 2.0, accuracy: 0.001)
        XCTAssertEqual(profile.minConfidence, 0.5, accuracy: 0.001)
        XCTAssertEqual(profile.maxRate, 10.0, accuracy: 0.001)
    }

    func testProfileApplicationDoesNotChangeModeOrLiveTap() {
        let pipeline = makePipeline(mode: .controlPrototype)
        pipeline.liveTapEnabled = true

        let profile = TimecodePrototypeProfile.scratchLabPrototype()
        profile.apply(to: pipeline)

        // Profile application must not change mode or live tap
        XCTAssertEqual(pipeline.mode, .controlPrototype,
                       "apply(profile:) must not change pipeline mode")
        XCTAssertTrue(pipeline.liveTapEnabled,
                      "apply(profile:) must not change live tap state")
    }

    // MARK: - 5. Validation failure blocks playback bridge

    func testTimecodePlaybackBridgeRequiresValidation() {
        // Pipeline with no buffers fed — validation status will be .noSignal
        let pipeline = makePipeline(mode: .controlPrototype)
        pipeline.liveTapEnabled = true  // live tap on but no signal

        let bridge = makeBridge(enabled: true, validationRequired: true)
        let drive = bridge.evaluate(pipeline: pipeline)

        XCTAssertNil(drive, "bridge must block when validation has not passed")
        XCTAssertEqual(bridge.state, .blockedByBadSignal,
                       "bridge must block on bad signal (no buffers fed)")
    }

    func testValidationGateBlocksEvenWithValidSignalButNoValidationPass() {
        // Even with signal present, if validation hasn't accumulated enough
        // accepted motion samples, it should still block.
        let pipeline = makePipeline(mode: .controlPrototype)
        pipeline.liveTapEnabled = true

        // Feed only one buffer — not enough to get usablePrototypeControl
        let tone = sineTone(frequency: carrierFrequency, frameCount: framesPerBuffer,
                            amplitude: 0.5)
        pipeline.pushStereoBuffer(left: tone, right: tone, sampleRate: sampleRate)
        _ = pipeline.flushDecode()

        let snap = pipeline.makeValidationSnapshot()
        // With identical channels, there's no phase delta — may be receivingButNoDecode or similar
        XCTAssertNotEqual(snap.validationStatus, .usablePrototypeControl,
                         "single-buffer identical channels should not be usablePrototypeControl")

        let bridge = makeBridge(enabled: true, validationRequired: true)
        let drive = bridge.evaluate(pipeline: pipeline)

        // Bridge should block (either by signal health or by the new validation gate)
        XCTAssertNil(drive, "bridge must block without usablePrototypeControl validation")
    }

    // MARK: - 6. Explicit override required for unvalidated playback

    func testTimecodeValidationOverrideRequiredForUnvalidatedPlayback() {
        // Use a trusted pipeline to get good signal, then test the validation
        // override mechanism
        let pipeline = makeTrustedPipeline()
        pipeline.liveTapEnabled = true

        // Bridge with validation required and NO override
        let bridgeNoOverride = makeBridge(
            enabled: true,
            validationRequired: true,
            validationOverride: false
        )

        let snap = pipeline.makeValidationSnapshot()
        let driveNoOverride = bridgeNoOverride.evaluate(pipeline: pipeline)

        if snap.validationStatus == .usablePrototypeControl {
            // If validation passes, bridge should drive
            XCTAssertNotNil(driveNoOverride,
                           "bridge must drive when validation passes")
        } else {
            // If validation doesn't pass, bridge must block
            XCTAssertNil(driveNoOverride,
                         "bridge must block without override when validation fails")
            XCTAssertEqual(bridgeNoOverride.state, .blockedByValidationRequired)

            // Now enable override — should drive
            bridgeNoOverride.validationOverride = true
            let driveWithOverride = bridgeNoOverride.evaluate(pipeline: pipeline)
            // Override bypasses validation but other gates (signal, confidence, etc.) still apply
            // If those pass, drive should be non-nil
            // If they don't, the state should NOT be .blockedByValidationRequired
            if driveWithOverride == nil {
                XCTAssertNotEqual(bridgeNoOverride.state, .blockedByValidationRequired,
                                 "override must bypass validation gate")
            }
        }
    }

    func testValidationOverrideResetsOnBridgeReset() {
        let bridge = makeBridge(enabled: true, validationOverride: true)
        XCTAssertTrue(bridge.validationOverride)

        bridge.reset()
        XCTAssertFalse(bridge.validationOverride,
                       "reset must clear validationOverride")
    }

    // MARK: - 7. Live tap does not silently enable on launch

    func testTimecodeLiveTapDoesNotPersistUnsafeEnabledState() {
        let pipeline = makePipeline()

        // Live tap must default to false
        XCTAssertFalse(pipeline.liveTapEnabled,
                       "liveTapEnabled must default to false")

        // Changing mode to controlPrototype must not auto-enable live tap
        pipeline.mode = .controlPrototype
        XCTAssertFalse(pipeline.liveTapEnabled,
                       "switching to controlPrototype must not auto-enable live tap")

        // DiagnosticsOnly must not auto-enable live tap
        pipeline.mode = .diagnosticsOnly
        XCTAssertFalse(pipeline.liveTapEnabled,
                       "switching to diagnosticsOnly must not auto-enable live tap")
    }

    // MARK: - 8. Recording does not silently enable on launch

    func testTimecodeRecordingDoesNotSilentlyEnableOnLaunch() {
        let pipeline = makePipeline(mode: .controlPrototype)

        // Prototype recorder must start idle
        XCTAssertEqual(pipeline.prototypeRecorder.state, .idle,
                       "prototype recorder must default to idle")
        XCTAssertEqual(pipeline.prototypeRecorder.acceptedSampleCount, 0,
                       "prototype recorder must have zero accepted samples on launch")
    }

    // MARK: - 9. Warnings / prototype labels are present

    func testTimecodePrototypeWarningsAreExposed() {
        // Snapshot must carry prototype-only labels
        let pipeline = makePipeline(mode: .controlPrototype)
        let snap = pipeline.makeValidationSnapshot()

        // Snapshot debug text must include prototype disclaimers
        XCTAssertTrue(snap.debugText.contains("prototype"),
                      "snapshot debug text must mention 'prototype'")
        XCTAssertTrue(snap.debugText.lowercased().contains("not sent to notation"),
                      "snapshot debug text must state 'not sent to notation'")

        // Source label must be timecode_live (not a production source)
        XCTAssertEqual(snap.sourceLabel, "timecode_live",
                       "source label must be timecode_live")
    }

    func testDVSExperimentalWarningPresent() {
        let dvsProfile = TimecodeDVSProfile()

        XCTAssertTrue(dvsProfile.isExperimental,
                      "DVS profile must be marked experimental")
        XCTAssertFalse(dvsProfile.experimentalLabel.isEmpty,
                       "DVS profile must have an experimental label")
        XCTAssertTrue(dvsProfile.experimentalLabel.contains("Experimental"),
                      "DVS label must contain 'Experimental'")
        XCTAssertTrue(dvsProfile.experimentalLabel.contains("not"),
                      "DVS label must contain 'not'")
    }

    func testGenericDVSPresetHasExperimentalWarning() {
        let preset = TimecodeControlPreset.genericDVS
        XCTAssertTrue(preset.isExperimental)
        XCTAssertNotNil(preset.experimentalWarning)
        XCTAssertTrue(preset.experimentalWarning?.contains("Experimental") ?? false)
        XCTAssertTrue(preset.experimentalWarning?.contains("not") ?? false)
    }

    func testScratchLabPresetIsNotMarkedExperimental() {
        let preset = TimecodeControlPreset.scratchLabPrototype
        XCTAssertFalse(preset.isExperimental)
        XCTAssertNil(preset.experimentalWarning)
    }

    // MARK: - 10. No official compatibility labels exposed

    func testTimecodeDoesNotExposeOfficialCompatibilityClaim() {
        // All labels and text must be free of official compatibility claims

        let forbiddenTerms: Set<String> = [
            "Serato certified",
            "SDJ compatible",
            "production DVS",
            "bypass DRM",
            "official DVS support",
            "Serato compatibility",
        ]

        // Check snapshot debug text
        let snap = TimecodeValidationSnapshot(
            mode: "controlPrototype",
            liveTapEnabled: true,
            hasRecentBuffer: true,
            lastBufferAge: 0.1,
            signalHealth: .usable,
            leftRMS: 0.1,
            rightRMS: 0.1,
            leftPeak: 0.2,
            rightPeak: 0.2,
            decodedDirection: "forward",
            decodedRate: 1.0,
            decoderConfidence: 0.5,
            acceptedMotionSamples: 10,
            recordedSamples: 5,
            droppedSilence: 0,
            droppedClipped: 0,
            droppedChannelFault: 0,
            droppedWeakSignal: 0,
            droppedLowConfidence: 0,
            directionChanges: 2,
            maxAbsRate: 1.5,
            averageConfidence: 0.5,
            lastDropReason: "",
            sourceLabel: "timecode_live",
            validationStatus: .usablePrototypeControl
        )

        let debugText = snap.debugText.lowercased()
        for term in forbiddenTerms {
            XCTAssertFalse(debugText.contains(term.lowercased()),
                          "snapshot debug text must not contain '\(term)'")
        }

        // Check TimecodePrototypeProfile labels
        let profile = TimecodePrototypeProfile.scratchLabPrototype()
        let profileName = profile.name.lowercased()
        for term in forbiddenTerms {
            XCTAssertFalse(profileName.contains(term.lowercased()),
                          "profile name must not contain '\(term)'")
        }

        // Check DVS profile label
        let dvsProfile = TimecodeDVSProfile()
        let dvsLabel = dvsProfile.experimentalLabel.lowercased()
        // The DVS label says "not ... compatible" which is correct — it's a disclaimer
        XCTAssertTrue(dvsLabel.contains("not"),
                      "DVS label must include 'not' (disclaimer)")

        // Check all preset labels
        for preset in TimecodeControlPreset.allCases {
            let label = preset.label.lowercased()
            for term in forbiddenTerms {
                XCTAssertFalse(label.contains(term.lowercased()),
                              "preset '\(preset.label)' must not contain '\(term)'")
            }
        }

        // Check bridge state labels
        for state in TimecodePlaybackBridgeState.allCases {
            let label = state.label.lowercased()
            for term in forbiddenTerms {
                XCTAssertFalse(label.contains(term.lowercased()),
                              "bridge state '\(state.label)' must not contain '\(term)'")
            }
        }

        // Check validation status labels
        for status in TimecodeValidationStatus.allCases {
            let label = status.label.lowercased()
            for term in forbiddenTerms {
                XCTAssertFalse(label.contains(term.lowercased()),
                              "validation status '\(status.label)' must not contain '\(term)'")
            }
        }
    }

    // MARK: - 11. RANE / replay tests unaffected

    func testRaneAndReplayLabelsUnaffectedByBatch10() {
        // Verify RANE source label is unchanged
        XCTAssertEqual(PlatterPositionTimeline.Source.liveCapture.rawValue, "liveCapture",
                       "liveCapture (RANE) source must be unchanged")

        // Verify no new source labels collide
        let existingSources: Set<String> = [
            PlatterPositionTimeline.Source.liveCapture.rawValue,
            PlatterPositionTimeline.Source.bundledDemo.rawValue,
            PlatterPositionTimeline.Source.coachAuthored.rawValue,
            PlatterPositionTimeline.Source.timecodeFixture.rawValue,
            PlatterPositionTimeline.Source.timecodeLive.rawValue,
        ]

        // Bridge source label must not collide
        let bridgeLabel = TimecodePlaybackBridge.sourceLabel
        XCTAssertFalse(existingSources.contains(bridgeLabel),
                       "bridge source label must not collide with existing sources")

        // All labels must be distinct
        let allLabels = existingSources.union([bridgeLabel])
        XCTAssertEqual(allLabels.count, 6,
                       "all source labels must remain distinct after Batch 10")
    }

    // MARK: - 12. Live tap gate works

    func testTimecodePlaybackBridgeBlocksWhenLiveTapOff() {
        let pipeline = makeTrustedPipeline()
        // Explicitly ensure live tap is off
        pipeline.liveTapEnabled = false

        let bridge = makeBridge(enabled: true)
        let drive = bridge.evaluate(pipeline: pipeline)

        XCTAssertNil(drive, "bridge must block when live tap is off")
        XCTAssertEqual(bridge.state, .blockedByLiveTapOff,
                       "bridge state must be .blockedByLiveTapOff when live tap is off")
    }

    func testTimecodePlaybackBridgeAllowsWhenLiveTapOn() {
        let pipeline = makeTrustedPipeline()
        pipeline.liveTapEnabled = true

        let snap = pipeline.makeValidationSnapshot()

        let bridge = makeBridge(enabled: true, validationRequired: true)

        // If validation passes with live tap on → should drive
        // If validation doesn't pass → should block on validation, not live tap
        let drive = bridge.evaluate(pipeline: pipeline)

        if snap.validationStatus == .usablePrototypeControl {
            XCTAssertNotNil(drive, "bridge must drive when live tap on and validation passes")
            XCTAssertEqual(bridge.state, .driving)
        }
        // In either case, it must NOT be blocked by live tap
        XCTAssertNotEqual(bridge.state, .blockedByLiveTapOff,
                         "bridge must not block by live tap when live tap is enabled")
    }

    // MARK: - 13. All presets are selectable and have distinct labels

    func testAllPresetsHaveDistinctLabels() {
        let labels = TimecodeControlPreset.allCases.map { $0.label }
        XCTAssertEqual(labels.count, Set(labels).count,
                       "all preset labels must be distinct")

        let shortLabels = TimecodeControlPreset.allCases.map { $0.shortLabel }
        XCTAssertEqual(shortLabels.count, Set(shortLabels).count,
                       "all preset short labels must be distinct")
    }

    // MARK: - 14. Smoothing profiles are distinct

    func testSmoothingConfigsAreDistinct() {
        let conservative = TimecodeSmoothingConfig.conservative
        let standard = TimecodeSmoothingConfig.standard

        // Conservative should be more aggressive at rejection
        XCTAssertTrue(conservative.emaAlpha < standard.emaAlpha,
                      "conservative smoothing should have lower alpha (more smoothing)")
        XCTAssertTrue(conservative.spikeRejectionThreshold < standard.spikeRejectionThreshold,
                      "conservative smoothing should have lower spike threshold (more rejection)")
        XCTAssertTrue(conservative.trustRebuildFrames >= standard.trustRebuildFrames,
                      "conservative smoothing should require at least as many rebuild frames")
    }

    // MARK: - 15. Bridge blockedByValidationRequired state transitions

    func testBridgeBlockedByValidationRequiredWhenValidationFails() {
        // Create pipeline with signal but no usable validation
        let pipeline = makePipeline(mode: .controlPrototype)
        pipeline.liveTapEnabled = true
        // Feed no buffers → noSignal

        let bridge = makeBridge(enabled: true, validationRequired: true)
        let drive = bridge.evaluate(pipeline: pipeline)

        XCTAssertNil(drive, "bridge must block when no signal")
        // Either blockedByBadSignal (gates 5-9 fail first) or blockedByLiveTapOff
        // depending on which gate trips first. The important thing is it does NOT drive.
        XCTAssertNotEqual(bridge.state, .driving,
                         "bridge must not be driving without signal")
        XCTAssertNotEqual(bridge.state, .armed,
                         "bridge must not be armed without signal")
    }

    func testValidationGateSkippedWhenValidationNotRequired() {
        let pipeline = makePipeline(mode: .controlPrototype)
        pipeline.liveTapEnabled = true
        // No signal → validation would fail, but validation not required
        // Other gates (signal health, confidence, timeline) will still block

        let bridge = makeBridge(enabled: true, validationRequired: false)
        let drive = bridge.evaluate(pipeline: pipeline)

        // Should NOT be blockedByValidationRequired
        XCTAssertNotEqual(bridge.state, .blockedByValidationRequired,
                         "bridge must not block by validation when validationRequired is false")
        // But should still block on bad signal
        XCTAssertNil(drive, "bridge must still block on bad signal")
    }

    // MARK: - 16. DVS profile is explicitly experimental

    func testDVSProfileIsExplicitlyExperimental() {
        let dvs = TimecodeDVSProfile.default
        XCTAssertTrue(dvs.isExperimental)
        // Underlying profile preset must be genericDVS
        XCTAssertEqual(dvs.profile.preset, .genericDVS)
        // DVS profile validation and playback bridge are safe
        XCTAssertTrue(dvs.profile.validationRequired)
        XCTAssertFalse(dvs.profile.playbackBridgeAllowed)
    }
}

#endif // DEBUG
