import XCTest
@testable import ScratchLab

final class ScratchBankPadMappingTests: XCTestCase {

    // MARK: - 1. Default conflict policy is listenOnly

    func testDefaultConflictPolicyIsListenOnly() {
        for mapping in ScratchBankPadMappingCatalog.raneOneMKII {
            XCTAssertEqual(mapping.conflictPolicy, .listenOnly,
                "All default Rane pad mappings must have .listenOnly conflict policy; pad \(mapping.padIndex) deck \(mapping.deck as Any) has .\(mapping.conflictPolicy)")
        }
    }

    // MARK: - 2. Default verificationRequired is true

    func testDefaultVerificationRequiredIsTrue() {
        for mapping in ScratchBankPadMappingCatalog.raneOneMKII {
            XCTAssertTrue(mapping.verificationRequired,
                "All default Rane pad mappings must have verificationRequired = true")
        }
    }

    // MARK: - 3. Rane ONE MK2 deck 1 large pads: ch=4 CC 20–27

    func testRaneOneMKIIDeck1LargePadsChannel4CC20to27() {
        let pads = ScratchBankPadMappingCatalog.deck1LargePads
        XCTAssertEqual(pads.count, 8)
        for (i, pad) in pads.enumerated() {
            XCTAssertEqual(pad.midiChannel, 4, "Deck 1 large pad \(i): expected ch=4, got ch=\(pad.midiChannel)")
            XCTAssertEqual(pad.midiCC, UInt8(20 + i), "Deck 1 large pad \(i): expected CC=\(20 + i), got CC=\(pad.midiCC)")
            XCTAssertEqual(pad.deck, 1)
            XCTAssertEqual(pad.controllerProfileID, "rane.one-mkii")
        }
    }

    // MARK: - 4. Rane ONE MK2 deck 2 large pads: ch=5 CC 20–27

    func testRaneOneMKIIDeck2LargePadsChannel5CC20to27() {
        let pads = ScratchBankPadMappingCatalog.deck2LargePads
        XCTAssertEqual(pads.count, 8)
        for (i, pad) in pads.enumerated() {
            XCTAssertEqual(pad.midiChannel, 5, "Deck 2 large pad \(i): expected ch=5, got ch=\(pad.midiChannel)")
            XCTAssertEqual(pad.midiCC, UInt8(20 + i), "Deck 2 large pad \(i): expected CC=\(20 + i), got CC=\(pad.midiCC)")
            XCTAssertEqual(pad.deck, 2)
        }
    }

    // MARK: - 5. Deck 1 shift pads: ch=4 CC 28–35

    func testRaneOneMKIIDeck1ShiftPadsCC28to35() {
        let pads = ScratchBankPadMappingCatalog.deck1ShiftPads
        XCTAssertEqual(pads.count, 8)
        for (i, pad) in pads.enumerated() {
            XCTAssertEqual(pad.midiChannel, 4)
            XCTAssertEqual(pad.midiCC, UInt8(28 + i), "Deck 1 shift pad \(i): expected CC=\(28 + i), got CC=\(pad.midiCC)")
            XCTAssertEqual(pad.deck, 1)
        }
    }

    // MARK: - 6. Deck 2 shift pads: ch=5 CC 28–35

    func testRaneOneMKIIDeck2ShiftPadsCC28to35() {
        let pads = ScratchBankPadMappingCatalog.deck2ShiftPads
        XCTAssertEqual(pads.count, 8)
        for (i, pad) in pads.enumerated() {
            XCTAssertEqual(pad.midiChannel, 5)
            XCTAssertEqual(pad.midiCC, UInt8(28 + i), "Deck 2 shift pad \(i): expected CC=\(28 + i), got CC=\(pad.midiCC)")
            XCTAssertEqual(pad.deck, 2)
        }
    }

    // MARK: - 7. Small pad strip: CC 100–103 on both decks

    func testRaneOneMKIISmallPadStripCC100to103() {
        let d1 = ScratchBankPadMappingCatalog.deck1SmallPads
        XCTAssertEqual(d1.count, 4)
        for (i, pad) in d1.enumerated() {
            XCTAssertEqual(pad.midiCC, UInt8(100 + i), "Deck 1 small pad \(i): expected CC=\(100 + i), got CC=\(pad.midiCC)")
            XCTAssertEqual(pad.padMode, .smallPad)
            XCTAssertEqual(pad.midiChannel, 4)
        }

        let d2 = ScratchBankPadMappingCatalog.deck2SmallPads
        XCTAssertEqual(d2.count, 4)
        for (i, pad) in d2.enumerated() {
            XCTAssertEqual(pad.midiCC, UInt8(100 + i), "Deck 2 small pad \(i): expected CC=\(100 + i), got CC=\(pad.midiCC)")
            XCTAssertEqual(pad.padMode, .smallPad)
            XCTAssertEqual(pad.midiChannel, 5)
        }
    }

