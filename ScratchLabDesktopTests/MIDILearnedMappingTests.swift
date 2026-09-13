// MIDILearnedMappingTests.swift
// ScratchLabDesktopTests
//
// Pure-model tests for the generic per-device MIDI Learn mapping model
// (ScratchLab/Models/ControllerInput/Registry/MIDILearnedMapping.swift).
// No CoreMIDI, no MacCaptureEngine — these exercise the Codable model and
// its file-backed persistence store in isolation.

import XCTest
@testable import ScratchLab

final class MIDILearnedMappingTests: XCTestCase {

    func testVerifiedRaneOneMKIIMappingContainsMixerAndRightDeckPads() throws {
        let controls = RaneOneMKIIVerifiedLearnedMapping.controls(learnedAt: Date(timeIntervalSince1970: 1))
        func control(_ action: MIDISemanticAction) -> MIDILearnedControl? {
            controls.first { $0.action == action }
        }

        XCTAssertEqual(controls.count, 11)
        XCTAssertEqual(control(.crossfader)?.channel, 15)
        XCTAssertEqual(control(.crossfader)?.controlNumber, 8)
        XCTAssertEqual(control(.leftUpfader)?.channel, 0)
        XCTAssertEqual(control(.leftUpfader)?.controlNumber, 28)
        XCTAssertEqual(control(.rightUpfader)?.channel, 1)
        XCTAssertEqual(control(.rightUpfader)?.controlNumber, 28)
        XCTAssertEqual(control(.hotCue1)?.messageType, .note)
        XCTAssertEqual(control(.hotCue1)?.channel, 5)
        XCTAssertEqual(control(.hotCue1)?.controlNumber, 20)
        XCTAssertEqual(control(.hotCue1)?.assignedSampleID, "dvs_ahhh")
        XCTAssertEqual(control(.hotCue8)?.controlNumber, 27)
    }

    func testVerifiedRaneMappingCanObserveSeratoPadsWithoutRoutingScratchLabAudio() throws {
        let controls = RaneOneMKIIVerifiedLearnedMapping.controls(
            learnedAt: Date(timeIntervalSince1970: 1),
            assignsScratchLabSamples: false
        )

        XCTAssertEqual(controls.count, 11)
        XCTAssertTrue(controls.filter { $0.action.hotCueIndex != nil }.allSatisfy {
            $0.assignedSampleID == nil
        })
    }

    func testVerifiedRaneSeedPreservesExistingOverridesWhenRequested() throws {
        var mapping = MIDIDeviceMapping(deviceIdentifier: "rane", deviceName: "Rane ONE MKII")
        mapping.upsert(MIDILearnedControl(
            action: .crossfader,
            messageType: .controlChange,
            channel: 3,
            controlNumber: 44
        ))

        RaneOneMKIIVerifiedLearnedMapping.apply(to: &mapping, overwriteExisting: false)

        XCTAssertEqual(mapping.control(for: .crossfader)?.channel, 3)
        XCTAssertEqual(mapping.control(for: .crossfader)?.controlNumber, 44)
        XCTAssertTrue(RaneOneMKIIVerifiedLearnedMapping.isComplete(mapping))
    }

    // MARK: - MIDILearnedControl

    func testLearnedControlCodableRoundTrip() throws {
        let control = MIDILearnedControl(
            action: .crossfader,
            messageType: .controlChange,
            channel: 15,
            controlNumber: 8,
            deck: nil,
            minValue: 0,
            maxValue: 127,
            inverted: false,
            assignedSampleID: nil,
            learnedAt: Date(timeIntervalSince1970: 1_700_000_000),
            isVerified: true
        )
        let data = try JSONEncoder().encode(control)
        let decoded = try JSONDecoder().decode(MIDILearnedControl.self, from: data)
        XCTAssertEqual(decoded, control)
    }

    func testLearnedControlNormalizedValueDefaultRange() {
        let control = MIDILearnedControl(action: .leftUpfader, messageType: .controlChange, channel: 0, controlNumber: 1)
        XCTAssertEqual(control.normalizedValue(from: 0), 0.0, accuracy: 0.0001)
        XCTAssertEqual(control.normalizedValue(from: 127), 1.0, accuracy: 0.0001)
        XCTAssertEqual(control.normalizedValue(from: 64), 64.0 / 127.0, accuracy: 0.0001)
    }

