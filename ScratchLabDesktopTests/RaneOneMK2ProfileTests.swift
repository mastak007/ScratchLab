import XCTest
@testable import ScratchLab

/// Rane ONE MKII partial profile — sourced from djay Pro MIDI mapping archive.
/// All 12 required safety and correctness tests.
final class RaneOneMK2ProfileTests: XCTestCase {

    private let catalog = ControllerProfileCatalog.shared

    private var profile: ControllerProfile {
        guard let p = catalog.partialProfiles.first(where: { $0.id == "rane.one-mkii" }) else {
            fatalError("rane.one-mkii not in partialProfiles — check catalog wiring")
        }
        return p
    }

    // MARK: - 1. Endpoint detection: "Rane ONE MKII"

    func testRaneONEMKIIEndpointDetectsRaneOneMkii() {
        let result = ControllerAutoDetector.resolve(endpointName: "Rane ONE MKII", in: catalog)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.profile.id, "rane.one-mkii")
    }

    // MARK: - 2. Endpoint detection: "Rane ONE MK2"

    func testRaneONEMK2EndpointDetectsRaneOneMkii() {
        let result = ControllerAutoDetector.resolve(endpointName: "Rane ONE MK2", in: catalog)
        XCTAssertNotNil(result, "Match name 'Rane ONE MK2' must be registered")
        XCTAssertEqual(result?.profile.id, "rane.one-mkii")
    }

    // MARK: - 3. Public display family

    func testPublicFamilyIsMotorizedPlatterController() {
        XCTAssertEqual(profile.publicDisplayFamily, "Motorized Platter Controller")
    }

    // MARK: - 4. Profile is partial, not complete

    func testMappingStatusIsPartialNotComplete() {
        XCTAssertEqual(profile.mappingStatus, .partial)
        XCTAssertNotEqual(profile.mappingStatus, .complete)
    }

    // MARK: - 5. verificationRequired == true

    func testVerificationRequired() {
        XCTAssertTrue(profile.verificationRequired)
    }

    // MARK: - 6. canFeedScoringBeforeVerification == false

    func testCannotFeedScoringBeforeVerification() {
        XCTAssertFalse(profile.canFeedScoringBeforeVerification)
    }

    // MARK: - 7. No guessed platter mapping exists

    func testNoGuessedPlatterMapping() {
        let platterRoles: Set<String> = ["platterTop", "platterMovement", "platterDelta", "jogScratch"]
        let platterBindings = profile.bindings.filter { platterRoles.contains($0.roleKey) }
        XCTAssertTrue(platterBindings.isEmpty,
            "No platter/scratch-motion binding may exist before live verification: \(platterBindings.map(\.roleKey))")
    }

    // MARK: - 8. No DDJ-FLX10 jog CC mapping (CC 0x22 relativeSignedOffset64)

    func testNoDDJFLX10JogCCMapping() {
        let ddj_jog_cc = UInt8(0x22)
        let hasJogCC = profile.bindings.contains { binding in
            if case .relativeSignedOffset64(_, let cc) = binding.primitive {
                return cc == ddj_jog_cc
            }
            return false
        }
        XCTAssertFalse(hasJogCC,
            "Rane ONE MKII must not reuse DDJ-FLX10 jog CC 0x22 (relativeSignedOffset64)")
    }

    // MARK: - 9. Crossfader candidate exists from uploaded djay mapping

    func testCrossfaderCandidateExistsFromDjayMapping() {
        guard let xf = profile.binding(roleKey: "crossfader") else {
            XCTFail("crossfader binding missing — djay mapping provides mixer.crossfade CC8")
            return
        }
        // djay mapping: CC8, ch=15
        if case .ccAbsolute7(_, let cc) = xf.primitive {
            XCTAssertEqual(cc, 8, "Crossfader must be CC8 (confirmed in djay mapping and MIDIHardwareRegistry)")
        } else {
            XCTFail("Crossfader binding must use ccAbsolute7 primitive, got: \(xf.primitive)")
        }
    }

    // MARK: - 10. Channel volume candidates exist

    func testChannelVolumeCandidatesExist() {
        let volBindings = profile.bindings.filter { $0.roleKey == "channelVolume" }
        XCTAssertGreaterThanOrEqual(volBindings.count, 2,
            "At least two channelVolume bindings required (deck 1 and deck 2 from djay mapping)")
        // Both must be CC28
        for binding in volBindings {
            if case .ccAbsolute7(_, let cc) = binding.primitive {
                XCTAssertEqual(cc, 28, "Channel volume fader must be CC28 per djay mapping")
            } else {
                XCTFail("channelVolume binding must use ccAbsolute7, got: \(binding.primitive)")
            }
        }
    }

    // MARK: - 11. Speed candidates are metadata/verification candidates only — not platter delta

    func testSpeedCandidatesAreMetadataOnly() {
        let speedBindings = profile.bindings.filter { $0.roleKey == "speedCandidate" }
        // Left deck pitch has been upgraded to confirmed pitchRaw14 (CC9+CC41 14-bit pair).
        // Right deck pitch is still an unverified djay candidate → only one speedCandidate expected.
        XCTAssertGreaterThanOrEqual(speedBindings.count, 1,
            "Speed candidate must exist for right deck (turntable.speed from djay mapping; left upgraded to pitchRaw14)")

        // Must NOT use CC6 — that's the verified platter ring counter in MIDIHardwareRegistry
        for binding in speedBindings {
            if case .ccAbsolute7(_, let cc) = binding.primitive {
                XCTAssertNotEqual(cc, 6,
                    "speedCandidate must not use CC6 — CC6 is the verified platter ring counter")
            }
        }

        // Must NOT use the relativeSignedOffset64 primitive — that's for real platter deltas
        for binding in speedBindings {
            if case .relativeSignedOffset64 = binding.primitive {
                XCTFail("speedCandidate must not use relativeSignedOffset64 — that encodes platter deltas")
            }
        }
    }

    // MARK: - 12. Scoring ignores unverified Rane ONE MK2 input

    func testScoringIgnoresUnverifiedRaneOneMK2() {
        // Pre-verification: canFeedScoringBeforeVerification must be false
        XCTAssertFalse(profile.canFeedScoringBeforeVerification,
            "Rane ONE MK2 must not feed scoring before live verification")

        // Profile is partial — canFeedScoringAfterVerification would be true after verification,
        // but the verificationRequired gate prevents it being used before verification
        XCTAssertTrue(profile.verificationRequired,
            "verificationRequired must block scoring until live verification completes")

        // Detection result must also carry the verification requirement
        let result = ControllerAutoDetector.resolve(endpointName: "Rane ONE MKII", in: catalog)
        XCTAssertEqual(result?.requiresVerification, true,
            "Detection result for Rane ONE MKII must report requiresVerification = true")
    }
}
