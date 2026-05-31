import XCTest
@testable import ScratchLab

/// Controller-input — pure, Codable ControllerProfile and the built-in RANE profile.
/// No Core MIDI, no AVFoundation, no UI, no notation/replay/export are exercised here.
/// The built-in profile is locked to the existing mapper constants, and adopting the
/// profile layer is proven to change no mapper output on a fixture stream.
final class ControllerProfileTests: XCTestCase {

    // MARK: - Built-in RANE profile reproduces the old constants exactly

    func testRaneProfileMatchesMapperConstants() {
        let profile = ControllerProfile.raneOneMKII

        // Platter = CC6, relative ring modulus 128 (the primary driver).
        XCTAssertEqual(profile.deck.platter.signal, .controlChange(number: 6))
        XCTAssertEqual(profile.deck.platter.ringModulus, ScratchPlatterPlayheadMapper.cc6Modulus)
        XCTAssertEqual(profile.deck.platter.ringModulus, 128)
        XCTAssertFalse(profile.deck.platter.isDiagnosticOnly)

        // Crossfader = CC8, absolute (no ring modulus).
        XCTAssertEqual(profile.deck.crossfader.signal, .controlChange(number: 8))
        XCTAssertNil(profile.deck.crossfader.ringModulus)

        // Pitch bend = 14-bit, diagnostic-only (never drives playback).
        XCTAssertEqual(profile.deck.pitchBend.signal, .pitchBend)
        XCTAssertTrue(profile.deck.pitchBend.isDiagnosticOnly)

        // Scalar constants match the mapper's statics exactly.
        XCTAssertEqual(profile.stepsPerRevolution, ScratchPlatterPlayheadMapper.defaultStepsPerRevolution)
        XCTAssertEqual(profile.stepsPerRevolution, 3932)
        XCTAssertEqual(profile.pitchBendTicksPerRevolution, ScratchPlatterPlayheadMapper.ticksPerRevolution)
        XCTAssertEqual(profile.pitchBendTicksPerRevolution, 16384)
        XCTAssertEqual(profile.aliasWarnThreshold, ScratchPlatterPlayheadMapper.aliasWarnThreshold)
        XCTAssertEqual(profile.aliasWarnThreshold, 4096)
        XCTAssertEqual(profile.aliasFailThreshold, ScratchPlatterPlayheadMapper.aliasFailThreshold)
        XCTAssertEqual(profile.aliasFailThreshold, 8192)
        XCTAssertEqual(profile.crossfaderCutWidth, ScratchPlatterPlayheadMapper.crossfaderCutWidth, accuracy: 1e-12)
        XCTAssertEqual(profile.crossfaderCutWidth, 0.05, accuracy: 1e-12)
    }

    // MARK: - Mapper output is identical before/after the profile seam

    func testProfileMapperMatchesDirectMapperOnFixtureStream() {
        // A representative CC6 stream: forward ramp, a wrap across the ring, then reverse.
        let stream = [10, 11, 12, 13, 14, 13, 12, 127, 0, 1, 2, 1, 0, 127]

        var direct = ScratchPlatterPlayheadMapper(
            sampleSecondsPerStep: 0.01, sampleDuration: 2.0, boundaryMode: .loop
        )
        var viaProfile = ScratchPlatterPlayheadMapper.forProfile(
            .raneOneMKII, sampleSecondsPerStep: 0.01, sampleDuration: 2.0, boundaryMode: .loop
        )

        for value in stream {
            let directStep = direct.ingestCC6(value)
            let profileStep = viaProfile.ingestCC6(value)
            XCTAssertEqual(directStep, profileStep)
            XCTAssertEqual(direct.samplePosition, viaProfile.samplePosition, accuracy: 1e-12)
        }
        XCTAssertEqual(direct, viaProfile)
    }

    func testForProfileDefaultsToRaneBuiltIn() {
        let viaDefault = ScratchPlatterPlayheadMapper.forProfile(sampleDuration: 1.0)
        let viaExplicit = ScratchPlatterPlayheadMapper.forProfile(.raneOneMKII, sampleDuration: 1.0)
        XCTAssertEqual(viaDefault, viaExplicit)
    }

    // MARK: - Codable roundtrip