    func testLearnedControlNormalizedValueClampsOutOfRange() {
        let control = MIDILearnedControl(action: .rightUpfader, messageType: .controlChange, channel: 1, controlNumber: 2, minValue: 10, maxValue: 100)
        XCTAssertEqual(control.normalizedValue(from: -5), 0.0, accuracy: 0.0001)
        XCTAssertEqual(control.normalizedValue(from: 500), 1.0, accuracy: 0.0001)
    }

    func testLearnedControlNormalizedValueInverted() {
        let control = MIDILearnedControl(action: .leftUpfader, messageType: .controlChange, channel: 0, controlNumber: 1, inverted: true)
        XCTAssertEqual(control.normalizedValue(from: 0), 1.0, accuracy: 0.0001)
        XCTAssertEqual(control.normalizedValue(from: 127), 0.0, accuracy: 0.0001)
        XCTAssertEqual(control.normalizedValue(from: 64), 1.0 - (64.0 / 127.0), accuracy: 0.0001)
    }

    func testLearnedControlNormalizedValueCustomCalibratedRangeWithInversion() {
        let control = MIDILearnedControl(action: .rightUpfader, messageType: .controlChange, channel: 1, controlNumber: 2, minValue: 20, maxValue: 110, inverted: true)
        XCTAssertEqual(control.normalizedValue(from: 20), 1.0, accuracy: 0.0001)
        XCTAssertEqual(control.normalizedValue(from: 110), 0.0, accuracy: 0.0001)
        XCTAssertEqual(control.normalizedValue(from: 65), 0.5, accuracy: 0.02)
    }

