// MIDIUserMixerGainTests.swift
// ScratchLabDesktopTests
//
// Engine-level coverage of `MacCaptureEngine.evaluateUserMixerGainForCC`:
// the wiring from a learned crossfader/right-upfader CC event, through the
// existing `MIDILearnedControl.normalizedValue(from:)` calibration/
// inversion math, to `ScratchSamplePlaybackController`'s new gain API.
// Right upfader is authoritative for scratch gain whenever mapped; left
// upfader only mirrors into that same path as a fallback when the device
// has no right-upfader mapping at all (parity with the iOS dispatcher).
// Mappings are constructed
// directly via `MIDILearnedMappingStore`/`loadDeviceMappingForCurrentSource`
// (the same store the production persistence path uses) rather than
// driving the full interactive learn UI flow, so calibration/inversion can
// be set up deterministically in one step.

import XCTest
import AVFoundation
import SwiftUI
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

    // MARK: - Regression #3: left upfader falls back to scratch gain only when right upfader is unmapped

    /// Right upfader is primary, but a device with only a left-upfader
    /// mapping must still control scratch playback gain — mirrors the
    /// equivalent iOS fallback in `IOSMIDIControllerDispatcher.receive(_:)`.
    /// Asserts an intermediate value (64) rather than only the sequence's
    /// final value: 0 and 127 both normalize to values indistinguishable
    /// from a default/unity readout, which previously masked this exact
    /// fallback from this same test.
    func testLearnedLeftUpfaderFallsBackToScratchGainWhenRightUnmapped() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_left_upfader_fallback"
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        let leftUpfader = MIDILearnedControl(action: .leftUpfader, messageType: .controlChange, channel: 0, controlNumber: 7, deck: 0)
        installMapping(leftUpfader, deviceID: deviceID, on: engine)

        engine.evaluateUserMixerGainForCC(channel: 0, controller: 7, value: 0)
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(engine), 0.0,
            "with no right-upfader mapping, left-upfader must drive scratch gain")

        engine.evaluateUserMixerGainForCC(channel: 0, controller: 7, value: 64)
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(engine), leftUpfader.normalizedValue(from: 64), accuracy: 0.0001,
            "left-upfader's raw normalized value (uncurved) drives the scratch-gain fallback")
    }

    /// Once a device has BOTH upfaders learned (the normal Rane wiring: left
    /// on one channel, right on another), right upfader must stay
    /// authoritative for scratch gain — moving the left fader must not also
    /// change it, even though left's own CC event still matches its own
    /// learned binding.
    func testRightUpfaderRemainsAuthoritativeWhenBothMapped() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_both_upfaders_mapped"
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        cleanUpMIDIMapping(deviceIdentifier: deviceID)
        var mapping = MIDIDeviceMapping(deviceIdentifier: deviceID, deviceName: "Test Device")
        mapping.upsert(MIDILearnedControl(action: .leftUpfader, messageType: .controlChange, channel: 0, controlNumber: 7, deck: 0))
        mapping.upsert(MIDILearnedControl(action: .rightUpfader, messageType: .controlChange, channel: 1, controlNumber: 7, deck: 1))
        MIDILearnedMappingStore.default.save(mapping)
        engine.selectedMIDIInputSourceID = deviceID
        loadMappingAndWait(on: engine)

        engine.evaluateUserMixerGainForCC(channel: 1, controller: 7, value: 127)
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(engine), 1.0)

        engine.evaluateUserMixerGainForCC(channel: 0, controller: 7, value: 0)
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(engine), 1.0,
            "right upfader stays authoritative for scratch gain once mapped, even when left is also mapped and moves")
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

    func testMappedMixerControlClassificationIncludesCrossfaderAndBothUpfaders() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        var mapping = MIDIDeviceMapping(deviceIdentifier: "test-device", deviceName: "Rane ONE MKII")
        mapping.upsert(MIDILearnedControl(
            action: .crossfader, messageType: .controlChange,
            channel: 15, controlNumber: 8
        ))
        mapping.upsert(MIDILearnedControl(
            action: .leftUpfader, messageType: .controlChange,
            channel: 0, controlNumber: 28, deck: 0
        ))
        mapping.upsert(MIDILearnedControl(
            action: .rightUpfader, messageType: .controlChange,
            channel: 1, controlNumber: 28, deck: 1
        ))
        engine.testOnly_setDeviceMapping(mapping)

        XCTAssertEqual(engine.mappedMixerControlForCC(channel: 15, controller: 8), "crossfader")
        XCTAssertEqual(engine.mappedMixerControlForCC(channel: 0, controller: 28), "leftUpfader")
        XCTAssertEqual(engine.mappedMixerControlForCC(channel: 1, controller: 28), "rightUpfader")
        XCTAssertNil(engine.mappedMixerControlForCC(channel: 1, controller: 6))
        XCTAssertNil(engine.mappedMixerControlForCC(channel: 0, controller: 8))
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

    /// A persisted left-upfader curve preset must feed the beat-bus output
    /// gain path only — the scratch-gain fallback (which activates because
    /// this device has no right-upfader mapping at all) still uses the RAW
    /// `normalizedValue`, never the curve-resolved gain. Value 3 sits inside
    /// sharpCut's 0...0.05 cut-in ramp, so its curved gain (~0.47) and raw
    /// normalized value (~0.024) diverge sharply — proving this isn't a
    /// coincidental match the way a boundary value (0 or 127) would be.
    func testLeftUpfaderCurveAffectsBeatBusButNotScratchGainFallback() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_curve_left_upfader_fallback"
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        let leftUpfader = MIDILearnedControl(action: .leftUpfader, messageType: .controlChange, channel: 0, controlNumber: 20, deck: 0)
        installMapping(leftUpfader, deviceID: deviceID, on: engine)
        engine.setCurvePreset(.sharpCut, for: .leftUpfader)
        engine.testOnly_waitForMappingPersistenceQueue()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(engine.currentMIDIDeviceMapping?.control(for: .leftUpfader)?.curveConfig?.preset, .sharpCut,
            "the left-upfader curve preference is persisted")

        engine.evaluateUserMixerGainForCC(channel: 0, controller: 20, value: 3)
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(engine), leftUpfader.normalizedValue(from: 3), accuracy: 0.0001,
            "the scratch-gain fallback must use the raw normalized value, not the curved beat-bus gain")
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


