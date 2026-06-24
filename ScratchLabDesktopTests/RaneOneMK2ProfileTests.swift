import XCTest
@testable import ScratchLab

/// Rane ONE MKII partial profile — synced to MIDIHardwareRegistry verified bindings.
/// All required safety and correctness tests.
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

    // MARK: - 9. Crossfader is CC8 on ch=15 (MIDI Monitor ch16)

    func testCrossfaderIsCC8OnChannel15() {
        guard let xf = profile.binding(roleKey: "crossfader") else {
            XCTFail("crossfader binding missing — verified CC8 ch=15")
            return
        }
        guard case .ccAbsolute7(let channel, let cc) = xf.primitive else {
            XCTFail("Crossfader binding must use ccAbsolute7 primitive, got: \(xf.primitive)")
            return
        }
        XCTAssertEqual(cc, 8, "Crossfader must be CC8")
        XCTAssertEqual(channel, 15, "Crossfader must be ch=15 (MIDI Monitor ch16) — confirmed via isolated capture 2026-06-25")
    }

    // MARK: - 10. Channel volume candidates exist for both decks

    func testChannelVolumeCandidatesExist() {
        let volBindings = profile.bindings.filter { $0.roleKey == "channelVolume" }
        XCTAssertGreaterThanOrEqual(volBindings.count, 2,
            "At least two channelVolume bindings required (deck 1 and deck 2)")
        // Both must be CC28
        for binding in volBindings {
            if case .ccAbsolute7(_, let cc) = binding.primitive {
                XCTAssertEqual(cc, 28, "Channel volume fader must be CC28")
            } else {
                XCTFail("channelVolume binding must use ccAbsolute7, got: \(binding.primitive)")
            }
        }
        // Left deck: ch=0, right deck: ch=1
        let leftBinding = volBindings.first(where: { $0.deck == 1 })
        let rightBinding = volBindings.first(where: { $0.deck == 2 })
        XCTAssertNotNil(leftBinding, "Left deck channel volume binding missing")
        XCTAssertNotNil(rightBinding, "Right deck channel volume binding missing")
        if case .ccAbsolute7(let ch, _) = leftBinding?.primitive {
            XCTAssertEqual(ch, 0, "Left channel fader must be ch=0 (MIDI Monitor ch1)")
        }
        if case .ccAbsolute7(let ch, _) = rightBinding?.primitive {
            XCTAssertEqual(ch, 1, "Right channel fader must be ch=1 (MIDI Monitor ch2)")
        }
    }

    // MARK: - 11. Both pitch/tempo faders are 14-bit high-res pairs (CC9+CC41)

    func testBothPitchTempoFadersAre14BitPairs() {
        let pitchBindings = profile.bindings.filter { $0.roleKey == "pitchRaw14" }
        XCTAssertEqual(pitchBindings.count, 2,
            "Both decks must have pitchRaw14 bindings — left confirmed early, right confirmed via re-capture 2026-06-25")

        for binding in pitchBindings {
            guard case .cc14(let channel, let msbCC, let lsbCC) = binding.primitive else {
                XCTFail("pitchRaw14 must use cc14 primitive, got: \(binding.primitive)")
                continue
            }
            XCTAssertEqual(msbCC, 9, "Pitch MSB must be CC9")
            XCTAssertEqual(lsbCC, 41, "Pitch LSB must be CC41")
            // Left deck = ch=0, right deck = ch=1
            if binding.deck == 1 {
                XCTAssertEqual(channel, 0, "Left pitch must be ch=0 (MIDI Monitor ch1)")
            } else if binding.deck == 2 {
                XCTAssertEqual(channel, 1, "Right pitch must be ch=1 (MIDI Monitor ch2)")
            }
        }
    }

    // MARK: - 12. No speedCandidate bindings remain (all upgraded to pitchRaw14)

    func testNoSpeedCandidateBindingsRemain() {
        let speedBindings = profile.bindings.filter { $0.roleKey == "speedCandidate" }
        XCTAssertTrue(speedBindings.isEmpty,
            "No speedCandidate bindings should remain — right deck upgraded to pitchRaw14 14-bit pair via verified re-capture 2026-06-25. Found: \(speedBindings.map { String(describing: $0.primitive) })")
    }

    // MARK: - 13. Transport Start/Stop bindings exist for both decks

    func testTransportStartStopBindingsExist() {
        let transportBindings = profile.bindings.filter { $0.roleKey == "playPause" }
        XCTAssertEqual(transportBindings.count, 2,
            "Two playPause bindings required (left and right Start/Stop ▶⏸)")

        let leftBinding = transportBindings.first(where: { $0.deck == 1 })
        let rightBinding = transportBindings.first(where: { $0.deck == 2 })
        XCTAssertNotNil(leftBinding, "Left Start/Stop missing")
        XCTAssertNotNil(rightBinding, "Right Start/Stop missing")

        // Left: ch=0 note=0
        if case .noteMomentary(let ch, let note, let onVal, let offVal) = leftBinding?.primitive {
            XCTAssertEqual(ch, 0, "Left Start/Stop must be ch=0 (MIDI Monitor ch1)")
            XCTAssertEqual(note, 0, "Left Start/Stop must be note=0")
            XCTAssertEqual(onVal, 127, "Note On velocity must be 127")
            XCTAssertEqual(offVal, 0, "Note Off velocity must be 0")
        } else {
            XCTFail("Left Start/Stop must use noteMomentary, got: \(String(describing: leftBinding?.primitive))")
        }

        // Right: ch=1 note=0
        if case .noteMomentary(let ch, let note, let onVal, let offVal) = rightBinding?.primitive {
            XCTAssertEqual(ch, 1, "Right Start/Stop must be ch=1 (MIDI Monitor ch2)")
            XCTAssertEqual(note, 0, "Right Start/Stop must be note=0")
            XCTAssertEqual(onVal, 127, "Note On velocity must be 127")
            XCTAssertEqual(offVal, 0, "Note Off velocity must be 0")
        } else {
            XCTFail("Right Start/Stop must use noteMomentary, got: \(String(describing: rightBinding?.primitive))")
        }
    }

    // MARK: - 14. SYNC binding exists (ch=1 note=2)

    func testSyncBindingExists() {
        guard let syncBinding = profile.binding(roleKey: "sync") else {
            XCTFail("SYNC binding missing — verified via isolated capture 2026-06-25")
            return
        }
        guard case .noteMomentary(let ch, let note, let onVal, let offVal) = syncBinding.primitive else {
            XCTFail("SYNC must use noteMomentary, got: \(syncBinding.primitive)")
            return
        }
        XCTAssertEqual(ch, 1, "SYNC must be ch=1 (MIDI Monitor ch2)")
        XCTAssertEqual(note, 2, "SYNC must be note=2")
        XCTAssertEqual(onVal, 127, "Note On velocity must be 127")
        XCTAssertEqual(offVal, 0, "Note Off velocity must be 0")
    }

    // MARK: - 15. Headphone PFL cue bindings exist for both decks

    func testHeadphonePFLCueBindingsExist() {
        let pflBindings = profile.bindings.filter { $0.roleKey == "headphoneCue" }
        XCTAssertEqual(pflBindings.count, 2,
            "Two headphoneCue bindings required (left and right PFL)")

        let leftBinding = pflBindings.first(where: { $0.deck == 1 })
        let rightBinding = pflBindings.first(where: { $0.deck == 2 })
        XCTAssertNotNil(leftBinding, "Left PFL missing")
        XCTAssertNotNil(rightBinding, "Right PFL missing")

        // Left: ch=0 note=27
        if case .noteMomentary(let ch, let note, _, _) = leftBinding?.primitive {
            XCTAssertEqual(ch, 0, "Left PFL must be ch=0 (MIDI Monitor ch1)")
            XCTAssertEqual(note, 27, "Left PFL must be note=27")
        } else {
            XCTFail("Left PFL must use noteMomentary, got: \(String(describing: leftBinding?.primitive))")
        }

        // Right: ch=1 note=27
        if case .noteMomentary(let ch, let note, _, _) = rightBinding?.primitive {
            XCTAssertEqual(ch, 1, "Right PFL must be ch=1 (MIDI Monitor ch2)")
            XCTAssertEqual(note, 27, "Right PFL must be note=27")
        } else {
            XCTFail("Right PFL must use noteMomentary, got: \(String(describing: rightBinding?.primitive))")
        }
    }

    // MARK: - 16. Note 27 is disambiguated: PFL on ch=0/ch=1, pad 8 on ch=4/ch=5

    func testNote27IsDisambiguatedByChannel() {
        // Pad 8 uses note 27 on pad channels
        let leftPad8 = profile.bindings.first { $0.roleKey == "leftDeckPad8" }
        let rightPad8 = profile.bindings.first { $0.roleKey == "rightDeckPad8" }
        XCTAssertNotNil(leftPad8, "Left pad 8 missing")
        XCTAssertNotNil(rightPad8, "Right pad 8 missing")

        // PFL uses note 27 on continuous channels
        let leftPFL = profile.bindings.first { $0.roleKey == "headphoneCue" && $0.deck == 1 }
        let rightPFL = profile.bindings.first { $0.roleKey == "headphoneCue" && $0.deck == 2 }
        XCTAssertNotNil(leftPFL, "Left PFL missing")
        XCTAssertNotNil(rightPFL, "Right PFL missing")

        // Both use note 27
        var padChannels = Set<UInt8>()
        var pflChannels = Set<UInt8>()

        for binding in [leftPad8, rightPad8].compactMap({ $0 }) {
            if case .noteMomentary(let ch, let note, _, _) = binding.primitive {
                XCTAssertEqual(note, 27, "Pad 8 must be note 27")
                padChannels.insert(ch)
            }
        }
        for binding in [leftPFL, rightPFL].compactMap({ $0 }) {
            if case .noteMomentary(let ch, let note, _, _) = binding.primitive {
                XCTAssertEqual(note, 27, "PFL must be note 27")
                pflChannels.insert(ch)
            }
        }

        // Channels must not overlap — pad 8 uses ch=4+ch=5, PFL uses ch=0+ch=1
        XCTAssertEqual(padChannels, [4, 5], "Pad 8 must use ch=4 and ch=5")
        XCTAssertEqual(pflChannels, [0, 1], "PFL must use ch=0 and ch=1")
        XCTAssertTrue(padChannels.isDisjoint(with: pflChannels),
            "Pad 8 (ch=\(padChannels)) and PFL (ch=\(pflChannels)) must not share channels")
    }

    // MARK: - 17. Pads are all Note On/Off (no CC-based pad bindings remain)

    func testPadsUseNoteMomentaryNotCC() {
        let padRoleKeys: Set<String> = [
            "leftDeckPad1", "leftDeckPad2", "leftDeckPad3", "leftDeckPad4",
            "leftDeckPad5", "leftDeckPad6", "leftDeckPad7", "leftDeckPad8",
            "rightDeckPad1", "rightDeckPad2", "rightDeckPad3", "rightDeckPad4",
            "rightDeckPad5", "rightDeckPad6", "rightDeckPad7", "rightDeckPad8",
        ]
        let padBindings = profile.bindings.filter { padRoleKeys.contains($0.roleKey) }
        XCTAssertEqual(padBindings.count, 16, "All 16 pads must be present")

        for binding in padBindings {
            guard case .noteMomentary = binding.primitive else {
                XCTFail("\(binding.roleKey) must use noteMomentary primitive — CC-based djay pad mapping is superseded. Got: \(binding.primitive)")
                return
            }
        }
    }

    // MARK: - 18. EQ/gain bindings use correct CC numbers and channels

    func testEQGainBindingsCorrect() {
        let lhs = profile.bindings.filter { $0.physicalSide == "left" }
        let rhs = profile.bindings.filter { $0.physicalSide == "right" }

        // Left deck EQ/gain
        let leftEQ: [(String, UInt8, UInt8)] = [
            ("eqBassRaw", 0, 25),
            ("eqMidRaw", 0, 24),
            ("eqHighsRaw", 0, 23),
            ("gainRaw", 0, 22),
        ]
        for (roleKey, expectedCh, expectedCC) in leftEQ {
            guard let b = lhs.first(where: { $0.roleKey == roleKey }) else {
                XCTFail("Left \(roleKey) missing")
                continue
            }
            guard case .ccAbsolute7(let ch, let cc) = b.primitive else {
                XCTFail("Left \(roleKey) must use ccAbsolute7, got: \(b.primitive)")
                continue
            }
            XCTAssertEqual(ch, expectedCh, "Left \(roleKey) channel")
            XCTAssertEqual(cc, expectedCC, "Left \(roleKey) CC")
        }

        // Right deck EQ/gain
        let rightEQ: [(String, UInt8, UInt8)] = [
            ("eqBassRaw", 1, 25),
            ("eqMidRaw", 1, 24),
            ("eqHighsRaw", 1, 23),
            ("gainRaw", 1, 22),
        ]
        for (roleKey, expectedCh, expectedCC) in rightEQ {
            guard let b = rhs.first(where: { $0.roleKey == roleKey }) else {
                XCTFail("Right \(roleKey) missing")
                continue
            }
            guard case .ccAbsolute7(let ch, let cc) = b.primitive else {
                XCTFail("Right \(roleKey) must use ccAbsolute7, got: \(b.primitive)")
                continue
            }
            XCTAssertEqual(ch, expectedCh, "Right \(roleKey) channel")
            XCTAssertEqual(cc, expectedCC, "Right \(roleKey) CC")
        }
    }

    // MARK: - 19. No "not yet captured" assumptions remain for verified controls

    func testNoStaleNotYetCapturedAssumptions() {
        let verifiedControls = [
            "right channel fader", "right pitch/tempo fader", "play/pause",
            "cue", "crossfader full sweep", "right platter",
        ]
        for term in verifiedControls {
            let hasStale = profile.assumptions.contains { $0.lowercased().contains(term.lowercased()) && $0.lowercased().contains("not yet captured") }
            XCTAssertFalse(hasStale,
                "Assumption 'not yet captured' for '\(term)' is stale — this control was verified in 2026-06-25 re-captures")
        }
    }

    // MARK: - 20. Loop/FX/load/shift are marked out of current milestone

    func testOutOfMilestoneControlsExplicitlyExcluded() {
        let outOfMilestoneTerms = ["loop", "fx", "load", "shift", "browser", "deck select"]
        let hasExclusion = profile.assumptions.contains { assumption in
            let lower = assumption.lowercased()
            return lower.contains("out of current milestone") || lower.contains("intentionally out")
        }
        XCTAssertTrue(hasExclusion,
            "Assumptions must explicitly mark loop/FX/browser/load/shift as intentionally out of current milestone")
    }

    // MARK: - 21. Scoring ignores unverified Rane ONE MK2 input

    func testScoringIgnoresUnverifiedRaneOneMK2() {
        XCTAssertFalse(profile.canFeedScoringBeforeVerification,
            "Rane ONE MK2 must not feed scoring before live verification")
        XCTAssertTrue(profile.verificationRequired,
            "verificationRequired must block scoring until live verification completes")
        let result = ControllerAutoDetector.resolve(endpointName: "Rane ONE MKII", in: catalog)
        XCTAssertEqual(result?.requiresVerification, true,
            "Detection result for Rane ONE MKII must report requiresVerification = true")
    }
}