    func testLearnedControlIsCompatibleAllowsSameActionUpdate() {
        let original = MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 15, controlNumber: 8)
        let relearned = MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 0, controlNumber: 9)
        XCTAssertTrue(original.isCompatible(with: relearned), "Re-learning the same action must never be flagged as a collision")
    }

    func testLearnedControlIsCompatibleDetectsCollision() {
        let crossfader = MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 15, controlNumber: 8)
        let hotCue = MIDILearnedControl(action: .hotCue1, messageType: .controlChange, channel: 15, controlNumber: 8)
        XCTAssertFalse(crossfader.isCompatible(with: hotCue), "Two different actions on the same (channel, controller, type) must collide")
    }

    // MARK: - MIDIDeviceMapping

    func testDeviceMappingCodableRoundTrip() throws {
        var mapping = MIDIDeviceMapping(deviceIdentifier: "midi_1001", deviceName: "Rane ONE MKII")
        mapping.upsert(MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 15, controlNumber: 8))
        let data = try JSONEncoder().encode(mapping)
        let decoded = try JSONDecoder().decode(MIDIDeviceMapping.self, from: data)
        XCTAssertEqual(decoded, mapping)
    }

    func testDeviceMappingUpsertReplacesSameAction() {
        var mapping = MIDIDeviceMapping(deviceIdentifier: "midi_1", deviceName: "Rane ONE MKII")
        mapping.upsert(MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 15, controlNumber: 8))
        mapping.upsert(MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 0, controlNumber: 9))
        XCTAssertEqual(mapping.controls.count, 1)
        XCTAssertEqual(mapping.control(for: .crossfader)?.controlNumber, 9)
    }

    func testDeviceMappingRemoveAction() {
        var mapping = MIDIDeviceMapping(deviceIdentifier: "midi_1", deviceName: "Rane ONE MKII")
        mapping.upsert(MIDILearnedControl(action: .hotCue1, messageType: .note, channel: 5, controlNumber: 20))
        XCTAssertFalse(mapping.isEmpty)
        mapping.remove(action: .hotCue1)
        XCTAssertTrue(mapping.isEmpty)
    }

    func testDeviceMappingCollisionExists() {
        var mapping = MIDIDeviceMapping(deviceIdentifier: "midi_1", deviceName: "Rane ONE MKII")
        mapping.upsert(MIDILearnedControl(action: .hotCue1, messageType: .note, channel: 5, controlNumber: 20))
        let candidate = MIDILearnedControl(action: .hotCue2, messageType: .note, channel: 5, controlNumber: 20)
        XCTAssertNotNil(mapping.collisionExists(for: candidate))
    }

    func testDeviceMappingHasFaderAndHotCueMappings() {
        var mapping = MIDIDeviceMapping(deviceIdentifier: "midi_1", deviceName: "Rane ONE MKII")
        XCTAssertFalse(mapping.hasFaderMappings)
        XCTAssertFalse(mapping.hasHotCueMappings)
        mapping.upsert(MIDILearnedControl(action: .leftUpfader, messageType: .controlChange, channel: 0, controlNumber: 1))
        XCTAssertTrue(mapping.hasFaderMappings)
        XCTAssertFalse(mapping.hasHotCueMappings)
        mapping.upsert(MIDILearnedControl(action: .hotCue3, messageType: .note, channel: 5, controlNumber: 22))
        XCTAssertTrue(mapping.hasHotCueMappings)
    }

    func testRestoringAssignedHotCueSamplesPreservesLearnedControllerMapping() throws {
        let learnedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let fader = MIDILearnedControl(
            action: .crossfader,
            messageType: .controlChange,
            channel: 15,
            controlNumber: 8,
            minValue: 4,
            maxValue: 120,
            inverted: true,
            learnedAt: learnedAt,
            isVerified: true
        )
        let hotCue = MIDILearnedControl(
            action: .hotCue1,
            messageType: .note,
            channel: 5,
            controlNumber: 20,
            deck: 1,
            minValue: 1,
            maxValue: 126,
            inverted: true,
            assignedSampleID: nil,
            learnedAt: learnedAt,
            isVerified: true
        )
        var mapping = MIDIDeviceMapping(
            deviceIdentifier: "midi_1",
            deviceName: "Rane ONE MKII",
            controls: [fader, hotCue]
        )

        XCTAssertTrue(mapping.restoreMissingAssignedHotCueSamples())
        XCTAssertEqual(mapping.control(for: .crossfader), fader)

        let normalizedHotCue = try XCTUnwrap(mapping.control(for: .hotCue1))
        XCTAssertEqual(normalizedHotCue.assignedSampleID, "dvs_ahhh")
        XCTAssertEqual(normalizedHotCue.action, hotCue.action)
        XCTAssertEqual(normalizedHotCue.messageType, hotCue.messageType)
        XCTAssertEqual(normalizedHotCue.channel, hotCue.channel)
        XCTAssertEqual(normalizedHotCue.controlNumber, hotCue.controlNumber)
        XCTAssertEqual(normalizedHotCue.deck, hotCue.deck)
        XCTAssertEqual(normalizedHotCue.minValue, hotCue.minValue)
        XCTAssertEqual(normalizedHotCue.maxValue, hotCue.maxValue)
        XCTAssertEqual(normalizedHotCue.inverted, hotCue.inverted)
        XCTAssertEqual(normalizedHotCue.learnedAt, hotCue.learnedAt)
        XCTAssertEqual(normalizedHotCue.isVerified, hotCue.isVerified)
        XCTAssertFalse(mapping.restoreMissingAssignedHotCueSamples(), "The repair must be idempotent")
    }

    func testDeviceMappingDecodeFailsClosedOnUnsupportedSchemaVersion() throws {
        let mapping = MIDIDeviceMapping(schemaVersion: 999, deviceIdentifier: "midi_1", deviceName: "Rane ONE MKII")
        let data = try JSONEncoder().encode(mapping)
        XCTAssertThrowsError(try MIDIDeviceMapping.decode(from: data)) { error in
            XCTAssertEqual(error as? MIDIDeviceMappingError, .unsupportedSchemaVersion(999))
        }
    }

    // MARK: - MIDILearnedMappingStore

    private func makeTemporaryStore() throws -> (store: MIDILearnedMappingStore, url: URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MIDILearnedMappingTests-\(UUID().uuidString)", isDirectory: true)
        return (MIDILearnedMappingStore(baseURL: url), url)
    }

    func testStoreSaveAndLoadRoundTrip() throws {
        let (store, url) = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: url) }

        var mapping = MIDIDeviceMapping(deviceIdentifier: "midi_rane", deviceName: "Rane ONE MKII")
        mapping.upsert(MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 15, controlNumber: 8))
        store.save(mapping)

        let loaded = store.load(deviceIdentifier: "midi_rane")
        XCTAssertEqual(loaded, mapping)
    }

    func testStoreLoadMissingDeviceReturnsNil() throws {
        let (store, url) = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(store.load(deviceIdentifier: "midi_never_saved"))
        XCTAssertNoThrow(try store.loadOrThrow(deviceIdentifier: "midi_never_saved"))
    }

    func testStoreDeleteRemovesMapping() throws {
        let (store, url) = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let mapping = MIDIDeviceMapping(deviceIdentifier: "midi_rane", deviceName: "Rane ONE MKII")
        store.save(mapping)
        XCTAssertNotNil(store.load(deviceIdentifier: "midi_rane"))

        store.delete(deviceIdentifier: "midi_rane")
        XCTAssertNil(store.load(deviceIdentifier: "midi_rane"))
    }

    /// Devices must never leak into each other's saved mappings — a Rane mapping
    /// must not be visible when loading the Pioneer S9's identifier, and vice versa.
    func testStorePerDeviceIsolation() throws {
        let (store, url) = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: url) }

        var rane = MIDIDeviceMapping(deviceIdentifier: "midi_rane", deviceName: "Rane ONE MKII")
        rane.upsert(MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 15, controlNumber: 8))
        store.save(rane)

        var pioneer = MIDIDeviceMapping(deviceIdentifier: "midi_pioneer_s9", deviceName: "Pioneer DJM-S9")
        pioneer.upsert(MIDILearnedControl(action: .crossfader, messageType: .controlChange, channel: 0, controlNumber: 11))
        store.save(pioneer)

        let loadedRane = try XCTUnwrap(store.load(deviceIdentifier: "midi_rane"))
        let loadedPioneer = try XCTUnwrap(store.load(deviceIdentifier: "midi_pioneer_s9"))
        XCTAssertEqual(loadedRane.control(for: .crossfader)?.controlNumber, 8)
        XCTAssertEqual(loadedPioneer.control(for: .crossfader)?.controlNumber, 11)
    }

    /// A corrupt/unsupported-schema mapping file must fail visibly (throw) rather
    /// than silently vanish, so the engine can surface a load error to the user.
    func testStoreLoadOrThrowSurfacesCorruptFile() throws {
        let (store, url) = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let corruptURL = url.appendingPathComponent("midi_rane.json")
        try Data("not valid json".utf8).write(to: corruptURL)

        XCTAssertNil(store.load(deviceIdentifier: "midi_rane"), "The nil-swallowing convenience API stays nil on corruption")
        XCTAssertThrowsError(try store.loadOrThrow(deviceIdentifier: "midi_rane"))
    }

    // MARK: - curveConfig tolerant decode
    //
    // `curveConfig` must decode as nil on ANY malformation (unknown preset,
    // wrong JSON type, malformed nested capture) rather than throwing and
    // discarding the whole control — let alone the whole device mapping's
    // array of controls, which synthesized decoding would do. schemaVersion
    // stays at 1 throughout: bumping it would reject every pre-existing
    // mapping file outright.

    private func controlJSON(
        action: String = "crossfader",
        messageType: String = "controlChange",
        channel: Int = 15,
        controlNumber: Int = 8,
        curveConfigJSON: String? = nil
    ) -> String {
        let curveField = curveConfigJSON.map { ",\n  \"curveConfig\": \($0)" } ?? ""
        return """
        {
          "action": "\(action)",
          "messageType": "\(messageType)",
          "channel": \(channel),
          "controlNumber": \(controlNumber),
          "minValue": 0,
          "maxValue": 127,
          "inverted": false,
          "learnedAt": 700000000.0,
          "isVerified": true\(curveField)
        }
        """
    }

    func testSchemaVersionUnchangedByCurveConfigAddition() {
        XCTAssertEqual(MIDIDeviceMapping.currentSchemaVersion, 1)
    }

    func testLegacyControlJSONWithoutCurveConfigDecodesWithNilCurveConfig() throws {
        let control = try JSONDecoder().decode(MIDILearnedControl.self, from: Data(controlJSON().utf8))
        XCTAssertNil(control.curveConfig)
        XCTAssertEqual(control.action, .crossfader)
        XCTAssertEqual(control.controlNumber, 8)
        XCTAssertEqual(control.resolvedCurveConfig, MIDIFaderCurveConfig.defaultConfig(for: .crossfader))
    }

    func testValidCurveConfigDecodes() throws {
        let json = controlJSON(action: "rightUpfader", controlNumber: 21, curveConfigJSON: #"{"preset": "linear", "customCapture": null}"#)
        let control = try JSONDecoder().decode(MIDILearnedControl.self, from: Data(json.utf8))
        XCTAssertEqual(control.curveConfig, MIDIFaderCurveConfig(preset: .linear, customCapture: nil))
    }

    func testUnknownCurvePresetFallsBackToNil() throws {
        let json = controlJSON(curveConfigJSON: #"{"preset": "someFuturePresetNotYetInvented", "customCapture": null}"#)
        let control = try JSONDecoder().decode(MIDILearnedControl.self, from: Data(json.utf8))
        XCTAssertNil(control.curveConfig, "an unknown preset string must fall back to nil, not throw")
        XCTAssertEqual(control.channel, 15)
        XCTAssertEqual(control.controlNumber, 8)
        XCTAssertTrue(control.isVerified)
    }

    func testMalformedCurveConfigTypeFallsBackToNil() throws {
        // curveConfig present but the WRONG JSON type entirely (a bare string, not an object).
        let json = controlJSON(curveConfigJSON: "\"not-an-object\"")
        let control = try JSONDecoder().decode(MIDILearnedControl.self, from: Data(json.utf8))
        XCTAssertNil(control.curveConfig)
        XCTAssertEqual(control.action, .crossfader)
    }

    func testMalformedNestedCaptureFallsBackToNil() throws {
        // customCapture present but a string where an Int raw value belongs.
        let json = controlJSON(action: "rightUpfader", curveConfigJSON: #"{"preset": "custom", "customCapture": {"closedRawValue": "not-a-number", "fullOnRawValue": 90}}"#)
        let control = try JSONDecoder().decode(MIDILearnedControl.self, from: Data(json.utf8))
        XCTAssertNil(control.curveConfig)
    }

    /// The central proof for Correction 2: a malformed curveConfig on ONE
    /// control must not discard that control, and must not discard the
    /// crossfader binding or any hot cue elsewhere in the same device
    /// mapping — which is exactly what synthesized `[MIDILearnedControl]`
    /// decoding would do (one bad array element fails the whole array).
    func testCorruptCurveConfigDoesNotDiscardUnrelatedMappingsOrHotCues() throws {
        let crossfaderJSON = controlJSON(action: "crossfader", controlNumber: 8)
        let rightUpfaderJSON = controlJSON(action: "rightUpfader", channel: 0, controlNumber: 21, curveConfigJSON: "\"totally-malformed\"")
        let hotCue1JSON = controlJSON(action: "hotCue1", messageType: "note", channel: 9, controlNumber: 60)
        let hotCue2JSON = controlJSON(action: "hotCue2", messageType: "note", channel: 9, controlNumber: 61)

        let mappingJSON = """
        {
          "schemaVersion": 1,
          "deviceIdentifier": "midi_rane",
          "deviceName": "Rane ONE MKII",
          "controls": [\(crossfaderJSON), \(rightUpfaderJSON), \(hotCue1JSON), \(hotCue2JSON)],
          "createdAt": 700000000.0,
          "lastModifiedAt": 700000000.0
        }
        """

        let mapping = try MIDIDeviceMapping.decode(from: Data(mappingJSON.utf8))
        XCTAssertEqual(mapping.controls.count, 4, "a malformed curveConfig on ONE control must not discard the others")
        XCTAssertNotNil(mapping.control(for: .crossfader))
        let rightUpfader = try XCTUnwrap(mapping.control(for: .rightUpfader))
        XCTAssertNil(rightUpfader.curveConfig, "the malformed curveConfig falls back to nil; the control itself survives")
        XCTAssertEqual(rightUpfader.controlNumber, 21)
        XCTAssertNotNil(mapping.control(for: .hotCue1))
        XCTAssertNotNil(mapping.control(for: .hotCue2))
    }
}