final class SeparateMixerFaderEvidenceTests: XCTestCase {
    private func binding(inverted: Bool = false, minimum: Int = 0, maximum: Int = 127,
                         curve: FaderCurveResponse = .init(zeroAt: 0, oneAt: 1, shape: .linear)) -> ScratchMixerFaderEvidence.Binding {
        .init(sourceID: "test-rig", connectionGeneration: 7, channel: 1, controller: 28,
              minimum: minimum, maximum: maximum, inverted: inverted, response: curve)
    }

    private func recorder(channel: Int? = 127, cross: Int? = 127) -> ScratchMixerFaderRecorder {
        var recorder = ScratchMixerFaderRecorder()
        if let cross { recorder.observe(control: .crossfader, binding: binding(), rawValue: cross, at: 9, admitted: false) }
        if let channel { recorder.observe(control: .rightChannel, binding: binding(), rawValue: channel, at: 9, admitted: false) }
        recorder.begin(at: 10, sessionID: "session", takeID: "take")
        return recorder
    }

    func testHeldStateRetainsOriginalTimeWithoutInventingMIDIPackets() throws {
        var r = recorder(); r.close(at: 12)
        let e = try XCTUnwrap(r.snapshot(at: 20))
        XCTAssertTrue(e.sealed)
        XCTAssertEqual(e.end, 2)
        XCTAssertEqual(e.observations.map(\.time), [-1, -1])
        XCTAssertTrue(e.observations.allSatisfy { $0.kind == .heldAtStart })
        XCTAssertTrue(e.combinedSpans(in: 0...2).allSatisfy { $0.state == .open })
    }

