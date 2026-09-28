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

    private var defaultsSuiteName: String!
    private var midiDefaults: UserDefaults!
    private var mappingRoot: URL!
    private var mappingStore: MIDILearnedMappingStore!

    override func setUp() {
        super.setUp()
        mappingRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        mappingStore = MIDILearnedMappingStore(baseURL: mappingRoot)
        defaultsSuiteName = "com.machelpnz.scratchlab.tests.MIDILearnEngineTests.\(UUID().uuidString)"
        midiDefaults = UserDefaults(suiteName: defaultsSuiteName)
        midiDefaults.removePersistentDomain(forName: defaultsSuiteName)
        ScratchAudioOwnershipMode.scratchLabStandalone.persist(to: midiDefaults)
    }

    override func tearDown() {
        midiDefaults.removePersistentDomain(forName: defaultsSuiteName)
        midiDefaults = nil
        try? FileManager.default.removeItem(at: mappingRoot)
        mappingStore = nil
        mappingRoot = nil
        defaultsSuiteName = nil
        super.tearDown()
    }

    private func makeEngine() -> MacCaptureEngine {
        MacCaptureEngine(autoRefreshDevices: false, midiDefaults: midiDefaults, midiMappingStore: mappingStore)
    }

    /// Removes any on-disk mapping left behind by a test's device identifier.
    private func cleanUpMIDIMapping(deviceIdentifier: String) {
        self.mappingStore!.delete(deviceIdentifier: deviceIdentifier)
    }

    private func drainMIDIPublication(_ engine: MacCaptureEngine) {
        let done = expectation(description: "mapping persistence and publication completed")
        engine.testOnly_afterMappingPersistenceAndPublication { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    private func loadMappingAndWait(on engine: MacCaptureEngine) {
        engine.loadDeviceMappingForCurrentSource()
        drainMIDIPublication(engine)
    }

    func testSyntheticSelectionUsesIsolatedDefaults() {
        let key = "scratchlab.mac.selectedMIDIInputSourceID"
        XCTAssertNil(midiDefaults.string(forKey: key))

        let engine = makeEngine()
        engine.selectedMIDIInputSourceID = "midi_test_selection_isolation"

        XCTAssertEqual(
            midiDefaults.string(forKey: key),
            "midi_test_selection_isolation",
            "Hosted MIDI tests must persist synthetic selections only in their isolated suite"
        )
    }

    func testCC6PlatterFloodIgnoredDuringUpfaderLearn() {
        let engine = makeEngine()
        let deviceID = "midi_test_cc6_flood"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .leftUpfader)
        drainMIDIPublication(engine)

        let result = engine.evaluateMIDILearnForCC(channel: 0, controller: 6, value: 64)
        XCTAssertFalse(result.consumedByLearn, "CC6 must never be claimed by an active learn session")
        XCTAssertNil(result.crossfaderMapping, "CC6 must never resolve as the effective crossfader mapping")
        drainMIDIPublication(engine)

        XCTAssertNil(engine.currentMIDIDeviceMapping?.control(for: .leftUpfader), "The platter's CC6 flood must never be captured as a learned control")
        XCTAssertEqual(engine.activeMIDILearnAction, .leftUpfader, "Ignoring CC6 must leave the learn session active, waiting for a real control")
    }

    func testCC8AcceptedForCrossfaderLearn() {
        let engine = makeEngine()
        let deviceID = "midi_test_cc8_crossfader"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .crossfader)
        drainMIDIPublication(engine)

        // Verified Rane ONE MKII crossfader: CC8 on channel 15 (displayed as "Ch16").
        let result = engine.evaluateMIDILearnForCC(channel: 15, controller: 8, value: 127)
        XCTAssertTrue(result.consumedByLearn)
        XCTAssertEqual(result.crossfaderMapping, MacCaptureEngine.CrossfaderCCMapping(channel: 15, controller: 8))
        drainMIDIPublication(engine)

        XCTAssertEqual(engine.currentMIDIDeviceMapping?.control(for: .crossfader)?.controlNumber, 8)
        XCTAssertEqual(engine.currentMIDIDeviceMapping?.control(for: .crossfader)?.channel, 15)
        XCTAssertEqual(engine.crossfaderCCMapping, MacCaptureEngine.CrossfaderCCMapping(channel: 15, controller: 8))
    }

    func testCC8NotBlanketBannedForNonCrossfaderLearn() {
        let engine = makeEngine()
        let deviceID = "midi_test_cc8_upfader"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .leftUpfader)
        drainMIDIPublication(engine)

        _ = engine.evaluateMIDILearnForCC(channel: 0, controller: 8, value: 64)
        drainMIDIPublication(engine)

        XCTAssertEqual(
            engine.currentMIDIDeviceMapping?.control(for: .leftUpfader)?.controlNumber, 8,
            "CC8 filtering must be action-aware (only CC6 is banned), not a blanket controller-number ban"
        )
    }

    func testCrossfaderLearnStopsAfterFirstAcceptedEvent() {
        let engine = makeEngine()
        let deviceID = "midi_test_learn_stops"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .crossfader)
        drainMIDIPublication(engine)

        _ = engine.evaluateMIDILearnForCC(channel: 15, controller: 8, value: 100)
        drainMIDIPublication(engine)
        XCTAssertEqual(engine.crossfaderCCMapping, MacCaptureEngine.CrossfaderCCMapping(channel: 15, controller: 8))

        // Regression: a later, unrelated CC event must not silently re-learn and
        // overwrite the mapping — learning must end after the first accepted event.
        _ = engine.evaluateMIDILearnForCC(channel: 0, controller: 20, value: 50)
        drainMIDIPublication(engine)
        XCTAssertEqual(engine.crossfaderCCMapping, MacCaptureEngine.CrossfaderCCMapping(channel: 15, controller: 8))
    }

    func testLeftAndRightUpfaderLearnAssignCorrectDeck() {
        let engine = makeEngine()
        let deviceID = "midi_test_upfader_deck"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .leftUpfader)
        _ = engine.evaluateMIDILearnForCC(channel: 0, controller: 20, value: 100)
        drainMIDIPublication(engine)
        XCTAssertEqual(engine.currentMIDIDeviceMapping?.control(for: .leftUpfader)?.deck, 0)

        engine.startMIDILearn(for: .rightUpfader)
        _ = engine.evaluateMIDILearnForCC(channel: 1, controller: 21, value: 100)
        drainMIDIPublication(engine)
        XCTAssertEqual(engine.currentMIDIDeviceMapping?.control(for: .rightUpfader)?.deck, 1)
        XCTAssertNil(engine.currentMIDIDeviceMapping?.control(for: .crossfader)?.deck)
    }

    func testHotCueNoteOffDoesNotTriggerLoad() {
        let engine = makeEngine()
        let deviceID = "midi_test_hotcue_noteoff"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .hotCue1)
        engine.receiveNoteOnPadEvent(channel: 10, noteNumber: 40, velocity: 127)
        drainMIDIPublication(engine)
        engine.assignSampleToHotCue("ahhh", hotCueIndex: 1)
        engine.testOnly_waitForMappingPersistenceQueue()
        drainMIDIPublication(engine)

        // Note Off is velocity 0 — must never reload the sample.
        engine.receiveNoteOnPadEvent(channel: 10, noteNumber: 40, velocity: 0)
        engine.testOnly_waitForPlaybackQueue()
        XCTAssertNil(engine.testOnly_scratchPlaybackDiagnosticsSnapshot().loadedSampleID)
    }

    func testHotCueCCReleaseDoesNotTriggerLoad() {
        let engine = makeEngine()
        let deviceID = "midi_test_hotcue_ccrelease"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .hotCue2)
        _ = engine.evaluateMIDILearnForCC(channel: 4, controller: 30, value: 127)
        drainMIDIPublication(engine)
        engine.assignSampleToHotCue("fresh", hotCueIndex: 2)
        engine.testOnly_waitForMappingPersistenceQueue()
        drainMIDIPublication(engine)

        // CC release (value 0) must never (re)load the sample.
        engine.recordReceivedMIDICCEvent(sourceName: "Test", channel: 4, controller: 30, value: 0)
        engine.testOnly_waitForPlaybackQueue()
        XCTAssertNil(engine.testOnly_scratchPlaybackDiagnosticsSnapshot().loadedSampleID)
    }

    func testHotCuePressLoadsAssignedSample() {
        let engine = makeEngine()
        let deviceID = "midi_test_hotcue_press"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .hotCue3)
        engine.receiveNoteOnPadEvent(channel: 10, noteNumber: 41, velocity: 127)
        drainMIDIPublication(engine)
        engine.assignSampleToHotCue("ah_yeah", hotCueIndex: 3)
        engine.testOnly_waitForMappingPersistenceQueue()
        drainMIDIPublication(engine)

        engine.receiveNoteOnPadEvent(channel: 10, noteNumber: 41, velocity: 127)
        engine.testOnly_waitForPlaybackQueue()
        XCTAssertEqual(engine.testOnly_scratchPlaybackDiagnosticsSnapshot().loadedSampleID, "ah_yeah")
    }

    /// ch6/note20 is the TEMP diagnostic ahhh fallback's trigger and has no entry
    /// in `ScratchBankPadEventRouter`'s note table, so only the `productionMatched`
    /// guard can suppress it — this is the one case that actually exercises "a
    /// learned hot cue must not double-fire alongside the temp fallback."
    func testLearnedHotCueSuppressesTempAhhhFallbackOnSameEvent() {
        let engine = makeEngine()
        let deviceID = "midi_test_hotcue_no_double_fire"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        func waitForMappingPublication(_ stage: String) -> Bool {
            engine.testOnly_waitForMappingPersistenceQueue()
            let published = expectation(description: stage)
            DispatchQueue.main.async { published.fulfill() }
            return XCTWaiter.wait(for: [published], timeout: 2) == .completed
        }

        engine.startMIDILearn(for: .hotCue4)
        engine.receiveNoteOnPadEvent(channel: 6, noteNumber: 20, velocity: 127)
        guard waitForMappingPublication("Hot Cue 4 learning published") else {
            return XCTFail("Hot Cue 4 learning did not finish publishing before assignment")
        }
        guard let learnedMapping = engine.currentMIDIDeviceMapping,
              learnedMapping.deviceIdentifier == deviceID,
              let learned = learnedMapping.control(for: .hotCue4),
              learned.messageType == .note,
              learned.channel == 6,
              learned.controlNumber == 20 else {
            return XCTFail("Expected the learned Hot Cue 4 note on device \(deviceID), channel 6, note 20 before assignment")
        }
        engine.assignSampleToHotCue("check_it_out", hotCueIndex: 4)
        guard waitForMappingPublication("Hot Cue 4 sample assignment published") else {
            return XCTFail("Hot Cue 4 sample assignment did not finish publishing before the press")
        }
        guard let assignedMapping = engine.currentMIDIDeviceMapping,
              assignedMapping.deviceIdentifier == deviceID,
              let assigned = assignedMapping.control(for: .hotCue4),
              assigned.messageType == .note,
              assigned.channel == 6,
              assigned.controlNumber == 20,
              assigned.assignedSampleID == "check_it_out" else {
            return XCTFail("Expected check_it_out assigned to the learned Hot Cue 4 note before the press")
        }

        engine.receiveNoteOnPadEvent(channel: 6, noteNumber: 20, velocity: 127)
        engine.testOnly_waitForPlaybackQueue()
        XCTAssertEqual(
            engine.testOnly_scratchPlaybackDiagnosticsSnapshot().loadedSampleID,
            "check_it_out",
            "A learned production hot-cue mapping must win over the temp ch6/note20 ahhh fallback, not double-fire both"
        )
    }

    func testLearningHotCueDoesNotFireItsOwnActionOnTheLearnEvent() {
        let engine = makeEngine()
        let deviceID = "midi_test_hotcue_no_fire_on_learn"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        // Pre-existing mapping + assignment for hot cue 5 on note 50.
        engine.startMIDILearn(for: .hotCue5)
        engine.receiveNoteOnPadEvent(channel: 10, noteNumber: 50, velocity: 127)
        drainMIDIPublication(engine)
        engine.assignSampleToHotCue("ahhh", hotCueIndex: 5)
        engine.testOnly_waitForMappingPersistenceQueue()
        drainMIDIPublication(engine)

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
        let engine = makeEngine()
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
        drainMIDIPublication(engine)
        XCTAssertEqual(engine.currentMIDIDeviceMapping?.control(for: .crossfader)?.controlNumber, 8)

        engine.selectedMIDIInputSourceID = pioneerID
        loadMappingAndWait(on: engine)
        XCTAssertNil(engine.currentMIDIDeviceMapping, "A device with no saved mapping must not inherit another device's mapping")

        engine.startMIDILearn(for: .crossfader)
        _ = engine.evaluateMIDILearnForCC(channel: 0, controller: 11, value: 100)
        drainMIDIPublication(engine)
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

        let engine1 = makeEngine()
        engine1.selectedMIDIInputSourceID = deviceID
        engine1.startMIDILearn(for: .rightUpfader)
        _ = engine1.evaluateMIDILearnForCC(channel: 1, controller: 21, value: 100)
        engine1.testOnly_waitForMappingPersistenceQueue()
        drainMIDIPublication(engine1)
        XCTAssertNotNil(engine1.currentMIDIDeviceMapping?.control(for: .rightUpfader))

        // A fresh engine instance (simulating relaunch) loading the same persisted
        // device identifier must recover the same mapping.
        let engine2 = makeEngine()
        engine2.selectedMIDIInputSourceID = deviceID
        loadMappingAndWait(on: engine2)
        XCTAssertEqual(engine2.currentMIDIDeviceMapping?.control(for: .rightUpfader)?.controlNumber, 21)
    }

    // MARK: - Continuous control calibration

    func testCalibrationFullZeroTo127RangeAccepted() {
        let engine = makeEngine()
        let deviceID = "midi_test_calibration_full_range"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .crossfader)
        _ = engine.evaluateMIDILearnForCC(channel: 15, controller: 8, value: 64)
        drainMIDIPublication(engine)

        engine.startCalibration(for: .crossfader)
        engine.evaluateCalibrationForCC(channel: 15, controller: 8, value: 0)
        engine.evaluateCalibrationForCC(channel: 15, controller: 8, value: 64)
        engine.evaluateCalibrationForCC(channel: 15, controller: 8, value: 127)
        engine.finishCalibration()
        engine.testOnly_waitForMappingPersistenceQueue()
        drainMIDIPublication(engine)

        let control = engine.currentMIDIDeviceMapping?.control(for: .crossfader)
        XCTAssertEqual(control?.minValue, 0)
        XCTAssertEqual(control?.maxValue, 127)
        XCTAssertTrue(engine.calibrationError.isEmpty)
        XCTAssertNil(engine.activeCalibrationAction)
    }

    func testCalibrationRestrictedRangeAccepted() {
        let engine = makeEngine()
        let deviceID = "midi_test_calibration_restricted_range"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .leftUpfader)
        _ = engine.evaluateMIDILearnForCC(channel: 0, controller: 20, value: 50)
        drainMIDIPublication(engine)

        // A real fader that doesn't quite reach 0/127 at its physical stops —
        // a restricted but perfectly usable range.
        engine.startCalibration(for: .leftUpfader)
        engine.evaluateCalibrationForCC(channel: 0, controller: 20, value: 20)
        engine.evaluateCalibrationForCC(channel: 0, controller: 20, value: 100)
        engine.finishCalibration()
        engine.testOnly_waitForMappingPersistenceQueue()
        drainMIDIPublication(engine)

        let control = engine.currentMIDIDeviceMapping?.control(for: .leftUpfader)
        XCTAssertEqual(control?.minValue, 20)
        XCTAssertEqual(control?.maxValue, 100)
    }

    func testCalibrationInsufficientRangeRejectedAndNotPersisted() {
        let engine = makeEngine()
        let deviceID = "midi_test_calibration_narrow_range"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .rightUpfader)
        _ = engine.evaluateMIDILearnForCC(channel: 1, controller: 21, value: 50)
        drainMIDIPublication(engine)

        // Jittery/near-stationary movement — far too narrow to calibrate from.
        engine.startCalibration(for: .rightUpfader)
        engine.evaluateCalibrationForCC(channel: 1, controller: 21, value: 60)
        engine.evaluateCalibrationForCC(channel: 1, controller: 21, value: 65)
        engine.finishCalibration()
        engine.testOnly_waitForMappingPersistenceQueue()
        drainMIDIPublication(engine)

        XCTAssertFalse(engine.calibrationError.isEmpty, "A too-narrow range must surface a visible rejection error")
        let control = engine.currentMIDIDeviceMapping?.control(for: .rightUpfader)
        XCTAssertEqual(control?.minValue, 0, "Rejected calibration must not overwrite the default/previous range")
        XCTAssertEqual(control?.maxValue, 127)
    }

    func testCalibrationNoMovementRejected() {
        let engine = makeEngine()
        let deviceID = "midi_test_calibration_no_movement"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .crossfader)
        _ = engine.evaluateMIDILearnForCC(channel: 15, controller: 8, value: 50)
        drainMIDIPublication(engine)

        engine.startCalibration(for: .crossfader)
        // No events fed at all — Karl clicked Finish without moving the control.
        engine.finishCalibration()
        drainMIDIPublication(engine)

        XCTAssertFalse(engine.calibrationError.isEmpty)
        XCTAssertEqual(engine.currentMIDIDeviceMapping?.control(for: .crossfader)?.minValue, 0)
        XCTAssertEqual(engine.currentMIDIDeviceMapping?.control(for: .crossfader)?.maxValue, 127)
    }

    func testCalibrationNormalizationNormalAndInverted() {
        let engine = makeEngine()
        let deviceID = "midi_test_calibration_normalize"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .crossfader)
        _ = engine.evaluateMIDILearnForCC(channel: 15, controller: 8, value: 50)
        drainMIDIPublication(engine)

        engine.startCalibration(for: .crossfader)
        engine.evaluateCalibrationForCC(channel: 15, controller: 8, value: 10)
        engine.evaluateCalibrationForCC(channel: 15, controller: 8, value: 110)
        engine.finishCalibration()
        engine.testOnly_waitForMappingPersistenceQueue()
        drainMIDIPublication(engine)

        var control = engine.currentMIDIDeviceMapping?.control(for: .crossfader)
        XCTAssertEqual(control?.normalizedValue(from: 10) ?? -1, 0.0, accuracy: 0.0001)
        XCTAssertEqual(control?.normalizedValue(from: 110) ?? -1, 1.0, accuracy: 0.0001)
        XCTAssertEqual(control?.normalizedValue(from: 60) ?? -1, 0.5, accuracy: 0.01)

        engine.setInversion(true, for: .crossfader)
        engine.testOnly_waitForMappingPersistenceQueue()
        drainMIDIPublication(engine)

        control = engine.currentMIDIDeviceMapping?.control(for: .crossfader)
        XCTAssertEqual(control?.inverted, true)
        XCTAssertEqual(control?.normalizedValue(from: 10) ?? -1, 1.0, accuracy: 0.0001)
        XCTAssertEqual(control?.normalizedValue(from: 110) ?? -1, 0.0, accuracy: 0.0001)
    }

    func testCalibrationClampsOutOfRangeValues() {
        let engine = makeEngine()
        let deviceID = "midi_test_calibration_clamp"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .leftUpfader)
        _ = engine.evaluateMIDILearnForCC(channel: 0, controller: 20, value: 50)
        drainMIDIPublication(engine)

        engine.startCalibration(for: .leftUpfader)
        engine.evaluateCalibrationForCC(channel: 0, controller: 20, value: 20)
        engine.evaluateCalibrationForCC(channel: 0, controller: 20, value: 100)
        engine.finishCalibration()
        engine.testOnly_waitForMappingPersistenceQueue()
        drainMIDIPublication(engine)

        let control = engine.currentMIDIDeviceMapping?.control(for: .leftUpfader)
        XCTAssertEqual(control?.normalizedValue(from: 0) ?? -1, 0.0, accuracy: 0.0001, "A raw value below the calibrated minimum must clamp safely, not go negative")
        XCTAssertEqual(control?.normalizedValue(from: 127) ?? -1, 1.0, accuracy: 0.0001, "A raw value above the calibrated maximum must clamp safely, not exceed 1.0")
    }

    func testCalibrationIgnoresUnrelatedCC() {
        let engine = makeEngine()
        let deviceID = "midi_test_calibration_unrelated_cc"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .crossfader)
        _ = engine.evaluateMIDILearnForCC(channel: 15, controller: 8, value: 50)
        drainMIDIPublication(engine)

        engine.startCalibration(for: .crossfader)
        // A hot-cue pad CC on an entirely different channel/controller — must
        // never be accumulated into the crossfader's calibration.
        engine.evaluateCalibrationForCC(channel: 4, controller: 22, value: 127)
        drainMIDIPublication(engine)

        XCTAssertNil(engine.calibrationObservedMin, "An unrelated control must not be accumulated during calibration")
        XCTAssertNil(engine.calibrationObservedMax)
    }

    func testCalibrationIgnoresCC6PlatterFlood() {
        let engine = makeEngine()
        let deviceID = "midi_test_calibration_cc6_flood"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .rightUpfader)
        _ = engine.evaluateMIDILearnForCC(channel: 1, controller: 21, value: 50)
        drainMIDIPublication(engine)

        engine.startCalibration(for: .rightUpfader)
        // The right platter's CC6 flood arriving mid-calibration must never be
        // mistaken for the upfader's own binding.
        engine.evaluateCalibrationForCC(channel: 1, controller: 6, value: 5)
        engine.evaluateCalibrationForCC(channel: 1, controller: 6, value: 120)
        drainMIDIPublication(engine)

        XCTAssertNil(engine.calibrationObservedMin, "CC6 platter traffic must never be accumulated during calibration")
        XCTAssertNil(engine.calibrationObservedMax)
    }

    func testCalibrationPersistsAcrossRelaunch() {
        let deviceID = "midi_test_calibration_relaunch"
        cleanUpMIDIMapping(deviceIdentifier: deviceID)
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        let engine1 = makeEngine()
        engine1.selectedMIDIInputSourceID = deviceID
        engine1.startMIDILearn(for: .leftUpfader)
        _ = engine1.evaluateMIDILearnForCC(channel: 0, controller: 20, value: 50)
        drainMIDIPublication(engine1)
        engine1.startCalibration(for: .leftUpfader)
        engine1.evaluateCalibrationForCC(channel: 0, controller: 20, value: 15)
        engine1.evaluateCalibrationForCC(channel: 0, controller: 20, value: 105)
        engine1.finishCalibration()
        engine1.setInversion(true, for: .leftUpfader)
        engine1.testOnly_waitForMappingPersistenceQueue()
        drainMIDIPublication(engine1)

        let engine2 = makeEngine()
        engine2.selectedMIDIInputSourceID = deviceID
        loadMappingAndWait(on: engine2)

        let control = engine2.currentMIDIDeviceMapping?.control(for: .leftUpfader)
        XCTAssertEqual(control?.minValue, 15)
        XCTAssertEqual(control?.maxValue, 105)
        XCTAssertEqual(control?.inverted, true)
    }

    func testCalibrationIsolatedBetweenDevices() {
        let engine = makeEngine()
        let raneID = "midi_test_calibration_iso_rane"
        let pioneerID = "midi_test_calibration_iso_pioneer"
        defer {
            cleanUpMIDIMapping(deviceIdentifier: raneID)
            cleanUpMIDIMapping(deviceIdentifier: pioneerID)
        }

        engine.selectedMIDIInputSourceID = raneID
        engine.startMIDILearn(for: .crossfader)
        _ = engine.evaluateMIDILearnForCC(channel: 15, controller: 8, value: 50)
        drainMIDIPublication(engine)
        engine.startCalibration(for: .crossfader)
        engine.evaluateCalibrationForCC(channel: 15, controller: 8, value: 5)
        engine.evaluateCalibrationForCC(channel: 15, controller: 8, value: 120)
        engine.finishCalibration()
        engine.testOnly_waitForMappingPersistenceQueue()
        drainMIDIPublication(engine)
        XCTAssertEqual(engine.currentMIDIDeviceMapping?.control(for: .crossfader)?.minValue, 5)

        engine.selectedMIDIInputSourceID = pioneerID
        engine.loadDeviceMappingForCurrentSource()
        engine.startMIDILearn(for: .crossfader)
        _ = engine.evaluateMIDILearnForCC(channel: 0, controller: 11, value: 50)
        drainMIDIPublication(engine)

        // The Pioneer's freshly-learned crossfader must start at the
        // uncalibrated default, not inherit the Rane's calibrated range.
        let pioneerControl = engine.currentMIDIDeviceMapping?.control(for: .crossfader)
        XCTAssertEqual(pioneerControl?.minValue, 0)
        XCTAssertEqual(pioneerControl?.maxValue, 127)
    }

    func testStartMIDILearnCancelsActiveCalibration() {
        let engine = makeEngine()
        let deviceID = "midi_test_calibration_learn_cancels"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .crossfader)
        _ = engine.evaluateMIDILearnForCC(channel: 15, controller: 8, value: 50)
        drainMIDIPublication(engine)
        engine.startCalibration(for: .crossfader)
        drainMIDIPublication(engine)
        XCTAssertEqual(engine.activeCalibrationAction, .crossfader)

        engine.startMIDILearn(for: .leftUpfader)
        drainMIDIPublication(engine)
        XCTAssertNil(engine.activeCalibrationAction, "Starting a new learn must abandon an in-progress calibration")
        XCTAssertEqual(engine.activeMIDILearnAction, .leftUpfader)
    }

    // MARK: - Off-main persistence ordering

    /// Two rapid, back-to-back writes to the same device's mapping must never
    /// let the earlier one clobber the later one — the persistence queue is
    /// serial, so each write's read-modify-write sees the result of the one
    /// before it, in the order they were requested.
    func testRapidSequentialMappingWritesPreserveNewestOnDisk() {
        let engine = makeEngine()
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
        drainMIDIPublication(engine)

        let onDisk = self.mappingStore!.load(deviceIdentifier: deviceID)
        XCTAssertEqual(onDisk?.control(for: .crossfader)?.controlNumber, 20, "The later write must not be clobbered by the earlier, still-in-flight one")
        XCTAssertEqual(onDisk?.control(for: .crossfader)?.channel, 0)
        XCTAssertEqual(engine.currentMIDIDeviceMapping?.control(for: .crossfader)?.controlNumber, 20)
    }

    func testAssignSampleToHotCueRejectsUnknownSampleID() {
        let engine = makeEngine()
        let deviceID = "midi_test_unknown_sample"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .hotCue7)
        engine.receiveNoteOnPadEvent(channel: 10, noteNumber: 60, velocity: 127)
        drainMIDIPublication(engine)

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
        self.mappingStore!.save(mapping)
        engine.selectedMIDIInputSourceID = deviceID
        loadMappingAndWait(on: engine)
    }

    func testLearnObservedValueIsNilUntilAFreshEventArrives() {
        let engine = makeEngine()
        let deviceID = "midi_test_learn_observed_fresh"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .rightUpfader)
        drainMIDIPublication(engine)
        XCTAssertNil(
            engine.midiLearnObservedRawValue,
            "The Learn panel must show nothing until an event arrives after Learn begins"
        )

        _ = engine.evaluateMIDILearnForCC(channel: 1, controller: 28, value: 100)
        drainMIDIPublication(engine)
        XCTAssertEqual(
            engine.midiLearnObservedRawValue, 100,
            "Once a real event lands it becomes the value the panel shows"
        )
    }

    func testLearnObservedValueResetsWhenANewSessionStarts() {
        let engine = makeEngine()
        let deviceID = "midi_test_learn_observed_reset"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .crossfader)
        drainMIDIPublication(engine)
        _ = engine.evaluateMIDILearnForCC(channel: 0, controller: 20, value: 55)
        drainMIDIPublication(engine)
        XCTAssertEqual(engine.midiLearnObservedRawValue, 55)

        engine.startMIDILearn(for: .leftUpfader)
        drainMIDIPublication(engine)
        XCTAssertNil(
            engine.midiLearnObservedRawValue,
            "Starting a new Learn session must not carry the previous control's value across"
        )
    }

    func testLearnObservedValueIsClearedOnCancel() {
        let engine = makeEngine()
        let deviceID = "midi_test_learn_observed_cancel"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .crossfader)
        drainMIDIPublication(engine)
        _ = engine.evaluateMIDILearnForCC(channel: 0, controller: 20, value: 77)
        drainMIDIPublication(engine)
        XCTAssertEqual(engine.midiLearnObservedRawValue, 77)

        engine.startMIDILearn(for: .rightUpfader)
        drainMIDIPublication(engine)
        engine.cancelMIDILearn()
        drainMIDIPublication(engine)
        XCTAssertNil(engine.midiLearnObservedRawValue, "Cancelling Learn must clear the observed value")
    }

    func testHotCueNoteLearnSurfacesTheNoteNumberAsObservedValue() {
        let engine = makeEngine()
        let deviceID = "midi_test_learn_observed_hotcue"
        engine.selectedMIDIInputSourceID = deviceID
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        engine.startMIDILearn(for: .hotCue1)
        drainMIDIPublication(engine)
        engine.receiveNoteOnPadEvent(channel: 5, noteNumber: 20, velocity: 127)
        drainMIDIPublication(engine)

        XCTAssertEqual(engine.midiLearnObservedRawValue, 20, "A learned pad surfaces its note number to the panel")
        XCTAssertEqual(engine.currentMIDIDeviceMapping?.control(for: .hotCue1)?.controlNumber, 20)
    }

    // MARK: - Learn guard: a streaming other-control CC cannot claim the session

    func testLearnRightUpfaderIgnoresStreamingCrossfaderCCThenLearnsTheRealControl() {
        let engine = makeEngine()
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
        drainMIDIPublication(engine)

        let blocked = engine.evaluateMIDILearnForCC(channel: 15, controller: 8, value: 62)
        drainMIDIPublication(engine)
        XCTAssertFalse(blocked.consumedByLearn, "The still-streaming crossfader CC must not claim the Right Upfader session")
        XCTAssertEqual(engine.activeMIDILearnAction, .rightUpfader, "The session must stay open for the real control")
        XCTAssertNil(engine.currentMIDIDeviceMapping?.control(for: .rightUpfader), "Nothing must be learned from the stale CC")
        XCTAssertNil(engine.midiLearnObservedRawValue, "The stale CC's value must not appear in the Learn panel")

        // Now the user actually moves the right upfader.
        let learned = engine.evaluateMIDILearnForCC(channel: 1, controller: 28, value: 90)
        drainMIDIPublication(engine)
        XCTAssertTrue(learned.consumedByLearn, "A distinct event from the target control is accepted")
        XCTAssertEqual(engine.currentMIDIDeviceMapping?.control(for: .rightUpfader)?.channel, 1)
        XCTAssertEqual(engine.currentMIDIDeviceMapping?.control(for: .rightUpfader)?.controlNumber, 28)
        XCTAssertEqual(engine.midiLearnObservedRawValue, 90)
    }

    func testLearnGuardDoesNotBlockADistinctCCWhenNoCollision() {
        let engine = makeEngine()
        let deviceID = "midi_test_learn_guard_no_collision"
        defer { cleanUpMIDIMapping(deviceIdentifier: deviceID) }

        installMapping(
            MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 15, controlNumber: 8),
            deviceID: deviceID,
            on: engine
        )

        engine.startMIDILearn(for: .leftUpfader)
        drainMIDIPublication(engine)

        let learned = engine.evaluateMIDILearnForCC(channel: 0, controller: 28, value: 40)
        drainMIDIPublication(engine)
        XCTAssertTrue(learned.consumedByLearn, "A CC that collides with no other continuous control is learned normally")
        XCTAssertEqual(engine.currentMIDIDeviceMapping?.control(for: .leftUpfader)?.channel, 0)
        XCTAssertEqual(engine.currentMIDIDeviceMapping?.control(for: .leftUpfader)?.controlNumber, 28)
    }

    /// C6 permanent ownership regression. The existing persistence barrier completes disk
    /// work while this synchronous MainActor segment holds main publication.
    /// A FIFO main-queue marker releases already-enqueued completions; no timing
    /// wait, new production seam, or synthetic runtime mapping is used.
    @MainActor
    func testC6ControlledMappingPublicationOwnership() async throws {
        for scenario in ["A-B", "A-B-A", "same-generation", "cancel-before-event",
                         "cancel-after-claim", "rejected-CC6"] {
            let prefix = "midi_c6_\(UUID().uuidString)"
            let suiteName = "com.machelpnz.scratchlab.tests.C6.\(prefix)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            ScratchAudioOwnershipMode.scratchLabStandalone.persist(to: defaults)
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let engine = MacCaptureEngine(autoRefreshDevices: false, midiDefaults: defaults, midiMappingStore: mappingStore)
            let sourceA = prefix + "_A"
            let sourceB = prefix + "_B"
            defer {
                cleanUpMIDIMapping(deviceIdentifier: sourceA)
                cleanUpMIDIMapping(deviceIdentifier: sourceB)
            }
            let trace = { (phase: String) in
                let control = engine.currentMIDIDeviceMapping?.control(for: .crossfader)
                let persistedA = self.mappingStore!.load(deviceIdentifier: sourceA)
                let persistedB = self.mappingStore!.load(deviceIdentifier: sourceB)
                let fields: [String: String] = [
                    "scenario": scenario, "phase": phase,
                    "sourceA": sourceA, "sourceB": sourceB,
                    "selected": engine.selectedMIDIInputSourceID,
                    "runtimeOwner": engine.currentMIDIDeviceMapping?.deviceIdentifier ?? "nil",
                    "persistedA": persistedA?.deviceIdentifier ?? "nil",
                    "persistedB": persistedB?.deviceIdentifier ?? "nil",
                    "control": control.map { "\($0.channel):\($0.controlNumber)" } ?? "nil",
                    "range": control.map { "\($0.minValue)...\($0.maxValue)" } ?? "nil",
                    "legacyMapping": String(describing: engine.crossfaderCCMapping),
                    "learnState": String(describing: engine.midiLearnState),
                    "activeLearn": String(describing: engine.activeMIDILearnAction),
                    "calibrationEligible": String(control != nil),
                    "activeCalibration": String(describing: engine.activeCalibrationAction),
                    "calibrationError": engine.calibrationError,
                    "mappingError": engine.midiMappingError
                ]
                let bytes = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
                print("C6_TRACE " + String(decoding: bytes, as: UTF8.self))
            }

            engine.selectedMIDIInputSourceID = sourceA
            engine.loadDeviceMappingForCurrentSource()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertNil(engine.currentMIDIDeviceMapping)
            engine.startMIDILearn(for: .crossfader)
            if scenario == "cancel-before-event" { engine.cancelMIDILearn() }
            let result = engine.evaluateMIDILearnForCC(
                channel: 15, controller: scenario == "rejected-CC6" ? 6 : 8, value: 100
            )
            let accepted = scenario != "cancel-before-event" && scenario != "rejected-CC6"
            XCTAssertEqual(result.consumedByLearn, accepted)

            // The barrier waits for disk work only. Main cannot run a queued
            // completion until this uninterrupted synchronous segment yields.
            engine.testOnly_waitForMappingPersistenceQueue()
            XCTAssertNil(engine.currentMIDIDeviceMapping, "Publication must still be held")
            let persisted = self.mappingStore!.load(deviceIdentifier: sourceA)
            XCTAssertEqual(persisted?.deviceIdentifier, accepted ? sourceA : nil)
            XCTAssertNil(self.mappingStore!.load(deviceIdentifier: sourceB))
            trace("persisted-publication-held")

            if scenario == "A-B" || scenario == "A-B-A" {
                engine.selectedMIDIInputSourceID = sourceB
                if scenario == "A-B-A" { engine.selectedMIDIInputSourceID = sourceA }
            }
            if scenario == "cancel-after-claim" { engine.cancelMIDILearn() }
            trace("selection-changed-before-release")
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
            trace("after-publication")

            let staleSelection = scenario == "A-B" || scenario == "A-B-A"
            if staleSelection {
                XCTAssertNil(engine.currentMIDIDeviceMapping,
                    "\(scenario): obsolete selection completion must not publish a runtime mapping")
                XCTAssertNil(engine.crossfaderCCMapping,
                    "\(scenario): obsolete selection completion must not publish the legacy mirror")
                XCTAssertEqual(engine.midiLearnState, .idle)
                XCTAssertEqual(engine.midiLearnFeedback, "")
                XCTAssertNil(engine.activeMIDILearnAction)
                XCTAssertNil(engine.midiLearnObservedRawValue)
                XCTAssertTrue(engine.midiMappingError.isEmpty)
                XCTAssertEqual(self.mappingStore!.load(deviceIdentifier: sourceA)?.deviceIdentifier, sourceA)
                XCTAssertNil(self.mappingStore!.load(deviceIdentifier: sourceB))
            } else if accepted {
                // Cancellation after the atomic claim does not revoke a learn
                // that already succeeded under the current architecture.
                XCTAssertEqual(engine.currentMIDIDeviceMapping?.deviceIdentifier, sourceA)
                XCTAssertEqual(engine.currentMIDIDeviceMapping?.control(for: .crossfader)?.controlNumber, 8)
            } else {
                XCTAssertNil(engine.currentMIDIDeviceMapping)
                XCTAssertNil(engine.crossfaderCCMapping)
            }

            // Expose whether the resulting mapping can authorize calibration.
            // A rejected CC6 leaves Learn active, so cancel that pending session
            // explicitly before testing calibration's learned-control precheck.
            if scenario == "rejected-CC6" { engine.cancelMIDILearn() }
            engine.startCalibration(for: .crossfader)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
            trace("calibration-probe")
            if staleSelection || !accepted {
                XCTAssertNil(engine.activeCalibrationAction,
                    "\(scenario): an absent or obsolete learned mapping must not enable calibration")
            } else {
                XCTAssertEqual(engine.activeCalibrationAction, .crossfader)
                XCTAssertTrue(engine.calibrationError.isEmpty)
            }
            engine.cancelCalibration()
            engine.cancelMIDILearn()
            engine.testOnly_waitForMappingPersistenceQueue()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    @MainActor
    private func drainC6Publications(_ engine: MacCaptureEngine) async {
        engine.testOnly_waitForMappingPersistenceQueue()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor
    func testC6StaleResultsCannotOverwritePublishedSuccessor() async throws {
        for operation in ["learn", "load-positive", "load-nil", "load-error", "clear-action",
                          "clear-device", "calibration-error", "verified-error", "learn-status",
                          "cancel-status", "calibration-finish", "preset", "reset", "inversion",
                          "hot-cue", "custom-curve"] {
            let engine = makeEngine()
            let sourceA = "midi_c6_A_\(UUID().uuidString)"
            let sourceB = "midi_c6_B_\(UUID().uuidString)"
            defer {
                cleanUpMIDIMapping(deviceIdentifier: sourceA)
                cleanUpMIDIMapping(deviceIdentifier: sourceB)
            }
            var mappingA = MIDIDeviceMapping(deviceIdentifier: sourceA, deviceName: "A")
            mappingA.upsert(MIDILearnedControl(action: .crossfader, messageType: .controlChange,
                channel: 15, controlNumber: 8,
                curveConfig: operation == "reset" ? MIDIFaderCurveConfig(preset: .smooth) : nil))
            if operation != "clear-action" {
                mappingA.upsert(MIDILearnedControl(action: .hotCue1, messageType: .note,
                    channel: 5, controlNumber: 20))
            }
            var mappingB = MIDIDeviceMapping(deviceIdentifier: sourceB, deviceName: "B")
            mappingB.upsert(MIDILearnedControl(action: .crossfader, messageType: .controlChange,
                channel: 3, controlNumber: 11))
            self.mappingStore!.save(mappingA)
            self.mappingStore!.save(mappingB)
            engine.selectedMIDIInputSourceID = sourceA
            engine.loadDeviceMappingForCurrentSource()
            await drainC6Publications(engine)
            XCTAssertEqual(engine.currentMIDIDeviceMapping?.deviceIdentifier, sourceA)

            var deferred: [() -> Void] = []
            engine.testOnly_deferSelectedMIDIPublication = { deferred.append($0) }
            switch operation {
            case "learn":
                engine.startMIDILearn(for: .crossfader)
                XCTAssertTrue(engine.evaluateMIDILearnForCC(channel: 15, controller: 9, value: 100).consumedByLearn)
            case "load-positive": engine.loadDeviceMappingForCurrentSource()
            case "load-nil":
                self.mappingStore!.delete(deviceIdentifier: sourceA)
                engine.loadDeviceMappingForCurrentSource()
            case "load-error":
                let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("ScratchLab/MIDIMappings/\(sourceA).json")
                try Data("not valid JSON".utf8).write(to: url)
                engine.loadDeviceMappingForCurrentSource()
            case "clear-action": engine.clearMapping(for: .crossfader)
            case "clear-device": engine.clearDeviceMappings()
            case "calibration-error": engine.startCalibration(for: .leftUpfader)
            case "verified-error": engine.applyVerifiedRaneOneMKIIMapping()
            case "learn-status": engine.startMIDILearn(for: .rightUpfader)
            case "cancel-status":
                engine.startMIDILearn(for: .crossfader)
                engine.cancelMIDILearn()
            case "calibration-finish":
                engine.startCalibration(for: .crossfader)
                engine.evaluateCalibrationForCC(channel: 15, controller: 8, value: 10)
                engine.evaluateCalibrationForCC(channel: 15, controller: 8, value: 110)
                engine.finishCalibration()
            case "preset": engine.setCurvePreset(.smooth, for: .crossfader)
            case "reset": engine.resetCurve(for: .crossfader)
            case "inversion": engine.setInversion(true, for: .crossfader)
            case "hot-cue": engine.assignSampleToHotCue("dvs_ahhh", hotCueIndex: 1)
            case "custom-curve":
                engine.startCurveCalibration(for: .crossfader)
                engine.evaluateCurveCaptureForCC(channel: 15, controller: 8, value: 10)
                engine.captureCurveClosedPoint()
                engine.evaluateCurveCaptureForCC(channel: 15, controller: 8, value: 100)
                engine.captureCurveFullOnPoint()
                engine.finishCurveCalibration()
            default: XCTFail("Uncovered operation")
            }
            await drainC6Publications(engine)
            XCTAssertFalse(deferred.isEmpty, operation)
            engine.testOnly_deferSelectedMIDIPublication = nil
            if operation == "learn" {
                XCTAssertEqual(self.mappingStore!.load(deviceIdentifier: sourceA)?
                    .control(for: .crossfader)?.controlNumber, 9)
            }
            if operation == "clear-action" || operation == "clear-device" {
                XCTAssertNil(self.mappingStore!.load(deviceIdentifier: sourceA))
            }

            engine.selectedMIDIInputSourceID = sourceB
            engine.loadDeviceMappingForCurrentSource()
            await drainC6Publications(engine)
            engine.startMIDILearn(for: .leftUpfader)
            XCTAssertTrue(engine.evaluateMIDILearnForCC(channel: 3, controller: 14, value: 90).consumedByLearn)
            await drainC6Publications(engine)
            engine.startCalibration(for: .crossfader)
            await drainC6Publications(engine)
            let successorMapping = try XCTUnwrap(engine.currentMIDIDeviceMapping)
            let successorState = engine.midiLearnState
            let successorFeedback = engine.midiLearnFeedback
            let successorRaw = engine.midiLearnObservedRawValue
            XCTAssertEqual(successorMapping.deviceIdentifier, sourceB)
            XCTAssertEqual(engine.activeCalibrationAction, .crossfader)

            for publish in deferred { publish() }
            XCTAssertEqual(engine.currentMIDIDeviceMapping, successorMapping, operation)
            XCTAssertEqual(engine.crossfaderCCMapping, .init(channel: 3, controller: 11), operation)
            XCTAssertEqual(engine.midiLearnState, successorState, operation)
            XCTAssertEqual(engine.midiLearnFeedback, successorFeedback, operation)
            XCTAssertEqual(engine.midiLearnObservedRawValue, successorRaw, operation)
            XCTAssertNil(engine.activeMIDILearnAction, operation)
            XCTAssertEqual(engine.activeCalibrationAction, .crossfader, operation)
            XCTAssertNil(engine.activeCurveCaptureAction, operation)
            XCTAssertTrue(engine.midiMappingError.isEmpty, operation)
            XCTAssertTrue(engine.calibrationError.isEmpty, operation)
            engine.cancelCalibration()
            await drainC6Publications(engine)
            engine.testOnly_waitForMappingPersistenceQueue()
        }
    }

    @MainActor
    func testC6FreshA2ReloadSurvivesObsoleteA1Clear() async throws {
        let engine = makeEngine()
        let sourceA = "midi_c6_reload_A_\(UUID().uuidString)"
        let sourceB = "midi_c6_reload_B_\(UUID().uuidString)"
        defer {
            cleanUpMIDIMapping(deviceIdentifier: sourceA)
            cleanUpMIDIMapping(deviceIdentifier: sourceB)
        }
        engine.selectedMIDIInputSourceID = sourceA
        await drainC6Publications(engine)
        var deferred: [() -> Void] = []
        engine.testOnly_deferSelectedMIDIPublication = { deferred.append($0) }
        engine.loadDeviceMappingForCurrentSource() // A1 nil result, before learning.
        engine.startMIDILearn(for: .crossfader)
        XCTAssertTrue(engine.evaluateMIDILearnForCC(channel: 15, controller: 8, value: 100).consumedByLearn)
        await drainC6Publications(engine)
        XCTAssertNil(engine.currentMIDIDeviceMapping)
        XCTAssertEqual(self.mappingStore!.load(deviceIdentifier: sourceA)?.deviceIdentifier, sourceA)
        XCTAssertFalse(deferred.isEmpty)
        engine.testOnly_deferSelectedMIDIPublication = nil
        engine.selectedMIDIInputSourceID = sourceB
        engine.selectedMIDIInputSourceID = sourceA
        engine.loadDeviceMappingForCurrentSource() // Fresh A2 owner; A's valid persistence is usable.
        await drainC6Publications(engine)
        let fresh = try XCTUnwrap(engine.currentMIDIDeviceMapping)
        XCTAssertEqual(fresh.deviceIdentifier, sourceA)
        XCTAssertEqual(fresh.control(for: .crossfader)?.controlNumber, 8)
        for publish in deferred { publish() }
        XCTAssertEqual(engine.currentMIDIDeviceMapping, fresh)
        XCTAssertEqual(engine.crossfaderCCMapping, .init(channel: 15, controller: 8))
        XCTAssertEqual(engine.midiLearnState, .idle, "A1 learned status must not reappear")
        engine.startCalibration(for: .crossfader)
        await drainC6Publications(engine)
        XCTAssertEqual(engine.activeCalibrationAction, .crossfader)
        engine.cancelCalibration()
        await drainC6Publications(engine)
    }

    @MainActor
    func testC6SelectionChangeRetiresPendingLearnAndExistingCalibration() async throws {
        let engine = makeEngine()
        let sourceA = "midi_c6_pending_A_\(UUID().uuidString)"
        let sourceB = "midi_c6_pending_B_\(UUID().uuidString)"
        defer {
            cleanUpMIDIMapping(deviceIdentifier: sourceA)
            cleanUpMIDIMapping(deviceIdentifier: sourceB)
        }
        engine.selectedMIDIInputSourceID = sourceA
        engine.startMIDILearn(for: .crossfader)
        engine.selectedMIDIInputSourceID = sourceB
        engine.selectedMIDIInputSourceID = sourceA
        XCTAssertFalse(engine.evaluateMIDILearnForCC(channel: 15, controller: 8, value: 100).consumedByLearn)
        await drainC6Publications(engine)
        XCTAssertNil(engine.currentMIDIDeviceMapping)
        XCTAssertNil(self.mappingStore!.load(deviceIdentifier: sourceA))
        XCTAssertNil(self.mappingStore!.load(deviceIdentifier: sourceB))

        engine.startMIDILearn(for: .crossfader)
        engine.selectedMIDIInputSourceID = sourceA // Same ID assignment is not a transition.
        XCTAssertTrue(engine.evaluateMIDILearnForCC(channel: 15, controller: 8, value: 100).consumedByLearn)
        await drainC6Publications(engine)
        engine.startCalibration(for: .crossfader)
        await drainC6Publications(engine)
        XCTAssertEqual(engine.activeCalibrationAction, .crossfader)
        engine.selectedMIDIInputSourceID = sourceB
        XCTAssertNil(engine.currentMIDIDeviceMapping, "Old mapping is retired even if B cannot connect")
        engine.finishCalibration()
        await drainC6Publications(engine)
        XCTAssertNil(engine.activeCalibrationAction)
        XCTAssertNil(engine.crossfaderCCMapping)
        XCTAssertNil(self.mappingStore!.load(deviceIdentifier: sourceB))
    }
}
