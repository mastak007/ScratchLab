import XCTest
@testable import ScratchLab

/// Gate tests for isScratchBankMIDIPreviewEnabled — the debug toggle that
/// controls whether bundled scratch-bank samples play from mapped MIDI pads.
///
/// Verifies default state, enable/disable, and the router-level isEnabled
/// seam (ScratchBankPadEventRouter.sampleID(isEnabled:)).
final class ScratchBankMIDIPreviewGateTests: XCTestCase {

    // MARK: - 1. Default false

    func testIsScratchBankMIDIPreviewEnabledDefaultsToFalse() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        XCTAssertFalse(engine.isScratchBankMIDIPreviewEnabled,
            "Scratch Bank MIDI preview must default to false (off)")
    }

    // MARK: - 2. Enable

    func testEnablingToggleSetsIsScratchBankMIDIPreviewEnabledTrue() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        engine.isScratchBankMIDIPreviewEnabled = true
        XCTAssertTrue(engine.isScratchBankMIDIPreviewEnabled,
            "Setting isScratchBankMIDIPreviewEnabled to true must take effect immediately")
    }

    // MARK: - 3. Disable

    func testDisablingToggleSetsIsScratchBankMIDIPreviewEnabledFalse() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        engine.isScratchBankMIDIPreviewEnabled = true
        engine.isScratchBankMIDIPreviewEnabled = false
        XCTAssertFalse(engine.isScratchBankMIDIPreviewEnabled,
            "Setting isScratchBankMIDIPreviewEnabled back to false must take effect immediately")
    }

    // MARK: - 4. Toggle cycle (default → true → false → true → false)

    func testToggleCyclePreservesValue() {
        let engine = MacCaptureEngine(autoRefreshDevices: false)
        XCTAssertFalse(engine.isScratchBankMIDIPreviewEnabled, "default")

        engine.isScratchBankMIDIPreviewEnabled = true
        XCTAssertTrue(engine.isScratchBankMIDIPreviewEnabled, "cycle step 1: on")

        engine.isScratchBankMIDIPreviewEnabled = false
        XCTAssertFalse(engine.isScratchBankMIDIPreviewEnabled, "cycle step 2: off")

        engine.isScratchBankMIDIPreviewEnabled = true
        XCTAssertTrue(engine.isScratchBankMIDIPreviewEnabled, "cycle step 3: on")

        engine.isScratchBankMIDIPreviewEnabled = false
        XCTAssertFalse(engine.isScratchBankMIDIPreviewEnabled, "cycle step 4: off")
    }

    // MARK: - 5. Router gate: disabled → nil (existing seam confirmed)

    func testRouterGateDisabledReturnsNilForAllKnownPads() {
        // The router's isEnabled parameter is the primary test seam for the
        // toggle. When isScratchBankMIDIPreviewEnabled is false, the MIDI
        // receive path passes isEnabled: false, and sampleID(_:_:_:isEnabled:)
        // must return nil for every mapped pad CC.
        for cc in 20...23 {
            XCTAssertNil(ScratchBankPadEventRouter.sampleID(
                channel: 4, cc: cc, value: 127, isEnabled: false
            ), "CC\(cc) must return nil when disabled")
        }
    }

    // MARK: - 6. Router gate: enabled → resolves for known pads

    func testRouterGateEnabledResolvesAllFourPads() {
        let expected: [Int: String] = [
            20: "ahhh",
            21: "fresh",
            22: "ah_yeah",
            23: "check_it_out",
        ]
        for (cc, sampleID) in expected {
            XCTAssertEqual(ScratchBankPadEventRouter.sampleID(
                channel: 4, cc: cc, value: 127, isEnabled: true
            ), sampleID, "CC\(cc) must resolve to \(sampleID) when enabled")
        }
    }

    // MARK: - 7. Two independent engine instances don't share gate state

    func testTwoEnginesHaveIndependentGateState() {
        let engine1 = MacCaptureEngine(autoRefreshDevices: false)
        let engine2 = MacCaptureEngine(autoRefreshDevices: false)

        engine1.isScratchBankMIDIPreviewEnabled = true

        XCTAssertTrue(engine1.isScratchBankMIDIPreviewEnabled)
        XCTAssertFalse(engine2.isScratchBankMIDIPreviewEnabled,
            "Each engine instance must have independent gate state")
    }
}