    func testEitherControlClosesTheCombinedGateWithoutOverwritingOtherLane() throws {
        for control in ScratchMixerFaderEvidence.Control.allCases {
            var r = recorder()
            r.observe(control: control, binding: binding(), rawValue: 0, at: 11, admitted: true)
            r.close(at: 12)
            let e = try XCTUnwrap(r.snapshot(at: 12))
            XCTAssertEqual(e.combinedSpans(in: 0...2).map(\.state), [.open, .closed])
            let other: ScratchMixerFaderEvidence.Control = control == .crossfader ? .rightChannel : .crossfader
            XCTAssertTrue(e.spans(for: other, in: 0...2).allSatisfy { $0.state == .open })
        }
    }

    func testUnknownChannelDoesNotBecomeOpenAndKnownClosureStillMutes() throws {
        var r = recorder(channel: nil)
        r.observe(control: .crossfader, binding: binding(), rawValue: 0, at: 11, admitted: true)
        let e = try XCTUnwrap(r.snapshot(at: 12))
        XCTAssertEqual(e.combinedSpans(in: 0...2).map(\.state), [nil, .closed])
        XCTAssertTrue(e.spans(for: .rightChannel, in: 0...2).allSatisfy { $0.gain == nil })
    }

    func testReopeningOneFaderDoesNotOpenTheOtherClosedFader() throws {
        var r = recorder(channel: 0, cross: 0)
        r.observe(control: .crossfader, binding: binding(), rawValue: 127, at: 11, admitted: true)
        let e = try XCTUnwrap(r.snapshot(at: 12))
        XCTAssertTrue(e.combinedSpans(in: 0...2).allSatisfy { $0.state == .closed })
    }

    func testDisconnectInvalidatesCoverageUntilANewObservation() throws {
        var r = recorder()
        r.invalidate(.rightChannel, at: 10.5)
        r.observe(control: .rightChannel, binding: binding(), rawValue: 0, at: 11, admitted: true)
        let e = try XCTUnwrap(r.snapshot(at: 12))
        XCTAssertEqual(e.spans(for: .rightChannel, in: 0...2).map(\.state), [.open, nil, .closed])
    }

    func testClosedEpochRejectsPostStopEvidenceAndDoesNotExtendHeldCoverage() throws {
        var r = recorder(); r.close(at: 11)
        r.observe(control: .rightChannel, binding: binding(), rawValue: 0, at: 11.5, admitted: true)
        r.close(at: 13)
        let e = try XCTUnwrap(r.snapshot(at: 14))
        XCTAssertEqual(e.end, 1)
        XCTAssertEqual(e.observations.count, 2)
        XCTAssertEqual(e.combinedSpans(in: 0...2).map(\.state), [.open, nil])
    }

    func testStaleWindowObservationCannotEnterCurrentTake() throws {
        var r = recorder()
        r.observe(control: .rightChannel, binding: binding(), rawValue: 0, at: 11, admitted: false)
        let e = try XCTUnwrap(r.snapshot(at: 12))
        XCTAssertTrue(e.combinedSpans(in: 0...2).allSatisfy { $0.state == .open })
        XCTAssertEqual(e.observations.count, 2)
    }

    func testRangeInversionAndAudioCurveAreAppliedTogether() throws {
        let b = binding(inverted: true, minimum: 10, maximum: 110,
                        curve: .init(zeroAt: 0, oneAt: 0.05, shape: .linear))
        XCTAssertEqual(b.gain(rawValue: 110), 0)
        XCTAssertEqual(b.gain(rawValue: 10), 1)
        XCTAssertEqual(try XCTUnwrap(b.gain(rawValue: 108)), 0.4, accuracy: 1e-12)
        XCTAssertNil(binding(minimum: 30, maximum: 30).gain(rawValue: 30))
    }

    func testNewTakeStartsWithItsOwnIdentityAndNoPriorTimeline() throws {
        var r = recorder()
        r.observe(control: .rightChannel, binding: binding(), rawValue: 0, at: 11, admitted: true)
        r.close(at: 12)
        r.begin(at: 15, sessionID: "next-session", takeID: "next-take")
        let e = try XCTUnwrap(r.snapshot(at: 16))
        XCTAssertEqual(e.sessionID, "next-session"); XCTAssertEqual(e.takeID, "next-take")
        XCTAssertEqual(e.observations.count, 2)
        XCTAssertTrue(e.observations.allSatisfy { $0.time < 0 && $0.kind == .heldAtStart })
    }

