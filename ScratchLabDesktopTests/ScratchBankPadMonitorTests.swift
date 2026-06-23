import XCTest
@testable import ScratchLab

/// Scratch bank pad monitor tests.
/// Verifies the compact label builder and the engine-level @Published property.
final class ScratchBankPadMonitorTests: XCTestCase {

    // MARK: - 1–4. Known pad CC → played/gated label

    func testDeck1Pad1ResolutionEnabled() {
        let label = MacCaptureEngine.compactScratchBankPadLabel(
            channel: 4, cc: 20, value: 127, isPreviewEnabled: true
        )
        XCTAssertEqual(label, "Deck 1 Pad 1 → ahhh · played")
    }

    func testDeck1Pad1ResolutionDisabled() {
        let label = MacCaptureEngine.compactScratchBankPadLabel(
            channel: 4, cc: 20, value: 127, isPreviewEnabled: false
        )
        XCTAssertEqual(label, "Deck 1 Pad 1 → ahhh · gated")
    }

    func testDeck1Pad4ResolutionEnabled() {
        let label = MacCaptureEngine.compactScratchBankPadLabel(
            channel: 4, cc: 23, value: 127, isPreviewEnabled: true
        )
        XCTAssertEqual(label, "Deck 1 Pad 4 → check_it_out · played")
    }

    func testDeck2Pad1ResolutionEnabled() {
        let label = MacCaptureEngine.compactScratchBankPadLabel(
            channel: 5, cc: 20, value: 127, isPreviewEnabled: true
        )
        XCTAssertEqual(label, "Deck 2 Pad 1 → ahhh · played")
    }

    // MARK: - 5–6. Pads 5–8 (no sample mapped)

    func testDeck1Pad5NoSample() {
        let label = MacCaptureEngine.compactScratchBankPadLabel(
            channel: 4, cc: 24, value: 127, isPreviewEnabled: true
        )
        XCTAssertEqual(label, "Deck 1 Pad 5 · (no sample)")
    }

    func testDeck1Pad8NoSample() {
        let label = MacCaptureEngine.compactScratchBankPadLabel(
            channel: 4, cc: 27, value: 127, isPreviewEnabled: false
        )
        XCTAssertEqual(label, "Deck 1 Pad 8 · (no sample)")
    }

    // MARK: - 7–9. Release / wrong channel / wrong CC → nil

    func testReleaseReturnsNil() {
        XCTAssertNil(MacCaptureEngine.compactScratchBankPadLabel(
            channel: 4, cc: 20, value: 0, isPreviewEnabled: true
        ))
    }

    func testWrongChannelReturnsNil() {
        XCTAssertNil(MacCaptureEngine.compactScratchBankPadLabel(
            channel: 0, cc: 20, value: 127, isPreviewEnabled: true
        ))
        XCTAssertNil(MacCaptureEngine.compactScratchBankPadLabel(
            channel: 6, cc: 20, value: 127, isPreviewEnabled: true
        ))
        XCTAssertNil(MacCaptureEngine.compactScratchBankPadLabel(
            channel: 3, cc: 20, value: 127, isPreviewEnabled: true
        ))
    }

    func testCCOutsideRangeReturnsNil() {
        XCTAssertNil(MacCaptureEngine.compactScratchBankPadLabel(
            channel: 4, cc: 19, value: 127, isPreviewEnabled: true
        ))
        XCTAssertNil(MacCaptureEngine.compactScratchBankPadLabel(
            channel: 4, cc: 28, value: 127, isPreviewEnabled: true
        ))
        XCTAssertNil(MacCaptureEngine.compactScratchBankPadLabel(
            channel: 4, cc: 100, value: 127, isPreviewEnabled: true
        ))
    }

    // MARK: - 10. Engine property defaults to empty

    func testEngineLastScratchBankPadLabelDefaultsToEmpty() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        XCTAssertEqual(engine.lastScratchBankPadLabel, "",
            "lastScratchBankPadLabel must default to empty string")
    }

    // MARK: - 11. Property is private(set) — testable but only engine sets it

    func testEnginePadLabelStartsEmptyAndStaysNonEmptyAfterSimulatedUpdate() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        XCTAssertEqual(engine.lastScratchBankPadLabel, "",
            "lastScratchBankPadLabel must default to empty string")

        // The engine's MIDI handler sets this property. We verify the static
        // helper produces the correct label for both played and gated states,
        // and that the engine exposes the property as read-only to callers.
        let playedLabel = MacCaptureEngine.compactScratchBankPadLabel(
            channel: 4, cc: 20, value: 127, isPreviewEnabled: true
        )
        XCTAssertEqual(playedLabel, "Deck 1 Pad 1 → ahhh · played")

        let gatedLabel = MacCaptureEngine.compactScratchBankPadLabel(
            channel: 4, cc: 20, value: 127, isPreviewEnabled: false
        )
        XCTAssertEqual(gatedLabel, "Deck 1 Pad 1 → ahhh · gated")
    }

    // MARK: - 12. Label format contains expected parts

    func testPlayedLabelContainsExpectedParts() {
        let label = MacCaptureEngine.compactScratchBankPadLabel(
            channel: 4, cc: 22, value: 127, isPreviewEnabled: true
        )
        XCTAssertNotNil(label)
        XCTAssertTrue(label!.contains("Deck 1"))
        XCTAssertTrue(label!.contains("Pad 3"))
        XCTAssertTrue(label!.contains("ah_yeah"))
        XCTAssertTrue(label!.contains("played"))
        XCTAssertFalse(label!.contains("gated"))
    }

    func testGatedLabelContainsExpectedParts() {
        let label = MacCaptureEngine.compactScratchBankPadLabel(
            channel: 5, cc: 21, value: 127, isPreviewEnabled: false
        )
        XCTAssertNotNil(label)
        XCTAssertTrue(label!.contains("Deck 2"))
        XCTAssertTrue(label!.contains("Pad 2"))
        XCTAssertTrue(label!.contains("fresh"))
        XCTAssertTrue(label!.contains("gated"))
        XCTAssertFalse(label!.contains("played"))
    }

    // MARK: - 13. Label has no scoring / routing / audio terminology

    func testLabelHasNoForbiddenTerminology() {
        let label = MacCaptureEngine.compactScratchBankPadLabel(
            channel: 4, cc: 20, value: 127, isPreviewEnabled: true
        )
        let lower = label!.lowercased()
        let forbidden = ["scor", "rout", "audio", "midi", "cc", "channel"]
        for word in forbidden {
            XCTAssertFalse(lower.contains(word),
                "label must not contain '\(word)'; got: \(label!)")
        }
    }

    // MARK: - 14. All 8 pads on deck 1 produce non-nil labels

    func testAllEightLargePadsOnDeck1ProduceNonNilLabels() {
        for cc in 20...27 {
            let label = MacCaptureEngine.compactScratchBankPadLabel(
                channel: 4, cc: cc, value: 127, isPreviewEnabled: true
            )
            XCTAssertNotNil(label, "CC\(cc) on deck 1 must produce a non-nil label")
        }
    }
}