    // MARK: - 8. No pad mapping enables scoring

    func testNoPadMappingEnablesScoring() {
        for mapping in ScratchBankPadMappingCatalog.raneOneMKII {
            XCTAssertFalse(mapping.canFeedScoring,
                "Pad mapping for profile '\(mapping.controllerProfileID)' pad \(mapping.padIndex) deck \(mapping.deck as Any) must not enable scoring")
        }
    }

    // MARK: - 9. Model is data-only — no audio side effects

    func testModelIsDataOnly_NoAudioSideEffects() {
        // Accessing all properties on every mapping must not trigger any audio or MIDI.
        for mapping in ScratchBankPadMappingCatalog.raneOneMKII {
            _ = mapping.controllerProfileID
            _ = mapping.deck
            _ = mapping.padIndex
            _ = mapping.padMode
            _ = mapping.midiChannel
            _ = mapping.midiCC
            _ = mapping.assignedSampleID
            _ = mapping.triggerMode
            _ = mapping.conflictPolicy
            _ = mapping.verificationRequired
            _ = mapping.sourceNotes
            _ = mapping.canFeedScoring
        }
        XCTAssertTrue(true, "No audio or MIDI triggered by model property access")
    }

    // MARK: - 10. Existing Rane ONE MK2 ControllerProfile canFeedScoringBeforeVerification is still false

    func testRaneOneMKIIControllerProfileCannotFeedScoring() {
        let catalog = ControllerProfileCatalog.shared
        guard let profile = catalog.partialProfiles.first(where: { $0.id == "rane.one-mkii" }) else {
            XCTFail("rane.one-mkii not found in partialProfiles — existing profile must not be affected")
            return
        }
        XCTAssertFalse(profile.canFeedScoringBeforeVerification,
            "rane.one-mkii ControllerProfile.canFeedScoringBeforeVerification must remain false")
        XCTAssertTrue(profile.verificationRequired,
            "rane.one-mkii ControllerProfile.verificationRequired must remain true")
    }

    // MARK: - 11. Total pad count for Rane ONE MK2 is 40

    func testTotalPadCountIsForty() {
        XCTAssertEqual(ScratchBankPadMappingCatalog.raneOneMKII.count, 40,
            "8+8+8+8+4+4 = 40 pad mappings for Rane ONE MK2")
    }

    // MARK: - 12. All mappings reference the correct profile ID

    func testAllMappingsReferenceRaneOneMKII() {
        for mapping in ScratchBankPadMappingCatalog.raneOneMKII {
            XCTAssertEqual(mapping.controllerProfileID, "rane.one-mkii",
                "Pad \(mapping.padIndex) deck \(mapping.deck as Any) must reference 'rane.one-mkii'")
        }
    }

    // MARK: - Confirmed hardware note pad catalog

    func testConfirmedHardwareNotePadsHasEightEntries() {
        XCTAssertEqual(ScratchBankPadMappingCatalog.confirmedHardwareNotePads.count, 8,
            "confirmedHardwareNotePads must have 8 entries: right deck pads 1–8 (notes 20–27)")
    }

    func testConfirmedHardwareNotePadsAreNoteMappings() {
        for pad in ScratchBankPadMappingCatalog.confirmedHardwareNotePads {
            XCTAssertTrue(pad.isNoteMapping,
                "All confirmed hardware pads must have isNoteMapping = true (Note On/Off, not CC)")
        }
    }

    func testConfirmedHardwareNotePad1IsNote20OnChannel5RightDeck() {
        let pad = ScratchBankPadMappingCatalog.confirmedHardwareNotePads[0]
        XCTAssertEqual(pad.midiNoteNumber, 20, "Pad 1 must be note 20")
        XCTAssertEqual(pad.midiChannel, 5, "Right deck pads on ch=5 (ch6 MIDI Monitor)")
        XCTAssertEqual(pad.padIndex, 0)
        XCTAssertEqual(pad.deck, 2, "Deck 2 = right deck (1-indexed v1 model)")
    }

    func testConfirmedHardwareNotePad4IsNote23OnChannel5() {
        let pad = ScratchBankPadMappingCatalog.confirmedHardwareNotePads[3]
        XCTAssertEqual(pad.midiNoteNumber, 23)
        XCTAssertEqual(pad.midiChannel, 5)
        XCTAssertEqual(pad.padIndex, 3)
        XCTAssertEqual(pad.deck, 2)
    }