    func testInvalidVersionAndOutOfOrderControlEvidenceStayUnknown() throws {
        let b = binding()
        for e in [
            ScratchMixerFaderEvidence(version: 2, sessionID: nil, takeID: nil, epoch: 10, end: 2,
                sealed: true, overflowed: false, observations: []),
            ScratchMixerFaderEvidence(version: 1, sessionID: nil, takeID: nil, epoch: 10, end: 2,
                sealed: true, overflowed: false, observations: [
                    .init(control: .rightChannel, time: 1, kind: .message, binding: b, rawValue: 0),
                    .init(control: .rightChannel, time: 0.5, kind: .message, binding: b, rawValue: 127)])
        ] {
            XCTAssertTrue(e.spans(for: .rightChannel, in: 0...2).allSatisfy { $0.gain == nil })
        }
    }

    @MainActor
    func testCombinedGatePreservesExactMotionAndRoundTripsSeparateControls() throws {
        var r = recorder()
        r.observe(control: .rightChannel, binding: binding(), rawValue: 0, at: 11, admitted: true)
        r.close(at: 12)
        let e = try XCTUnwrap(r.snapshot(at: 12))
        let motion = ScratchNotation.GestureRecord.Evidence(provenance: .measured,
            observation: .init(source: .platterTimeline, confidence: 1, reason: "test motion"))
        let record = ScratchNotation.GestureRecord(id: "gesture", direction: .forward,
            timingDomain: .seconds, coordinateSpace: .normalizedTakeLocalDisplacement, evidence: motion,
            subdivisions: [.init(id: "travel", span: .init(startTime: 0, endTime: 2), evidence: motion,
                measuredCurve: .init(points: [.init(time: 0, position: -0.2), .init(time: 1, position: 0.4),
                                             .init(time: 2, position: 1.1)], evidence: motion))])
        let original = ReferenceTearCanonicalProjection(records: [record], timeRange: 0...2,
            positionRange: -0.2...1.1, coordinateSpace: .normalizedTakeLocalDisplacement, reasons: [])
        let updated = original.applyingMixerFaders(e)
        let frame = try XCTUnwrap(ScratchStrokeGeometry.CanonicalFrame(timeRange: 0...2,
            positionRange: -0.2...1.1, coordinateSpace: .normalizedTakeLocalDisplacement, beatsPerMinute: 95))
        let chart = ScratchPhraseChartView(source: .canonical(updated.records, layer: .performance, frame: frame),
            showBeatGrid: false, mixerFaders: e, showsMixerFaderLanes: true)
            .frame(width: 800, height: 320).background(Color.black).environment(\.colorScheme, .dark)
        let image = try XCTUnwrap(ImageRenderer(content: chart).nsImage)
        XCTAssertEqual(image.size.width, 800)
        let attachment = XCTAttachment(image: image)
        attachment.name = "Separate lanes - synthetic model fixture, not hardware evidence"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(updated.records[0].subdivisions, record.subdivisions)
        XCTAssertEqual(updated.records[0].internalHolds, record.internalHolds)
        XCTAssertEqual(updated.records[0].direction, record.direction)
        XCTAssertEqual(updated.records[0].faderIntervals.map(\.state), [.open, .closed])
        XCTAssertTrue(updated.records[0].faderValidationIssues().isEmpty)
        XCTAssertEqual(updated, try JSONDecoder().decode(ReferenceTearCanonicalProjection.self,
            from: JSONEncoder().encode(updated)))
        XCTAssertNil(try JSONDecoder().decode(ReferenceTearCanonicalProjection.self,
            from: JSONEncoder().encode(original)).mixerFaders)
    }
}


