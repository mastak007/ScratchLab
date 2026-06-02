import XCTest
@testable import ScratchLab

/// Pro-DJ MIDI registry layer — identity matching, ranking/confidence, the verified RANE
/// seed, and profile Codable round-trip / fail-closed decoding. Pure models only: no Core
/// MIDI, no audio, no playback, no engine or RANE scratch-zone code is referenced.
final class MIDIHardwareRegistryTests: XCTestCase {

    // MARK: - Identity / name match

    func testRaneIdentityMatchesSeedProfileAsCertified() {
        let identity = MIDIDeviceIdentity(sourceName: "RANE ONE")
        let match = MIDIHardwareRegistry.shared.bestMatch(for: identity)

        XCTAssertNotNil(match)
        XCTAssertEqual(match?.profile.identifier, "rane-one")
        XCTAssertEqual(match?.confidence, .certified)
        XCTAssertEqual(match?.matchedFragment, "rane one")
    }

    func testRaneOneMKIIStillMatchesViaNameFragment() {
        let identity = MIDIDeviceIdentity(sourceName: "RANE ONE MKII")
        XCTAssertEqual(MIDIHardwareRegistry.shared.bestMatch(for: identity)?.profile.identifier, "rane-one")
    }

    func testManufacturerOnlyHitIsCandidateNotCertified() {
        // Name doesn't contain "rane one"; only the manufacturer "rane" matches. This is a
        // candidate that still needs verification — it must NOT certify as RANE ONE.
        let identity = MIDIDeviceIdentity(sourceName: "USB MIDI Device", manufacturer: "RANE")
        let match = MIDIHardwareRegistry.shared.bestMatch(for: identity)

        XCTAssertNotNil(match)
        XCTAssertEqual(match?.matchedFragment, "rane")
        XCTAssertNotEqual(match?.confidence, .certified, "manufacturer-only must not certify")
        XCTAssertEqual(match?.confidence, .heuristic)
    }

    func testGenericDeviceWithRaneManufacturerDoesNotCertifyAsRaneOne() {
        let identity = MIDIDeviceIdentity(sourceName: "USB MIDI Device", manufacturer: "RANE")
        let resolved = MIDIHardwareRegistry.shared.resolve(for: identity)
        // Even though it may surface the rane-one profile as a candidate, it is NOT certified.
        XCTAssertLessThan(resolved.confidence, .certified)
        XCTAssertNotEqual(resolved.confidence, .certified)
    }

    func testRealRaneOneNameStillCertifiesDespiteSameManufacturer() {
        // Specific name evidence ("RANE ONE") restores full certified confidence.
        let identity = MIDIDeviceIdentity(sourceName: "RANE ONE", manufacturer: "RANE")
        let match = MIDIHardwareRegistry.shared.bestMatch(for: identity)
        XCTAssertEqual(match?.profile.identifier, "rane-one")
        XCTAssertEqual(match?.confidence, .certified)
        XCTAssertEqual(match?.matchedFragment, "rane one")
    }

    // MARK: - Unknown device → no certified match, unverified fallback

    func testUnknownDeviceHasNoRealMatch() {
        let identity = MIDIDeviceIdentity(sourceName: "Acme DJ 9000")
        XCTAssertNil(MIDIHardwareRegistry.shared.bestMatch(for: identity))
        XCTAssertTrue(MIDIHardwareRegistry.shared.matches(for: identity).isEmpty)
    }

    func testResolveFallsBackToUnverifiedForUnknownDevice() {
        let identity = MIDIDeviceIdentity(sourceName: "Acme DJ 9000")
        let resolved = MIDIHardwareRegistry.shared.resolve(for: identity)

        XCTAssertEqual(resolved.confidence, .unverified)
        XCTAssertNil(resolved.matchedFragment)
        XCTAssertEqual(resolved.profile.identifier, "unverified")
        XCTAssertEqual(resolved.profile.displayName, "Acme DJ 9000")
        XCTAssertTrue(resolved.profile.bindings.isEmpty)
    }

    func testResolveReturnsCertifiedForKnownDevice() {
        let resolved = MIDIHardwareRegistry.shared.resolve(for: MIDIDeviceIdentity(sourceName: "RANE ONE"))
        XCTAssertEqual(resolved.confidence, .certified)
        XCTAssertEqual(resolved.profile.identifier, "rane-one")
    }

    // MARK: - Ranking / confidence

    func testMatchesRankedByConfidenceThenSpecificity() {
        let certified = MIDIControllerProfile(
            identifier: "certified-rane",
            displayName: "Certified RANE",
            confidence: .certified,
            matching: MIDIProfileMatching(nameFragments: ["rane"]),
            deckCount: 2,
            bindings: []
        )
        let community = MIDIControllerProfile(
            identifier: "community-rane-one",
            displayName: "Community RANE ONE",
            confidence: .community,
            matching: MIDIProfileMatching(nameFragments: ["rane one"]),
            deckCount: 2,
            bindings: []
        )
        let registry = MIDIHardwareRegistry(profiles: [community, certified])
        let ranked = registry.matches(for: MIDIDeviceIdentity(sourceName: "RANE ONE"))

        // Certified outranks community even though community had the longer fragment.
        XCTAssertEqual(ranked.map(\.profile.identifier), ["certified-rane", "community-rane-one"])
        XCTAssertEqual(registry.bestMatch(for: MIDIDeviceIdentity(sourceName: "RANE ONE"))?.confidence, .certified)
    }

