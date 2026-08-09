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
}