extension SeparateMixerFaderEvidenceTests {
    func testRecordedControlEvidenceUsesExactSourceConnectionAndLearnedAddress() throws {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        engine.selectedMIDIInputSourceID = "separate-lane-test-only"
        let token = engine.testOnly_armTakeMIDIWindow()
        defer { _ = engine.testOnly_releaseAbandonedTakeMIDIWindow(token: token) }
        var mapping = MIDIDeviceMapping(deviceIdentifier: "separate-lane-test-only", deviceName: "Test")
        mapping.upsert(.init(action: .rightUpfader, messageType: .controlChange,
                            channel: 1, controlNumber: 28, deck: 1))
        engine.testOnly_setDeviceMapping(mapping)
        engine.testOnly_setLiveFaderContext(sourceID: "separate-lane-test-only",
            connectionGeneration: 7, mapping: nil, calibrations: [])
        let start = CACurrentMediaTime()
        engine.testOnly_openTakeMIDIEpoch(at: start)
        func send(_ source: String, _ generation: UInt64, _ channel: Int, _ controller: Int, _ value: Int, _ offset: Double) {
            engine.recordReceivedMIDICCEvent(sourceIdentifier: source, sourceName: "Test",
                channel: channel, controller: controller, value: value, mappedControl: "rightUpfader",
                timestamp: start + offset, inputConnectionGeneration: generation)
        }
        send("other-source", 7, 1, 28, 0, 0.1)
        send("separate-lane-test-only", 6, 1, 28, 0, 0.2)
        send("separate-lane-test-only", 7, 0, 28, 0, 0.3)
        send("separate-lane-test-only", 7, 1, 29, 0, 0.4)
        send("separate-lane-test-only", 7, 1, 28, 0, 0.5)
        engine.testOnly_closeTakeMIDIEpoch(at: start + 1, token: token)
        let evidence = try XCTUnwrap(engine.mixerFaderEvidenceSnapshot())
        XCTAssertEqual(evidence.observations.count, 1)
        XCTAssertEqual(evidence.observations.first?.control, .rightChannel)
        XCTAssertEqual(evidence.observations.first?.time ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertEqual(evidence.spans(for: .rightChannel, in: 0...1).map(\.state), [nil, .closed])
        XCTAssertEqual(evidence.combinedSpans(in: 0...1).map(\.state), [nil, .closed])
    }

    func testTakeOverflowRemainsUnknownWhilePreviewRetainsBoundedRecentObservations() throws {
        var take = recorder()
        var preview = ScratchMixerFaderRecorder()
        preview.begin(at: 10, sessionID: nil, takeID: nil, isPreview: true)
        for i in 0..<32_010 {
            let time = 10 + Double(i) / 1000
            take.observe(control: .rightChannel, binding: binding(), rawValue: i % 128, at: time, admitted: true)
            preview.observe(control: .rightChannel, binding: binding(), rawValue: i % 128, at: time, admitted: true)
        }
        let takeEvidence = try XCTUnwrap(take.snapshot(at: 43))
        XCTAssertTrue(takeEvidence.overflowed)
        XCTAssertNil(takeEvidence.combinedSpans(in: 32...33).first?.gain)
        let previewEvidence = try XCTUnwrap(preview.snapshot(at: 43))
        XCTAssertFalse(previewEvidence.overflowed)
        XCTAssertLessThan(previewEvidence.observations.count, 32_000)
        XCTAssertNotNil(previewEvidence.spans(for: .rightChannel, in: 32.01...33).first?.gain)
        XCTAssertNil(previewEvidence.spans(for: .crossfader, in: 32...33).first?.gain)
    }
}


extension SeparateMixerFaderEvidenceTests {
    func testLivePollDiscardsMotionWhenMixerCaptureEpochChangesDuringRead() throws {
        var r = recorder()
        let old = try XCTUnwrap(r.snapshot(at: 12))
        r.begin(at: 20, sessionID: "session", takeID: "next")
        let next = try XCTUnwrap(r.snapshot(at: 22))
        var current: ScratchMixerFaderEvidence? = old
        let racing = LivePerformedNotationDataSource(selectedMIDISourceName: { "Test" },
            capturedMidiCCEventsSnapshot: { current = next; return [] },
            cameraMovementEventsSnapshot: { _ in nil }, mixerFaderEvidence: { current })
        XCTAssertNil(LivePerformedNotationTracker.computeFrame(dataSource: racing, baselineTimestamp: 0))
        let stable = try XCTUnwrap(LivePerformedNotationTracker.computeFrame(dataSource: racing, baselineTimestamp: 0))
        XCTAssertEqual(stable.mixerFaders, next)
        current = nil
        let legacy = LivePerformedNotationDataSource(selectedMIDISourceName: { "Test" },
            capturedMidiCCEventsSnapshot: { [] }, cameraMovementEventsSnapshot: { _ in nil })
        XCTAssertNotNil(LivePerformedNotationTracker.computeFrame(dataSource: legacy, baselineTimestamp: 0))
    }
}


extension SeparateMixerFaderEvidenceTests {
    func testClearingWindowCannotRebindPriorTakeButPreservesOriginalHeldObservation() throws {
        var r = recorder()
        r.close(at: 12)
        XCTAssertNotNil(r.snapshot(at: 12))
        r.clearWindow()
        XCTAssertNil(r.snapshot(at: 13))
        r.close(at: 14)
        XCTAssertNil(r.snapshot(at: 14), "A failed start cannot seal or reuse the previous timeline")
        r.begin(at: 20, sessionID: "session", takeID: "next")
        let e = try XCTUnwrap(r.snapshot(at: 21))
        XCTAssertEqual(e.takeID, "next")
        XCTAssertEqual(e.observations.map(\.time), [-11, -11])
        XCTAssertTrue(e.observations.allSatisfy { $0.kind == .heldAtStart })
    }

