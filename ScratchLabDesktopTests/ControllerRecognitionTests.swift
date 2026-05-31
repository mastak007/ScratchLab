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

/// Pure MIDI-learn inference (Slice 5): guess the platter (±1 ring) and crossfader
/// (broad 0...127 sweep) from an observed stream. Model only, no UI, no persistence.
final class ControllerMappingInferenceTests: XCTestCase {

    private func ccStream(cc: Int, values: [Int]) -> [ParsedMIDIMessage] {
        values.map { MIDIMessageParsing.parse([0xB0 | UInt8(0), UInt8(cc), UInt8($0)]) }
    }

    private func pitchBendStream(count: Int) -> [ParsedMIDIMessage] {
        (0..<count).map { i in
            let raw = 4000 + i * 7
            return MIDIMessageParsing.parse([0xE0, UInt8(raw & 0x7F), UInt8((raw >> 7) & 0x7F)])
        }
    }

    func testCC6PlusOneStreamInfersPlatter() {
        // A clean ±1 ring ramp on CC6 — the RANE platter fingerprint.
        let values = Array(40...80) // 41 values, 40 ±1 transitions
        let result = ControllerMappingInference.infer(ccStream(cc: 6, values: values))
        XCTAssertEqual(result.platter?.signal, .controlChange(number: 6))
        XCTAssertGreaterThan(result.platter?.confidence ?? 0, 0.9)
        XCTAssertNil(result.crossfader)
    }

    func testCC8SweepInfersCrossfader() {
        // A broad sweep across the 0...127 range, in big jumps (not ±1).
        let values = [0, 20, 40, 60, 80, 100, 120, 127, 100, 60, 20, 0]
        let result = ControllerMappingInference.infer(ccStream(cc: 8, values: values))
        XCTAssertEqual(result.crossfader?.signal, .controlChange(number: 8))
        XCTAssertGreaterThan(result.crossfader?.confidence ?? 0, 0.9)
        XCTAssertNil(result.platter) // a sweep is not a ±1 platter
    }

    func testPitchBendOnlyStreamIsNotAcceptedAsPlatter() {
        let result = ControllerMappingInference.infer(pitchBendStream(count: 40))
        XCTAssertNil(result.platter, "pitch bend is diagnostic-only and must not be a platter candidate")
        XCTAssertNil(result.crossfader)
        XCTAssertTrue(result.notes.contains { $0.contains("diagnostic-only") })
    }

    func testNoisyUnrelatedCCIsIgnored() {
        // A jittery CC with no ±1 ring run and a narrow range — neither platter nor fader.
        let values = [64, 70, 62, 68, 66, 64, 69, 63, 65, 67]
        let result = ControllerMappingInference.infer(ccStream(cc: 20, values: values))
        XCTAssertNil(result.platter)
        XCTAssertNil(result.crossfader)
    }

    func testCombinedStreamInfersBothControls() {
        var stream = ccStream(cc: 6, values: Array(40...80))
        stream += ccStream(cc: 8, values: [0, 20, 40, 60, 80, 100, 120, 127, 64])
        let result = ControllerMappingInference.infer(stream)
        XCTAssertEqual(result.platter?.signal, .controlChange(number: 6))
        XCTAssertEqual(result.crossfader?.signal, .controlChange(number: 8))
    }

    func testInferenceIsDeterministic() {
        let stream = ccStream(cc: 6, values: Array(40...80))
        XCTAssertEqual(ControllerMappingInference.infer(stream), ControllerMappingInference.infer(stream))
    }
}

/// Guided mapping check state machine (Slice 6): walks spin-platter → move-crossfader →
/// review → confirm, collecting MIDI and inferring controls. Pure; memory only.
final class GuidedMappingSessionTests: XCTestCase {

    private func cc(_ number: Int, _ value: Int) -> ParsedMIDIMessage {
        MIDIMessageParsing.parse([0xB0, UInt8(number), UInt8(value)])
    }

    func testFlowProgressesThroughStepsAndInfers() {
        var session = GuidedMappingSession()
        XCTAssertEqual(session.step, .idle)
        XCTAssertFalse(session.isCollecting)

        session.start()
        XCTAssertEqual(session.step, .spinPlatter)
        XCTAssertTrue(session.isCollecting)

        // Spin the platter: a ±1 ring ramp on CC6.
        for value in 40...80 { session.record(cc(6, value)) }
        session.advance()
        XCTAssertEqual(session.step, .moveCrossfader)

        // Move the crossfader: a broad sweep on CC8.
        for value in [0, 20, 40, 60, 80, 100, 120, 127, 64] { session.record(cc(8, value)) }
        session.advance()

        guard case .review(let candidates) = session.step else {
            return XCTFail("expected review step")
        }
        XCTAssertEqual(candidates.platter?.signal, .controlChange(number: 6))
        XCTAssertEqual(candidates.crossfader?.signal, .controlChange(number: 8))
        XCTAssertNotNil(session.inferred)
        XCTAssertNil(session.confirmedMapping)

        session.advance()
        XCTAssertNotNil(session.confirmedMapping)
        if case .confirmed = session.step {} else { XCTFail("expected confirmed step") }
    }

    func testRecordIgnoredWhenNotCollecting() {
        var session = GuidedMappingSession()
        session.record(cc(6, 40)) // idle → ignored
        session.start()
        session.advance() // moveCrossfader still collecting
        session.advance() // review — no longer collecting
        let countAtReview = session.collected.count
        session.record(cc(6, 41)) // ignored at review
        XCTAssertEqual(session.collected.count, countAtReview)
    }

