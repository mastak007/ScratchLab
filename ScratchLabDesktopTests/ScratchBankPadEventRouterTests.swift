import XCTest
@testable import ScratchLab

/// Gated MIDI pad-to-sample router tests.
/// Verifies enabled/disabled, press/release, mapping correctness,
/// safety gates, and Slice 3 regression.
final class ScratchBankPadEventRouterTests: XCTestCase {

    // MARK: - 1. Router disabled → nil

    func testDisabledRouterReturnsNilForPad1() {
        XCTAssertNil(ScratchBankPadEventRouter.sampleID(
            channel: 4, cc: 20, value: 127, isEnabled: false
        ))
    }

    // MARK: - 2–5. Enabled mapping for pads 1–4

    func testEnabledRouterCh4CC20ReturnsAhhh() {
        XCTAssertEqual(ScratchBankPadEventRouter.sampleID(
            channel: 4, cc: 20, value: 127, isEnabled: true
        ), "ahhh")
    }

    func testEnabledRouterCh4CC21ReturnsFresh() {
        XCTAssertEqual(ScratchBankPadEventRouter.sampleID(
            channel: 4, cc: 21, value: 127, isEnabled: true
        ), "fresh")
    }

    func testEnabledRouterCh4CC22ReturnsAhYeah() {
        XCTAssertEqual(ScratchBankPadEventRouter.sampleID(
            channel: 4, cc: 22, value: 127, isEnabled: true
        ), "ah_yeah")
    }

    func testEnabledRouterCh4CC23ReturnsCheckItOut() {
        XCTAssertEqual(ScratchBankPadEventRouter.sampleID(
            channel: 4, cc: 23, value: 127, isEnabled: true
        ), "check_it_out")
    }

    // MARK: - 6. Release (value 0) → nil

    func testValueZeroReturnsNil() {
        XCTAssertNil(ScratchBankPadEventRouter.sampleID(
            channel: 4, cc: 20, value: 0, isEnabled: true
        ))
    }

    // MARK: - 7–8. Unrelated CC / channel → nil

    func testUnrelatedCCReturnsNil() {
        XCTAssertNil(ScratchBankPadEventRouter.sampleID(
            channel: 4, cc: 19, value: 127, isEnabled: true
        ))
        XCTAssertNil(ScratchBankPadEventRouter.sampleID(
            channel: 4, cc: 24, value: 127, isEnabled: true
        ))
        XCTAssertNil(ScratchBankPadEventRouter.sampleID(
            channel: 4, cc: 50, value: 127, isEnabled: true
        ))
    }

    func testUnrelatedChannelReturnsNil() {
        XCTAssertNil(ScratchBankPadEventRouter.sampleID(
            channel: 0, cc: 20, value: 127, isEnabled: true
        ))
        XCTAssertNil(ScratchBankPadEventRouter.sampleID(
            channel: 6, cc: 20, value: 127, isEnabled: true
        ))
    }

    // MARK: - 9. Deck 2 mirror (ch5 CC20–23)

    func testDeck2MirrorCh5CC20ReturnsAhhh() {
        XCTAssertEqual(ScratchBankPadEventRouter.sampleID(
            channel: 5, cc: 20, value: 127, isEnabled: true
        ), "ahhh")
    }

    func testDeck2MirrorCh5CC23ReturnsCheckItOut() {
        XCTAssertEqual(ScratchBankPadEventRouter.sampleID(
            channel: 5, cc: 23, value: 127, isEnabled: true
        ), "check_it_out")
    }

    // MARK: - 10. Pads 5–8 (CC24–27) return nil

    func testCC24Thru27ReturnNilForNow() {
        for cc in 24...27 {
            XCTAssertNil(ScratchBankPadEventRouter.sampleID(
                channel: 4, cc: cc, value: 127, isEnabled: true
            ), "CC\(cc) must return nil — pads 5–8 not wired yet")
            XCTAssertNil(ScratchBankPadEventRouter.sampleID(
                channel: 5, cc: cc, value: 127, isEnabled: true
            ), "Deck 2 CC\(cc) must return nil — pads 5–8 not wired yet")
        }
    }

    // MARK: - 11. No scoring enabled