    func testEngineDrainAndFailedStartClearTheAssociatedFaderTimeline() throws {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        engine.selectedMIDIInputSourceID = "separate-lane-failed-start-test"
        let first = engine.testOnly_armTakeMIDIWindow()
        let start = CACurrentMediaTime()
        engine.testOnly_openTakeMIDIEpoch(at: start)
        engine.testOnly_closeTakeMIDIEpoch(at: start + 1, token: first)
        XCTAssertTrue(try XCTUnwrap(engine.mixerFaderEvidenceSnapshot()).sealed)
        XCTAssertNotNil(engine.testOnly_drainTakeMIDIWindow(token: first))
        XCTAssertNil(engine.mixerFaderEvidenceSnapshot())
        let failed = engine.testOnly_armTakeMIDIWindow()
        defer { _ = engine.testOnly_releaseAbandonedTakeMIDIWindow(token: failed) }
        engine.testOnly_closeTakeMIDIEpoch(at: start + 2, token: failed)
        XCTAssertNil(engine.mixerFaderEvidenceSnapshot())
    }
}


extension SeparateMixerFaderEvidenceTests {
    func testAdmittedOutOfOrderControlPacketsRemainVisibleAndInvalidateCoverage() throws {
        var r = recorder()
        r.observe(control: .rightChannel, binding: binding(), rawValue: 0, at: 11, admitted: true)
        r.observe(control: .rightChannel, binding: binding(), rawValue: 127, at: 10.5, admitted: true)
        r.close(at: 12)
        let e = try XCTUnwrap(r.snapshot(at: 12))
        XCTAssertEqual(e.observations.filter { $0.control == .rightChannel }.map(\.time), [-1, 1, 0.5])
        XCTAssertTrue(e.spans(for: .rightChannel, in: 0...2).allSatisfy { $0.gain == nil })
        r.clearWindow()
        r.begin(at: 20, sessionID: "session", takeID: "next")
        XCTAssertEqual(r.snapshot(at: 21)?.observations.first { $0.control == .rightChannel }?.rawValue, 0,
                       "An older packet must not rewind the held position cache")
    }
}

// The native fixtures intercept Core MIDI effects after the production reuse
// decision. A non-reused connection follows the real mapping reload path.
extension MIDIUserMixerGainTests {
    @MainActor
    private func settleMappingPublication() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor
    private func makeCaptureBoundaryEngine(_ id: String) async -> MacCaptureEngine {
        cleanUpMIDIMapping(deviceIdentifier: id)
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        engine.selectedMIDIInputSourceID = id
        await settleMappingPublication()
        var mapping = MIDIDeviceMapping(deviceIdentifier: id, deviceName: "Test controller")
        mapping.upsert(.init(action: .crossfader, messageType: .controlChange, channel: 15, controlNumber: 8))
        mapping.upsert(.init(action: .rightUpfader, messageType: .controlChange, channel: 1, controlNumber: 28, deck: 1))
        MIDILearnedMappingStore.default.save(mapping)
        engine.loadDeviceMappingForCurrentSource()
        await settleMappingPublication()
        engine.testOnly_setLiveFaderContext(sourceID: id, connectionGeneration: 1, mapping: nil, calibrations: [])
        return engine
    }

