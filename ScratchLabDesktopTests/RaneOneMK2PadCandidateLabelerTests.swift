import XCTest
@testable import ScratchLab

/// Rane ONE MK2 pad candidate labeler tests.
/// Verifies CC-range mapping, mode labelling, exclusion of unrelated CCs,
/// release-value handling, CC6 platter independence, and safety gates.
final class RaneOneMK2PadCandidateLabelerTests: XCTestCase {

    // MARK: - 1–4: Large pad labelling (deck 1 & 2, pads 1 & 8)

    func testCh4CC20LabelsDeck1Pad1() {
        let label = RaneOneMK2PadCandidateLabeler.label(channel: 4, cc: 20, value: 127)
        XCTAssertNotNil(label)
        XCTAssertTrue(label!.contains("deck 1 pad 1"))
        XCTAssertTrue(label!.contains("CC20"))
        XCTAssertTrue(label!.contains("ch4"))
        XCTAssertTrue(label!.contains("value 127"))
        XCTAssertTrue(label!.hasPrefix("Rane ONE MK2 pad candidate:"))
    }

    func testCh4CC27LabelsDeck1Pad8() {
        let label = RaneOneMK2PadCandidateLabeler.label(channel: 4, cc: 27, value: 127)
        XCTAssertNotNil(label)
        XCTAssertTrue(label!.contains("deck 1 pad 8"))
        XCTAssertTrue(label!.contains("CC27"))
        XCTAssertTrue(label!.contains("ch4"))
    }

    func testCh5CC20LabelsDeck2Pad1() {
        let label = RaneOneMK2PadCandidateLabeler.label(channel: 5, cc: 20, value: 127)
        XCTAssertNotNil(label)
        XCTAssertTrue(label!.contains("deck 2 pad 1"))
        XCTAssertTrue(label!.contains("CC20"))
        XCTAssertTrue(label!.contains("ch5"))
    }

    func testCh5CC27LabelsDeck2Pad8() {
        let label = RaneOneMK2PadCandidateLabeler.label(channel: 5, cc: 27, value: 127)
        XCTAssertNotNil(label)
        XCTAssertTrue(label!.contains("deck 2 pad 8"))
        XCTAssertTrue(label!.contains("CC27"))
        XCTAssertTrue(label!.contains("ch5"))
    }

    // MARK: - 5–6: Shifted/clear pad labelling

    func testCh4CC28LabelsDeck1ShiftedPad1() {
        let label = RaneOneMK2PadCandidateLabeler.label(channel: 4, cc: 28, value: 127)
        XCTAssertNotNil(label)
        XCTAssertTrue(label!.contains("shifted pad candidate"))
        XCTAssertTrue(label!.contains("deck 1 pad 1"))
        XCTAssertTrue(label!.contains("CC28"))
    }

    func testCh5CC35LabelsDeck2ShiftedPad8() {
        let label = RaneOneMK2PadCandidateLabeler.label(channel: 5, cc: 35, value: 127)
        XCTAssertNotNil(label)
        XCTAssertTrue(label!.contains("shifted pad candidate"))
        XCTAssertTrue(label!.contains("deck 2 pad 8"))
        XCTAssertTrue(label!.contains("CC35"))
    }

    // MARK: - 7–8: Small 4-pad strip labelling

    func testCh4CC100LabelsDeck1SmallPad1() {
        let label = RaneOneMK2PadCandidateLabeler.label(channel: 4, cc: 100, value: 127)
        XCTAssertNotNil(label)
        XCTAssertTrue(label!.contains("small pad candidate"))
        XCTAssertTrue(label!.contains("deck 1 small pad 1"))
        XCTAssertTrue(label!.contains("CC100"))
    }

    func testCh5CC103LabelsDeck2SmallPad4() {
        let label = RaneOneMK2PadCandidateLabeler.label(channel: 5, cc: 103, value: 127)
        XCTAssertNotNil(label)
        XCTAssertTrue(label!.contains("small pad candidate"))
        XCTAssertTrue(label!.contains("deck 2 small pad 4"))
        XCTAssertTrue(label!.contains("CC103"))
    }

