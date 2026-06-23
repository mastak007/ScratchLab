import XCTest
@testable import ScratchLab

final class DDJFlx10ProfileTests: XCTestCase {

    private let profile = ControllerProfile.ddj_flx10

    // MARK: - Profile identity

    func testProfileIdentity() {
        XCTAssertEqual(profile.id, "alphatheta.ddj-flx10")
        XCTAssertEqual(profile.publicDisplayFamily, "4-Channel Performance Controller")
        XCTAssertEqual(profile.mappingStatus, .complete)
        XCTAssertEqual(profile.sourceConfidence, .highOfficial)
        XCTAssertTrue(profile.verificationRequired)
    }

    func testPublicFamilyIsNotBrandFacing() {
        XCTAssertFalse(profile.publicDisplayFamily.contains("Pioneer"))
        XCTAssertFalse(profile.publicDisplayFamily.contains("AlphaTheta"))
        XCTAssertFalse(profile.publicDisplayFamily.contains("Mode"))
    }

    // MARK: - Match names

    func testMatchesEndpointNameDDJFLX10() {
        XCTAssertTrue(profile.matches(endpointName: "DDJ-FLX10"))
    }

    func testMatchesPioneerPrefix() {
        XCTAssertTrue(profile.matches(endpointName: "Pioneer DDJ-FLX10"))
    }

    func testMatchesAlphaThetaPrefix() {
        XCTAssertTrue(profile.matches(endpointName: "AlphaTheta DDJ-FLX10"))
    }

    func testDoesNotMatchUnrelatedDevice() {
        XCTAssertFalse(profile.matches(endpointName: "DDJ-REV7"))
        XCTAssertFalse(profile.matches(endpointName: "RANE ONE MKII"))
    }

    // MARK: - Deck channel mapping

    func testDeck1MapsToChannel0() {
        XCTAssertEqual(DDJFLX10Decoder.deck(forChannel: 0), 1)
    }

    func testDeck2MapsToChannel1() {
        XCTAssertEqual(DDJFLX10Decoder.deck(forChannel: 1), 2)
    }

    func testDeck3MapsToChannel2() {
        XCTAssertEqual(DDJFLX10Decoder.deck(forChannel: 2), 3)
    }

    func testDeck4MapsToChannel3() {
        XCTAssertEqual(DDJFLX10Decoder.deck(forChannel: 3), 4)
    }

    func testMixerChannelReturnsNilDeck() {
        XCTAssertNil(DDJFLX10Decoder.deck(forChannel: 6))
    }

    // MARK: - relativeSignedOffset64 decoder

    func testRelativeOffset0x40isZero() {
        XCTAssertEqual(MappingPrimitive.decodeRelativeSignedOffset64(0x40), 0)
    }

    func testRelativeOffset0x41isPlusOne() {
        XCTAssertEqual(MappingPrimitive.decodeRelativeSignedOffset64(0x41), +1)
    }

    func testRelativeOffset0x42isPlusTwo() {
        XCTAssertEqual(MappingPrimitive.decodeRelativeSignedOffset64(0x42), +2)
    }

    func testRelativeOffset0x3FisMinusOne() {
        XCTAssertEqual(MappingPrimitive.decodeRelativeSignedOffset64(0x3F), -1)
    }

    func testRelativeOffset0x3EisMinusTwo() {
        XCTAssertEqual(MappingPrimitive.decodeRelativeSignedOffset64(0x3E), -2)
    }

    func testRelativeOffset0x43isPlusThree() {
        XCTAssertEqual(MappingPrimitive.decodeRelativeSignedOffset64(0x43), +3)
    }

    func testRelativeOffset0x3DisMinusThree() {
        XCTAssertEqual(MappingPrimitive.decodeRelativeSignedOffset64(0x3D), -3)
    }

    // MARK: - Platter top bindings (primary scratch-motion source, CC 0x22 / JogScratch, vinyl mode ON)
    // Source: DDJ-FLX10.midi.csv "JogScratch,JogScratch,JogRotate,B022,0,1,2,3,,,,,,RO;Dual,Scratch"