    func testCancelResetsToIdle() {
        var session = GuidedMappingSession()
        session.start()
        session.record(cc(6, 40))
        session.cancel()
        XCTAssertEqual(session.step, .idle)
        XCTAssertTrue(session.collected.isEmpty)
    }

    func testConfirmIsTerminal() {
        var session = GuidedMappingSession()
        session.start(); session.advance(); session.advance(); session.advance() // → confirmed
        let confirmed = session.step
        session.advance() // no-op
        XCTAssertEqual(session.step, confirmed)
    }
}

/// Tester onboarding copy (Slice 11): the private-build help text must be honest and
/// PROFILE.md-safe — no overclaiming, and it must frame captured notation as a preview.
final class TesterOnboardingContentTests: XCTestCase {

    func testNoForbiddenOverclaimingPhrases() {
        let joined = TesterOnboardingContent.allText.joined(separator: "\n").lowercased()
        for phrase in TesterOnboardingContent.forbiddenPhrases {
            XCTAssertFalse(joined.contains(phrase.lowercased()), "tester copy must not contain \"\(phrase)\"")
        }
    }

    func testCopyFramesCaptureAsEstimatedPreview() {
        let joined = TesterOnboardingContent.allText.joined(separator: "\n").lowercased()
        XCTAssertTrue(joined.contains("estimated"))
        XCTAssertTrue(joined.contains("preview"))
    }

    func testCopyStatesItDoesNotScore() {
        let joined = TesterOnboardingContent.allText.joined(separator: "\n").lowercased()
        XCTAssertTrue(joined.contains("does not score") || joined.contains("not a saved, scored"))
    }

    func testSectionsAreNonEmpty() {
        XCTAssertFalse(TesterOnboardingContent.sections.isEmpty)
        for section in TesterOnboardingContent.sections {
            XCTAssertFalse(section.title.isEmpty)
            XCTAssertFalse(section.body.isEmpty)
        }
    }
}

/// Scratch Visualizer mirror: SV's clean 14-bit pitch bend maps to absolute sample position,
/// and Auto mode mirrors ONLY SV — never the RANE hardware (whose pitch bend aliases).
final class ScratchVisualizerMirrorTests: XCTestCase {

    private let span = Double(ScratchVisualizerMirror.positionEndBend - ScratchVisualizerMirror.positionStartBend)

    // MARK: - Pitch bend → absolute position (8192 = start, 16383 = end)

    func testCenterIsStartAndMaxIsEnd() {
        XCTAssertEqual(ScratchVisualizerMirror.positionFraction(pitchBend: 8192), 0.0, accuracy: 1e-9)
        XCTAssertEqual(ScratchVisualizerMirror.positionFraction(pitchBend: 16383), 1.0, accuracy: 1e-9)
    }

    func testClampsBelowStartAndAboveEnd() {
        XCTAssertEqual(ScratchVisualizerMirror.positionFraction(pitchBend: 0), 0.0, accuracy: 1e-9)
        // 8162 = the observed session floor, just below centre → clamps to start.
        XCTAssertEqual(ScratchVisualizerMirror.positionFraction(pitchBend: 8162), 0.0, accuracy: 1e-9)
        XCTAssertEqual(ScratchVisualizerMirror.positionFraction(pitchBend: 30000), 1.0, accuracy: 1e-9)
    }

    func testMatchesObservedScratch() {
        // Cue ~11634 → ~0.42; peak 15155 → ~0.85 (partial travel stays partial).
        XCTAssertEqual(ScratchVisualizerMirror.positionFraction(pitchBend: 11634),
                       (11634.0 - 8192) / span, accuracy: 1e-9)
        XCTAssertEqual(ScratchVisualizerMirror.positionFraction(pitchBend: 15155), 0.85, accuracy: 0.01)
    }

    // MARK: - Mode resolution (Auto mirrors SV, never RANE)

    func testSourceDetection() {
        XCTAssertTrue(ScratchVisualizerMirror.isScratchVisualizerSource(name: "SV Midi Out"))
        XCTAssertTrue(ScratchVisualizerMirror.isScratchVisualizerSource(name: "Scratch Visualizer"))
        XCTAssertFalse(ScratchVisualizerMirror.isScratchVisualizerSource(name: "Rane ONE MKII"))
        XCTAssertFalse(ScratchVisualizerMirror.isScratchVisualizerSource(name: nil))
    }

    func testAutoMirrorsSVButNeverRane() {
        XCTAssertTrue(ScratchVisualizerMirror.isActive(mode: .auto, sourceName: "SV Midi Out"))
        XCTAssertFalse(ScratchVisualizerMirror.isActive(mode: .auto, sourceName: "Rane ONE MKII"))
        XCTAssertFalse(ScratchVisualizerMirror.isActive(mode: .auto, sourceName: nil))
    }

    func testForcedModesOverrideRegardlessOfSource() {
        XCTAssertTrue(ScratchVisualizerMirror.isActive(mode: .mirrorSV, sourceName: "Rane ONE MKII"))
        XCTAssertTrue(ScratchVisualizerMirror.isActive(mode: .mirrorSV, sourceName: nil))
        XCTAssertFalse(ScratchVisualizerMirror.isActive(mode: .rane, sourceName: "SV Midi Out"))
    }
}
