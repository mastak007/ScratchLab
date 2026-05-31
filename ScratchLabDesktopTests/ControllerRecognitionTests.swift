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

/// Active controller profile state (Slice 3): the verified built-in or "Unverified",
/// with the unknown-controller warning routed through it. Pure and side-effect free.
final class ActiveControllerProfileTests: XCTestCase {

    func testRecognizedSelectionResolvesToVerifiedRaneAndAllowsFlow() {
        let active = ActiveControllerProfile.resolve(
            selectedSourceName: "RANE ONE",
            availableSourceNames: ["RANE ONE"]
        )
        XCTAssertEqual(active, .builtIn(.raneOneMKII))
        XCTAssertTrue(active.isVerified)
        XCTAssertEqual(active.displayName, "RANE ONE MKII")
        XCTAssertNil(active.warning) // current flow, no warning
    }

    func testUnknownSelectionResolvesToUnverifiedAndWarns() {
        let active = ActiveControllerProfile.resolve(
            selectedSourceName: "Pioneer DDJ-GRV6",
            availableSourceNames: ["Pioneer DDJ-GRV6"]
        )
        XCTAssertEqual(active, .unverified)
        XCTAssertFalse(active.isVerified)
        XCTAssertEqual(active.displayName, "Unverified")
        XCTAssertEqual(active.warning, ControllerRecognition.unverifiedWarning)
    }

    func testWarningRoutesThroughActiveProfile() {
        // The active-profile warning must equal the standalone recognition warning so
        // there is a single source of truth for "is the mapping trustworthy".
        for (selected, available) in [
            (Optional("RANE ONE"), ["RANE ONE", "IAC Driver Bus 1"]),
            (Optional("Pioneer DDJ-GRV6"), ["Pioneer DDJ-GRV6"]),
            (Optional<String>.none, ["RANE ONE MKII"]),
            (Optional<String>.none, ["IAC Driver Bus 1"]),
            (Optional<String>.none, [])
        ] {
            let viaActive = ActiveControllerProfile
                .resolve(selectedSourceName: selected, availableSourceNames: available).warning
            let viaRecognition = ControllerRecognition
                .warning(selectedSourceName: selected, availableSourceNames: available)
            XCTAssertEqual(viaActive, viaRecognition)
        }
    }

    func testResolutionIsPureAndDeterministic() {
        // Same inputs → same result, repeatedly (no hidden state, nothing to mutate).
        let first = ActiveControllerProfile.resolve(
            selectedSourceName: nil, availableSourceNames: ["RANE ONE"]
        )
        let second = ActiveControllerProfile.resolve(
            selectedSourceName: nil, availableSourceNames: ["RANE ONE"]
        )
        XCTAssertEqual(first, second)
    }

    @MainActor
    func testSwitchingActiveProfileViaModelDoesNotMutateTimeline() {
        // The model is not started here (no MIDI/audio); we only flip the source so the
        // derived active profile changes, and assert the captured timeline is untouched.
        let model = ScratchPlaybackLabModel()
        let before = model.timelineEventCount

        model.selectedSourceName = "RANE ONE"
        let verified = model.activeControllerProfile
        XCTAssertTrue(verified.isVerified)
        XCTAssertEqual(model.timelineEventCount, before)

        model.selectedSourceName = "Pioneer DDJ-GRV6"
        let unverified = model.activeControllerProfile
        XCTAssertFalse(unverified.isVerified)
        XCTAssertEqual(model.timelineEventCount, before, "switching profile must not touch timeline")

        XCTAssertNotEqual(verified, unverified)
    }
}

/// Pure mapping validation (Slice 4): is a detected mapping safe enough to capture from?
/// No Core MIDI, no UI — observations are hand-built so every verdict is deterministic.
final class ControllerMappingValidationTests: XCTestCase {

    private let rane = ActiveControllerProfile.builtIn(.raneOneMKII)

    func testRaneWithPlatterAndCrossfaderIsValid() {
        let observation = ControllerSignalObservation(
            platterEventCount: 200, crossfaderEventCount: 12
        )
        let result = ControllerMappingValidation.validate(
            observation: observation, sourceName: "RANE ONE", activeProfile: rane
        )
        XCTAssertEqual(result.validity, .valid)
        XCTAssertTrue(result.reasons.isEmpty)
    }

    func testMissingPlatterIsInvalid() {
        let observation = ControllerSignalObservation(
            platterEventCount: 0, crossfaderEventCount: 5
        )
        let result = ControllerMappingValidation.validate(
            observation: observation, sourceName: "RANE ONE", activeProfile: rane
        )
        XCTAssertEqual(result.validity, .invalid)
        XCTAssertTrue(result.reasons.contains { $0.contains("No platter motion") })
    }

    func testMissingCrossfaderIsWarning() {
        let observation = ControllerSignalObservation(
            platterEventCount: 200, crossfaderEventCount: 0
        )
        let result = ControllerMappingValidation.validate(
            observation: observation, sourceName: "RANE ONE", activeProfile: rane
        )
        XCTAssertEqual(result.validity, .warning)
        XCTAssertTrue(result.reasons.contains { $0.contains("No crossfader motion") })
    }

    func testPitchBendOnlyPlatterIsInvalid() {
        // Pitch bend arrived but no CC6 platter steps → diagnostic-only, cannot capture.
        let observation = ControllerSignalObservation(
            platterEventCount: 0, crossfaderEventCount: 8, pitchBendEventCount: 300
        )
        let result = ControllerMappingValidation.validate(
            observation: observation, sourceName: "RANE ONE", activeProfile: rane
        )
        XCTAssertEqual(result.validity, .invalid)
        XCTAssertTrue(result.reasons.contains { $0.contains("pitch bend is diagnostic-only") })
    }

    func testUnverifiedProfileIsAtLeastWarning() {
        let observation = ControllerSignalObservation(
            platterEventCount: 200, crossfaderEventCount: 12
        )
        let result = ControllerMappingValidation.validate(
            observation: observation, sourceName: "Pioneer DDJ-GRV6", activeProfile: .unverified
        )
        XCTAssertEqual(result.validity, .warning)
        XCTAssertTrue(result.reasons.contains { $0.contains("not a verified profile") })
    }

    func testValidationIsPureAndDeterministic() {
        let observation = ControllerSignalObservation(platterEventCount: 0, pitchBendEventCount: 10)
        let a = ControllerMappingValidation.validate(
            observation: observation, sourceName: "X", activeProfile: .unverified
        )
        let b = ControllerMappingValidation.validate(
            observation: observation, sourceName: "X", activeProfile: .unverified
        )
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.validity, .invalid) // unverified (warn) + pitch-bend-only (invalid)
    }

    // MARK: - Observation bucketing against a profile

    func testObserveBucketsAgainstProfileBindings() {
        let profile = ControllerProfile.raneOneMKII
        let messages: [ParsedMIDIMessage] = [
            MIDIMessageParsing.parse([0xB0, 6, 64]),   // platter CC6
            MIDIMessageParsing.parse([0xB0, 6, 65]),   // platter CC6
            MIDIMessageParsing.parse([0xB0, 8, 100]),  // crossfader CC8
            MIDIMessageParsing.parse([0xE0, 0x10, 0x40]), // pitch bend
            MIDIMessageParsing.parse([0xB0, 20, 5])    // unrelated CC — ignored
        ]
        let observation = ControllerSignalObservation.observe(messages, profile: profile)
        XCTAssertEqual(observation.platterEventCount, 2)
        XCTAssertEqual(observation.crossfaderEventCount, 1)
        XCTAssertEqual(observation.pitchBendEventCount, 1)
    }
}