    // B0 22 41 -> Deck 1 +1 platter delta
    func testDeck1PlatterTopForwardDelta() {
        let binding = profile.binding(roleKey: "platterTop", deck: 1)
        XCTAssertNotNil(binding, "platterTop deck 1 binding must exist")
        guard case .relativeSignedOffset64(let ch, let cc) = binding?.primitive else {
            XCTFail("Deck 1 platter must be relativeSignedOffset64"); return
        }
        XCTAssertEqual(ch, 0)    // MIDI channel 0 = Deck 1
        XCTAssertEqual(cc, 0x22) // JogScratch CC — confirmed against DDJ-FLX10.midi.csv
        XCTAssertEqual(MappingPrimitive.decodeRelativeSignedOffset64(0x41), +1)
    }

    // B0 22 3F -> Deck 1 -1 platter delta
    func testDeck1PlatterTopBackwardDelta() {
        XCTAssertEqual(DDJFLX10Decoder.platterDelta(0x3F), -1)
    }

    // B1 22 41 -> Deck 2 +1 platter delta
    func testDeck2PlatterTopForwardDelta() {
        let binding = profile.binding(roleKey: "platterTop", deck: 2)
        XCTAssertNotNil(binding)
        guard case .relativeSignedOffset64(let ch, let cc) = binding?.primitive else {
            XCTFail("Deck 2 platter must be relativeSignedOffset64"); return
        }
        XCTAssertEqual(ch, 1)    // MIDI channel 1 = Deck 2
        XCTAssertEqual(cc, 0x22) // JogScratch CC — confirmed against DDJ-FLX10.midi.csv
        XCTAssertEqual(DDJFLX10Decoder.platterDelta(0x41), +1)
    }

    // B1 22 3F -> Deck 2 -1 platter delta
    func testDeck2PlatterTopBackwardDelta() {
        XCTAssertEqual(DDJFLX10Decoder.platterDelta(0x3F), -1)
    }

    // CC 0x29 must NOT appear as platterTop — it is a pad/beat-jump note, not the jog scratch CC.
    func testCC0x29IsNotPlatterTop() {
        for deck in 1...4 {
            let binding = profile.binding(roleKey: "platterTop", deck: deck)
            guard case .relativeSignedOffset64(_, let cc) = binding?.primitive else { continue }
            XCTAssertNotEqual(cc, 0x29,
                "platterTop deck \(deck) must NOT use CC 0x29 (pad/beat-jump note, not JogScratch)")
        }
    }

    // MARK: - Jog pitch-bend binding (CC 0x23, vinyl mode OFF — not used for scoring)
    // Source: DDJ-FLX10.midi.csv "JogPitchBend,JogPitchBend,JogRotate,B023,0,1,2,3,,,,,,RO;Dual,Pitch Bend"

    func testJogPitchBendBindingIsCCx23() {
        let binding = profile.binding(roleKey: "jogPitchBend", deck: 1)
        XCTAssertNotNil(binding, "jogPitchBend deck 1 binding must exist")
        guard case .relativeSignedOffset64(let ch, let cc) = binding?.primitive else {
            XCTFail("jogPitchBend must be relativeSignedOffset64"); return
        }
        XCTAssertEqual(ch, 0)
        XCTAssertEqual(cc, 0x23)
    }

    func testJogPitchBendIsDistinctFromPlatterTop() {
        let platterBinding = profile.binding(roleKey: "platterTop", deck: 1)
        let pitchBendBinding = profile.binding(roleKey: "jogPitchBend", deck: 1)
        XCTAssertNotEqual(platterBinding?.primitive, pitchBendBinding?.primitive,
            "platterTop (CC 0x22) and jogPitchBend (CC 0x23) must be distinct bindings")
    }

    // MARK: - Jog side (secondary source, CC 0x21)

    // B0 21 41 -> Deck 1 +1 side-jog delta, NOT primary
    func testDeck1JogSideBindingExistsButIsNotPrimary() {
        let sideBinding = profile.binding(roleKey: "jogSide", deck: 1)
        XCTAssertNotNil(sideBinding)
        guard case .relativeSignedOffset64(let ch, let cc) = sideBinding?.primitive else {
            XCTFail("Jog side must be relativeSignedOffset64"); return
        }
        XCTAssertEqual(ch, 0)
        XCTAssertEqual(cc, 0x21)
        // Jog side is NOT the primary platter source.
        let topBinding = profile.binding(roleKey: "platterTop", deck: 1)
        XCTAssertNotNil(topBinding, "platterTop (primary) must co-exist with jogSide")
    }

