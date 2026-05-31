import XCTest
@testable import ScratchLab

/// Scratch Playback Lab — pure controller recognition (the "unverified mapping" warning).
/// No Core MIDI, no AVFoundation, no UI, no notation/replay/export are exercised here:
/// recognition is name-only and never mutates anything.
final class ControllerRecognitionTests: XCTestCase {

    // MARK: - Single source name

    func testRaneOneIsRecognized() {
        XCTAssertTrue(ControllerRecognition.isRecognized(sourceName: "RANE ONE"))
    }

    func testRaneOneMK2IsRecognized() {
        XCTAssertTrue(ControllerRecognition.isRecognized(sourceName: "RANE ONE MKII"))
    }

    func testRecognitionIsCaseInsensitive() {
        XCTAssertTrue(ControllerRecognition.isRecognized(sourceName: "rane one"))
        XCTAssertTrue(ControllerRecognition.isRecognized(sourceName: "Rane One mkII"))
    }

    func testUnknownControllerIsNotRecognized() {
        XCTAssertFalse(ControllerRecognition.isRecognized(sourceName: "Pioneer DDJ-GRV6"))
        XCTAssertFalse(ControllerRecognition.isRecognized(sourceName: "IAC Driver Bus 1"))
    }

    func testUnrelatedRaneGearIsNotMistakenForTheDeck() {
        // Intentionally strict: only the verified ONE deck mapping is recognized,
        // not any device that merely contains "RANE".
        XCTAssertFalse(ControllerRecognition.isRecognized(sourceName: "RANE SEVENTY"))
    }

    // MARK: - Active selection (selected source + available sources)

    func testSpecificRaneSelectionIsRecognized() {
        XCTAssertNil(ControllerRecognition.warning(
            selectedSourceName: "RANE ONE",
            availableSourceNames: ["RANE ONE", "IAC Driver Bus 1"]
        ))
    }

    func testSpecificUnknownSelectionWarns() {
        XCTAssertEqual(
            ControllerRecognition.warning(
                selectedSourceName: "Pioneer DDJ-GRV6",
                availableSourceNames: ["RANE ONE", "Pioneer DDJ-GRV6"]
            ),
            ControllerRecognition.unverifiedWarning
        )
    }

    func testAllSourcesWithRanePresentIsRecognized() {
        XCTAssertNil(ControllerRecognition.warning(
            selectedSourceName: nil,
            availableSourceNames: ["IAC Driver Bus 1", "RANE ONE MKII"]
        ))
    }

    func testAllSourcesWithOnlyUnknownGearWarns() {
        XCTAssertEqual(
            ControllerRecognition.warning(
                selectedSourceName: nil,
                availableSourceNames: ["Pioneer DDJ-GRV6", "IAC Driver Bus 1"]
            ),
            ControllerRecognition.unverifiedWarning
        )
    }

    func testNoSourcesDoesNotWarn() {
        // Nothing connected → nothing to capture → no false alarm.
        XCTAssertNil(ControllerRecognition.warning(
            selectedSourceName: nil,
            availableSourceNames: []
        ))
    }

    func testWarningCopyIsExactAndProfileSafe() {
        XCTAssertEqual(
            ControllerRecognition.unverifiedWarning,
            "Unverified controller mapping — captured notation may be invalid."
        )
    }
}
