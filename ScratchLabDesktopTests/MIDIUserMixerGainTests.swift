// MIDIUserMixerGainTests.swift
// ScratchLabDesktopTests
//
// Engine-level coverage of `MacCaptureEngine.evaluateUserMixerGainForCC`:
// the wiring from a learned crossfader/right-upfader CC event, through the
// existing `MIDILearnedControl.normalizedValue(from:)` calibration/
// inversion math, to `ScratchSamplePlaybackController`'s new gain API.
// Left upfader is proven to have no audio effect. Mappings are constructed
// directly via `MIDILearnedMappingStore`/`loadDeviceMappingForCurrentSource`
// (the same store the production persistence path uses) rather than
// driving the full interactive learn UI flow, so calibration/inversion can
// be set up deterministically in one step.

import XCTest
import AVFoundation
@testable import ScratchLab

final class MIDIUserMixerGainTests: XCTestCase {

    private func cleanUpMIDIMapping(deviceIdentifier: String) {
        MIDILearnedMappingStore.default.delete(deviceIdentifier: deviceIdentifier)
    }

    /// `loadDeviceMappingForCurrentSource()` reads disk synchronously but
    /// publishes its `@Published` mapping on the next main-queue turn.
    /// Tests must observe that documented boundary instead of treating the
    /// UI-facing state update as synchronous.
    private func loadMappingAndWait(on engine: MacCaptureEngine) {
        engine.loadDeviceMappingForCurrentSource()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    private func makeSyntheticLoopBuffer(frames: Int = 8_000) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            let value = 0.8 * Float(sin(Double(i) * 2 * .pi / 100))
            buffer.floatChannelData![0][i] = value
            buffer.floatChannelData![1][i] = value
        }
        return buffer
    }

    /// Writes a malformed mapping file directly at the location
    /// `MIDILearnedMappingStore.default` would use, to exercise the
    /// mapping-load failure path deterministically — the store's own
    /// public API can only ever write valid, current-schema JSON.
    private func writeMalformedMappingFile(deviceIdentifier: String) throws {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let baseURL = appSupport.appendingPathComponent("ScratchLab/MIDIMappings", isDirectory: true)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let fileURL = baseURL.appendingPathComponent("\(deviceIdentifier).json")
        try Data("{ this is not valid mapping JSON".utf8).write(to: fileURL, options: .atomic)
    }

    /// Saves a one-control mapping for `deviceID`, then observes the production
    /// load path through its main-queue publication boundary.
    private func installMapping(_ control: MIDILearnedControl, deviceID: String, on engine: MacCaptureEngine) {
        cleanUpMIDIMapping(deviceIdentifier: deviceID)
        var mapping = MIDIDeviceMapping(deviceIdentifier: deviceID, deviceName: "Test Device")
        mapping.upsert(control)
        MIDILearnedMappingStore.default.save(mapping)
        engine.selectedMIDIInputSourceID = deviceID
        loadMappingAndWait(on: engine)
    }

    /// `targetUserMixerGain` (the render core's un-ramped mirror of the
    /// last published value) only updates during an actual render call —
    /// publishing alone does not touch it. Forces one minimal render (1
    /// frame) so reading it immediately afterward reflects the latest
    /// publish rather than a stale default.
    private func publishedTargetUserMixerGain(_ engine: MacCaptureEngine) -> Double {
        let renderer = engine.testOnly_scratchPlaybackController.dvsContinuousRenderer
        var scratch = [Float](repeating: 0, count: 1)
        scratch.withUnsafeMutableBufferPointer { ptr in
            renderer.testOnly_render(left: ptr.baseAddress!, right: nil, frameCount: 1)
        }
        return renderer.testOnly_coreTargetUserMixerGain
    }

    // MARK: - Regression #1: unmapped defaults to unity

    func testUnmappedCrossfaderAndUpfaderLeaveGainAtUnity() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        engine.evaluateUserMixerGainForCC(channel: 0, controller: 7, value: 0)
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(engine), 1.0)
    }

    // MARK: - Regression #2: right upfader forwards calibrated/normalized value

    func testLearnedRightUpfaderForwardsNormalizedGain() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_right_upfader_gain"
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        installMapping(
            MIDILearnedControl(action: .rightUpfader, messageType: .controlChange, channel: 0, controlNumber: 7, deck: 1),
            deviceID: deviceID, on: engine
        )

        engine.evaluateUserMixerGainForCC(channel: 0, controller: 7, value: 0)
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(engine), 0.0)

        engine.evaluateUserMixerGainForCC(channel: 0, controller: 7, value: 127)
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(engine), 1.0)
    }

    // MARK: - Regression #3: left upfader never alters scratch gain

    func testLearnedLeftUpfaderNeverAltersScratchGain() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_left_upfader_no_audio"
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        installMapping(
            MIDILearnedControl(action: .leftUpfader, messageType: .controlChange, channel: 0, controlNumber: 7, deck: 0),
            deviceID: deviceID, on: engine
        )

        for value in [0, 32, 64, 96, 127] {
            engine.evaluateUserMixerGainForCC(channel: 0, controller: 7, value: value)
        }
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(engine), 1.0,
            "a learned left-upfader mapping must never reach the playback controller's gain")
    }

    // MARK: - Non-matching channel/controller never forwards

    func testNonMatchingChannelOrControllerDoesNotForwardGain() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_non_matching_cc"
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        installMapping(
            MIDILearnedControl(action: .rightUpfader, messageType: .controlChange, channel: 0, controlNumber: 7, deck: 1),
            deviceID: deviceID, on: engine
        )

        // Same controller, different channel; same channel, different controller.
        engine.evaluateUserMixerGainForCC(channel: 1, controller: 7, value: 0)
        engine.evaluateUserMixerGainForCC(channel: 0, controller: 8, value: 0)
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(engine), 1.0)
    }

    // MARK: - Regression #7: inversion and calibration are respected

    func testInversionIsRespected() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_right_upfader_inverted"
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        installMapping(
            MIDILearnedControl(
                action: .rightUpfader, messageType: .controlChange, channel: 0, controlNumber: 7, deck: 1,
                inverted: true
            ),
            deviceID: deviceID, on: engine
        )

        // Inverted: raw 0 (physically "down") must produce gain 1, raw 127
        // ("up") must produce gain 0 — the opposite of the uninverted case.
        engine.evaluateUserMixerGainForCC(channel: 0, controller: 7, value: 0)
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(engine), 1.0)

        engine.evaluateUserMixerGainForCC(channel: 0, controller: 7, value: 127)
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(engine), 0.0)
    }

    func testCalibrationRangeIsRespected() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_right_upfader_calibrated"
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        // Calibrated to a narrower observed throw (20...100) rather than
        // the full 0...127 — matches what `finishCalibration` would persist.
        installMapping(
            MIDILearnedControl(
                action: .rightUpfader, messageType: .controlChange, channel: 0, controlNumber: 7, deck: 1,
                minValue: 20, maxValue: 100
            ),
            deviceID: deviceID, on: engine
        )

        engine.evaluateUserMixerGainForCC(channel: 0, controller: 7, value: 20)
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(engine), 0.0)

        engine.evaluateUserMixerGainForCC(channel: 0, controller: 7, value: 100)
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(engine), 1.0)

        engine.evaluateUserMixerGainForCC(channel: 0, controller: 7, value: 60) // midpoint of 20...100
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(engine), 0.5, accuracy: 0.01)

        // Values clamp at the calibrated bounds rather than exceeding 0...1.
        engine.evaluateUserMixerGainForCC(channel: 0, controller: 7, value: 5)
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(engine), 0.0)
    }

    // MARK: - Crossfader forwards its position for the cut curve

    func testLearnedCrossfaderForwardsNormalizedPosition() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_crossfader_gain"
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        installMapping(
            MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 15, controlNumber: 8),
            deviceID: deviceID, on: engine
        )

        engine.evaluateUserMixerGainForCC(channel: 15, controller: 8, value: 0)
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(engine), 0.0,
            "crossfader hard left must produce scratch gain 0")

        engine.evaluateUserMixerGainForCC(channel: 15, controller: 8, value: 127)
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(engine), 1.0,
            "crossfader hard right must produce full scratch gain")
    }

    // MARK: - Regression #13: mappings survive relaunch (persistence round trip)

    func testRightUpfaderAndCrossfaderMappingsSurviveRoundTripPersistence() throws {
        let deviceID = "midi_test_relaunch_round_trip"
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        var mapping = MIDIDeviceMapping(deviceIdentifier: deviceID, deviceName: "Test Device")
        mapping.upsert(MIDILearnedControl(
            action: .rightUpfader, messageType: .controlChange, channel: 0, controlNumber: 7, deck: 1,
            minValue: 10, maxValue: 110, inverted: true
        ))
        mapping.upsert(MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 15, controlNumber: 8))
        MIDILearnedMappingStore.default.save(mapping)

        // Simulates relaunch: a fresh engine loading the same device's
        // mapping straight from disk, not from any in-memory state.
        let relaunchedEngine = MacCaptureEngine(autoRefreshDevices: false)
        relaunchedEngine.selectedMIDIInputSourceID = deviceID
        loadMappingAndWait(on: relaunchedEngine)

        let reloaded = try XCTUnwrap(relaunchedEngine.currentMIDIDeviceMapping)
        let reloadedUpfader = try XCTUnwrap(reloaded.control(for: .rightUpfader))
        XCTAssertEqual(reloadedUpfader.minValue, 10)
        XCTAssertEqual(reloadedUpfader.maxValue, 110)
        XCTAssertTrue(reloadedUpfader.inverted)
        XCTAssertNotNil(reloaded.control(for: .crossfader))

        // And the reloaded mapping still drives gain correctly end-to-end.
        relaunchedEngine.evaluateUserMixerGainForCC(channel: 0, controller: 7, value: 10)
        relaunchedEngine.testOnly_scratchPlaybackController.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(relaunchedEngine), 1.0,
            "inverted + calibrated mapping must still resolve correctly after a simulated relaunch")
    }

    // MARK: - Lifecycle: absent/replaced mapping must never mute audio (2026-08-10 review fix)
    //
    // "If a control is unmapped or has not received a valid value during
    // the current session, it contributes unity gain. An absent mapping
    // must never mute audio." A previous value of zero must never survive
    // a MIDI source change, a mapping load (including empty/missing/
    // failed), a mapping clear, or a replace/relearn/recalibrate/
    // re-invert of either control.

    func testSwitchingToUnmappedSourceResetsBothControlsToUnity() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceA = "midi_test_lifecycle_source_a"
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceA) }

        var mapping = MIDIDeviceMapping(deviceIdentifier: deviceA, deviceName: "Device A")
        mapping.upsert(MIDILearnedControl(action: .rightUpfader, messageType: .controlChange, channel: 0, controlNumber: 7, deck: 1))
        mapping.upsert(MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 15, controlNumber: 8))
        MIDILearnedMappingStore.default.save(mapping)
        engine.selectedMIDIInputSourceID = deviceA
        loadMappingAndWait(on: engine)

        engine.evaluateUserMixerGainForCC(channel: 0, controller: 7, value: 0)
        engine.evaluateUserMixerGainForCC(channel: 15, controller: 8, value: 0)
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(engine), 0.0,
            "sanity: both controls must actually be at zero before the switch")

        // Switch to a source with no stored mapping at all.
        engine.selectedMIDIInputSourceID = "midi_test_lifecycle_unmapped_source"
        loadMappingAndWait(on: engine)
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()

        XCTAssertEqual(publishedTargetUserMixerGain(engine), 1.0,
            "switching to an unmapped source must reset both controls to unity, not carry over the previous device's zero")
    }

    func testMappingLoadFailureResetsBothControlsToUnity() throws {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceA = "midi_test_lifecycle_source_ok"
        let deviceBroken = "midi_test_lifecycle_source_broken"
        defer {
            cleanUpMIDIMapping(deviceIdentifier: deviceA)
            cleanUpMIDIMapping(deviceIdentifier: deviceBroken)
        }

        var mapping = MIDIDeviceMapping(deviceIdentifier: deviceA, deviceName: "Device A")
        mapping.upsert(MIDILearnedControl(action: .rightUpfader, messageType: .controlChange, channel: 0, controlNumber: 7, deck: 1))
        mapping.upsert(MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 15, controlNumber: 8))
        MIDILearnedMappingStore.default.save(mapping)
        engine.selectedMIDIInputSourceID = deviceA
        loadMappingAndWait(on: engine)
        engine.evaluateUserMixerGainForCC(channel: 0, controller: 7, value: 0)
        engine.evaluateUserMixerGainForCC(channel: 15, controller: 8, value: 0)
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(engine), 0.0)

        try writeMalformedMappingFile(deviceIdentifier: deviceBroken)
        engine.selectedMIDIInputSourceID = deviceBroken
        loadMappingAndWait(on: engine)
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()

        XCTAssertFalse(engine.midiMappingError.isEmpty, "sanity: the load must actually have failed")
        XCTAssertEqual(publishedTargetUserMixerGain(engine), 1.0,
            "a mapping-load failure must still reset both controls to unity")
    }

    func testClearingCrossfaderRestoresOnlyCrossfaderUnityPreservingRightUpfader() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_lifecycle_clear_crossfader"
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        var mapping = MIDIDeviceMapping(deviceIdentifier: deviceID, deviceName: "Test Device")
        mapping.upsert(MIDILearnedControl(action: .rightUpfader, messageType: .controlChange, channel: 0, controlNumber: 7, deck: 1))
        mapping.upsert(MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 15, controlNumber: 8))
        MIDILearnedMappingStore.default.save(mapping)
        engine.selectedMIDIInputSourceID = deviceID
        loadMappingAndWait(on: engine)

        // Right upfader at a distinctive, non-unity, non-zero value; crossfader closed.
        engine.evaluateUserMixerGainForCC(channel: 0, controller: 7, value: 64)
        engine.evaluateUserMixerGainForCC(channel: 15, controller: 8, value: 0)
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()
        let expectedUpfaderGain = Double(64) / 127.0
        XCTAssertEqual(publishedTargetUserMixerGain(engine), 0.0, accuracy: 0.001)

        engine.clearMapping(for: .crossfader)
        engine.testOnly_waitForMappingPersistenceQueue()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()

        // Crossfader resets to unity; the right upfader's own last value —
        // never touched by this clear — is preserved exactly.
        XCTAssertEqual(publishedTargetUserMixerGain(engine), expectedUpfaderGain, accuracy: 0.01,
            "clearing the crossfader mapping must restore only its own unity contribution, preserving the right upfader's current gain")
    }

    func testClearingRightUpfaderRestoresOnlyRightUpfaderUnityPreservingCrossfader() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_lifecycle_clear_upfader"
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        var mapping = MIDIDeviceMapping(deviceIdentifier: deviceID, deviceName: "Test Device")
        mapping.upsert(MIDILearnedControl(action: .rightUpfader, messageType: .controlChange, channel: 0, controlNumber: 7, deck: 1))
        mapping.upsert(MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 15, controlNumber: 8))
        MIDILearnedMappingStore.default.save(mapping)
        engine.selectedMIDIInputSourceID = deviceID
        loadMappingAndWait(on: engine)

        // Crossfader inside its cut-in region (a distinctive, non-unity,
        // non-zero gain); right upfader closed.
        let crossfaderRawValue = 3
        let crossfaderNormalized = Double(crossfaderRawValue) / 127.0
        let expectedCrossfaderGain = ScratchSamplePlaybackController.crossfaderRightDeckGain(forNormalizedPosition: crossfaderNormalized)
        engine.evaluateUserMixerGainForCC(channel: 15, controller: 8, value: crossfaderRawValue)
        engine.evaluateUserMixerGainForCC(channel: 0, controller: 7, value: 0)
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(engine), 0.0, accuracy: 0.001)

        engine.clearMapping(for: .rightUpfader)
        engine.testOnly_waitForMappingPersistenceQueue()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()

        XCTAssertEqual(publishedTargetUserMixerGain(engine), expectedCrossfaderGain, accuracy: 0.01,
            "clearing the right-upfader mapping must restore only its own unity contribution, preserving the crossfader's current gain")
    }

    func testClearingAllMappingsRestoresBothControlsToUnity() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_lifecycle_clear_all"
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        var mapping = MIDIDeviceMapping(deviceIdentifier: deviceID, deviceName: "Test Device")
        mapping.upsert(MIDILearnedControl(action: .rightUpfader, messageType: .controlChange, channel: 0, controlNumber: 7, deck: 1))
        mapping.upsert(MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 15, controlNumber: 8))
        MIDILearnedMappingStore.default.save(mapping)
        engine.selectedMIDIInputSourceID = deviceID
        loadMappingAndWait(on: engine)

        engine.evaluateUserMixerGainForCC(channel: 0, controller: 7, value: 0)
        engine.evaluateUserMixerGainForCC(channel: 15, controller: 8, value: 0)
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(engine), 0.0)

        engine.clearDeviceMappings()
        engine.testOnly_waitForMappingPersistenceQueue()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()

        XCTAssertEqual(publishedTargetUserMixerGain(engine), 1.0,
            "clearing all mappings must restore both controls to unity")
    }

    func testReplacingRightUpfaderMappingResetsToUnityUntilNewCCArrives() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_lifecycle_replace_upfader"
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        installMapping(
            MIDILearnedControl(action: .rightUpfader, messageType: .controlChange, channel: 0, controlNumber: 7, deck: 1),
            deviceID: deviceID, on: engine
        )
        engine.evaluateUserMixerGainForCC(channel: 0, controller: 7, value: 0)
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(engine), 0.0, "sanity: right upfader is at zero before replacing")

        // Replace/relearn right upfader onto a different CC.
        engine.startMIDILearn(for: .rightUpfader)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        _ = engine.evaluateMIDILearnForCC(channel: 1, controller: 9, value: 64)
        engine.testOnly_waitForMappingPersistenceQueue()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()

        XCTAssertEqual(publishedTargetUserMixerGain(engine), 1.0,
            "replacing the mapping must reset to unity — the learn event's own value must not count as a live gain update")

        // Only a new event, after the replace, actually changes gain.
        engine.evaluateUserMixerGainForCC(channel: 1, controller: 9, value: 0)
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(engine), 0.0,
            "the newly mapped CC must drive gain normally after the reset")
    }

    func testNewlyLoadedMappedDeviceBeginsAtUnityUntilSessionValueArrives() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_lifecycle_newly_loaded_mapped"
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        var mapping = MIDIDeviceMapping(deviceIdentifier: deviceID, deviceName: "Test Device")
        mapping.upsert(MIDILearnedControl(action: .rightUpfader, messageType: .controlChange, channel: 0, controlNumber: 7, deck: 1))
        mapping.upsert(MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 15, controlNumber: 8))
        MIDILearnedMappingStore.default.save(mapping)

        engine.selectedMIDIInputSourceID = deviceID
        loadMappingAndWait(on: engine)
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()

        XCTAssertEqual(publishedTargetUserMixerGain(engine), 1.0,
            "a device with both controls mapped must still begin at unity until this session's first valid CC arrives")
    }

    func testRapidSourceChangesLeaveFinalSourceWithCorrectMappingAndUnity() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceA = "midi_test_lifecycle_rapid_a"
        let deviceB = "midi_test_lifecycle_rapid_b"
        defer {
            cleanUpMIDIMapping(deviceIdentifier: deviceA)
            cleanUpMIDIMapping(deviceIdentifier: deviceB)
        }

        var mappingA = MIDIDeviceMapping(deviceIdentifier: deviceA, deviceName: "Device A")
        mappingA.upsert(MIDILearnedControl(action: .rightUpfader, messageType: .controlChange, channel: 0, controlNumber: 7, deck: 1))
        MIDILearnedMappingStore.default.save(mappingA)

        var mappingB = MIDIDeviceMapping(deviceIdentifier: deviceB, deviceName: "Device B")
        mappingB.upsert(MIDILearnedControl(action: .rightUpfader, messageType: .controlChange, channel: 2, controlNumber: 11, deck: 1))
        MIDILearnedMappingStore.default.save(mappingB)

        engine.selectedMIDIInputSourceID = deviceA
        loadMappingAndWait(on: engine)
        engine.evaluateUserMixerGainForCC(channel: 0, controller: 7, value: 0)
        // Rapid switch to B without draining A's queued gain work first.
        engine.selectedMIDIInputSourceID = deviceB
        loadMappingAndWait(on: engine)
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()

        XCTAssertEqual(engine.currentMIDIDeviceMapping?.deviceIdentifier, deviceB)
        XCTAssertEqual(publishedTargetUserMixerGain(engine), 1.0,
            "the final source must end at unity gain, unaffected by the previous source's queued zero")

        // Device B's own mapping still works normally afterward.
        engine.evaluateUserMixerGainForCC(channel: 2, controller: 11, value: 0)
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(engine), 0.0)
    }

    func testLifecycleGainResetsNeverTouchPlaybackPositionOrPhase() throws {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_lifecycle_position_preserved"
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        installMapping(
            MIDILearnedControl(action: .rightUpfader, messageType: .controlChange, channel: 0, controlNumber: 7, deck: 1),
            deviceID: deviceID, on: engine
        )

        let controller = engine.testOnly_scratchPlaybackController
        controller.testOnly_installSyntheticSample(try makeSyntheticLoopBuffer(), sampleID: "synthetic")
        controller.dvsContinuousRenderer.publish(velocity: 20_000, authoritativePhase: 0, active: true)

        var warmup = [Float](repeating: 0, count: 2_000)
        warmup.withUnsafeMutableBufferPointer { ptr in
            controller.dvsContinuousRenderer.testOnly_render(left: ptr.baseAddress!, right: nil, frameCount: 2_000)
        }
        let phaseBefore = controller.dvsContinuousRenderer.testOnly_corePhase
        XCTAssertGreaterThan(phaseBefore, 0, "sanity: phase must actually have advanced before the resets")

        // Exercise every lifecycle reset path once.
        loadMappingAndWait(on: engine)
        controller.resetCrossfaderGainToUnity()
        controller.resetRightUpfaderGainToUnity()
        controller.resetUserMixerGainToUnity()
        controller.waitForAudioQueue()

        var afterReset = [Float](repeating: 0, count: 1)
        afterReset.withUnsafeMutableBufferPointer { ptr in
            controller.dvsContinuousRenderer.testOnly_render(left: ptr.baseAddress!, right: nil, frameCount: 1)
        }
        XCTAssertGreaterThanOrEqual(controller.dvsContinuousRenderer.testOnly_corePhase, phaseBefore,
            "gain lifecycle resets must never move the renderer's retained phase backward or reset it")
    }

    // MARK: - Fader curve configuration (engine-level)

    func testSetCurvePresetPersistsAndResetsOnlyAffectedControl() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_curve_preset_change"
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        var mapping = MIDIDeviceMapping(deviceIdentifier: deviceID, deviceName: "Test Device")
        mapping.upsert(MIDILearnedControl(action: .rightUpfader, messageType: .controlChange, channel: 0, controlNumber: 7, deck: 1))
        mapping.upsert(MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 15, controlNumber: 8))
        MIDILearnedMappingStore.default.save(mapping)
        engine.selectedMIDIInputSourceID = deviceID
        loadMappingAndWait(on: engine)

        engine.evaluateUserMixerGainForCC(channel: 0, controller: 7, value: 76) // 0.6 of 0...127
        engine.evaluateUserMixerGainForCC(channel: 15, controller: 8, value: 127)
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(engine), 76.0 / 127.0, accuracy: 0.01)

        // Changing the CROSSFADER's preset must reset only the crossfader's
        // contribution — the right-upfader's value must survive.
        engine.setCurvePreset(.blend, for: .crossfader)
        engine.testOnly_waitForMappingPersistenceQueue()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()

        XCTAssertEqual(engine.currentMIDIDeviceMapping?.control(for: .crossfader)?.curveConfig?.preset, .blend)
        XCTAssertEqual(publishedTargetUserMixerGain(engine), 76.0 / 127.0, accuracy: 0.01,
            "right-upfader's contribution must be untouched by the crossfader's preset change")
    }

    func testDeviceSwitchingRestoresEachDevicesOwnCurve() {
        let engineA = "midi_test_curve_device_a"
        let engineBID = "midi_test_curve_device_b"
        defer {
            cleanUpMIDIMapping(deviceIdentifier: engineA)
            cleanUpMIDIMapping(deviceIdentifier: engineBID)
        }

        var mappingA = MIDIDeviceMapping(deviceIdentifier: engineA, deviceName: "Device A")
        mappingA.upsert(MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 15, controlNumber: 8, curveConfig: MIDIFaderCurveConfig(preset: .blend, customCapture: nil)))
        MIDILearnedMappingStore.default.save(mappingA)

        var mappingB = MIDIDeviceMapping(deviceIdentifier: engineBID, deviceName: "Device B")
        mappingB.upsert(MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 15, controlNumber: 8, curveConfig: MIDIFaderCurveConfig(preset: .sharpScratch, customCapture: nil)))
        MIDILearnedMappingStore.default.save(mappingB)

        let engine = MacCaptureEngine(autoRefreshDevices: false)
        engine.selectedMIDIInputSourceID = engineA
        loadMappingAndWait(on: engine)
        engine.evaluateUserMixerGainForCC(channel: 15, controller: 8, value: 64) // midpoint
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(engine), 0.5, accuracy: 0.01, "Device A's Blend curve: midpoint gain is 0.5")

        engine.selectedMIDIInputSourceID = engineBID
        loadMappingAndWait(on: engine)
        engine.evaluateUserMixerGainForCC(channel: 15, controller: 8, value: 64) // still well past the 5% cut-in
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(engine), 1.0, accuracy: 0.01, "Device B's Sharp Scratch curve: midpoint gain is already 1.0")
    }

    func testCustomCaptureFullFlowAppliesOnFinish() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_curve_custom_capture"
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        installMapping(MIDILearnedControl(action: .rightUpfader, messageType: .controlChange, channel: 0, controlNumber: 7, deck: 1), deviceID: deviceID, on: engine)

        engine.startCurveCalibration(for: .rightUpfader)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(engine.activeCurveCaptureAction, .rightUpfader)
        // Persisted preset must remain the pre-existing default until Finish.
        XCTAssertNil(engine.currentMIDIDeviceMapping?.control(for: .rightUpfader)?.curveConfig)

        engine.evaluateCurveCaptureForCC(channel: 0, controller: 7, value: 20)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        engine.captureCurveClosedPoint()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(engine.curveCaptureHasClosedPoint)

        engine.evaluateCurveCaptureForCC(channel: 0, controller: 7, value: 100)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        engine.captureCurveFullOnPoint()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(engine.curveCaptureHasFullOnPoint)

        engine.finishCurveCalibration()
        engine.testOnly_waitForMappingPersistenceQueue()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let control = engine.currentMIDIDeviceMapping?.control(for: .rightUpfader)
        XCTAssertEqual(control?.curveConfig?.preset, .custom)
        XCTAssertEqual(control?.curveConfig?.customCapture, FaderCurveCapture(closedRawValue: 20, fullOnRawValue: 100))
        XCTAssertNil(engine.activeCurveCaptureAction)

        engine.evaluateUserMixerGainForCC(channel: 0, controller: 7, value: 20)
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(engine), 0.0, accuracy: 0.001)

        engine.evaluateUserMixerGainForCC(channel: 0, controller: 7, value: 100)
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(engine), 1.0, accuracy: 0.001)

        engine.evaluateUserMixerGainForCC(channel: 0, controller: 7, value: 127) // beyond the captured full-on point
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(engine), 1.0, accuracy: 0.001, "beyond full-on, gain stays exactly 1")
    }

    func testCurveCaptureIgnoresCC6AndUnrelatedControllers() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_curve_capture_filtering"
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        installMapping(MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 15, controlNumber: 8), deviceID: deviceID, on: engine)

        engine.startCurveCalibration(for: .crossfader)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        // Platter flood on CC6, and an unrelated controller on the same channel.
        engine.evaluateCurveCaptureForCC(channel: 15, controller: 6, value: 64)
        engine.evaluateCurveCaptureForCC(channel: 15, controller: 99, value: 64)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(engine.curveCaptureHasLiveValue, "unrelated CC6/other-controller events must never register as a captured live value")

        engine.evaluateCurveCaptureForCC(channel: 15, controller: 8, value: 64) // the actual learned crossfader binding
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(engine.curveCaptureHasLiveValue)
    }

    func testCurveCaptureNeverStartsMIDILearnOrReplacesBinding() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_curve_capture_no_learn_side_effect"
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        installMapping(MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 15, controlNumber: 8), deviceID: deviceID, on: engine)

        engine.startCurveCalibration(for: .crossfader)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(engine.activeMIDILearnAction, "starting curve capture must never start MIDI Learn")

        engine.evaluateCurveCaptureForCC(channel: 15, controller: 8, value: 30)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        engine.captureCurveClosedPoint()
        engine.evaluateCurveCaptureForCC(channel: 15, controller: 8, value: 90)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        engine.captureCurveFullOnPoint()
        engine.finishCurveCalibration()
        engine.testOnly_waitForMappingPersistenceQueue()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let control = engine.currentMIDIDeviceMapping?.control(for: .crossfader)
        XCTAssertEqual(control?.channel, 15)
        XCTAssertEqual(control?.controlNumber, 8, "the learned binding itself must be unaffected by curve capture")
    }

    func testCancelCurveCalibrationLeavesPersistedAndAppliedCurveUnchanged() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_curve_capture_cancel"
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        installMapping(MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 15, controlNumber: 8), deviceID: deviceID, on: engine)
        engine.setCurvePreset(.blend, for: .crossfader)
        engine.testOnly_waitForMappingPersistenceQueue()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        engine.evaluateUserMixerGainForCC(channel: 15, controller: 8, value: 64)
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(engine), 0.5, accuracy: 0.01, "sanity: Blend applied before the capture session")

        engine.startCurveCalibration(for: .crossfader)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        engine.evaluateCurveCaptureForCC(channel: 15, controller: 8, value: 10)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        engine.captureCurveClosedPoint()
        engine.cancelCurveCalibration()
        engine.testOnly_waitForMappingPersistenceQueue()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(engine.currentMIDIDeviceMapping?.control(for: .crossfader)?.curveConfig?.preset, .blend,
            "Cancel must leave the previously persisted preset untouched")

        // The controller's currently-applied curve was never touched by
        // start+cancel either — the SAME raw value must still produce the
        // Blend-curve gain, not a reset-to-unity or any other value.
        engine.evaluateUserMixerGainForCC(channel: 15, controller: 8, value: 64)
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(engine), 0.5, accuracy: 0.01)
    }

    func testFinishCurveCalibrationRequiresTwoDistinctPoints() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_curve_capture_incomplete"
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        installMapping(MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 15, controlNumber: 8), deviceID: deviceID, on: engine)

        engine.startCurveCalibration(for: .crossfader)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        engine.evaluateCurveCaptureForCC(channel: 15, controller: 8, value: 40)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        engine.captureCurveClosedPoint()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(engine.curveCaptureCanFinish, "Finish must not be enabled with only one point captured")
        // Only ONE point captured — Finish must reject.
        engine.finishCurveCalibration()
        engine.testOnly_waitForMappingPersistenceQueue()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNil(engine.currentMIDIDeviceMapping?.control(for: .crossfader)?.curveConfig,
            "an incomplete capture must never be persisted")
        XCTAssertFalse(engine.curveCaptureError.isEmpty)
        XCTAssertEqual(engine.activeCurveCaptureAction, .crossfader,
            "an invalid Finish must NOT end/hide the capture session — the editor must stay open with the error visible")
        XCTAssertTrue(engine.curveCaptureHasClosedPoint, "the already-captured closed point must survive the rejected Finish")
    }

    func testFinishCurveCalibrationRejectsIdenticalPoints() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_curve_capture_identical_points"
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        installMapping(MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 15, controlNumber: 8), deviceID: deviceID, on: engine)

        engine.startCurveCalibration(for: .crossfader)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        engine.evaluateCurveCaptureForCC(channel: 15, controller: 8, value: 40)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        engine.captureCurveClosedPoint()
        engine.captureCurveFullOnPoint() // same raw value both times
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(engine.curveCaptureCanFinish, "Finish must not be enabled when both points are identical")
        engine.finishCurveCalibration()
        engine.testOnly_waitForMappingPersistenceQueue()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNil(engine.currentMIDIDeviceMapping?.control(for: .crossfader)?.curveConfig,
            "identical closed/full-on points must never be persisted")
        XCTAssertFalse(engine.curveCaptureError.isEmpty)
        XCTAssertEqual(engine.activeCurveCaptureAction, .crossfader, "session must remain active after a rejected Finish")
    }

    /// Two distinct RAW values that clamp/normalize to the SAME endpoint
    /// under the current (narrow) calibration must also be rejected —
    /// distinctness of the raw Int is not sufficient on its own.
    func testFinishCurveCalibrationRejectsPointsThatNormalizeToSameEndpointDueToClamping() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_curve_capture_clamped_collapse"
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        // Calibrated so raw 0 and raw 5 both clamp to the SAME minValue (10).
        installMapping(
            MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 15, controlNumber: 8, minValue: 10, maxValue: 120),
            deviceID: deviceID, on: engine
        )

        engine.startCurveCalibration(for: .crossfader)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        engine.evaluateCurveCaptureForCC(channel: 15, controller: 8, value: 0)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        engine.captureCurveClosedPoint()
        engine.evaluateCurveCaptureForCC(channel: 15, controller: 8, value: 5) // distinct raw, but clamps to the same normalized 0.0
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        engine.captureCurveFullOnPoint()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertTrue(engine.curveCaptureHasClosedPoint)
        XCTAssertTrue(engine.curveCaptureHasFullOnPoint)
        XCTAssertFalse(engine.curveCaptureCanFinish, "distinct raw values that clamp to the same endpoint must not enable Finish")

        engine.finishCurveCalibration()
        engine.testOnly_waitForMappingPersistenceQueue()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNil(engine.currentMIDIDeviceMapping?.control(for: .crossfader)?.curveConfig,
            "a degenerate resolved span must never be persisted, even with distinct raw values")
        XCTAssertFalse(engine.curveCaptureError.isEmpty)
        XCTAssertEqual(engine.activeCurveCaptureAction, .crossfader, "session must remain active")
    }

    /// After an invalid Finish, correcting the offending point and Finishing
    /// again must succeed WITHOUT restarting the capture session.
    func testCorrectingPointThenFinishSucceedsWithoutRestarting() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_curve_capture_correct_then_finish"
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        installMapping(MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 15, controlNumber: 8), deviceID: deviceID, on: engine)

        engine.startCurveCalibration(for: .crossfader)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        engine.evaluateCurveCaptureForCC(channel: 15, controller: 8, value: 40)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        engine.captureCurveClosedPoint()
        engine.captureCurveFullOnPoint() // identical — invalid
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        engine.finishCurveCalibration() // rejected, session stays active
        engine.testOnly_waitForMappingPersistenceQueue()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(engine.activeCurveCaptureAction, .crossfader)
        XCTAssertFalse(engine.curveCaptureError.isEmpty)

        // Correct the full-on point — NO restart, same session.
        engine.evaluateCurveCaptureForCC(channel: 15, controller: 8, value: 100)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        engine.captureCurveFullOnPoint()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(engine.curveCaptureCanFinish)

        engine.finishCurveCalibration()
        engine.testOnly_waitForMappingPersistenceQueue()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let control = engine.currentMIDIDeviceMapping?.control(for: .crossfader)
        XCTAssertEqual(control?.curveConfig?.preset, .custom)
        XCTAssertEqual(control?.curveConfig?.customCapture, FaderCurveCapture(closedRawValue: 40, fullOnRawValue: 100))
        XCTAssertNil(engine.activeCurveCaptureAction, "the now-successful Finish ends the session")
        XCTAssertTrue(engine.curveCaptureError.isEmpty)
    }

    func testLeftUpfaderCurveIsPersistedButNeverAffectsScratchGain() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_curve_left_upfader_inert"
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        installMapping(MIDILearnedControl(action: .leftUpfader, messageType: .controlChange, channel: 0, controlNumber: 20, deck: 0), deviceID: deviceID, on: engine)
        engine.setCurvePreset(.sharpCut, for: .leftUpfader)
        engine.testOnly_waitForMappingPersistenceQueue()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(engine.currentMIDIDeviceMapping?.control(for: .leftUpfader)?.curveConfig?.preset, .sharpCut,
            "the left-upfader curve preference is persisted")

        for value in [0, 32, 64, 96, 127] {
            engine.evaluateUserMixerGainForCC(channel: 0, controller: 20, value: value)
        }
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(engine), 1.0,
            "a persisted left-upfader curve must still never reach scratch-audio gain")
    }

    func testCurvePresetChangeNeverTouchesPlaybackPositionOrPhase() throws {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_curve_change_position_preserved"
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        installMapping(MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 15, controlNumber: 8), deviceID: deviceID, on: engine)

        let controller = engine.testOnly_scratchPlaybackController
        controller.testOnly_installSyntheticSample(try makeSyntheticLoopBuffer(), sampleID: "synthetic")
        controller.dvsContinuousRenderer.publish(velocity: 20_000, authoritativePhase: 0, active: true)

        var warmup = [Float](repeating: 0, count: 2_000)
        warmup.withUnsafeMutableBufferPointer { ptr in
            controller.dvsContinuousRenderer.testOnly_render(left: ptr.baseAddress!, right: nil, frameCount: 2_000)
        }
        let phaseBefore = controller.dvsContinuousRenderer.testOnly_corePhase
        XCTAssertGreaterThan(phaseBefore, 0, "sanity: phase must actually have advanced before the curve change")

        engine.setCurvePreset(.blend, for: .crossfader)
        engine.testOnly_waitForMappingPersistenceQueue()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        controller.waitForAudioQueue()

        var afterChange = [Float](repeating: 0, count: 1)
        afterChange.withUnsafeMutableBufferPointer { ptr in
            controller.dvsContinuousRenderer.testOnly_render(left: ptr.baseAddress!, right: nil, frameCount: 1)
        }
        XCTAssertGreaterThanOrEqual(controller.dvsContinuousRenderer.testOnly_corePhase, phaseBefore,
            "a fader-curve preset change must never move the renderer's retained phase backward or reset it")
    }

    // MARK: - Curve-capture session identity binding (Defect 2)

    func testDeviceSwitchDuringCaptureCancelsSessionAndWritesNothing() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceA = "midi_test_curve_identity_device_a"
        let deviceB = "midi_test_curve_identity_device_b"
        defer {
            cleanUpMIDIMapping(deviceIdentifier: deviceA)
            cleanUpMIDIMapping(deviceIdentifier: deviceB)
        }

        installMapping(MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 15, controlNumber: 8), deviceID: deviceA, on: engine)
        // Device B happens to have a control at the SAME (channel, controller) — the exact trap this defect describes.
        var mappingB = MIDIDeviceMapping(deviceIdentifier: deviceB, deviceName: "Device B")
        mappingB.upsert(MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 15, controlNumber: 8))
        MIDILearnedMappingStore.default.save(mappingB)

        engine.startCurveCalibration(for: .crossfader)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        engine.evaluateCurveCaptureForCC(channel: 15, controller: 8, value: 20)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        engine.captureCurveClosedPoint()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(engine.curveCaptureHasClosedPoint)

        // Switch to device B mid-session.
        engine.selectedMIDIInputSourceID = deviceB
        loadMappingAndWait(on: engine)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNil(engine.activeCurveCaptureAction, "a source change must cancel any in-progress curve-capture session")
        XCTAssertFalse(engine.curveCaptureError.isEmpty)

        // Even a matching CC on the new device must not resume the (cancelled) capture.
        engine.evaluateCurveCaptureForCC(channel: 15, controller: 8, value: 100)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        engine.captureCurveFullOnPoint()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(engine.curveCaptureHasFullOnPoint, "captureCurveFullOnPoint must no-op once the session is cancelled")

        engine.finishCurveCalibration()
        engine.testOnly_waitForMappingPersistenceQueue()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNil(MIDILearnedMappingStore.default.load(deviceIdentifier: deviceA)?.control(for: .crossfader)?.curveConfig,
            "no curve data may be written to the OLD device")
        XCTAssertNil(MIDILearnedMappingStore.default.load(deviceIdentifier: deviceB)?.control(for: .crossfader)?.curveConfig,
            "no curve data may be written to the NEW device either — Finish had no active session to complete")
    }

    func testSwitchingToEmptyUnmappedSourceDuringCaptureCancelsSession() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_curve_identity_unmapped_switch"
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        installMapping(MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 15, controlNumber: 8), deviceID: deviceID, on: engine)
        engine.startCurveCalibration(for: .crossfader)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(engine.activeCurveCaptureAction, .crossfader)

        engine.selectedMIDIInputSourceID = ""
        loadMappingAndWait(on: engine)

        XCTAssertNil(engine.activeCurveCaptureAction, "switching to an empty/unmapped source must cancel the session")
    }

    func testRelearningCapturedBindingCancelsSessionAndWritesNothing() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_curve_identity_relearn"
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        installMapping(MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 15, controlNumber: 8), deviceID: deviceID, on: engine)
        engine.startCurveCalibration(for: .crossfader)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        engine.evaluateCurveCaptureForCC(channel: 15, controller: 8, value: 20)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        engine.captureCurveClosedPoint()

        // Relearn the crossfader onto a DIFFERENT physical control.
        engine.startMIDILearn(for: .crossfader)
        _ = engine.evaluateMIDILearnForCC(channel: 14, controller: 9, value: 64)
        engine.testOnly_waitForMappingPersistenceQueue()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNil(engine.activeCurveCaptureAction, "relearning the captured action must cancel the pending capture session")

        // The OLD binding's CC must no longer feed a (cancelled) session, and Finish has nothing to do.
        engine.evaluateCurveCaptureForCC(channel: 15, controller: 8, value: 100)
        engine.finishCurveCalibration()
        engine.testOnly_waitForMappingPersistenceQueue()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(engine.currentMIDIDeviceMapping?.control(for: .crossfader)?.curveConfig)
    }

    func testClearingCapturedActionCancelsSession() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_curve_identity_clear_one"
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        installMapping(MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 15, controlNumber: 8), deviceID: deviceID, on: engine)
        engine.startCurveCalibration(for: .crossfader)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(engine.activeCurveCaptureAction, .crossfader)

        engine.clearMapping(for: .crossfader)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNil(engine.activeCurveCaptureAction, "clearing the captured action's mapping must cancel the session")
    }

    func testClearingAllMappingsCancelsSession() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_curve_identity_clear_all"
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        installMapping(MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 15, controlNumber: 8), deviceID: deviceID, on: engine)
        engine.startCurveCalibration(for: .crossfader)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(engine.activeCurveCaptureAction, .crossfader)

        engine.clearDeviceMappings()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNil(engine.activeCurveCaptureAction, "clearing all mappings must cancel the session")
    }

    /// A late-arriving `evaluateCurveCaptureForCC` publish, enqueued
    /// before Cancel but executed after it, must never resurrect the
    /// cancelled session's UI state — proven directly via the generation
    /// token: `curveCaptureHasLiveValue` must stay false.
    func testLateCurveCaptureObservedPublicationAfterCancelDoesNotResurrectState() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_curve_identity_stale_publish"
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        installMapping(MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 15, controlNumber: 8), deviceID: deviceID, on: engine)
        engine.startCurveCalibration(for: .crossfader)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        // Enqueue a matching CC event (which will publish asynchronously)...
        engine.evaluateCurveCaptureForCC(channel: 15, controller: 8, value: 40)
        // ...then cancel BEFORE that publish's main-thread block has run.
        engine.cancelCurveCalibration()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertNil(engine.activeCurveCaptureAction)
        XCTAssertFalse(engine.curveCaptureHasLiveValue, "a stale publish from before Cancel must never mark the (now-cancelled) session as having a live value")
    }

    /// A Finish's own persistence-write race (identity re-verified fresh
    /// inside the queued transform) must never silently corrupt a
    /// DIFFERENT device's mapping — end-to-end proof that neither the old
    /// nor a same-shaped new device ever receives stray curve data.
    func testDeviceSwitchThenFinishWritesNoCurveDataToEitherDevice() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceA = "midi_test_curve_identity_finish_after_switch_a"
        let deviceB = "midi_test_curve_identity_finish_after_switch_b"
        defer {
            cleanUpMIDIMapping(deviceIdentifier: deviceA)
            cleanUpMIDIMapping(deviceIdentifier: deviceB)
        }

        installMapping(MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 15, controlNumber: 8), deviceID: deviceA, on: engine)
        engine.startCurveCalibration(for: .crossfader)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        engine.evaluateCurveCaptureForCC(channel: 15, controller: 8, value: 20)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        engine.captureCurveClosedPoint()
        engine.evaluateCurveCaptureForCC(channel: 15, controller: 8, value: 100)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        engine.captureCurveFullOnPoint()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(engine.curveCaptureCanFinish, "sanity: both points valid before the switch")

        installMapping(MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 15, controlNumber: 8), deviceID: deviceB, on: engine)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        engine.finishCurveCalibration()
        engine.testOnly_waitForMappingPersistenceQueue()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNil(MIDILearnedMappingStore.default.load(deviceIdentifier: deviceA)?.control(for: .crossfader)?.curveConfig)
        XCTAssertNil(MIDILearnedMappingStore.default.load(deviceIdentifier: deviceB)?.control(for: .crossfader)?.curveConfig)
    }

    // MARK: - Same-preset calls are true no-ops (Defect 3)

    func testSettingAlreadyPersistedPresetIsATrueNoOp() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_curve_preset_noop"
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        installMapping(MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 15, controlNumber: 8), deviceID: deviceID, on: engine)
        engine.setCurvePreset(.blend, for: .crossfader)
        engine.testOnly_waitForMappingPersistenceQueue()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        // Drive gain to a non-unity, non-default value so a spurious reset would be observable.
        engine.evaluateUserMixerGainForCC(channel: 15, controller: 8, value: 64)
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(engine), 0.5, accuracy: 0.01, "sanity: Blend applied, gain reflects the current position")

        let lastModifiedBefore = engine.currentMIDIDeviceMapping?.lastModifiedAt

        // Re-select the ALREADY-persisted preset.
        engine.setCurvePreset(.blend, for: .crossfader)
        engine.testOnly_waitForMappingPersistenceQueue()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(engine.currentMIDIDeviceMapping?.lastModifiedAt, lastModifiedBefore, "no persistence write must occur for a same-preset call")
        XCTAssertEqual(publishedTargetUserMixerGain(engine), 0.5, accuracy: 0.01,
            "gain must be untouched — a same-preset call must not reset to unity or otherwise affect audio")
    }

    /// Same principle for the (unconfigured / nil `curveConfig`) default
    /// case: selecting the preset that's ALREADY the resolved default,
    /// without ever having explicitly persisted a curveConfig, is also a
    /// true no-op.
    func testSettingResolvedDefaultPresetWithNilCurveConfigIsATrueNoOp() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_curve_preset_noop_default"
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        installMapping(MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 15, controlNumber: 8), deviceID: deviceID, on: engine)
        XCTAssertNil(engine.currentMIDIDeviceMapping?.control(for: .crossfader)?.curveConfig, "sanity: no curve configured yet")

        engine.evaluateUserMixerGainForCC(channel: 15, controller: 8, value: 1) // just past the 5% Sharp Scratch cut-in
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()
        let gainBefore = publishedTargetUserMixerGain(engine)

        engine.setCurvePreset(.sharpScratch, for: .crossfader) // already the resolved default
        engine.testOnly_waitForMappingPersistenceQueue()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNil(engine.currentMIDIDeviceMapping?.control(for: .crossfader)?.curveConfig, "must remain nil — no write for a no-op")
        XCTAssertEqual(publishedTargetUserMixerGain(engine), gainBefore, accuracy: 0.001, "gain must be untouched")
    }
}