    // MARK: - Jog touch (NOTE 0x36)

    // 90 36 7F -> Deck 1 touch on
    func testDeck1JogTouchOn() {
        let binding = profile.binding(roleKey: "jogTouch", deck: 1)
        XCTAssertNotNil(binding)
        guard case .noteMomentary(let ch, let note, let on, let off) = binding?.primitive else {
            XCTFail("jogTouch must be noteMomentary"); return
        }
        XCTAssertEqual(ch, 0)
        XCTAssertEqual(note, 0x36)
        XCTAssertEqual(on, 0x7F)
        XCTAssertEqual(off, 0x00)
    }

    // 90 36 00 -> Deck 1 touch off
    func testDeck1JogTouchOffValueIsZero() {
        let binding = profile.binding(roleKey: "jogTouch", deck: 1)
        guard case .noteMomentary(_, _, _, let off) = binding?.primitive else {
            XCTFail(); return
        }
        XCTAssertEqual(off, 0x00)
    }

    // 91 36 7F -> Deck 2 touch on
    func testDeck2JogTouchOn() {
        let binding = profile.binding(roleKey: "jogTouch", deck: 2)
        XCTAssertNotNil(binding)
        guard case .noteMomentary(let ch, _, _, _) = binding?.primitive else {
            XCTFail(); return
        }
        XCTAssertEqual(ch, 1)  // MIDI channel 1 = Deck 2
    }

    // MARK: - Crossfader (14-bit CC pair on mixer channel)

    // B6 1F xx and B6 3F xx -> normalized crossfader
    func testCrossfaderBindingIs14bit() {
        let binding = profile.binding(roleKey: "crossfader", deck: nil)
        XCTAssertNotNil(binding)
        guard case .cc14(let ch, let msb, let lsb) = binding?.primitive else {
            XCTFail("Crossfader must be cc14"); return
        }
        XCTAssertEqual(ch, 6)    // Mixer channel (MIDI ch 7 = index 6)
        XCTAssertEqual(msb, 0x1F)
        XCTAssertEqual(lsb, 0x3F)
    }

    // B6 1F 00 + B6 3F 00 -> normalized 0.0 (leftmost)
    func testCrossfaderFullLeftNormalizesToZero() {
        let raw = MappingPrimitive.decode14bit(msb: 0x00, lsb: 0x00)
        XCTAssertEqual(raw, 0)
        XCTAssertEqual(MappingPrimitive.normalize14bit(raw), 0.0, accuracy: 0.001)
    }

    // B6 1F 7F + B6 3F 7F -> normalized near 1.0 (rightmost)
    func testCrossfaderFullRightNormalizesNearOne() {
        let raw = MappingPrimitive.decode14bit(msb: 0x7F, lsb: 0x7F)
        XCTAssertEqual(raw, 16383)
        XCTAssertEqual(MappingPrimitive.normalize14bit(raw), 1.0, accuracy: 0.001)
    }

    // Midpoint normalizes near 0.5
    func testCrossfaderMidpointNormalizesNearHalf() {
        let raw = MappingPrimitive.decode14bit(msb: 0x3F, lsb: 0x40)
        let normalized = MappingPrimitive.normalize14bit(raw)
        XCTAssertEqual(normalized, 0.5, accuracy: 0.02)
    }

    func testDDJFLX10CrossfaderPosition() {
        // DDJFLX10Decoder convenience
        XCTAssertEqual(DDJFLX10Decoder.crossfaderPosition(msb: 0x00, lsb: 0x00), 0.0, accuracy: 0.001)
        XCTAssertEqual(DDJFLX10Decoder.crossfaderPosition(msb: 0x7F, lsb: 0x7F), 1.0, accuracy: 0.001)
    }

    // MARK: - Play / Pause (NOTE 0x0B)

    // 90 0B 7F -> Deck 1 play/pause pressed
    func testDeck1PlayPauseBinding() {
        let binding = profile.binding(roleKey: "playPause", deck: 1)
        XCTAssertNotNil(binding)
        guard case .noteMomentary(let ch, let note, let on, _) = binding?.primitive else {
            XCTFail(); return
        }
        XCTAssertEqual(ch, 0)
        XCTAssertEqual(note, 0x0B)
        XCTAssertEqual(on, 0x7F)
    }

