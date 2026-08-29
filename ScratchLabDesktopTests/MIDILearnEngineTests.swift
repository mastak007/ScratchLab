// MIDILearnEngineTests.swift
// ScratchLabDesktopTests
//
// Engine-level tests for the multi-action MIDI Learn / hot-cue checkpoint
// (MacCaptureEngine): CC6 platter-flood rejection, CC8 crossfader acceptance
// (action-aware filtering, not a blanket controller-number ban), upfader
// deck/calibration assignment, hot-cue press-edge and exactly-once loading,
// and per-device mapping isolation/reconnect.
//
// Kept in its own file/class (mirroring MIDILearnedMappingTests.swift)
// rather than appended to CaptureReliabilityPhase1Tests.swift's single giant
// XCTestCase class, which was observed to only run a subset of its own
// pre-existing tests under `xcodebuild test -only-testing:.../ClassName`
// (confirmed via `xcrun xcresulttool`: 57 of 94 declared methods selected,
// including some unrelated to this session's changes) — a class-size/
// discovery limitation, not something these tests should depend on.

import XCTest
@testable import ScratchLab

final class MIDILearnEngineTests: XCTestCase {

    /// Removes any on-disk mapping left behind by a test's device identifier.
    private func cleanUpMIDIMapping(deviceIdentifier: String) {
        MIDILearnedMappingStore.default.delete(deviceIdentifier: deviceIdentifier)
    }

    private func loadMappingAndWait(on engine: MacCaptureEngine) {
        engine.loadDeviceMappingForCurrentSource()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    func testSyntheticSelectionDoesNotOverwriteAppStandardDefaults() {
        let key = "scratchlab.mac.selectedMIDIInputSourceID"
        let appSelectionBeforeTest = UserDefaults.standard.string(forKey: key)

        let engine = MacCaptureEngine(autoRefreshDevices: false)
        engine.selectedMIDIInputSourceID = "midi_test_selection_isolation"

        XCTAssertEqual(
            UserDefaults.standard.string(forKey: key),
            appSelectionBeforeTest,
            "Hosted MIDI tests must never replace the user's selected controller"
        )
    }

    func testCC6PlatterFloodIgnoredDuringUpfaderLearn() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_cc6_flood"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .leftUpfader)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let result = engine.evaluateMIDILearnForCC(channel: 0, controller: 6, value: 64)
        XCTAssertFalse(result.consumedByLearn, "CC6 must never be claimed by an active learn session")
        XCTAssertNil(result.crossfaderMapping, "CC6 must never resolve as the effective crossfader mapping")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNil(engine.currentMIDIDeviceMapping?.control(for: .leftUpfader), "The platter's CC6 flood must never be captured as a learned control")
        XCTAssertEqual(engine.activeMIDILearnAction, .leftUpfader, "Ignoring CC6 must leave the learn session active, waiting for a real control")
    }