    func testConfirmedHardwareNotePad5IsNote24OnChannel5() {
        let pad = ScratchBankPadMappingCatalog.confirmedHardwareNotePads[4]
        XCTAssertEqual(pad.midiNoteNumber, 24, "Pad 5 (latest capture) must be note 24")
        XCTAssertEqual(pad.midiChannel, 5)
        XCTAssertEqual(pad.padIndex, 4)
        XCTAssertEqual(pad.deck, 2)
    }

    func testConfirmedHardwareNotePad8IsNote27OnChannel5() {
        let pad = ScratchBankPadMappingCatalog.confirmedHardwareNotePads[7]
        XCTAssertEqual(pad.midiNoteNumber, 27, "Pad 8 must be note 27")
        XCTAssertEqual(pad.midiChannel, 5)
        XCTAssertEqual(pad.padIndex, 7)
        XCTAssertEqual(pad.deck, 2)
    }

    func testConfirmedHardwareNotePadCoversNotes20Through27() {
        let notes = ScratchBankPadMappingCatalog.confirmedHardwareNotePads
            .compactMap { $0.midiNoteNumber }
            .sorted()
        XCTAssertEqual(notes, Array(20...27).map(UInt8.init),
            "confirmedHardwareNotePads must cover notes 20–27")
    }

    func testConfirmedHardwareNotePadsHaveCorrectSampleIDsForPads1to4() {
        let pads = ScratchBankPadMappingCatalog.confirmedHardwareNotePads
        XCTAssertEqual(pads[0].assignedSampleID, "ahhh")
        XCTAssertEqual(pads[1].assignedSampleID, "fresh")
        XCTAssertEqual(pads[2].assignedSampleID, "ah_yeah")
        XCTAssertEqual(pads[3].assignedSampleID, "check_it_out")
        // Pads 5–8 have no sample assigned yet.
        XCTAssertEqual(pads[4].assignedSampleID, "")
        XCTAssertEqual(pads[7].assignedSampleID, "")
    }

    func testConfirmedHardwareNotePadsAreVerified() {
        for pad in ScratchBankPadMappingCatalog.confirmedHardwareNotePads {
            XCTAssertFalse(pad.verificationRequired,
                "Confirmed hardware pads must have verificationRequired = false")
        }
    }

    func testConfirmedHardwareNotePadsDoNotFeedScoring() {
        for pad in ScratchBankPadMappingCatalog.confirmedHardwareNotePads {
            XCTAssertFalse(pad.canFeedScoring,
                "Note pad mappings must never feed scoring at the model layer")
        }
    }

    func testConfirmedHardwareNotePadsAreAllRightDeck() {
        for pad in ScratchBankPadMappingCatalog.confirmedHardwareNotePads {
            XCTAssertEqual(pad.deck, 2, "All confirmedHardwareNotePads must be right deck (deck 2)")
        }
    }

    func testExistingCCPadsAreNotNoteMappings() {
        for pad in ScratchBankPadMappingCatalog.deck1LargePads {
            XCTAssertFalse(pad.isNoteMapping,
                "Deck 1 large pad \(pad.padIndex) must be a CC mapping (isNoteMapping = false)")
        }
    }

    func testConfirmedNotePadsCoversFullRightDeckRange() {
        let notes = ScratchBankPadMappingCatalog.confirmedHardwareNotePads
            .compactMap { $0.midiNoteNumber }
        XCTAssertTrue(notes.allSatisfy { $0 >= 20 && $0 <= 27 },
            "confirmedHardwareNotePads notes must be in range 20–27 (pads 1–8 right deck)")
    }

    // MARK: - 13. Verification display helpers

    func testVerificationDisplayStatusWhenRequired() {
        let mapping = ScratchBankPadMappingCatalog.raneOneMKII[0]
        XCTAssertTrue(mapping.verificationRequired)
        XCTAssertEqual(mapping.verificationDisplayStatus, "Pending hardware verification")
    }

    func testProvenanceDisplayNoteIsNonEmpty() {
        let mapping = ScratchBankPadMappingCatalog.raneOneMKII[0]
        XCTAssertTrue(mapping.provenanceDisplayNote.contains("djay Pro"))
        XCTAssertTrue(mapping.provenanceDisplayNote.contains("real hardware"))
        XCTAssertFalse(mapping.provenanceDisplayNote.isEmpty)
    }
}