    // MARK: - Cue (NOTE 0x0C)

    // 90 0C 7F -> Deck 1 cue pressed
    func testDeck1CueBinding() {
        let binding = profile.binding(roleKey: "cue", deck: 1)
        XCTAssertNotNil(binding)
        guard case .noteMomentary(let ch, let note, let on, _) = binding?.primitive else {
            XCTFail(); return
        }
        XCTAssertEqual(ch, 0)
        XCTAssertEqual(note, 0x0C)
        XCTAssertEqual(on, 0x7F)
    }

    // MARK: - Deck select (NOTE 0x3C)

    // Deck 1 note 60 (0x3C) value 0x7F -> left deck is Deck 1
    func testDeck1SelectBinding() {
        let binding = profile.binding(roleKey: "deckSelect", deck: 1)
        XCTAssertNotNil(binding)
        guard case .deckLayerSelect(let ch, let note) = binding?.primitive else {
            XCTFail("deckSelect must be deckLayerSelect"); return
        }
        XCTAssertEqual(ch, 0)      // Deck 1 channel
        XCTAssertEqual(note, 0x3C) // Note 60
    }

    // Deck 3 note 60 value 0x7F -> left deck switches to Deck 3
    func testDeck3SelectBinding() {
        let binding = profile.binding(roleKey: "deckSelect", deck: 3)
        XCTAssertNotNil(binding)
        guard case .deckLayerSelect(let ch, let note) = binding?.primitive else {
            XCTFail(); return
        }
        XCTAssertEqual(ch, 2)      // Deck 3 channel
        XCTAssertEqual(note, 0x3C)
    }

    // Deck 2 note 60 value 0x7F -> right deck is Deck 2
    func testDeck2SelectBinding() {
        let binding = profile.binding(roleKey: "deckSelect", deck: 2)
        guard case .deckLayerSelect(let ch, _) = binding?.primitive else {
            XCTFail(); return
        }
        XCTAssertEqual(ch, 1) // Deck 2 channel
    }

    // Deck 4 note 60 value 0x7F -> right deck switches to Deck 4
    func testDeck4SelectBinding() {
        let binding = profile.binding(roleKey: "deckSelect", deck: 4)
        guard case .deckLayerSelect(let ch, _) = binding?.primitive else {
            XCTFail(); return
        }
        XCTAssertEqual(ch, 3) // Deck 4 channel
    }

    // MARK: - Platter top is NOT treated as absolute

    func testPlatterTopBindingIsRelativeNotAbsolute() {
        let binding = profile.binding(roleKey: "platterTop", deck: 1)
        guard let primitive = binding?.primitive else {
            XCTFail(); return
        }
        // Must not be ccAbsolute7 or cc14 — it must be relative.
        if case .ccAbsolute7 = primitive { XCTFail("Platter top must NOT be absolute CC") }
        if case .cc14 = primitive { XCTFail("Platter top must NOT be 14-bit CC") }
    }

    // MARK: - Channel fader bindings (14-bit)

    func testDeck1ChannelFaderIs14bit() {
        let binding = profile.binding(roleKey: "channelFader", deck: 1)
        XCTAssertNotNil(binding)
        guard case .cc14(_, let msb, let lsb) = binding?.primitive else {
            XCTFail("Channel fader must be cc14"); return
        }
        XCTAssertEqual(msb, 0x13)
        XCTAssertEqual(lsb, 0x33)
    }

    // MARK: - Verification steps

    func testVerificationStepsExist() {
        XCTAssertFalse(profile.verificationSteps.isEmpty)
    }

    func testRequiredVerificationStepsIncludePlatterAndCrossfader() {
        let required = profile.verificationSteps.filter(\.required)
        let roles = Set(required.map(\.expectedControl))
        XCTAssertTrue(roles.contains { $0.contains("platterTop") })
        XCTAssertTrue(roles.contains { $0.contains("crossfader") })
    }

    // MARK: - Profile sourced from official doc

    func testProfileIsFullySourced() {
        XCTAssertTrue(profile.isFullySourced)
    }

    func testProfileCanFeedScoringAfterVerification() {
        XCTAssertTrue(profile.canFeedScoringAfterVerification)
    }
}