    func testCC8AcceptedForCrossfaderLearn() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_cc8_crossfader"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .crossfader)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        // Verified Rane ONE MKII crossfader: CC8 on channel 15 (displayed as "Ch16").
        let result = engine.evaluateMIDILearnForCC(channel: 15, controller: 8, value: 127)
        XCTAssertTrue(result.consumedByLearn)
        XCTAssertEqual(result.crossfaderMapping, MacCaptureEngine.CrossfaderCCMapping(channel: 15, controller: 8))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(engine.currentMIDIDeviceMapping?.control(for: .crossfader)?.controlNumber, 8)
        XCTAssertEqual(engine.currentMIDIDeviceMapping?.control(for: .crossfader)?.channel, 15)
        XCTAssertEqual(engine.crossfaderCCMapping, MacCaptureEngine.CrossfaderCCMapping(channel: 15, controller: 8))
    }

    func testCC8NotBlanketBannedForNonCrossfaderLearn() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_cc8_upfader"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .leftUpfader)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        _ = engine.evaluateMIDILearnForCC(channel: 0, controller: 8, value: 64)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(
            engine.currentMIDIDeviceMapping?.control(for: .leftUpfader)?.controlNumber, 8,
            "CC8 filtering must be action-aware (only CC6 is banned), not a blanket controller-number ban"
        )
    }

    func testCrossfaderLearnStopsAfterFirstAcceptedEvent() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_learn_stops"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .crossfader)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        _ = engine.evaluateMIDILearnForCC(channel: 15, controller: 8, value: 100)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(engine.crossfaderCCMapping, MacCaptureEngine.CrossfaderCCMapping(channel: 15, controller: 8))

        // Regression: a later, unrelated CC event must not silently re-learn and
        // overwrite the mapping — learning must end after the first accepted event.
        _ = engine.evaluateMIDILearnForCC(channel: 0, controller: 20, value: 50)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(engine.crossfaderCCMapping, MacCaptureEngine.CrossfaderCCMapping(channel: 15, controller: 8))
    }

    func testLeftAndRightUpfaderLearnAssignCorrectDeck() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_upfader_deck"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .leftUpfader)
        _ = engine.evaluateMIDILearnForCC(channel: 0, controller: 20, value: 100)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(engine.currentMIDIDeviceMapping?.control(for: .leftUpfader)?.deck, 0)

        engine.startMIDILearn(for: .rightUpfader)
        _ = engine.evaluateMIDILearnForCC(channel: 1, controller: 21, value: 100)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(engine.currentMIDIDeviceMapping?.control(for: .rightUpfader)?.deck, 1)
        XCTAssertNil(engine.currentMIDIDeviceMapping?.control(for: .crossfader)?.deck)
    }

    func testHotCueNoteOffDoesNotTriggerLoad() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_hotcue_noteoff"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .hotCue1)
        engine.receiveNoteOnPadEvent(channel: 10, noteNumber: 40, velocity: 127)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        engine.assignSampleToHotCue("ahhh", hotCueIndex: 1)
        engine.testOnly_waitForMappingPersistenceQueue()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        // Note Off is velocity 0 — must never reload the sample.
        engine.receiveNoteOnPadEvent(channel: 10, noteNumber: 40, velocity: 0)
        engine.testOnly_waitForPlaybackQueue()
        XCTAssertNil(engine.testOnly_scratchPlaybackDiagnosticsSnapshot().loadedSampleID)
    }

    func testHotCueCCReleaseDoesNotTriggerLoad() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_hotcue_ccrelease"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .hotCue2)
        _ = engine.evaluateMIDILearnForCC(channel: 4, controller: 30, value: 127)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        engine.assignSampleToHotCue("fresh", hotCueIndex: 2)
        engine.testOnly_waitForMappingPersistenceQueue()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        // CC release (value 0) must never (re)load the sample.
        engine.recordReceivedMIDICCEvent(sourceName: "Test", channel: 4, controller: 30, value: 0)
        engine.testOnly_waitForPlaybackQueue()
        XCTAssertNil(engine.testOnly_scratchPlaybackDiagnosticsSnapshot().loadedSampleID)
    }

    func testHotCuePressLoadsAssignedSample() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_hotcue_press"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .hotCue3)
        engine.receiveNoteOnPadEvent(channel: 10, noteNumber: 41, velocity: 127)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        engine.assignSampleToHotCue("ah_yeah", hotCueIndex: 3)
        engine.testOnly_waitForMappingPersistenceQueue()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        engine.receiveNoteOnPadEvent(channel: 10, noteNumber: 41, velocity: 127)
        engine.testOnly_waitForPlaybackQueue()
        XCTAssertEqual(engine.testOnly_scratchPlaybackDiagnosticsSnapshot().loadedSampleID, "ah_yeah")
    }

    /// ch6/note20 is the TEMP diagnostic ahhh fallback's trigger and has no entry
    /// in `ScratchBankPadEventRouter`'s note table, so only the `productionMatched`
    /// guard can suppress it — this is the one case that actually exercises "a
    /// learned hot cue must not double-fire alongside the temp fallback."
    func testLearnedHotCueSuppressesTempAhhhFallbackOnSameEvent() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_hotcue_no_double_fire"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .hotCue4)
        engine.receiveNoteOnPadEvent(channel: 6, noteNumber: 20, velocity: 127)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        engine.assignSampleToHotCue("check_it_out", hotCueIndex: 4)
        engine.testOnly_waitForMappingPersistenceQueue()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        engine.receiveNoteOnPadEvent(channel: 6, noteNumber: 20, velocity: 127)
        engine.testOnly_waitForPlaybackQueue()
        XCTAssertEqual(
            engine.testOnly_scratchPlaybackDiagnosticsSnapshot().loadedSampleID,
            "check_it_out",
            "A learned production hot-cue mapping must win over the temp ch6/note20 ahhh fallback, not double-fire both"
        )
    }

    func testLearningHotCueDoesNotFireItsOwnActionOnTheLearnEvent() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_hotcue_no_fire_on_learn"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        // Pre-existing mapping + assignment for hot cue 5 on note 50.
        engine.startMIDILearn(for: .hotCue5)
        engine.receiveNoteOnPadEvent(channel: 10, noteNumber: 50, velocity: 127)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        engine.assignSampleToHotCue("ahhh", hotCueIndex: 5)
        engine.testOnly_waitForMappingPersistenceQueue()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        // Re-learning hot cue 6 onto the SAME note (a collision with the
        // existing hot-cue-5 mapping) must not fire hot cue 5's sample on the
        // event used to learn hot cue 6.
        engine.startMIDILearn(for: .hotCue6)
        engine.receiveNoteOnPadEvent(channel: 10, noteNumber: 50, velocity: 127)
        engine.testOnly_waitForPlaybackQueue()
        XCTAssertNil(
            engine.testOnly_scratchPlaybackDiagnosticsSnapshot().loadedSampleID,
            "Learning must not trigger any hot cue's sample load on the same event that taught it"
        )
    }

    func testEngineDeviceMappingIsolationBetweenDevices() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let raneID = "midi_test_iso_rane"
        let pioneerID = "midi_test_iso_pioneer"
        cleanUpMIDIMapping(deviceIdentifier: raneID)
        cleanUpMIDIMapping(deviceIdentifier: pioneerID)
        defer {
            cleanUpMIDIMapping(deviceIdentifier: raneID)
            cleanUpMIDIMapping(deviceIdentifier: pioneerID)
        }

        engine.selectedMIDIInputSourceID = raneID
        engine.startMIDILearn(for: .crossfader)
        _ = engine.evaluateMIDILearnForCC(channel: 15, controller: 8, value: 100)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(engine.currentMIDIDeviceMapping?.control(for: .crossfader)?.controlNumber, 8)

        engine.selectedMIDIInputSourceID = pioneerID
        loadMappingAndWait(on: engine)
        XCTAssertNil(engine.currentMIDIDeviceMapping, "A device with no saved mapping must not inherit another device's mapping")

        engine.startMIDILearn(for: .crossfader)
        _ = engine.evaluateMIDILearnForCC(channel: 0, controller: 11, value: 100)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(engine.currentMIDIDeviceMapping?.control(for: .crossfader)?.controlNumber, 11)

        // Switching back to the Rane must restore ITS mapping, not the Pioneer's.
        engine.selectedMIDIInputSourceID = raneID
        loadMappingAndWait(on: engine)
        XCTAssertEqual(engine.currentMIDIDeviceMapping?.control(for: .crossfader)?.controlNumber, 8)
    }

    func testReconnectRestoresPersistedDeviceMapping() {
        let deviceID = "midi_test_reconnect"
        cleanUpMIDIMapping(deviceIdentifier: deviceID)
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        let engine1 = MacCaptureEngine(autoRefreshDevices: false)
        engine1.selectedMIDIInputSourceID = deviceID
        engine1.startMIDILearn(for: .rightUpfader)
        _ = engine1.evaluateMIDILearnForCC(channel: 1, controller: 21, value: 100)
        engine1.testOnly_waitForMappingPersistenceQueue()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNotNil(engine1.currentMIDIDeviceMapping?.control(for: .rightUpfader))

        // A fresh engine instance (simulating relaunch) loading the same persisted
        // device identifier must recover the same mapping.
        let engine2 = MacCaptureEngine(autoRefreshDevices: false)
        engine2.selectedMIDIInputSourceID = deviceID
        loadMappingAndWait(on: engine2)
        XCTAssertEqual(engine2.currentMIDIDeviceMapping?.control(for: .rightUpfader)?.controlNumber, 21)
    }

    // MARK: - Continuous control calibration

    func testCalibrationFullZeroTo127RangeAccepted() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_calibration_full_range"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .crossfader)
        _ = engine.evaluateMIDILearnForCC(channel: 15, controller: 8, value: 64)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        engine.startCalibration(for: .crossfader)
        engine.evaluateCalibrationForCC(channel: 15, controller: 8, value: 0)
        engine.evaluateCalibrationForCC(channel: 15, controller: 8, value: 64)
        engine.evaluateCalibrationForCC(channel: 15, controller: 8, value: 127)
        engine.finishCalibration()
        engine.testOnly_waitForMappingPersistenceQueue()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let control = engine.currentMIDIDeviceMapping?.control(for: .crossfader)
        XCTAssertEqual(control?.minValue, 0)
        XCTAssertEqual(control?.maxValue, 127)
        XCTAssertTrue(engine.calibrationError.isEmpty)
        XCTAssertNil(engine.activeCalibrationAction)
    }

    func testCalibrationRestrictedRangeAccepted() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_calibration_restricted_range"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .leftUpfader)
        _ = engine.evaluateMIDILearnForCC(channel: 0, controller: 20, value: 50)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        // A real fader that doesn't quite reach 0/127 at its physical stops —
        // a restricted but perfectly usable range.
        engine.startCalibration(for: .leftUpfader)
        engine.evaluateCalibrationForCC(channel: 0, controller: 20, value: 20)
        engine.evaluateCalibrationForCC(channel: 0, controller: 20, value: 100)
        engine.finishCalibration()
        engine.testOnly_waitForMappingPersistenceQueue()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let control = engine.currentMIDIDeviceMapping?.control(for: .leftUpfader)
        XCTAssertEqual(control?.minValue, 20)
        XCTAssertEqual(control?.maxValue, 100)
    }

    func testCalibrationInsufficientRangeRejectedAndNotPersisted() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_calibration_narrow_range"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .rightUpfader)
        _ = engine.evaluateMIDILearnForCC(channel: 1, controller: 21, value: 50)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        // Jittery/near-stationary movement — far too narrow to calibrate from.
        engine.startCalibration(for: .rightUpfader)
        engine.evaluateCalibrationForCC(channel: 1, controller: 21, value: 60)
        engine.evaluateCalibrationForCC(channel: 1, controller: 21, value: 65)
        engine.finishCalibration()
        engine.testOnly_waitForMappingPersistenceQueue()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertFalse(engine.calibrationError.isEmpty, "A too-narrow range must surface a visible rejection error")
        let control = engine.currentMIDIDeviceMapping?.control(for: .rightUpfader)
        XCTAssertEqual(control?.minValue, 0, "Rejected calibration must not overwrite the default/previous range")
        XCTAssertEqual(control?.maxValue, 127)
    }

    func testCalibrationNoMovementRejected() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_calibration_no_movement"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .crossfader)
        _ = engine.evaluateMIDILearnForCC(channel: 15, controller: 8, value: 50)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        engine.startCalibration(for: .crossfader)
        // No events fed at all — Karl clicked Finish without moving the control.
        engine.finishCalibration()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertFalse(engine.calibrationError.isEmpty)
        XCTAssertEqual(engine.currentMIDIDeviceMapping?.control(for: .crossfader)?.minValue, 0)
        XCTAssertEqual(engine.currentMIDIDeviceMapping?.control(for: .crossfader)?.maxValue, 127)
    }

    func testCalibrationNormalizationNormalAndInverted() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_calibration_normalize"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .crossfader)
        _ = engine.evaluateMIDILearnForCC(channel: 15, controller: 8, value: 50)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        engine.startCalibration(for: .crossfader)
        engine.evaluateCalibrationForCC(channel: 15, controller: 8, value: 10)
        engine.evaluateCalibrationForCC(channel: 15, controller: 8, value: 110)
        engine.finishCalibration()
        engine.testOnly_waitForMappingPersistenceQueue()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        var control = engine.currentMIDIDeviceMapping?.control(for: .crossfader)
        XCTAssertEqual(control?.normalizedValue(from: 10) ?? -1, 0.0, accuracy: 0.0001)
        XCTAssertEqual(control?.normalizedValue(from: 110) ?? -1, 1.0, accuracy: 0.0001)
        XCTAssertEqual(control?.normalizedValue(from: 60) ?? -1, 0.5, accuracy: 0.01)

        engine.setInversion(true, for: .crossfader)
        engine.testOnly_waitForMappingPersistenceQueue()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        control = engine.currentMIDIDeviceMapping?.control(for: .crossfader)
        XCTAssertEqual(control?.inverted, true)
        XCTAssertEqual(control?.normalizedValue(from: 10) ?? -1, 1.0, accuracy: 0.0001)
        XCTAssertEqual(control?.normalizedValue(from: 110) ?? -1, 0.0, accuracy: 0.0001)
    }

    func testCalibrationClampsOutOfRangeValues() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_calibration_clamp"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .leftUpfader)
        _ = engine.evaluateMIDILearnForCC(channel: 0, controller: 20, value: 50)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        engine.startCalibration(for: .leftUpfader)
        engine.evaluateCalibrationForCC(channel: 0, controller: 20, value: 20)
        engine.evaluateCalibrationForCC(channel: 0, controller: 20, value: 100)
        engine.finishCalibration()
        engine.testOnly_waitForMappingPersistenceQueue()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let control = engine.currentMIDIDeviceMapping?.control(for: .leftUpfader)
        XCTAssertEqual(control?.normalizedValue(from: 0) ?? -1, 0.0, accuracy: 0.0001, "A raw value below the calibrated minimum must clamp safely, not go negative")
        XCTAssertEqual(control?.normalizedValue(from: 127) ?? -1, 1.0, accuracy: 0.0001, "A raw value above the calibrated maximum must clamp safely, not exceed 1.0")
    }

    func testCalibrationIgnoresUnrelatedCC() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_calibration_unrelated_cc"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .crossfader)
        _ = engine.evaluateMIDILearnForCC(channel: 15, controller: 8, value: 50)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        engine.startCalibration(for: .crossfader)
        // A hot-cue pad CC on an entirely different channel/controller — must
        // never be accumulated into the crossfader's calibration.
        engine.evaluateCalibrationForCC(channel: 4, controller: 22, value: 127)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNil(engine.calibrationObservedMin, "An unrelated control must not be accumulated during calibration")
        XCTAssertNil(engine.calibrationObservedMax)
    }

    func testCalibrationIgnoresCC6PlatterFlood() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_calibration_cc6_flood"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .rightUpfader)
        _ = engine.evaluateMIDILearnForCC(channel: 1, controller: 21, value: 50)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        engine.startCalibration(for: .rightUpfader)
        // The right platter's CC6 flood arriving mid-calibration must never be
        // mistaken for the upfader's own binding.
        engine.evaluateCalibrationForCC(channel: 1, controller: 6, value: 5)
        engine.evaluateCalibrationForCC(channel: 1, controller: 6, value: 120)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNil(engine.calibrationObservedMin, "CC6 platter traffic must never be accumulated during calibration")
        XCTAssertNil(engine.calibrationObservedMax)
    }

    func testCalibrationPersistsAcrossRelaunch() {
        let deviceID = "midi_test_calibration_relaunch"
        cleanUpMIDIMapping(deviceIdentifier: deviceID)
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        let engine1 = MacCaptureEngine(autoRefreshDevices: false)
        engine1.selectedMIDIInputSourceID = deviceID
        engine1.startMIDILearn(for: .leftUpfader)
        _ = engine1.evaluateMIDILearnForCC(channel: 0, controller: 20, value: 50)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        engine1.startCalibration(for: .leftUpfader)
        engine1.evaluateCalibrationForCC(channel: 0, controller: 20, value: 15)
        engine1.evaluateCalibrationForCC(channel: 0, controller: 20, value: 105)
        engine1.finishCalibration()
        engine1.setInversion(true, for: .leftUpfader)
        engine1.testOnly_waitForMappingPersistenceQueue()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let engine2 = MacCaptureEngine(autoRefreshDevices: false)
        engine2.selectedMIDIInputSourceID = deviceID
        loadMappingAndWait(on: engine2)

        let control = engine2.currentMIDIDeviceMapping?.control(for: .leftUpfader)
        XCTAssertEqual(control?.minValue, 15)
        XCTAssertEqual(control?.maxValue, 105)
        XCTAssertEqual(control?.inverted, true)
    }

    func testCalibrationIsolatedBetweenDevices() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let raneID = "midi_test_calibration_iso_rane"
        let pioneerID = "midi_test_calibration_iso_pioneer"
        defer {
            cleanUpMIDIMapping(deviceIdentifier: raneID)
            cleanUpMIDIMapping(deviceIdentifier: pioneerID)
        }

        engine.selectedMIDIInputSourceID = raneID
        engine.startMIDILearn(for: .crossfader)
        _ = engine.evaluateMIDILearnForCC(channel: 15, controller: 8, value: 50)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        engine.startCalibration(for: .crossfader)
        engine.evaluateCalibrationForCC(channel: 15, controller: 8, value: 5)
        engine.evaluateCalibrationForCC(channel: 15, controller: 8, value: 120)
        engine.finishCalibration()
        engine.testOnly_waitForMappingPersistenceQueue()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(engine.currentMIDIDeviceMapping?.control(for: .crossfader)?.minValue, 5)

        engine.selectedMIDIInputSourceID = pioneerID
        engine.loadDeviceMappingForCurrentSource()
        engine.startMIDILearn(for: .crossfader)
        _ = engine.evaluateMIDILearnForCC(channel: 0, controller: 11, value: 50)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        // The Pioneer's freshly-learned crossfader must start at the
        // uncalibrated default, not inherit the Rane's calibrated range.
        let pioneerControl = engine.currentMIDIDeviceMapping?.control(for: .crossfader)
        XCTAssertEqual(pioneerControl?.minValue, 0)
        XCTAssertEqual(pioneerControl?.maxValue, 127)
    }

    func testStartMIDILearnCancelsActiveCalibration() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_calibration_learn_cancels"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .crossfader)
        _ = engine.evaluateMIDILearnForCC(channel: 15, controller: 8, value: 50)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        engine.startCalibration(for: .crossfader)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(engine.activeCalibrationAction, .crossfader)

        engine.startMIDILearn(for: .leftUpfader)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(engine.activeCalibrationAction, "Starting a new learn must abandon an in-progress calibration")
        XCTAssertEqual(engine.activeMIDILearnAction, .leftUpfader)
    }

    // MARK: - Off-main persistence ordering

    /// Two rapid, back-to-back writes to the same device's mapping must never
    /// let the earlier one clobber the later one — the persistence queue is
    /// serial, so each write's read-modify-write sees the result of the one
    /// before it, in the order they were requested.
    func testRapidSequentialMappingWritesPreserveNewestOnDisk() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_persistence_order"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        // Two rapid, sequential learns for the same action, with no wait in
        // between — the second must be the one left on disk and in memory.
        engine.startMIDILearn(for: .crossfader)
        _ = engine.evaluateMIDILearnForCC(channel: 15, controller: 8, value: 100)
        engine.startMIDILearn(for: .crossfader)
        _ = engine.evaluateMIDILearnForCC(channel: 0, controller: 20, value: 100)

        engine.testOnly_waitForMappingPersistenceQueue()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        let onDisk = MIDILearnedMappingStore.default.load(deviceIdentifier: deviceID)
        XCTAssertEqual(onDisk?.control(for: .crossfader)?.controlNumber, 20, "The later write must not be clobbered by the earlier, still-in-flight one")
        XCTAssertEqual(onDisk?.control(for: .crossfader)?.channel, 0)
        XCTAssertEqual(engine.currentMIDIDeviceMapping?.control(for: .crossfader)?.controlNumber, 20)
    }

    func testAssignSampleToHotCueRejectsUnknownSampleID() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_unknown_sample"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .hotCue7)
        engine.receiveNoteOnPadEvent(channel: 10, noteNumber: 60, velocity: 127)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        engine.assignSampleToHotCue("this_sample_does_not_exist", hotCueIndex: 7)
        XCTAssertNil(
            engine.currentMIDIDeviceMapping?.control(for: .hotCue7)?.assignedSampleID,
            "An unknown sample ID must fail visibly and safely, not silently assign"
        )
        XCTAssertFalse(engine.midiMappingError.isEmpty, "Rejecting an unknown sample must surface a visible error")
    }

    // MARK: - Learn panel: no stale value, wait for a fresh event

    /// Saves a one-control mapping for `deviceID` and observes the production
    /// load path through its main-queue publication boundary (mirrors the
    /// helper in `MIDIUserMixerGainTests`).
    private func installMapping(_ control: MIDILearnedControl, deviceID: String, on engine: MacCaptureEngine) {
        cleanUpMIDIMapping(deviceIdentifier: deviceID)
        var mapping = MIDIDeviceMapping(deviceIdentifier: deviceID, deviceName: "Test Device")
        mapping.upsert(control)
        MIDILearnedMappingStore.default.save(mapping)
        engine.selectedMIDIInputSourceID = deviceID
        loadMappingAndWait(on: engine)
    }

    func testLearnObservedValueIsNilUntilAFreshEventArrives() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_learn_observed_fresh"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .rightUpfader)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(
            engine.midiLearnObservedRawValue,
            "The Learn panel must show nothing until an event arrives after Learn begins"
        )

        _ = engine.evaluateMIDILearnForCC(channel: 1, controller: 28, value: 100)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(
            engine.midiLearnObservedRawValue, 100,
            "Once a real event lands it becomes the value the panel shows"
        )
    }

    func testLearnObservedValueResetsWhenANewSessionStarts() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_learn_observed_reset"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .crossfader)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        _ = engine.evaluateMIDILearnForCC(channel: 0, controller: 20, value: 55)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(engine.midiLearnObservedRawValue, 55)

        engine.startMIDILearn(for: .leftUpfader)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(
            engine.midiLearnObservedRawValue,
            "Starting a new Learn session must not carry the previous control's value across"
        )
    }

    func testLearnObservedValueIsClearedOnCancel() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_learn_observed_cancel"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .crossfader)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        _ = engine.evaluateMIDILearnForCC(channel: 0, controller: 20, value: 77)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(engine.midiLearnObservedRawValue, 77)

        engine.startMIDILearn(for: .rightUpfader)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        engine.cancelMIDILearn()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(engine.midiLearnObservedRawValue, "Cancelling Learn must clear the observed value")
    }

    func testHotCueNoteLearnSurfacesTheNoteNumberAsObservedValue() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_learn_observed_hotcue"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .hotCue1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        engine.receiveNoteOnPadEvent(channel: 5, noteNumber: 20, velocity: 127)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(engine.midiLearnObservedRawValue, 20, "A learned pad surfaces its note number to the panel")
        XCTAssertEqual(engine.currentMIDIDeviceMapping?.control(for: .hotCue1)?.controlNumber, 20)
    }

    // MARK: - Learn guard: a streaming other-control CC cannot claim the session

    func testLearnRightUpfaderIgnoresStreamingCrossfaderCCThenLearnsTheRealControl() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_learn_guard_stale_cc"
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        // Crossfader already learned at ch16 (raw 15) / CC8 — the real Rane
        // ONE MKII address, still streaming as the user starts a new Learn.
        installMapping(
            MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 15, controlNumber: 8),
            deviceID: deviceID,
            on: engine
        )

        engine.startMIDILearn(for: .rightUpfader)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let blocked = engine.evaluateMIDILearnForCC(channel: 15, controller: 8, value: 62)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(blocked.consumedByLearn, "The still-streaming crossfader CC must not claim the Right Upfader session")
        XCTAssertEqual(engine.activeMIDILearnAction, .rightUpfader, "The session must stay open for the real control")
        XCTAssertNil(engine.currentMIDIDeviceMapping?.control(for: .rightUpfader), "Nothing must be learned from the stale CC")
        XCTAssertNil(engine.midiLearnObservedRawValue, "The stale CC's value must not appear in the Learn panel")

        // Now the user actually moves the right upfader.
        let learned = engine.evaluateMIDILearnForCC(channel: 1, controller: 28, value: 90)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(learned.consumedByLearn, "A distinct event from the target control is accepted")
        XCTAssertEqual(engine.currentMIDIDeviceMapping?.control(for: .rightUpfader)?.channel, 1)
        XCTAssertEqual(engine.currentMIDIDeviceMapping?.control(for: .rightUpfader)?.controlNumber, 28)
        XCTAssertEqual(engine.midiLearnObservedRawValue, 90)
    }

    func testLearnGuardDoesNotBlockADistinctCCWhenNoCollision() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        let deviceID = "midi_test_learn_guard_no_collision"
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        installMapping(
            MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 15, controlNumber: 8),
            deviceID: deviceID,
            on: engine
        )

        engine.startMIDILearn(for: .leftUpfader)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let learned = engine.evaluateMIDILearnForCC(channel: 0, controller: 28, value: 40)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(learned.consumedByLearn, "A CC that collides with no other continuous control is learned normally")
        XCTAssertEqual(engine.currentMIDIDeviceMapping?.control(for: .leftUpfader)?.channel, 0)
        XCTAssertEqual(engine.currentMIDIDeviceMapping?.control(for: .leftUpfader)?.controlNumber, 28)
    }
}