    func testCodableRoundtripPreservesProfile() throws {
        let original = ControllerProfile.raneOneMKII
        let data = try JSONEncoder().encode(original)
        let decoded = try ControllerProfile.decode(from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Schema versioning fails closed

    func testUnknownSchemaVersionFailsClosed() throws {
        let future = ControllerProfile(
            schemaVersion: ControllerProfile.currentSchemaVersion + 1,
            identifier: "future-device",
            displayName: "Future Device",
            deck: ControllerProfile.raneOneMKII.deck,
            stepsPerRevolution: 4000,
            pitchBendTicksPerRevolution: 16384,
            aliasWarnThreshold: 4096,
            aliasFailThreshold: 8192,
            crossfaderCutWidth: 0.05
        )
        let data = try JSONEncoder().encode(future)
        XCTAssertThrowsError(try ControllerProfile.decode(from: data)) { error in
            XCTAssertEqual(
                error as? ControllerProfileError,
                .unsupportedSchemaVersion(ControllerProfile.currentSchemaVersion + 1)
            )
        }
    }

    func testCurrentSchemaVersionDecodes() throws {
        let data = try JSONEncoder().encode(ControllerProfile.raneOneMKII)
        XCTAssertNoThrow(try ControllerProfile.decode(from: data))
    }
}

/// Controller profile persistence + import/export (Slice 7). File I/O against an injected
/// temporary directory. Touches no timeline/session export schema.
final class ControllerProfileStoreTests: XCTestCase {

    private var tempDir: URL!
    private var store: ControllerProfileStore!

    /// A custom (non-built-in) profile derived from RANE with a different identifier.
    private func customProfile(identifier: String = "custom-test") -> ControllerProfile {
        let rane = ControllerProfile.raneOneMKII
        return ControllerProfile(
            schemaVersion: ControllerProfile.currentSchemaVersion,
            identifier: identifier,
            displayName: "Custom Test Controller",
            deck: rane.deck,
            stepsPerRevolution: rane.stepsPerRevolution,
            pitchBendTicksPerRevolution: rane.pitchBendTicksPerRevolution,
            aliasWarnThreshold: rane.aliasWarnThreshold,
            aliasFailThreshold: rane.aliasFailThreshold,
            crossfaderCutWidth: rane.crossfaderCutWidth
        )
    }

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ControllerProfileStoreTests-\(UUID().uuidString)")
        store = ControllerProfileStore(directory: tempDir)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    func testSaveLoadRoundtrip() throws {
        let profile = customProfile()
        let url = try store.save(profile)
        let loaded = try store.load(at: url)
        XCTAssertEqual(loaded, profile)
    }

    func testEncodeIsDeterministic() throws {
        let profile = customProfile()
        let a = try ControllerProfileStore.encodeDocument(profile)
        let b = try ControllerProfileStore.encodeDocument(profile)
        XCTAssertEqual(a, b)
        XCTAssertEqual(try ControllerProfileStore.decodeDocument(a), profile)
    }

    func testExportWritesLoadableFile() throws {
        let url = try store.export(.raneOneMKII, to: tempDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try store.load(at: url), .raneOneMKII)
    }

    func testUnknownFormatRejected() throws {
        let document = ControllerProfileDocument(format: "controller_profile_v99", profile: customProfile())
        let data = try JSONEncoder().encode(document)
        XCTAssertThrowsError(try ControllerProfileStore.decodeDocument(data)) { error in
            XCTAssertEqual(error as? ControllerProfileStore.StoreError, .unsupportedFormat("controller_profile_v99"))
        }
    }

    func testUnknownSchemaVersionRejected() throws {
        let future = ControllerProfile(
            schemaVersion: ControllerProfile.currentSchemaVersion + 1,
            identifier: "future", displayName: "Future",
            deck: ControllerProfile.raneOneMKII.deck,
            stepsPerRevolution: 4000, pitchBendTicksPerRevolution: 16384,
            aliasWarnThreshold: 4096, aliasFailThreshold: 8192, crossfaderCutWidth: 0.05
        )
        let data = try JSONEncoder().encode(ControllerProfileDocument(profile: future))
        XCTAssertThrowsError(try ControllerProfileStore.decodeDocument(data)) { error in
            XCTAssertEqual(
                error as? ControllerProfileStore.StoreError,
                .unsupportedSchemaVersion(ControllerProfile.currentSchemaVersion + 1)
            )
        }
    }

    func testMissingFormatKeyFailsClosed() throws {
        // A JSON object with only the profile (no `format`) must not be assumed current.
        let inner = try JSONEncoder().encode(ControllerProfile.raneOneMKII)
        let json = "{\"profile\":\(String(data: inner, encoding: .utf8)!)}"
        XCTAssertThrowsError(try ControllerProfileStore.decodeDocument(Data(json.utf8)))
    }

    func testBuiltInProfileCannotBeOverwritten() {
        XCTAssertThrowsError(try store.save(.raneOneMKII)) { error in
            XCTAssertEqual(
                error as? ControllerProfileStore.StoreError,
                .builtInProfileReadOnly(ControllerProfile.raneOneMKII.identifier)
            )
        }
    }

    func testListSavedReturnsSavedProfiles() throws {
        try store.save(customProfile(identifier: "alpha"))
        try store.save(customProfile(identifier: "beta"))
        let identifiers = Set(store.listSaved().map(\.identifier))
        XCTAssertEqual(identifiers, ["alpha", "beta"])
    }
}