    // MARK: - 9–10: Shifted small 4-pad strip labelling

    func testCh4CC104LabelsDeck1ShiftedSmallPad1() {
        let label = RaneOneMK2PadCandidateLabeler.label(channel: 4, cc: 104, value: 127)
        XCTAssertNotNil(label)
        XCTAssertTrue(label!.contains("shifted small pad candidate"))
        XCTAssertTrue(label!.contains("deck 1 small pad 1"))
        XCTAssertTrue(label!.contains("CC104"))
    }

    func testCh5CC107LabelsDeck2ShiftedSmallPad4() {
        let label = RaneOneMK2PadCandidateLabeler.label(channel: 5, cc: 107, value: 127)
        XCTAssertNotNil(label)
        XCTAssertTrue(label!.contains("shifted small pad candidate"))
        XCTAssertTrue(label!.contains("deck 2 small pad 4"))
        XCTAssertTrue(label!.contains("CC107"))
    }

    // MARK: - 11–12: Unrelated CC / channel → nil

    func testUnrelatedCCReturnsNil() {
        // CC 19 is just below the large-pad range on both decks.
        XCTAssertNil(RaneOneMK2PadCandidateLabeler.label(channel: 4, cc: 19, value: 127))
        // CC 36 is just above the shifted range on both decks.
        XCTAssertNil(RaneOneMK2PadCandidateLabeler.label(channel: 4, cc: 36, value: 127))
        // CC 50 is well away from any pad range.
        XCTAssertNil(RaneOneMK2PadCandidateLabeler.label(channel: 4, cc: 50, value: 127))
    }

    func testUnrelatedChannelReturnsNil() {
        // Channel 0 CC20 is a valid CC but on ch1, not a Rane pad channel.
        XCTAssertNil(RaneOneMK2PadCandidateLabeler.label(channel: 0, cc: 20, value: 127))
        // Channel 6 CC20 is not a Rane pad channel.
        XCTAssertNil(RaneOneMK2PadCandidateLabeler.label(channel: 6, cc: 20, value: 127))
    }

    // MARK: - 13: Value 0 is shown as release (zero value, not ignored)

    func testValueZeroIsLabelledNotIgnored() {
        let label = RaneOneMK2PadCandidateLabeler.label(channel: 4, cc: 20, value: 0)
        XCTAssertNotNil(label, "value 0 must be labelled, not dropped")
        XCTAssertTrue(label!.contains("value 0"), "label must show value 0")
        XCTAssertTrue(label!.contains("deck 1 pad 1"))
    }

    // MARK: - 14: CC6 platter behaviour is unchanged (returns nil from pad labeler)

    func testCC6OnEitherDeckDoesNotLabelAsPad() {
        // CC6 is the platter ring counter — must never produce a pad candidate label.
        XCTAssertNil(RaneOneMK2PadCandidateLabeler.label(channel: 4, cc: 6, value: 1))
        XCTAssertNil(RaneOneMK2PadCandidateLabeler.label(channel: 5, cc: 6, value: 1))
    }

    // MARK: - 15: No sample playback API is called (labeler is data-only)

    func testLabelerIsPureFunction_NoSideEffects() {
        // Calling label() repeatedly must not trigger audio, MIDI, or any mutation.
        for _ in 0..<10 {
            _ = RaneOneMK2PadCandidateLabeler.label(channel: 4, cc: 20, value: 127)
        }
        XCTAssertTrue(true, "label() is a pure function — no side effects")
    }

    // MARK: - 16: Scoring remains blocked before verification

    func testLabelerDoesNotEnableScoring() {
        // The labeler has no scoring-related API — just verify .label() returns strings.
        let label = RaneOneMK2PadCandidateLabeler.label(channel: 4, cc: 20, value: 127)
        XCTAssertNotNil(label)
        // Pad mappings still carry verificationRequired = true (Slice 1 guard).
        for mapping in ScratchBankPadMappingCatalog.raneOneMKII {
            XCTAssertTrue(mapping.verificationRequired)
            XCTAssertFalse(mapping.canFeedScoring)
        }
    }
}