    private func observeBoundaryFader(_ engine: MacCaptureEngine, id: String,
                                     channel: Int, cc: Int, value: Int, time: Double) {
        engine.evaluateUserMixerGainForCC(channel: channel, controller: cc, value: value)
        engine.recordReceivedMIDICCEvent(sourceIdentifier: id, sourceName: "Test controller",
            channel: channel, controller: cc, value: value, timestamp: time, inputConnectionGeneration: 1)
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()
    }

    @MainActor
    func testCaptureBoundariesPreserveObservedFadersAndActualMixerGain() async throws {
        // Includes both-closed then opening just one: no boundary may unmute it.
        for (cross, channel) in [(127, 0), (0, 127), (0, 0), (127, 64)] {
            let id = "midi_test_capture_boundary_\(cross)_\(channel)"
            defer { cleanUpMIDIMapping(deviceIdentifier: id) }
            let engine = await makeCaptureBoundaryEngine(id)
            var decisions: [Bool] = []
            engine.testOnly_setMIDIReconnectContext(sourceID: id, connected: true) { [weak engine] reused in
                decisions.append(reused)
                if !reused { engine?.loadDeviceMappingForCurrentSource() }
            }
            let observed = CACurrentMediaTime()
            observeBoundaryFader(engine, id: id, channel: 15, cc: 8, value: cross, time: observed)
            observeBoundaryFader(engine, id: id, channel: 1, cc: 28, value: channel, time: observed)
            let gainBefore = publishedTargetUserMixerGain(engine)
            XCTAssertLessThan(gainBefore, 1, "A reset to unity must be observable in every case")
            for offset in [1.0, 3.0] {
                let token = engine.testOnly_armTakeMIDIWindow()
                await settleMappingPublication()
                engine.testOnly_openTakeMIDIEpoch(at: observed + offset)
                engine.testOnly_closeTakeMIDIEpoch(at: observed + offset + 1, token: token)
                let evidence = try XCTUnwrap(engine.mixerFaderEvidenceSnapshot())
                XCTAssertEqual(evidence.observations.count, 2)
                XCTAssertTrue(evidence.observations.allSatisfy { $0.kind == .heldAtStart && $0.time == -offset })
                XCTAssertEqual(evidence.observations.first { $0.control == .crossfader }?.rawValue, cross)
                XCTAssertEqual(evidence.observations.first { $0.control == .rightChannel }?.rawValue, channel)
                XCTAssertEqual(try XCTUnwrap(evidence.combinedSpans(in: 0...1).first?.gain), gainBefore, accuracy: 1e-12)
                engine.testOnly_scratchPlaybackController.waitForAudioQueue()
                XCTAssertEqual(publishedTargetUserMixerGain(engine), gainBefore, accuracy: 1e-12)
                XCTAssertTrue(try XCTUnwrap(engine.testOnly_drainTakeMIDIWindow(token: token)).isEmpty,
                              "Held observations must never become fabricated in-take MIDI messages")
                engine.testOnly_restoreMIDIMonitoringAfterCapture()
                await settleMappingPublication()
            }
            XCTAssertEqual(decisions, [true, true, true, true])
        }
    }

