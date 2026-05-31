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