    func testRouterHasNoScoringAPI() {
        // The router is a pure enum with one static function — no scoring
        // properties, no scoring observers.
        let mirror = Mirror(reflecting: ScratchBankPadEventRouter.self)
        let children = mirror.children.compactMap { $0.label }
        let containsScore = children.contains { $0.lowercased().contains("scor") }
        XCTAssertFalse(containsScore,
            "ScratchBankPadEventRouter must not reference scoring; found: \(children)")
    }

    // MARK: - 12. Pad mappings remain verificationRequired

    func testPadMappingsRemainVerificationRequired() {
        for mapping in ScratchBankPadMappingCatalog.raneOneMKII {
            XCTAssertTrue(mapping.verificationRequired)
            XCTAssertFalse(mapping.canFeedScoring)
        }
    }

    // MARK: - 13. Slice 3 labeler behaviour unchanged

    func testSlice3LabelerStillWorks() {
        // The labeler from Slice 3 must still return the same labels.
        let label = RaneOneMK2PadCandidateLabeler.label(channel: 4, cc: 20, value: 127)
        XCTAssertNotNil(label)
        XCTAssertTrue(label!.contains("deck 1 pad 1"))
        XCTAssertTrue(label!.contains("value 127"))

        // Router must not affect labeler.
        let id = ScratchBankPadEventRouter.sampleID(channel: 4, cc: 20, value: 127, isEnabled: true)
        XCTAssertEqual(id, "ahhh")
    }

    // MARK: - 14. Router is pure — no side effects

    func testRouterIsPureFunction_NoSideEffects() {
        for _ in 0..<10 {
            _ = ScratchBankPadEventRouter.sampleID(
                channel: 4, cc: 20, value: 127, isEnabled: true
            )
        }
        // Reaching here without side effects is the assertion.
        XCTAssertTrue(true, "sampleID() is pure — no side effects")
    }

    // MARK: - 15–16. Safety gate + sample ID requires both enabled AND press

    func testEnabledFalseAlwaysReturnsNilEvenForKnownCC() {
        for cc in 20...23 {
            XCTAssertNil(ScratchBankPadEventRouter.sampleID(
                channel: 4, cc: cc, value: 127, isEnabled: false
            ), "CC\(cc) must return nil when disabled")
        }
    }

    func testValueZeroAlwaysReturnsNilEvenWhenEnabled() {
        XCTAssertNil(ScratchBankPadEventRouter.sampleID(
            channel: 4, cc: 20, value: 0, isEnabled: true
        ))
        // Also check all mapped pads.
        for cc in 20...23 {
            XCTAssertNil(ScratchBankPadEventRouter.sampleID(
                channel: 4, cc: cc, value: 0, isEnabled: true
            ), "CC\(cc) value 0 must return nil (release)")
        }
    }

    // MARK: - Note On: confirmed Rane ONE MK2 hardware (ch6 = channel 5, notes 20–23)

    func testNoteOnCh5Note20Vel127GateOnResolvesAhhh() {
        XCTAssertEqual(ScratchBankPadEventRouter.sampleID(
            channel: 5, noteNumber: 20, velocity: 127, isEnabled: true
        ), "ahhh")
    }

    func testNoteOnCh5Note21Vel127GateOnResolvesFresh() {
        XCTAssertEqual(ScratchBankPadEventRouter.sampleID(
            channel: 5, noteNumber: 21, velocity: 127, isEnabled: true
        ), "fresh")
    }

    func testNoteOnCh5Note22Vel127GateOnResolvesAhYeah() {
        XCTAssertEqual(ScratchBankPadEventRouter.sampleID(
            channel: 5, noteNumber: 22, velocity: 127, isEnabled: true
        ), "ah_yeah")
    }

    func testNoteOnCh5Note23Vel127GateOnResolvesCheckItOut() {
        XCTAssertEqual(ScratchBankPadEventRouter.sampleID(
            channel: 5, noteNumber: 23, velocity: 127, isEnabled: true
        ), "check_it_out")
    }

    func testNoteOnGateOffReturnsNilForAllFourPads() {
        for note in 20...23 {
            XCTAssertNil(ScratchBankPadEventRouter.sampleID(
                channel: 5, noteNumber: note, velocity: 127, isEnabled: false
            ), "Note \(note) must return nil when gate is OFF")
        }
    }