    @MainActor
    func testCaptureArmRejectsMissingChangedAndUnreadyConnections() async {
        let id = "midi_test_capture_boundary_reject"
        defer { cleanUpMIDIMapping(deviceIdentifier: id) }
        let engine = await makeCaptureBoundaryEngine(id)
        var decisions: [Bool] = []
        for (source, endpoint, ready) in [(Optional(id), UInt32(1), false), (Optional(id), 2, true), (nil, 1, true)] {
            engine.testOnly_setMIDIReconnectContext(sourceID: source, endpointRef: endpoint, connected: ready) {
                decisions.append($0)
            }
            let token = engine.testOnly_armTakeMIDIWindow()
            XCTAssertTrue(engine.testOnly_releaseAbandonedTakeMIDIWindow(token: token))
        }
        engine.testOnly_setLiveFaderContext(sourceID: "other-device", connectionGeneration: 2, mapping: nil, calibrations: [])
        engine.testOnly_setMIDIReconnectContext(sourceID: id, connected: true) { decisions.append($0) }
        let token = engine.testOnly_armTakeMIDIWindow()
        XCTAssertTrue(engine.testOnly_releaseAbandonedTakeMIDIWindow(token: token))
        XCTAssertEqual(decisions, [false, false, false, false])
    }

    @MainActor
    func testExplicitReconnectStillInvalidatesHeldStateAndResetsGain() async throws {
        let id = "midi_test_capture_boundary_explicit_reload"
        defer { cleanUpMIDIMapping(deviceIdentifier: id) }
        let engine = await makeCaptureBoundaryEngine(id)
        var decisions: [Bool] = []
        engine.testOnly_setMIDIReconnectContext(sourceID: id, connected: true) { [weak engine] reused in
            decisions.append(reused)
            if !reused { engine?.loadDeviceMappingForCurrentSource() }
        }
        let observed = CACurrentMediaTime()
        observeBoundaryFader(engine, id: id, channel: 1, cc: 28, value: 0, time: observed)
        XCTAssertEqual(publishedTargetUserMixerGain(engine), 0)
        engine.testOnly_forceMIDIReconnect()
        await settleMappingPublication()
        engine.testOnly_scratchPlaybackController.waitForAudioQueue()
        XCTAssertEqual(publishedTargetUserMixerGain(engine), 1)
        let token = engine.testOnly_armTakeMIDIWindow()
        defer { _ = engine.testOnly_releaseAbandonedTakeMIDIWindow(token: token) }
        engine.testOnly_openTakeMIDIEpoch(at: observed + 1)
        engine.testOnly_closeTakeMIDIEpoch(at: observed + 2, token: token)
        let evidence = try XCTUnwrap(engine.mixerFaderEvidenceSnapshot())
        XCTAssertTrue(evidence.observations.isEmpty)
        XCTAssertTrue(evidence.combinedSpans(in: 0...1).allSatisfy { $0.gain == nil })
        XCTAssertEqual(decisions, [false, true])
    }

    @MainActor
    func testCaptureArmDoesNotInventAnUnobservedRightChannelPosition() async throws {
        let id = "midi_test_capture_boundary_unknown"
        defer { cleanUpMIDIMapping(deviceIdentifier: id) }
        let engine = await makeCaptureBoundaryEngine(id)
        engine.testOnly_setMIDIReconnectContext(sourceID: id, connected: true) { XCTAssertTrue($0) }
        let observed = CACurrentMediaTime()
        observeBoundaryFader(engine, id: id, channel: 15, cc: 8, value: 127, time: observed)
        let token = engine.testOnly_armTakeMIDIWindow()
        defer { _ = engine.testOnly_releaseAbandonedTakeMIDIWindow(token: token) }
        engine.testOnly_openTakeMIDIEpoch(at: observed + 1)
        engine.testOnly_closeTakeMIDIEpoch(at: observed + 2, token: token)
        let evidence = try XCTUnwrap(engine.mixerFaderEvidenceSnapshot())
        XCTAssertEqual(evidence.observations.map(\.control), [.crossfader])
        XCTAssertTrue(evidence.spans(for: .rightChannel, in: 0...1).allSatisfy { $0.gain == nil })
        XCTAssertTrue(evidence.combinedSpans(in: 0...1).allSatisfy { $0.gain == nil })
    }
}
