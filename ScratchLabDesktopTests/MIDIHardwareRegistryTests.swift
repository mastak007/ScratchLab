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

    // MARK: - Rane ONE MKII pad bindings (confirmed hardware capture)

    func testRaneSeedHasSixteenPadBindings() {
        let seed = MIDIControllerProfile.raneOneSeed
        let padBindings = seed.bindings.filter { $0.role.kind == .pad }
        XCTAssertEqual(padBindings.count, 16, "raneOneSeed must have 8 left + 8 right = 16 pad bindings")
    }

    func testRaneSeedHasEightLeftDeckPadBindings() {
        let seed = MIDIControllerProfile.raneOneSeed
        let left = seed.bindings.filter { $0.role.kind == .pad && $0.role.deck == 0 }
        XCTAssertEqual(left.count, 8, "8 left deck pads (deck 0)")
    }

    func testRaneSeedHasEightRightDeckPadBindings() {
        let seed = MIDIControllerProfile.raneOneSeed
        let right = seed.bindings.filter { $0.role.kind == .pad && $0.role.deck == 1 }
        XCTAssertEqual(right.count, 8, "8 right deck pads (deck 1)")
    }

    // Left deck pads: ch5 (MIDI Monitor) = ch=4 (0-indexed), notes 20–27.
    func testLeftDeckPad1IsNoteCh4Note20() {
        let seed = MIDIControllerProfile.raneOneSeed
        let pad = seed.bindings.first { $0.role.label == "Left Deck Pad 1" }
        XCTAssertNotNil(pad)
        XCTAssertEqual(pad?.signal, .note(number: 20), "Left Deck Pad 1 must be note 20, not CC")
        XCTAssertEqual(pad?.channel, 4, "Left deck pads must be on ch=4 (ch5 in MIDI Monitor)")
        XCTAssertEqual(pad?.role.deck, 0, "Left deck pads must carry deck=0")
        XCTAssertFalse(pad?.isDiagnosticOnly ?? true)
    }

    func testLeftDeckPad8IsNoteCh4Note27() {
        let seed = MIDIControllerProfile.raneOneSeed
        let pad = seed.bindings.first { $0.role.label == "Left Deck Pad 8" }
        XCTAssertNotNil(pad)
        XCTAssertEqual(pad?.signal, .note(number: 27))
        XCTAssertEqual(pad?.channel, 4)
    }

    func testLeftDeckPadsCoversNotes20Through27() {
        let seed = MIDIControllerProfile.raneOneSeed
        let leftPads = seed.bindings.filter { $0.role.kind == .pad && $0.role.deck == 0 }
        let noteNumbers = leftPads.compactMap { binding -> Int? in
            if case .note(let n) = binding.signal { return n }
            return nil
        }.sorted()
        XCTAssertEqual(noteNumbers, Array(20...27), "Left deck pads must cover notes 20–27 in order")
    }

    func testLeftDeckPadsAreAllOnChannel4() {
        let seed = MIDIControllerProfile.raneOneSeed
        let leftPads = seed.bindings.filter { $0.role.kind == .pad && $0.role.deck == 0 }
        for pad in leftPads {
            XCTAssertEqual(pad.channel, 4, "All left deck pads must be on ch=4 (ch5 MIDI Monitor)")
        }
    }

    // Right deck pads: ch6 (MIDI Monitor) = ch=5 (0-indexed), notes 20–27.
    func testRightDeckPad1IsNoteCh5Note20() {
        let seed = MIDIControllerProfile.raneOneSeed
        let pad = seed.bindings.first { $0.role.label == "Right Deck Pad 1" }
        XCTAssertNotNil(pad)
        XCTAssertEqual(pad?.signal, .note(number: 20))
        XCTAssertEqual(pad?.channel, 5, "Right deck pads must be on ch=5 (ch6 in MIDI Monitor)")
        XCTAssertEqual(pad?.role.deck, 1, "Right deck pads must carry deck=1")
        XCTAssertFalse(pad?.isDiagnosticOnly ?? true)
    }

    func testRightDeckPad8IsNoteCh5Note27() {
        let seed = MIDIControllerProfile.raneOneSeed
        let pad = seed.bindings.first { $0.role.label == "Right Deck Pad 8" }
        XCTAssertNotNil(pad)
        XCTAssertEqual(pad?.signal, .note(number: 27))
        XCTAssertEqual(pad?.channel, 5)
    }

    func testRightDeckPadsCoversNotes20Through27() {
        let seed = MIDIControllerProfile.raneOneSeed
        let rightPads = seed.bindings.filter { $0.role.kind == .pad && $0.role.deck == 1 }
        let noteNumbers = rightPads.compactMap { binding -> Int? in
            if case .note(let n) = binding.signal { return n }
            return nil
        }.sorted()
        XCTAssertEqual(noteNumbers, Array(20...27), "Right deck pads must cover notes 20–27 in order")
    }

    func testRightDeckPadsAreAllOnChannel5() {
        let seed = MIDIControllerProfile.raneOneSeed
        let rightPads = seed.bindings.filter { $0.role.kind == .pad && $0.role.deck == 1 }
        for pad in rightPads {
            XCTAssertEqual(pad.channel, 5, "All right deck pads must be on ch=5 (ch6 MIDI Monitor)")
        }
    }

    func testLeftAndRightDeckPadChannelsAreNotSwapped() {
        let seed = MIDIControllerProfile.raneOneSeed
        let leftPads = seed.bindings.filter { $0.role.kind == .pad && $0.role.deck == 0 }
        let rightPads = seed.bindings.filter { $0.role.kind == .pad && $0.role.deck == 1 }
        XCTAssertTrue(leftPads.allSatisfy { $0.channel == 4 },
            "Left deck pads must all be on ch=4 (not ch=5)")
        XCTAssertTrue(rightPads.allSatisfy { $0.channel == 5 },
            "Right deck pads must all be on ch=5 (not ch=4)")
    }

    func testNoteOnVelocityMatchesPadPressForLeftDeck() {
        // Note On ch5 (ch=4) note20 vel127 = Left Deck Pad 1 press.
        let noteOn = MIDIMessageParsing.parse([0x90 | 4, 20, 127])
        let seed = MIDIControllerProfile.raneOneSeed
        let pad1 = seed.bindings.first { $0.role.label == "Left Deck Pad 1" }!
        XCTAssertTrue(pad1.matches(noteOn), "Left Deck Pad 1 must match Note On ch5 note20")
    }

    func testNoteOffMatchesPadReleaseForLeftDeck() {
        let noteOff = MIDIMessageParsing.parse([0x80 | 4, 20, 0])
        let seed = MIDIControllerProfile.raneOneSeed
        let pad1 = seed.bindings.first { $0.role.label == "Left Deck Pad 1" }!
        XCTAssertTrue(pad1.matches(noteOff), "Left Deck Pad 1 must match Note Off ch5 note20")
    }

    func testNoteOnVelocityMatchesPadPressForRightDeck() {
        let noteOn = MIDIMessageParsing.parse([0x90 | 5, 20, 127])
        let seed = MIDIControllerProfile.raneOneSeed
        let pad1 = seed.bindings.first { $0.role.label == "Right Deck Pad 1" }!
        XCTAssertTrue(pad1.matches(noteOn), "Right Deck Pad 1 must match Note On ch6 note20")
    }

    func testNoteOffMatchesPadReleaseForRightDeck() {
        let noteOff = MIDIMessageParsing.parse([0x80 | 5, 20, 0])
        let seed = MIDIControllerProfile.raneOneSeed
        let pad1 = seed.bindings.first { $0.role.label == "Right Deck Pad 1" }!
        XCTAssertTrue(pad1.matches(noteOff), "Right Deck Pad 1 must match Note Off ch6 note20")
    }

    func testPadBindingsAreNoteNotCC() {
        let seed = MIDIControllerProfile.raneOneSeed
        // CC on ch=4 or ch=5 note20 must NOT match pad bindings.
        let ccLeft = MIDIMessageParsing.parse([0xB0 | 4, 20, 127])
        let ccRight = MIDIMessageParsing.parse([0xB0 | 5, 20, 127])
        let padBindings = seed.bindings.filter { $0.role.kind == .pad }
        XCTAssertFalse(padBindings.contains { $0.matches(ccLeft) },
            "CC message must not match any pad binding (pads are Note On/Off)")
        XCTAssertFalse(padBindings.contains { $0.matches(ccRight) },
            "CC message must not match any pad binding")
    }

    func testLeftDeckPadDoesNotMatchRightDeckChannel() {
        // Note On on ch=5 (right deck) must not match left deck pad (ch=4).
        let rightNote = MIDIMessageParsing.parse([0x90 | 5, 20, 127])
        let seed = MIDIControllerProfile.raneOneSeed
        let leftPad1 = seed.bindings.first { $0.role.label == "Left Deck Pad 1" }!
        XCTAssertFalse(leftPad1.matches(rightNote),
            "Left Deck Pad 1 (ch=4) must not match Note On on ch=5 (right deck)")
    }

    func testRightDeckPadDoesNotMatchLeftDeckChannel() {
        // Note On on ch=4 (left deck) must not match right deck pad (ch=5).
        let leftNote = MIDIMessageParsing.parse([0x90 | 4, 20, 127])
        let seed = MIDIControllerProfile.raneOneSeed
        let rightPad1 = seed.bindings.first { $0.role.label == "Right Deck Pad 1" }!
        XCTAssertFalse(rightPad1.matches(leftNote),
            "Right Deck Pad 1 (ch=5) must not match Note On on ch=4 (left deck)")
    }

    func testUnmappedNotesDoNotMatchAnyPadBinding() {
        // Note 19 (below pad range) and note 28 (above pad range) must not match.
        let note19 = MIDIMessageParsing.parse([0x90 | 4, 19, 127])
        let note28 = MIDIMessageParsing.parse([0x90 | 5, 28, 127])
        let seed = MIDIControllerProfile.raneOneSeed
        let pads = seed.bindings.filter { $0.role.kind == .pad }
        XCTAssertFalse(pads.contains { $0.matches(note19) }, "Note 19 must not match any pad")
        XCTAssertFalse(pads.contains { $0.matches(note28) }, "Note 28 must not match any pad")
    }

    func testAllPadBindingsAreVerifiable() {
        let seed = MIDIControllerProfile.raneOneSeed
        let verifiable = seed.verifiableBindings
        let padCount = verifiable.filter { $0.role.kind == .pad }.count
        XCTAssertEqual(padCount, 16, "All 16 pad bindings must be verifiable (not diagnostic-only)")
    }

    // MARK: - Rane ONE MKII EQ/gain raw bindings

    func testRaneSeedHasFourLeftEQGainRawBindings() {
        let seed = MIDIControllerProfile.raneOneSeed
        let leftRaw = seed.bindings.filter { $0.role.kind == .unknown && $0.role.deck == 0 }
        XCTAssertEqual(leftRaw.count, 4, "4 left deck EQ/gain raw bindings (CC22-25 ch=0)")
    }

    func testRaneSeedHasFourRightEQGainRawBindings() {
        let seed = MIDIControllerProfile.raneOneSeed
        let rightRaw = seed.bindings.filter { $0.role.kind == .unknown && $0.role.deck == 1 }
        XCTAssertEqual(rightRaw.count, 4, "4 right deck EQ/gain raw bindings (CC22-25 ch=1)")
    }

    func testLeftEQGainRawControlsAreCC22to25OnChannel0() {
        let seed = MIDIControllerProfile.raneOneSeed
        let leftRaw = seed.bindings.filter { $0.role.kind == .unknown && $0.role.deck == 0 }
        let ccs = leftRaw.compactMap { b -> Int? in
            if case .absoluteCC(let n) = b.signal { return n }
            return nil
        }.sorted()
        XCTAssertEqual(ccs, [22, 23, 24, 25], "Left EQ/gain must be CC22-25")
        XCTAssertTrue(leftRaw.allSatisfy { $0.channel == 0 },
            "Left EQ/gain must be on ch=0 (ch1 MIDI Monitor)")
    }

    func testRightEQGainRawControlsAreCC22to25OnChannel1() {
        let seed = MIDIControllerProfile.raneOneSeed
        let rightRaw = seed.bindings.filter { $0.role.kind == .unknown && $0.role.deck == 1 }
        let ccs = rightRaw.compactMap { b -> Int? in
            if case .absoluteCC(let n) = b.signal { return n }
            return nil
        }.sorted()
        XCTAssertEqual(ccs, [22, 23, 24, 25], "Right EQ/gain must be CC22-25")
        XCTAssertTrue(rightRaw.allSatisfy { $0.channel == 1 },
            "Right EQ/gain must be on ch=1 (ch2 MIDI Monitor)")
    }

    func testLeftBassEQIsCC25AndMatchesCCMessage() {
        let seed = MIDIControllerProfile.raneOneSeed
        let bassBinding = seed.bindings.first { $0.role.label == "Left Bass EQ" }
        XCTAssertNotNil(bassBinding, "Must have Left Bass EQ binding")
        XCTAssertEqual(bassBinding?.signal, .absoluteCC(number: 25))
        XCTAssertEqual(bassBinding?.channel, 0)
        // Verify it matches a CC25 message on ch=0.
        let ccMsg = MIDIMessageParsing.parse([0xB0 | 0, 25, 64])
        XCTAssertTrue(bassBinding?.matches(ccMsg) ?? false)
    }

    func testRightGainIsCC22OnChannel1() {
        let seed = MIDIControllerProfile.raneOneSeed
        let gainBinding = seed.bindings.first { $0.role.label == "Right Gain" }
        XCTAssertNotNil(gainBinding)
        XCTAssertEqual(gainBinding?.signal, .absoluteCC(number: 22))
        XCTAssertEqual(gainBinding?.channel, 1)
    }

    // MARK: - Rane ONE MKII channel fader + pitch pair

    func testRaneSeedHasLeftChannelFaderBinding() {
        let seed = MIDIControllerProfile.raneOneSeed
        let fader = seed.bindings.first { $0.role.kind == .channelFader && $0.role.deck == 0 }
        XCTAssertNotNil(fader, "Must have a left channel fader binding")
        XCTAssertEqual(fader?.signal, .absoluteCC(number: 28), "Left channel fader is CC28")
        XCTAssertEqual(fader?.channel, 0, "Left channel fader is on ch=0 (ch1 MIDI Monitor)")
    }

    func testRaneSeedHasLeftPitchHighResPairBinding() {
        let seed = MIDIControllerProfile.raneOneSeed
        let pitch = seed.bindings.first { $0.role.kind == .tempo && $0.role.deck == 0 }
        XCTAssertNotNil(pitch, "Must have a left pitch/tempo 14-bit binding")
        XCTAssertEqual(pitch?.signal, .highResCCPair(msb: 9, lsb: 41),
            "Left pitch fader must be CC9 (MSB) + CC41 (LSB)")
        XCTAssertEqual(pitch?.channel, 0)
    }

    func testLeftPitchBindingMatchesCC9OnChannel0() {
        let seed = MIDIControllerProfile.raneOneSeed
        let pitch = seed.bindings.first { $0.role.kind == .tempo && $0.role.deck == 0 }!
        let cc9 = MIDIMessageParsing.parse([0xB0 | 0, 9, 64])
        let cc41 = MIDIMessageParsing.parse([0xB0 | 0, 41, 0])
        XCTAssertTrue(pitch.matches(cc9), "Pitch binding must match CC9 on ch=0 (MSB)")
        XCTAssertTrue(pitch.matches(cc41), "Pitch binding must match CC41 on ch=0 (LSB)")
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