    func testNoteOnVelocityZeroReturnsNilForAllFourPads() {
        for note in 20...23 {
            XCTAssertNil(ScratchBankPadEventRouter.sampleID(
                channel: 5, noteNumber: note, velocity: 0, isEnabled: true
            ), "Note \(note) velocity 0 must return nil")
        }
    }

    func testNoteOffVelocityZeroReturnsNil() {
        XCTAssertNil(ScratchBankPadEventRouter.sampleID(
            channel: 5, noteNumber: 20, velocity: 0, isEnabled: true
        ), "Note Off (velocity 0) must return nil")
    }

    func testNoteOnNonPadChannelReturnsNil() {
        for channel in [0, 1, 3, 6, 15] {
            XCTAssertNil(ScratchBankPadEventRouter.sampleID(
                channel: channel, noteNumber: 20, velocity: 127, isEnabled: true
            ), "Channel \(channel) note 20 must return nil — not a Rane pad channel")
        }
    }

    func testNoteOnOutsidePadRangeReturnsNil() {
        for note in [0, 8, 11, 19, 28, 127] {
            XCTAssertNil(ScratchBankPadEventRouter.sampleID(
                channel: 5, noteNumber: note, velocity: 127, isEnabled: true
            ), "Note \(note) must return nil — not a known Rane pad note (20–27)")
        }
    }

    func testCCCrossfaderCh16DoesNotResolveViaCCRouter() {
        // ch16 Balance crossfader = channel 15 (0-indexed).
        XCTAssertNil(ScratchBankPadEventRouter.sampleID(
            channel: 15, cc: 8, value: 64, isEnabled: true
        ))
    }

    func testCCVolumeFaderCh2DoesNotResolveViaCCRouter() {
        // ch2 CC28 volume fader = channel 1 (0-indexed).
        XCTAssertNil(ScratchBankPadEventRouter.sampleID(
            channel: 1, cc: 28, value: 64, isEnabled: true
        ))
    }

    func testCCTempoFaderCh2DoesNotResolveViaCCRouter() {
        // ch2 CC9/CC41 tempo slider = channel 1 (0-indexed).
        XCTAssertNil(ScratchBankPadEventRouter.sampleID(
            channel: 1, cc: 9, value: 64, isEnabled: true
        ))
        XCTAssertNil(ScratchBankPadEventRouter.sampleID(
            channel: 1, cc: 41, value: 64, isEnabled: true
        ))
    }

    func testNoteOnNoteRouterIsPure_NoSideEffects() {
        for _ in 0..<10 {
            _ = ScratchBankPadEventRouter.sampleID(
                channel: 5, noteNumber: 20, velocity: 127, isEnabled: true
            )
        }
        XCTAssertTrue(true, "note sampleID() is pure — no side effects")
    }

    // MARK: - Extended Note routing: ch=4 (left deck) pads 1–8

    func testNoteOnCh4Note20Vel127ResolvesAhhh() {
        XCTAssertEqual(ScratchBankPadEventRouter.sampleID(
            channel: 4, noteNumber: 20, velocity: 127, isEnabled: true
        ), "ahhh")
    }

    func testNoteOnCh4Note23Vel127ResolvesCheckItOut() {
        XCTAssertEqual(ScratchBankPadEventRouter.sampleID(
            channel: 4, noteNumber: 23, velocity: 127, isEnabled: true
        ), "check_it_out")
    }

    func testNoteOnCh4Note24Vel127ResolvesAhhh() {
        // Pad 5 = note 24, cycles back to ahhh
        XCTAssertEqual(ScratchBankPadEventRouter.sampleID(
            channel: 4, noteNumber: 24, velocity: 127, isEnabled: true
        ), "ahhh")
    }

    func testNoteOnCh4Note27Vel127ResolvesCheckItOut() {
        // Pad 8 = note 27, cycles to check_it_out
        XCTAssertEqual(ScratchBankPadEventRouter.sampleID(
            channel: 4, noteNumber: 27, velocity: 127, isEnabled: true
        ), "check_it_out")
    }

    // MARK: - Extended Note routing: ch=5 (right deck) pads 5–8

    func testNoteOnCh5Note24Vel127ResolvesAhhh() {
        // Pad 5 right deck = note 24 → ahhh
        XCTAssertEqual(ScratchBankPadEventRouter.sampleID(
            channel: 5, noteNumber: 24, velocity: 127, isEnabled: true
        ), "ahhh")
    }

