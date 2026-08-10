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

    /// Saves a one-control mapping for `deviceID` and loads it onto
    /// `engine` synchronously via the production `loadDeviceMappingForCurrentSource`
    /// path (no persistence-queue wait needed — that call is synchronous).
    private func installMapping(_ control: MIDILearnedControl, deviceID: String, on engine: MacCaptureEngine) {
        var mapping = MIDIDeviceMapping(deviceIdentifier: deviceID, deviceName: "Test Device")
        mapping.upsert(control)
        MIDILearnedMappingStore.default.save(mapping)
        engine.selectedMIDIInputSourceID = deviceID
        engine.loadDeviceMappingForCurrentSource()
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
        relaunchedEngine.loadDeviceMappingForCurrentSource()

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
        engine.loadDeviceMappingForCurrentSource()

        engine.evaluateUserMixerGainForCC(channel: 0, controller: 7, value: 0)
        engine.evaluateUserMixerGainForCC(channel: 15, controller: 8, value: 0)
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(engine), 0.0,
            "sanity: both controls must actually be at zero before the switch")

        // Switch to a source with no stored mapping at all.
        engine.selectedMIDIInputSourceID = "midi_test_lifecycle_unmapped_source"
        engine.loadDeviceMappingForCurrentSource()
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
        engine.loadDeviceMappingForCurrentSource()
        engine.evaluateUserMixerGainForCC(channel: 0, controller: 7, value: 0)
        engine.evaluateUserMixerGainForCC(channel: 15, controller: 8, value: 0)
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(engine), 0.0)

        try writeMalformedMappingFile(deviceIdentifier: deviceBroken)
        engine.selectedMIDIInputSourceID = deviceBroken
        engine.loadDeviceMappingForCurrentSource()
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
        engine.loadDeviceMappingForCurrentSource()

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
        engine.loadDeviceMappingForCurrentSource()

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
        engine.loadDeviceMappingForCurrentSource()

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
        engine.loadDeviceMappingForCurrentSource()
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
        engine.loadDeviceMappingForCurrentSource()
        engine.evaluateUserMixerGainForCC(channel: 0, controller: 7, value: 0)
        // Rapid switch to B without draining A's queued gain work first.
        engine.selectedMIDIInputSourceID = deviceB
        engine.loadDeviceMappingForCurrentSource()
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
        engine.loadDeviceMappingForCurrentSource()
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
}