    func testLongerFragmentWinsWithinSameConfidence() {
        let broad = MIDIControllerProfile(
            identifier: "broad",
            displayName: "Broad",
            confidence: .community,
            matching: MIDIProfileMatching(nameFragments: ["rane"]),
            deckCount: 0,
            bindings: []
        )
        let specific = MIDIControllerProfile(
            identifier: "specific",
            displayName: "Specific",
            confidence: .community,
            matching: MIDIProfileMatching(nameFragments: ["rane one"]),
            deckCount: 0,
            bindings: []
        )
        let registry = MIDIHardwareRegistry(profiles: [broad, specific])
        let ranked = registry.matches(for: MIDIDeviceIdentity(sourceName: "RANE ONE"))
        XCTAssertEqual(ranked.first?.profile.identifier, "specific")
    }

    func testNameHitOutranksManufacturerOnlyHit() {
        // Profile A matches by manufacturer only (→ heuristic); profile B matches by a
        // specific name fragment (→ stays certified). B must rank first, deterministically.
        let mfrOnly = MIDIControllerProfile(
            identifier: "a-mfr-only",
            displayName: "Mfr Only",
            confidence: .certified,
            matching: MIDIProfileMatching(manufacturerFragments: ["acme"]),
            deckCount: 2,
            bindings: []
        )
        let nameHit = MIDIControllerProfile(
            identifier: "b-name-hit",
            displayName: "Name Hit",
            confidence: .certified,
            matching: MIDIProfileMatching(nameFragments: ["acme dj"]),
            deckCount: 2,
            bindings: []
        )
        let registry = MIDIHardwareRegistry(profiles: [mfrOnly, nameHit])
        let ranked = registry.matches(for: MIDIDeviceIdentity(sourceName: "ACME DJ 500", manufacturer: "ACME"))

        XCTAssertEqual(ranked.map(\.profile.identifier), ["b-name-hit", "a-mfr-only"])
        XCTAssertEqual(ranked.first?.confidence, .certified)   // name evidence
        XCTAssertEqual(ranked.last?.confidence, .heuristic)    // manufacturer-only, downgraded
    }

    func testConfidenceIsComparable() {
        XCTAssertGreaterThan(MIDIProfileConfidence.certified, .community)
        XCTAssertGreaterThan(MIDIProfileConfidence.community, .heuristic)
        XCTAssertGreaterThan(MIDIProfileConfidence.heuristic, .unverified)
    }

    // MARK: - Seed contents (verified RANE facts)

    func testRaneSeedCarriesVerifiedFacts() {
        let seed = MIDIControllerProfile.raneOneSeed
        XCTAssertEqual(seed.confidence, .certified)
        XCTAssertEqual(seed.deckCount, 2)

        // Platter = relative CC6 ring(128) per deck; not diagnostic-only.
        let platter = seed.binding(for: .platterMovement, deck: 0)
        XCTAssertEqual(platter?.signal, .relativeCC(number: 6, encoding: .ringCounter(modulus: 128)))
        XCTAssertEqual(platter?.ringModulus, 128)
        XCTAssertEqual(platter?.channel, 0)
        XCTAssertFalse(platter?.isDiagnosticOnly ?? true)

        // Crossfader = absolute CC8.
        XCTAssertEqual(seed.binding(for: .crossfader)?.signal, .absoluteCC(number: 8))

        // Pitch bend present but diagnostic-only.
        let bend = seed.binding(for: .platterAbsolute, deck: 0)
        XCTAssertEqual(bend?.signal, .pitchBend)
        XCTAssertTrue(bend?.isDiagnosticOnly ?? false)

        // Diagnostic bindings are excluded from verification.
        XCTAssertFalse(seed.verifiableBindings.contains { $0.isDiagnosticOnly })
    }

    // MARK: - Codable round-trip + fail-closed schema

    func testProfileCodableRoundtrip() throws {
        let original = MIDIControllerProfile.raneOneSeed
        let data = try JSONEncoder().encode(original)
        let decoded = try MIDIControllerProfile.decode(from: data)
        XCTAssertEqual(decoded, original)
    }

    func testUnknownSchemaVersionFailsClosed() throws {
        let future = MIDIControllerProfile(
            schemaVersion: MIDIControllerProfile.currentSchemaVersion + 1,
            identifier: "future",
            displayName: "Future Device",
            confidence: .community,
            matching: MIDIProfileMatching(nameFragments: ["future"]),
            deckCount: 1,
            bindings: []
        )
        let data = try JSONEncoder().encode(future)
        XCTAssertThrowsError(try MIDIControllerProfile.decode(from: data)) { error in
            XCTAssertEqual(
                error as? MIDIControllerProfileError,
                .unsupportedSchemaVersion(MIDIControllerProfile.currentSchemaVersion + 1)
            )
        }
    }

    func testSignalTypeCodableRoundtripAcrossCases() throws {
        let signals: [MIDIControlSignalType] = [
            .absoluteCC(number: 8),
            .relativeCC(number: 6, encoding: .ringCounter(modulus: 128)),
            .relativeCC(number: 7, encoding: .twosComplement),
            .pitchBend,
            .note(number: 36),
            .highResCCPair(msb: 31, lsb: 63),
            .nrpn(parameter: 1234),
            .rpn(parameter: 0),
            .universalPacket(statusHint: "midi2-cc")
        ]
        for signal in signals {
            let data = try JSONEncoder().encode(signal)
            XCTAssertEqual(try JSONDecoder().decode(MIDIControlSignalType.self, from: data), signal)
        }
    }
}