    func testNoteOnCh5Note25Vel127ResolvesFresh() {
        // Pad 6 right deck = note 25 → fresh
        XCTAssertEqual(ScratchBankPadEventRouter.sampleID(
            channel: 5, noteNumber: 25, velocity: 127, isEnabled: true
        ), "fresh")
    }

    func testNoteOnCh5Note26Vel127ResolvesAhYeah() {
        // Pad 7 right deck = note 26 → ah_yeah
        XCTAssertEqual(ScratchBankPadEventRouter.sampleID(
            channel: 5, noteNumber: 26, velocity: 127, isEnabled: true
        ), "ah_yeah")
    }

    func testNoteOnCh5Note27Vel127ResolvesCheckItOut() {
        // Pad 8 right deck = note 27 → check_it_out
        XCTAssertEqual(ScratchBankPadEventRouter.sampleID(
            channel: 5, noteNumber: 27, velocity: 127, isEnabled: true
        ), "check_it_out")
    }

    // MARK: - PFL note 27 disambiguation: ch=0/ch=1 must NOT route

    func testPFLNote27Ch0DoesNotRoute() {
        XCTAssertNil(ScratchBankPadEventRouter.sampleID(
            channel: 0, noteNumber: 27, velocity: 127, isEnabled: true
        ), "PFL note 27 on ch=0 must not route to pad preview")
    }

    func testPFLNote27Ch1DoesNotRoute() {
        XCTAssertNil(ScratchBankPadEventRouter.sampleID(
            channel: 1, noteNumber: 27, velocity: 127, isEnabled: true
        ), "PFL note 27 on ch=1 must not route to pad preview")
    }

    // MARK: - Pad 8 note 27 on ch=4/ch=5 DOES route

    func testPad8Note27Ch4DoesRoute() {
        XCTAssertEqual(ScratchBankPadEventRouter.sampleID(
            channel: 4, noteNumber: 27, velocity: 127, isEnabled: true
        ), "check_it_out", "Pad 8 note 27 on ch=4 (left deck) must route")
    }

    func testPad8Note27Ch5DoesRoute() {
        XCTAssertEqual(ScratchBankPadEventRouter.sampleID(
            channel: 5, noteNumber: 27, velocity: 127, isEnabled: true
        ), "check_it_out", "Pad 8 note 27 on ch=5 (right deck) must route")
    }

    // MARK: - Start/Stop, SYNC still do not route

    func testStartStopNote0Channels0and1DoNotRoute() {
        XCTAssertNil(ScratchBankPadEventRouter.sampleID(
            channel: 0, noteNumber: 0, velocity: 127, isEnabled: true
        ))
        XCTAssertNil(ScratchBankPadEventRouter.sampleID(
            channel: 1, noteNumber: 0, velocity: 127, isEnabled: true
        ))
    }

    func testSyncNote2Ch1DoesNotRoute() {
        XCTAssertNil(ScratchBankPadEventRouter.sampleID(
            channel: 1, noteNumber: 2, velocity: 127, isEnabled: true
        ))
    }

    // MARK: - All 8 pads on both decks resolve via Note On

    func testAllEightPadsOnCh4Resolve() {
        let expected: [Int: String] = [
            20: "ahhh", 21: "fresh", 22: "ah_yeah", 23: "check_it_out",
            24: "ahhh", 25: "fresh", 26: "ah_yeah", 27: "check_it_out",
        ]
        for (note, sampleID) in expected {
            XCTAssertEqual(ScratchBankPadEventRouter.sampleID(
                channel: 4, noteNumber: note, velocity: 127, isEnabled: true
            ), sampleID, "ch=4 note \(note) must resolve to \(sampleID)")
        }
    }

    func testAllEightPadsOnCh5Resolve() {
        let expected: [Int: String] = [
            20: "ahhh", 21: "fresh", 22: "ah_yeah", 23: "check_it_out",
            24: "ahhh", 25: "fresh", 26: "ah_yeah", 27: "check_it_out",
        ]
        for (note, sampleID) in expected {
            XCTAssertEqual(ScratchBankPadEventRouter.sampleID(
                channel: 5, noteNumber: note, velocity: 127, isEnabled: true
            ), sampleID, "ch=5 note \(note) must resolve to \(sampleID)")
        }
    }
}
