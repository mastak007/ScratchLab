// PlatterTestSampleLoadTests.swift
// Confirms the Debug hardware-test "Load platter ahhh test" button loads
// the validated one-revolution `dvs_ahhh` asset (VirtualPlatter/ahhh.wav,
// ~1.0474 s) — not the ~4.4667 s hot-cue pad asset `ahhh.wav`, which does
// not fit one physical platter revolution and silently produced no audio
// via direct-MIDI on the first Rane hardware test (2026-08-09).

import XCTest
@testable import ScratchLab

final class PlatterTestSampleLoadTests: XCTestCase {

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "PlatterTestSampleLoadTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeEngine(
        mode: ScratchAudioOwnershipMode? = .scratchLabStandalone,
        defaults: UserDefaults? = nil
    ) throws -> MacCaptureEngine {
        let resourceRoot = try XCTUnwrap(
            Bundle(for: MacCaptureEngine.self).resourceURL,
            "The app test host must expose its resource root"
        )
        let defaults = try defaults ?? makeDefaults()
        mode?.persist(to: defaults)
        return MacCaptureEngine(
            autoRefreshDevices: false,
            midiDefaults: defaults,
            sampleResourceRoot: resourceRoot
        )
    }

    private func flushMainQueue(file: StaticString = #filePath, line: UInt = #line) {
        let published = expectation(description: "main-queue publication")
        DispatchQueue.main.async { published.fulfill() }
        wait(for: [published], timeout: 2.0)
    }

    func testAudioOwnershipDefaultsToScratchLabStandalone() throws {
        let defaults = try makeDefaults()
        XCTAssertEqual(ScratchAudioOwnershipMode.load(from: defaults), .scratchLabStandalone)
        XCTAssertTrue(ScratchAudioOwnershipMode.defaultMode.allowsLocalScratchPlayback)
    }

    func testLegacyExternalOwnershipPreferenceMigratesToStandalone() throws {
        let defaults = try makeDefaults()
        defaults.set("externalSerato", forKey: ScratchAudioOwnershipMode.defaultsKey)
        XCTAssertEqual(ScratchAudioOwnershipMode.load(from: defaults), .scratchLabStandalone)
        XCTAssertEqual(
            defaults.string(forKey: ScratchAudioOwnershipMode.defaultsKey),
            ScratchAudioOwnershipMode.scratchLabStandalone.rawValue
        )
    }

    func testLoadPlatterTestSampleRequestsDVSAhhhNotTheLongPadAsset() throws {
        let engine = try makeEngine()
        engine.loadPlatterTestSample()

        let snapshot = engine.testOnly_scratchPlaybackDiagnosticsSnapshot()
        XCTAssertEqual(
            snapshot.loadedSampleID,
            "dvs_ahhh",
            "The platter test button must load the validated one-revolution asset, not the long hot-cue pad clip"
        )
        XCTAssertNil(snapshot.lastLoadError)

        // `platterTestLoadStatus` is published via an async main-queue hop
        // (`publishOnMainAsync`, matching every other UI-facing field in
        // this class) — flush the main queue before reading it, rather than
        // asserting immediately against a not-yet-applied value.
        let statusPublished = expectation(description: "platterTestLoadStatus published")
        DispatchQueue.main.async { statusPublished.fulfill() }
        wait(for: [statusPublished], timeout: 2.0)

        XCTAssertEqual(engine.platterTestLoadStatus, "loaded: dvs_ahhh")
    }

    func testAudiblePlatterTestUsesDVSAhhhAndLeavesItArmed() throws {
        let engine = try makeEngine()
        engine.previewPlatterTestSample()

        let snapshot = engine.testOnly_scratchPlaybackDiagnosticsSnapshot()
        XCTAssertEqual(snapshot.loadedSampleID, "dvs_ahhh")
        XCTAssertNil(snapshot.lastLoadError)
        XCTAssertTrue(snapshot.engineRunning)

        let statusPublished = expectation(description: "audible platter test status published")
        DispatchQueue.main.async { statusPublished.fulfill() }
        wait(for: [statusPublished], timeout: 2.0)

        XCTAssertEqual(engine.platterTestLoadStatus, "audible test: dvs_ahhh")
    }
    func testManualSelectorLoadsAllFourBundledSamples() throws {
        let engine = try makeEngine()
        for sample in ["dvs_ahhh", "fresh", "ah_yeah", "check_it_out"] {
            engine.loadScratchSample(sample)
            let snapshot = engine.testOnly_scratchPlaybackDiagnosticsSnapshot()
            XCTAssertEqual(snapshot.loadedSampleID, sample)
            XCTAssertNil(snapshot.lastLoadError)
        }
    }

    func testUnavailableSampleKeepsCurrentSampleAndExplainsFailure() throws {
        let engine = try makeEngine()
        engine.loadScratchSample("fresh")
        flushMainQueue()
        engine.loadScratchSample("missing")
        XCTAssertEqual(engine.testOnly_scratchPlaybackDiagnosticsSnapshot().loadedSampleID, "fresh")
        XCTAssertTrue(engine.platterTestLoadStatus.contains("unavailable"))
    }

    func testTakeOwnershipLocksSampleAndMappingMutations() throws {
        let engine = try makeEngine()
        engine.loadScratchSample("fresh")
        let token = engine.testOnly_armTakeMIDIWindow()
        defer { engine.testOnly_releaseAbandonedTakeMIDIWindow(token: token) }
        engine.loadScratchSample("dvs_ahhh")
        engine.startMIDILearn(for: .crossfader)
        engine.startCalibration(for: .crossfader)
        engine.startCurveCalibration(for: .crossfader)
        engine.previewPlatterTestSample()
        flushMainQueue()
        XCTAssertEqual(engine.testOnly_scratchPlaybackDiagnosticsSnapshot().loadedSampleID, "fresh")
        XCTAssertNil(engine.activeMIDILearnAction)
        XCTAssertNil(engine.activeCalibrationAction)
        XCTAssertNil(engine.activeCurveCaptureAction)
    }

    func testSavedUSBOutputPairsStayBoundToEachDeviceAndCannotChangeDuringTake() throws {
        let defaults = try makeDefaults()
        let saved = ["seventy-two-A": MacCaptureEngine.ScratchUSBOutputPairs(scratch: 2, beat: 0),
                     "one-B": MacCaptureEngine.ScratchUSBOutputPairs(scratch: 4, beat: 2)]
        let data = try JSONEncoder().encode(saved)
        defaults.set(data, forKey: "scratchlab.mac.usbOutputPairsByUID")
        let engine = try makeEngine(defaults: defaults)
        XCTAssertEqual(engine.scratchUSBOutputPairsByUID, saved)
        XCTAssertEqual(engine.selectedScratchUSBOutputPairs, .init())
        let previousUID = engine.selectedAudioDeviceUniqueID
        engine.selectedAudioDeviceUniqueID = "seventy-two-A"
        defer { engine.selectedAudioDeviceUniqueID = previousUID }
        XCTAssertEqual(engine.selectedScratchUSBOutputPairs, saved["seventy-two-A"])
        let token = engine.testOnly_armTakeMIDIWindow()
        defer { engine.testOnly_releaseAbandonedTakeMIDIWindow(token: token) }
        engine.setScratchUSBOutputPair(nil, forBeat: false)
        XCTAssertEqual(defaults.data(forKey: "scratchlab.mac.usbOutputPairsByUID"), data)
        XCTAssertEqual(engine.scratchUSBOutputPairsByUID, saved)
    }

    func testControllerSetupAuditRetainsInitialSampleSourcesAndLearnedCurves() throws {
        let date = Date(timeIntervalSince1970: 1_788_000_000)
        let mapping = MIDIDeviceMapping(deviceIdentifier: "mixer-72", deviceName: "Seventy-Two",
            controls: [
                MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 15,
                    controlNumber: 8, learnedAt: date,
                    curveConfig: MIDIFaderCurveConfig(preset: .sharpScratch, customCapture: nil)),
                MIDILearnedControl(action: .hotCue1, messageType: .note, channel: 1,
                    controlNumber: 40, assignedSampleID: "fresh", learnedAt: date)
            ], createdAt: date, lastModifiedAt: date)
        let event = try MacCaptureEngine.scratchControllerSetupAuditEvent(sampleID: "fresh",
            mixerSourceID: "mixer-72", platterSourceID: "platter-12", mapping: mapping, at: date)
        let restored = try JSONDecoder().decode(CaptureAuditEvent.self, from: JSONEncoder().encode(event))
        XCTAssertEqual(restored, event)
        XCTAssertEqual(event.category, "scratch_controller_setup")
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(restored.detail.utf8)) as? [String: Any])
        XCTAssertEqual(fields["initialSampleID"] as? String, "fresh")
        XCTAssertEqual(fields["mixerSourceID"] as? String, "mixer-72")
        XCTAssertEqual(fields["platterSourceID"] as? String, "platter-12")
        XCTAssertEqual(fields["physicalTicksPerRevolutionVerified"] as? Bool, false)
        let mappingData = try JSONSerialization.data(withJSONObject: XCTUnwrap(fields["learnedMixerMapping"]))
        XCTAssertEqual(try JSONDecoder().decode(MIDIDeviceMapping.self, from: mappingData), mapping)
    }

}
