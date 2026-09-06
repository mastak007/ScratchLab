// ReferenceAuthoringTests.swift
// ScratchLabDesktopTests
//
// Pure-model tests for reference authoring: technique requirements, take
// validation, lifecycle, the registry's refusal to fall back to deprecated
// assets, call-and-response scheduling, and package model validation.
//
// No CoreMIDI, no capture engine, no audio. Every artifact measurement is
// supplied as data, which is what lets the whole rule set be exercised without
// a controller or a take on disk.

import XCTest
@testable import ScratchLab

final class ReferenceAuthoringTests: XCTestCase {

    // MARK: - Shared fixtures

    private static let calibration = CrossfaderCalibration(
        address: CrossfaderMIDIAddress(
            deviceIdentifier: "Rane ONE MKII",
            deviceName: "Rane ONE MKII",
            channel: 15,
            controller: 8
        ),
        fullLeftRawValue: 0,
        centerRawValue: 52,
        fullRightRawValue: 104,
        openEnd: .left,
        activeDeck: .rightDeck,
        calibratedAt: Date(timeIntervalSince1970: 1_788_000_000)
    )

    private static let deviceInfo = ReferenceDeviceInfo(
        platform: "macOS",
        appVersion: "1.0.1",
        controllerName: "Rane ONE MKII",
        controllerIdentifier: "Rane ONE MKII",
        audioDeviceName: "Rane ONE MKII",
        videoDeviceName: "Studio Camera",
        // Linked wrist motion is REQUIRED evidence for a canonical reference,
        // so the shared "clean take" fixture carries it; the missing-Watch
        // case has its own test.
        watchLinked: true
    )

    private func makeMetadata(
        technique: ReferenceTechnique = .babyScratch,
        bpm: Int = 95,
        phraseBars: Int = 1,
        repetitionCount: Int = 4,
        lifecycleState: ReferenceLifecycleState = .draft
    ) -> ReferenceTakeMetadata {
        ReferenceTakeMetadata(
            referenceTakeID: "ref-take-0001",
            authoringSessionID: "auth-0001",
            takeNumber: 1,
            operatorName: "Karl",
            technique: technique,
            pattern: ReferencePatternIdentity(
                id: "quarter_notes",
                name: "Quarter notes",
                phraseBars: phraseBars
            ),
            bpm: bpm,
            repetitionCount: repetitionCount,
            startingPlatterDirection: .forward,
            faderVariant: technique == .babyScratch ? .faderOpenThroughout : .crossfader,
            referenceVersion: 1,
            crossfaderCalibration: Self.calibration,
            deviceInfo: Self.deviceInfo,
            recordedAt: Date(timeIntervalSince1970: 1_788_000_100),
            lifecycleState: lifecycleState
        )
    }

    private func goodAudio(fileName: String = "reference.wav") -> ReferenceArtifactMeasurement {
        ReferenceArtifactMeasurement(
            fileName: fileName,
            exists: true,
            byteCount: 1_024_000,
            peakLevel: 0.82,
            frameCount: 256_000
        )
    }

    private func goodSidecar() -> ReferenceArtifactMeasurement {
        ReferenceArtifactMeasurement(fileName: "take.json", exists: true, byteCount: 4_096)
    }

    /// Build a derivation directly from state intervals, so a test can state
    /// the fader behaviour it means without simulating a MIDI stream.
    private func derivation(
        _ pieces: [(CrossfaderGateState, Double, Double)],
        events: [(CrossfaderSemanticEventKind, Double, Double)] = []
    ) -> CrossfaderDerivation {
        CrossfaderDerivation(
            intervals: pieces.map {
                CrossfaderStateInterval(
                    state: $0.0,
                    startTime: $0.1,
                    endTime: $0.2,
                    startPosition: $0.0 == .open ? 1 : 0,
                    endPosition: $0.0 == .open ? 1 : 0
                )
            },
            events: events.map {
                CrossfaderSemanticEvent(
                    kind: $0.0,
                    startTime: $0.1,
                    endTime: $0.2,
                    fromPosition: 0,
                    toPosition: 1
                )
            }
        )
    }

    private func makeEvidence(
        metadata: ReferenceTakeMetadata,
        boundaries: ReferencePhraseBoundaries? = nil,
        audio: ReferenceArtifactMeasurement? = nil,
        video: ReferenceArtifactMeasurement? = nil,
        crossfaderSampleCount: Int = 800,
        platterEventCount: Int = 42,
        derivation: CrossfaderDerivation? = nil,
        observedAddress: CrossfaderMIDIAddress? = ReferenceAuthoringTests.calibration.address,
        // Linked wrist evidence is the shared "clean take" default; the
        // pending / missing / mismatched states have their own cases.
        watchEvidence: ReferenceWatchEvidence = .linked(motionFileName: "watch-motion.json")
    ) -> ReferenceTakeEvidence {
        var resolvedBoundaries = boundaries ?? ReferencePhraseBoundaries.nominal(for: metadata)
        if resolvedBoundaries.selectedRepetitionIndex == nil {
            resolvedBoundaries.selectedRepetitionIndex = 0
        }
        let samples = (0..<crossfaderSampleCount).map { index in
            CrossfaderPositionSample(
                takeRelativeTime: Double(index) * 0.001,
                rawValue: 1,
                normalizedPosition: 1.0
            )
        }
        return ReferenceTakeEvidence(
            metadata: metadata,
            boundaries: resolvedBoundaries,
            audio: audio ?? goodAudio(),
            video: video,
            sidecar: goodSidecar(),
            actualMediaFileName: video?.fileName,
            crossfaderRawSamples: samples,
            observedCrossfaderAddress: observedAddress,
            platterMovementEventCount: platterEventCount,
            derivation: derivation ?? self.derivation([(.open, 0, 10)]),
            watchEvidence: watchEvidence
        )
    }

    // MARK: - Technique identity

    func testFlareCannotExistWithoutAClickCount() {
        // A generic "flare" token is not a technique and must not resolve.
        XCTAssertNil(ReferenceTechnique(scratchTypeID: "flare"))
        XCTAssertEqual(ReferenceTechnique(scratchTypeID: "flare_1click"), .flare(.oneClick))
        XCTAssertEqual(ReferenceTechnique(scratchTypeID: "flare_2click"), .flare(.twoClick))
        XCTAssertEqual(ReferenceTechnique(scratchTypeID: "flare_3click"), .flare(.threeClick))
    }

    func testFlareClickCountDrivesTheRequiredCutCount() {
        XCTAssertEqual(ReferenceTechnique.flare(.oneClick).defaultFaderExpectation.minimumCutEventsPerRepetition, 1)
        XCTAssertEqual(ReferenceTechnique.flare(.twoClick).defaultFaderExpectation.minimumCutEventsPerRepetition, 2)
        XCTAssertEqual(ReferenceTechnique.flare(.threeClick).defaultFaderExpectation.minimumCutEventsPerRepetition, 3)
    }

    func testBabyScratchExpectsAContinuouslyOpenFaderAndNoCuts() {
        let expectation = ReferenceTechnique.babyScratch.defaultFaderExpectation
        XCTAssertTrue(expectation.requiresContinuouslyOpenFader)
        XCTAssertEqual(expectation.minimumCutEventsPerRepetition, 0)
        XCTAssertEqual(expectation.maximumUnknownEventRatio, 0)
    }

    func testChirpAndTransformRequireFaderActivity() {
        XCTAssertFalse(ReferenceTechnique.chirp.defaultFaderExpectation.requiresContinuouslyOpenFader)
        XCTAssertGreaterThanOrEqual(ReferenceTechnique.chirp.defaultFaderExpectation.minimumCutEventsPerRepetition, 1)
        XCTAssertGreaterThanOrEqual(ReferenceTechnique.transform.defaultFaderExpectation.minimumCutEventsPerRepetition, 2)
    }

    func testEveryTechniqueRequiresOperatorApproval() {
        for technique in ReferenceTechnique.minimumRequiredSet {
            XCTAssertTrue(
                technique.defaultFaderExpectation.requiresOperatorApproval,
                "\(technique.displayName) must not be publishable without a human decision."
            )
        }
    }

    func testOnlyBabyScratchHasVerifiedTargetSemanticsToday() {
        XCTAssertTrue(ReferenceTechnique.babyScratch.hasVerifiedTargetSemantics)
        XCTAssertFalse(ReferenceTechnique.chirp.hasVerifiedTargetSemantics)
        XCTAssertFalse(ReferenceTechnique.transform.hasVerifiedTargetSemantics)
        XCTAssertFalse(ReferenceTechnique.flare(.twoClick).hasVerifiedTargetSemantics)
    }

    // MARK: - Validation: a clean take

    func testACleanBabyScratchTakePassesValidation() {
        let evidence = makeEvidence(metadata: makeMetadata())
        let report = ReferenceValidator.validate(evidence)
        XCTAssertTrue(report.passes, "Unexpected failures: \(report.failureMessages)")
    }

    // MARK: - Validation: technique fader requirements

    func testBabyScratchFailsWhenTheFaderLeavesTheOpenZone() {
        let evidence = makeEvidence(
            metadata: makeMetadata(technique: .babyScratch),
            derivation: derivation(
                [(.open, 0, 2), (.closed, 2, 3), (.open, 3, 10)],
                events: [(.cut, 2, 2.1), (.release, 2.9, 3)]
            )
        )
        let report = ReferenceValidator.validate(evidence)
        XCTAssertFalse(report.passes)
        XCTAssertTrue(
            report.failureMessages.contains { $0.contains("crossfader open") },
            report.failureMessages.description
        )
    }

    func testUnconfirmedTransformCutRequirementIsAdvisoryNotBlocking() {
        // ScratchLab has not been shown a correct transform — no recorded
        // take is valid reference material — so the shipped
        // `.provisionalDefault` cut-count requirement must NOT fail a take on
        // its own. Automated validation only enforces capture integrity here;
        // technique correctness is CXL's call in review.
        let metadata = makeMetadata(technique: .transform, bpm: 100)
        let evidence = makeEvidence(
            metadata: metadata,
            derivation: derivation(
                [(.open, 0, 20)],
                events: [(.cut, 2.5, 2.6)]
            )
        )
        XCTAssertFalse(
            ReferenceTechnique.transform.defaultFaderExpectation.source.isOperatorConfirmed
        )
        let report = ReferenceValidator.validate(evidence)
        XCTAssertTrue(
            report.failureMessages.filter { $0.contains("crossfader cut") }.isEmpty,
            "An unconfirmed technique-shape requirement must not block approval: \(report.failureMessages)"
        )
    }

    func testOnceCXLConfirmsTheTransformRequirementTheSameTakeFails() {
        let metadata = makeMetadata(technique: .transform, bpm: 100)
        // One cut in repetition 0, nothing anywhere else.
        let evidence = makeEvidence(
            metadata: metadata,
            derivation: derivation(
                [(.open, 0, 20)],
                events: [(.cut, 2.5, 2.6)]
            )
        )
        let confirmed = ReferenceTechnique.transform.defaultFaderExpectation.confirmed(
            by: "CXL",
            at: Date(timeIntervalSince1970: 1_788_000_000)
        )
        XCTAssertTrue(confirmed.source.isOperatorConfirmed)
        let report = ReferenceValidator.validate(evidence, expectation: confirmed)
        XCTAssertFalse(report.passes)
        let cutFindings = report.failureMessages.filter { $0.contains("crossfader cut") }
        XCTAssertEqual(cutFindings.count, 4, "Every repetition should be reported, not just the first.")
    }

    func testTwoClickFlarePassesAgainstAConfirmedRequirementWithAPulseFigure() {
        let metadata = makeMetadata(technique: .flare(.twoClick), bpm: 60, phraseBars: 1)
        // At 60 bpm one bar is 4 s; count-in ends at 4 s, so repetition 0 runs
        // 4…8 s, repetition 1 8…12 s, and so on.
        let events: [(CrossfaderSemanticEventKind, Double, Double)] = [
            (.pulse, 4.5, 4.8),
            (.pulse, 8.5, 8.8),
            (.pulse, 12.5, 12.8),
            (.pulse, 16.5, 16.8)
        ]
        let evidence = makeEvidence(
            metadata: metadata,
            derivation: derivation([(.open, 0, 20)], events: events)
        )
        let confirmed = ReferenceTechnique.flare(.twoClick).defaultFaderExpectation.confirmed(
            by: "CXL",
            at: Date(timeIntervalSince1970: 1_788_000_000)
        )
        let report = ReferenceValidator.validate(evidence, expectation: confirmed)
        XCTAssertTrue(report.passes, "Unexpected failures: \(report.failureMessages)")
    }

    // MARK: - Validation: unknown-event ratio

    func testExcessiveUnknownFaderEventsBlockApproval() {
        // The shape of the 2026-09-04 take: 20 events, 12 unclassified.
        var events: [(CrossfaderSemanticEventKind, Double, Double)] = []
        for index in 0..<12 {
            events.append((.unknown, Double(index) * 0.1, Double(index) * 0.1 + 0.05))
        }
        for index in 12..<20 {
            events.append((.cut, Double(index) * 0.1, Double(index) * 0.1 + 0.05))
        }
        let evidence = makeEvidence(
            metadata: makeMetadata(technique: .chirp),
            derivation: derivation([(.open, 0, 10)], events: events)
        )
        let report = ReferenceValidator.validate(evidence)
        XCTAssertFalse(report.passes)
        XCTAssertTrue(
            report.failureMessages.contains { $0.contains("could not be classified") },
            report.failureMessages.description
        )
    }

    func testUnknownRatioIsMeasuredAgainstTheEventCountNotTheSampleCount() {
        let derived = derivation(
            [(.open, 0, 10)],
            events: [(.unknown, 0, 1), (.cut, 1, 2), (.cut, 2, 3), (.cut, 3, 4)]
        )
        XCTAssertEqual(derived.unknownEventCount, 1)
        XCTAssertEqual(derived.unknownEventRatio, 0.25, accuracy: 0.0001)
    }

    // MARK: - Validation: missing evidence

    /// "No crossfader MIDI was recorded" is now the rule for techniques that
    /// REQUIRE fader cuts. Baby Scratch is performed with the fader held open
    /// and has its own open-state rule — see the D2 cases below.
    func testMissingCrossfaderEvidenceIsReportedExplicitly() {
        let evidence = ReferenceTakeEvidence(
            metadata: makeMetadata(technique: .chirp),
            boundaries: {
                var b = ReferencePhraseBoundaries.nominal(for: makeMetadata(technique: .chirp))
                b.selectedRepetitionIndex = 0
                return b
            }(),
            audio: goodAudio(),
            video: nil,
            sidecar: goodSidecar(),
            actualMediaFileName: nil,
            crossfaderRawSamples: [],
            observedCrossfaderAddress: nil,
            platterMovementEventCount: 42,
            derivation: derivation([(.open, 0, 10)]),
            watchEvidence: .linked(motionFileName: "watch-motion.json")
        )
        let report = ReferenceValidator.validate(evidence)
        XCTAssertFalse(report.passes)
        XCTAssertTrue(
            report.failureMessages.contains { $0.contains("No crossfader MIDI was recorded") },
            report.failureMessages.description
        )
    }

    func testMissingPlatterEvidenceIsReportedExplicitly() {
        let evidence = makeEvidence(metadata: makeMetadata(), platterEventCount: 0)
        let report = ReferenceValidator.validate(evidence)
        XCTAssertFalse(report.passes)
        XCTAssertTrue(
            report.failureMessages.contains { $0.contains("No platter movement") },
            report.failureMessages.description
        )
    }

    func testAnUnidentifiedControllerIsReportedExplicitly() {
        var metadata = makeMetadata()
        metadata = ReferenceTakeMetadata(
            referenceTakeID: metadata.referenceTakeID,
            authoringSessionID: metadata.authoringSessionID,
            takeNumber: metadata.takeNumber,
            operatorName: metadata.operatorName,
            technique: metadata.technique,
            pattern: metadata.pattern,
            bpm: metadata.bpm,
            startingPlatterDirection: metadata.startingPlatterDirection,
            faderVariant: metadata.faderVariant,
            handedness: metadata.handedness,
            referenceVersion: metadata.referenceVersion,
            crossfaderCalibration: metadata.crossfaderCalibration,
            deviceInfo: ReferenceDeviceInfo(
                platform: "macOS",
                appVersion: "1.0.1",
                controllerName: "",
                controllerIdentifier: "",
                audioDeviceName: nil,
                videoDeviceName: nil,
                watchLinked: false
            ),
            recordedAt: metadata.recordedAt
        )
        let report = ReferenceValidator.validate(makeEvidence(metadata: metadata))
        XCTAssertTrue(
            report.failureMessages.contains { $0.contains("could not be identified") },
            report.failureMessages.description
        )
    }

    func testACalibrationMeasuredOnADifferentAddressIsRejected() {
        let evidence = makeEvidence(
            metadata: makeMetadata(),
            observedAddress: CrossfaderMIDIAddress(
                deviceIdentifier: "Rane ONE MKII",
                deviceName: "Rane ONE MKII",
                channel: 1,
                controller: 6
            )
        )
        let report = ReferenceValidator.validate(evidence)
        XCTAssertFalse(report.passes)
        XCTAssertTrue(
            report.failureMessages.contains { $0.contains("Recalibrate on the controller") },
            report.failureMessages.description
        )
    }

    // MARK: - Validation: artifacts

    func testSilentProgramAudioIsRejectedWithItsMeasuredPeak() {
        let silent = ReferenceArtifactMeasurement(
            fileName: "reference.wav",
            exists: true,
            byteCount: 1_024_000,
            peakLevel: 0.0,
            frameCount: 256_000
        )
        let report = ReferenceValidator.validate(makeEvidence(metadata: makeMetadata(), audio: silent))
        XCTAssertFalse(report.passes)
        XCTAssertTrue(
            report.failureMessages.contains { $0.contains("which is silence") },
            report.failureMessages.description
        )
    }

    func testAnUnreadableAudioFileIsDistinguishedFromAMissingOne() {
        let unreadable = ReferenceArtifactMeasurement(
            fileName: "reference.wav",
            exists: true,
            byteCount: 900,
            readError: "The file couldn't be opened."
        )
        let unreadableReport = ReferenceValidator.validate(
            makeEvidence(metadata: makeMetadata(), audio: unreadable)
        )
        XCTAssertTrue(
            unreadableReport.failureMessages.contains { $0.contains("exists but could not be read") },
            unreadableReport.failureMessages.description
        )

        let missing = ReferenceArtifactMeasurement(
            fileName: "reference.wav",
            exists: false,
            byteCount: 0
        )
        let missingReport = ReferenceValidator.validate(
            makeEvidence(metadata: makeMetadata(), audio: missing)
        )
        XCTAssertTrue(
            missingReport.failureMessages.contains { $0.contains("is missing from the take folder") },
            missingReport.failureMessages.description
        )
        XCTAssertFalse(
            missingReport.failureMessages.contains { $0.contains("exists but could not be read") }
        )
    }

    func testAnArtifactHashMismatchNamesTheFile() {
        let tampered = ReferenceArtifactMeasurement(
            fileName: "reference.wav",
            exists: true,
            byteCount: 1_024_000,
            peakLevel: 0.8,
            frameCount: 256_000,
            recordedSHA256: String(repeating: "a", count: 64),
            currentSHA256: String(repeating: "b", count: 64)
        )
        let report = ReferenceValidator.validate(makeEvidence(metadata: makeMetadata(), audio: tampered))
        XCTAssertFalse(report.passes)
        XCTAssertTrue(
            report.failureMessages.contains {
                $0.contains("reference.wav") && $0.contains("does not match its recorded hash")
            },
            report.failureMessages.description
        )
    }

    func testAFileNameSidecarMismatchIsReported() {
        let video = ReferenceArtifactMeasurement(
            fileName: "declared.mov",
            exists: true,
            byteCount: 500_000
        )
        var evidence = makeEvidence(metadata: makeMetadata(), video: video)
        evidence = ReferenceTakeEvidence(
            metadata: evidence.metadata,
            boundaries: evidence.boundaries,
            audio: evidence.audio,
            video: video,
            sidecar: evidence.sidecar,
            actualMediaFileName: "actual.mov",
            crossfaderRawSamples: evidence.crossfaderRawSamples,
            observedCrossfaderAddress: evidence.observedCrossfaderAddress,
            platterMovementEventCount: evidence.platterMovementEventCount,
            derivation: evidence.derivation
        )
        let report = ReferenceValidator.validate(evidence)
        XCTAssertTrue(
            report.failureMessages.contains { $0.contains("names its media file as declared.mov") },
            report.failureMessages.description
        )
    }

    // MARK: - Validation: metadata and boundaries

    func testAnOutOfRangeBPMIsRejectedWithTheSupportedRange() {
        let report = ReferenceValidator.validate(makeEvidence(metadata: makeMetadata(bpm: 300)))
        XCTAssertTrue(
            report.failureMessages.contains { $0.contains("BPM 300 is outside the supported range") },
            report.failureMessages.description
        )
    }

    func testARepetitionCountOtherThanFourIsRejected() {
        let report = ReferenceValidator.validate(
            makeEvidence(metadata: makeMetadata(repetitionCount: 3))
        )
        XCTAssertTrue(
            report.failureMessages.contains { $0.contains("must contain 4") },
            report.failureMessages.description
        )
    }

    func testOverlappingRepetitionBoundariesAreRejected() {
        let metadata = makeMetadata()
        var boundaries = ReferencePhraseBoundaries.nominal(for: metadata)
        boundaries.repetitions[1].startBeat = boundaries.repetitions[0].endBeat - 1
        boundaries.selectedRepetitionIndex = 0
        let report = ReferenceValidator.validate(
            makeEvidence(metadata: metadata, boundaries: boundaries)
        )
        XCTAssertTrue(
            report.failureMessages.contains { $0.contains("starts before repetition") },
            report.failureMessages.description
        )
    }

    func testNoSelectedRepetitionBlocksApproval() {
        let metadata = makeMetadata()
        var boundaries = ReferencePhraseBoundaries.nominal(for: metadata)
        boundaries.selectedRepetitionIndex = nil
        let evidence = ReferenceTakeEvidence(
            metadata: metadata,
            boundaries: boundaries,
            audio: goodAudio(),
            video: nil,
            sidecar: goodSidecar(),
            actualMediaFileName: nil,
            crossfaderRawSamples: [
                CrossfaderPositionSample(takeRelativeTime: 0, rawValue: 1, normalizedPosition: 1)
            ],
            observedCrossfaderAddress: Self.calibration.address,
            platterMovementEventCount: 10,
            derivation: derivation([(.open, 0, 10)])
        )
        let report = ReferenceValidator.validate(evidence)
        XCTAssertFalse(report.passes)
        XCTAssertTrue(
            report.failureMessages.contains { $0.contains("No repetition has been selected") },
            report.failureMessages.description
        )
    }

    func testNominalBoundariesStartAfterTheCountInBar() {
        let metadata = makeMetadata(bpm: 60, phraseBars: 1)
        let boundaries = ReferencePhraseBoundaries.nominal(for: metadata)
        XCTAssertEqual(boundaries.repetitions.count, 4)
        XCTAssertEqual(boundaries.repetitions[0].startBeat, 4)
        XCTAssertEqual(boundaries.repetitions[3].endBeat, 20)
        // Count-in bar + 4 repetitions + tail bar = 24 beats.
        XCTAssertEqual(metadata.totalBeats, 24)
        XCTAssertEqual(boundaries.repetitions[0].startSeconds(bpm: 60), 4.0, accuracy: 0.0001)
    }

    // MARK: - Lifecycle

    func testLifecycleAdvancesOneStepAtATime() {
        XCTAssertTrue(ReferenceLifecycleState.draft.canAdvance(to: .reviewed))
        XCTAssertFalse(ReferenceLifecycleState.draft.canAdvance(to: .approvedCanonical))
        XCTAssertFalse(ReferenceLifecycleState.draft.canAdvance(to: .published))
        XCTAssertTrue(ReferenceLifecycleState.reviewed.canAdvance(to: .approvedCanonical))
        XCTAssertTrue(ReferenceLifecycleState.approvedCanonical.canAdvance(to: .published))
        XCTAssertTrue(ReferenceLifecycleState.published.permittedNextStates.isEmpty == false)
        XCTAssertEqual(ReferenceLifecycleState.published.permittedNextStates, [.deprecated])
    }

    func testARawCaptureIsNeverPlayableByALearner() {
        XCTAssertFalse(ReferenceLifecycleState.diagnostic.isPlayableByLearner)
        XCTAssertFalse(ReferenceLifecycleState.draft.isPlayableByLearner)
        XCTAssertFalse(ReferenceLifecycleState.reviewed.isPlayableByLearner)
        XCTAssertFalse(ReferenceLifecycleState.approvedCanonical.isPlayableByLearner)
        XCTAssertTrue(ReferenceLifecycleState.published.isPlayableByLearner)
    }

    func testAnIllegalLifecycleMoveIsNamed() {
        let finding = ReferenceValidator.lifecycleFinding(from: .draft, to: .published)
        XCTAssertNotNil(finding)
        XCTAssertTrue(finding?.message.contains("draft → reviewed → approved canonical → published") ?? false)
        XCTAssertNil(ReferenceValidator.lifecycleFinding(from: .draft, to: .reviewed))
    }

    // MARK: - Registry: no fallback to deprecated data

    func testTheShippedRegistryServesNothingAndSaysWhy() {
        let registry = LegacyReferenceInventory.withdrawnBaselineRegistry(
            now: Date(timeIntervalSince1970: 1_788_000_000)
        )
        XCTAssertTrue(registry.isEmptyOfServableReferences)
        for technique in ReferenceTechnique.minimumRequiredSet {
            XCTAssertFalse(
                registry.resolve(technique: technique).isTrainable,
                "\(technique.displayName) must not be trainable before a calibrated re-record is approved."
            )
        }
    }

    func testADeprecatedAssetExplainsAnAbsenceButIsNeverServed() {
        let registry = LegacyReferenceInventory.withdrawnBaselineRegistry(
            now: Date(timeIntervalSince1970: 1_788_000_000)
        )
        let availability = registry.resolve(technique: .babyScratch)
        guard case .awaitingReRecord(let assetID, let reason) = availability else {
            return XCTFail("Baby Scratch has deprecated assets, so it should report awaitingReRecord, got \(availability)")
        }
        XCTAssertNotNil(assetID)
        XCTAssertEqual(reason, .uncalibratedCrossfader)
        XCTAssertNil(availability.entry, "A deprecated asset must never surface as a servable entry.")
        XCTAssertFalse(availability.isTrainable)
        XCTAssertNotNil(availability.learnerMessage(for: .babyScratch))
    }

    func testATechniqueWithNoAssetsAtAllReportsUnavailable() {
        let registry = ReferenceRegistry(
            document: ReferenceRegistryDocument(
                generatedAt: Date(),
                entries: [],
                deprecatedAssets: [],
                trainingEnabledTechniques: [.chirp]
            )
        )
        XCTAssertEqual(registry.resolve(technique: .chirp), .unavailable)
    }

    func testAnApprovedEntryBecomesTrainableAndTheHighestVersionWins() {
        let entryV1 = makeRegistryEntry(version: 1, approvedAt: Date(timeIntervalSince1970: 1_788_000_000))
        let entryV2 = makeRegistryEntry(version: 2, approvedAt: Date(timeIntervalSince1970: 1_788_100_000))
        let registry = ReferenceRegistry(
            document: ReferenceRegistryDocument(
                generatedAt: Date(),
                entries: [entryV1, entryV2],
                deprecatedAssets: LegacyReferenceInventory.deprecatedAssets(deprecatedAt: Date()),
                trainingEnabledTechniques: [.babyScratch]
            )
        )
        let availability = registry.resolve(technique: .babyScratch)
        XCTAssertTrue(availability.isTrainable)
        XCTAssertEqual(availability.entry?.referenceVersion, 2)
    }

    func testACandidateEntryIsNotServable() {
        var entry = makeRegistryEntry(version: 1, approvedAt: Date())
        entry = ReferenceRegistryEntry(
            referenceID: entry.referenceID,
            technique: entry.technique,
            pattern: entry.pattern,
            bpm: entry.bpm,
            referenceVersion: entry.referenceVersion,
            lifecycleState: .reviewed,
            audioResourcePath: entry.audioResourcePath,
            manifestResourcePath: entry.manifestResourcePath,
            audioSHA256: entry.audioSHA256,
            phraseBeats: entry.phraseBeats,
            startingPlatterDirection: entry.startingPlatterDirection,
            approvedAt: entry.approvedAt,
            approvedBy: entry.approvedBy
        )
        XCTAssertFalse(entry.isServable)
        let registry = ReferenceRegistry(
            document: ReferenceRegistryDocument(
                generatedAt: Date(),
                entries: [entry],
                deprecatedAssets: [],
                trainingEnabledTechniques: [.babyScratch]
            )
        )
        XCTAssertFalse(registry.resolve(technique: .babyScratch).isTrainable)
    }

    private func makeRegistryEntry(version: Int, approvedAt: Date) -> ReferenceRegistryEntry {
        ReferenceRegistryEntry(
            referenceID: "baby_scratch.quarter_notes",
            technique: .babyScratch,
            pattern: ReferencePatternIdentity(id: "quarter_notes", name: "Quarter notes", phraseBars: 1),
            bpm: 95,
            referenceVersion: version,
            lifecycleState: .published,
            audioResourcePath: "References/baby_scratch/quarter_notes.wav",
            manifestResourcePath: "References/baby_scratch/manifest.json",
            audioSHA256: String(repeating: "c", count: 64),
            phraseBeats: 4,
            startingPlatterDirection: .forward,
            approvedAt: approvedAt,
            approvedBy: "Karl"
        )
    }

    // MARK: - Call and response

    func testListenThenCopyOpensAResponseWindowEqualToThePhrase() {
        guard let schedule = CallAndResponseSchedule(
            configuration: CallAndResponseConfiguration(
                mode: .listenThenCopy,
                phraseDurationSeconds: 2.4,
                countInBeats: 4,
                bpm: 100
            )
        ) else {
            return XCTFail("Usable configuration produced no schedule.")
        }
        // 4 beats at 100 bpm = 2.4 s count-in.
        XCTAssertEqual(schedule.phases.first?.kind, .countIn)
        XCTAssertEqual(schedule.phases.first?.duration ?? 0, 2.4, accuracy: 0.0001)
        XCTAssertEqual(schedule.responseWindows.count, 1)
        XCTAssertEqual(schedule.responseWindows[0].endTime - schedule.responseWindows[0].startTime, 2.4, accuracy: 0.0001)
        XCTAssertEqual(schedule.totalDuration, 7.2, accuracy: 0.0001)
    }

    func testResponseWindowLengthIsConfigurableWithoutRerecording() {
        guard let schedule = CallAndResponseSchedule(
            configuration: CallAndResponseConfiguration(
                mode: .listenThenCopy,
                phraseDurationSeconds: 2.0,
                responseDurationSeconds: 6.0,
                countInBeats: 0,
                bpm: 120
            )
        ) else {
            return XCTFail("Usable configuration produced no schedule.")
        }
        XCTAssertEqual(schedule.responseWindows[0].endTime - schedule.responseWindows[0].startTime, 6.0, accuracy: 0.0001)
    }

    func testRepeatedRoundsAlternateReferenceAndResponse() {
        guard let schedule = CallAndResponseSchedule(
            configuration: CallAndResponseConfiguration(
                mode: .repeatedRounds,
                phraseDurationSeconds: 2.0,
                roundCount: 4,
                countInBeats: 0,
                bpm: 120
            )
        ) else {
            return XCTFail("Usable configuration produced no schedule.")
        }
        XCTAssertEqual(schedule.responseWindows.count, 4)
        XCTAssertEqual(schedule.roundCount, 4)
        let kinds = schedule.phases.dropLast().map(\.kind)
        XCTAssertEqual(kinds, [.reference, .response, .reference, .response, .reference, .response, .reference, .response])
    }

    func testListenOnlyAndLoopingOpenNoResponseWindow() {
        for mode in [CallAndResponseMode.listenOnly, .loopingReference] {
            guard let schedule = CallAndResponseSchedule(
                configuration: CallAndResponseConfiguration(
                    mode: mode,
                    phraseDurationSeconds: 2.0,
                    roundCount: 3,
                    countInBeats: 0,
                    bpm: 120
                )
            ) else {
                return XCTFail("Usable configuration produced no schedule for \(mode).")
            }
            XCTAssertTrue(schedule.responseWindows.isEmpty)
            XCTAssertFalse(schedule.capturesLearner(at: 1.0))
        }
    }

    func testTheLearnerIsCapturedOnlyInsideTheResponseWindow() {
        guard let schedule = CallAndResponseSchedule(
            configuration: CallAndResponseConfiguration(
                mode: .listenThenCopy,
                phraseDurationSeconds: 2.0,
                countInBeats: 0,
                bpm: 120
            )
        ) else {
            return XCTFail("Usable configuration produced no schedule.")
        }
        XCTAssertFalse(schedule.capturesLearner(at: 1.0))
        XCTAssertTrue(schedule.capturesLearner(at: 3.0))
        XCTAssertEqual(schedule.phase(at: 3.0)?.kind.displayLabel, "YOUR TURN")
    }

    func testTheClickCanBeSilencedThroughTheResponseWindowOnly() {
        guard let running = CallAndResponseSchedule(
            configuration: CallAndResponseConfiguration(
                mode: .listenThenCopy,
                phraseDurationSeconds: 2.0,
                countInBeats: 0,
                bpm: 120,
                clickRunsThroughResponse: true
            )
        ),
        let silent = CallAndResponseSchedule(
            configuration: CallAndResponseConfiguration(
                mode: .listenThenCopy,
                phraseDurationSeconds: 2.0,
                countInBeats: 0,
                bpm: 120,
                clickRunsThroughResponse: false
            )
        ) else {
            return XCTFail("Usable configurations produced no schedule.")
        }
        XCTAssertTrue(running.clickIsAudible(at: 1.0))
        XCTAssertTrue(running.clickIsAudible(at: 3.0))
        XCTAssertTrue(silent.clickIsAudible(at: 1.0))
        XCTAssertFalse(silent.clickIsAudible(at: 3.0))
    }

    func testAnUnusableConfigurationProducesNoSchedule() {
        XCTAssertNil(
            CallAndResponseSchedule(
                configuration: CallAndResponseConfiguration(
                    mode: .listenThenCopy,
                    phraseDurationSeconds: 0,
                    bpm: 120
                )
            )
        )
        XCTAssertNil(
            CallAndResponseSchedule(
                configuration: CallAndResponseConfiguration(
                    mode: .listenThenCopy,
                    phraseDurationSeconds: 2,
                    bpm: 0
                )
            )
        )
    }

    func testComparisonIsGatedOnVerifiedTargetSemantics() {
        XCTAssertTrue(CallAndResponseComparisonGate.decision(for: .babyScratch).isComparable)
        for technique in [ReferenceTechnique.chirp, .transform, .flare(.oneClick)] {
            let decision = CallAndResponseComparisonGate.decision(for: technique)
            XCTAssertFalse(
                decision.isComparable,
                "\(technique.displayName) has no verified target notation and must not be scored."
            )
            if case .notComparable(let reason) = decision {
                XCTAssertTrue(reason.contains("will not score"))
            }
        }
    }

    // MARK: - Preflight

    private func makeSnapshot(
        calibration: CrossfaderCalibration? = ReferenceAuthoringTests.calibration,
        controllerName: String? = "Rane ONE MKII",
        rawValue: Int? = 1,
        platterEvents: Int = 500,
        platterMoving: Bool = true,
        audioPeak: Double? = 0.4,
        watchReachable: Bool = true,
        crossfaderSecondsSinceLastMessage: Double? = 0.1
    ) -> ReferencePreflightSnapshot {
        ReferencePreflightSnapshot(
            controllerName: controllerName,
            controllerIdentifier: controllerName,
            observedCrossfaderAddress: controllerName == nil ? nil : Self.calibration.address,
            latestCrossfaderRawValue: rawValue,
            calibration: calibration,
            crossfaderEventCount: 120,
            platterEventCount: platterEvents,
            platterIsMoving: platterMoving,
            audioInputPeakLevel: audioPeak,
            audioDeviceName: "Rane ONE MKII",
            watchIsReachable: watchReachable,
            watchMotionIsStreaming: watchReachable,
            cameraDeviceName: "Studio Camera",
            cameraIsActive: true,
            crossfaderSecondsSinceLastMessage: crossfaderSecondsSinceLastMessage
        )
    }

    func testPreflightPassesWithEverythingConnectedAndCalibrated() {
        let result = ReferenceCapturePreflight.evaluate(
            snapshot: makeSnapshot(),
            technique: .babyScratch
        )
        XCTAssertFalse(result.blocksRecording, result.blockingSummary ?? "")
    }

    func testPreflightBlocksRecordingWithoutACalibration() {
        let result = ReferenceCapturePreflight.evaluate(
            snapshot: makeSnapshot(calibration: nil),
            technique: .chirp
        )
        XCTAssertTrue(result.blocksRecording)
        XCTAssertTrue(
            result.blockingChecks.contains { $0.detail.contains("No calibration on file") },
            result.blockingSummary ?? ""
        )
    }

    func testPreflightBlocksRecordingWithoutAController() {
        let result = ReferenceCapturePreflight.evaluate(
            snapshot: makeSnapshot(controllerName: nil),
            technique: .transform
        )
        XCTAssertTrue(result.blocksRecording)
        XCTAssertTrue(result.blockingChecks.contains { $0.id == "controller" })
    }

    func testPreflightBlocksBabyScratchWhenTheFaderIsNotOpen() {
        // raw 52 is fully closed on this calibration.
        let result = ReferenceCapturePreflight.evaluate(
            snapshot: makeSnapshot(rawValue: 52),
            technique: .babyScratch
        )
        XCTAssertTrue(result.blocksRecording)
        XCTAssertTrue(result.blockingChecks.contains { $0.id == "crossfaderState" })
    }

    func testPreflightAllowsAClosedFaderForATransform() {
        let result = ReferenceCapturePreflight.evaluate(
            snapshot: makeSnapshot(rawValue: 52),
            technique: .transform
        )
        XCTAssertFalse(result.blocksRecording, result.blockingSummary ?? "")
    }

    func testPreflightBlocksOnADeadAudioInput() {
        let result = ReferenceCapturePreflight.evaluate(
            snapshot: makeSnapshot(audioPeak: 0.0),
            technique: .chirp
        )
        XCTAssertTrue(result.blocksRecording)
        XCTAssertTrue(result.blockingChecks.contains { $0.id == "audioInput" })
    }

    /// The Watch row used to be advisory, from when reference authoring had no
    /// Watch wiring at all. Authoring now performs the same paired start
    /// handshake Capture does and refuses to record without an
    /// acknowledgement, so an unreachable Watch is a condition to fix BEFORE
    /// recording — not a note added afterwards to a take that can never carry
    /// wrist evidence.
    func testPreflightBlocksRecordingWhenTheWatchIsUnreachable() {
        let result = ReferenceCapturePreflight.evaluate(
            snapshot: makeSnapshot(watchReachable: false),
            technique: .chirp
        )
        let watch = result.checks.first { $0.id == "watch" }
        XCTAssertEqual(watch?.status, .blocking)
        XCTAssertTrue(result.blocksRecording)
    }

    func testPreflightAcceptsAReachableWatch() {
        let result = ReferenceCapturePreflight.evaluate(
            snapshot: makeSnapshot(watchReachable: true),
            technique: .chirp
        )
        XCTAssertEqual(result.checks.first { $0.id == "watch" }?.status, .satisfied)
    }

    func testPreflightNeverFallsBackToFullRangeNormalization() {
        // No calibration: the calibrated value must be absent, not raw/127.
        let snapshot = makeSnapshot(calibration: nil, rawValue: 52)
        XCTAssertNil(snapshot.calibratedCrossfaderPosition)
        XCTAssertNil(snapshot.crossfaderGateState())
    }

    // MARK: - Crossfader liveness in the preflight panel

    /// The row used to report only a lifetime total and call any non-zero
    /// count "satisfied". That total never decreases, so after one message it
    /// read as working for the rest of the session — which is how the
    /// 2026-09-04 smoke recorded a take with no crossfader traffic at all
    /// while the panel showed 1,089 events.
    func testALifetimeCrossfaderCountWithNoRecentMessageIsNotSatisfied() {
        let snapshot = makeSnapshot(crossfaderSecondsSinceLastMessage: 90)
        let result = ReferenceCapturePreflight.evaluate(snapshot: snapshot, technique: .babyScratch)
        let row = result.checks.first { $0.id == "crossfaderEvents" }
        XCTAssertEqual(row?.status, .advisory)
        XCTAssertTrue(row?.detail.contains("currently silent") ?? false, row?.detail ?? "")
        XCTAssertTrue(row?.detail.contains("120 since launch") ?? false, row?.detail ?? "")
    }

    func testARecentCrossfaderMessageIsSatisfied() {
        let snapshot = makeSnapshot(crossfaderSecondsSinceLastMessage: 0.2)
        let result = ReferenceCapturePreflight.evaluate(snapshot: snapshot, technique: .babyScratch)
        let row = result.checks.first { $0.id == "crossfaderEvents" }
        XCTAssertEqual(row?.status, .satisfied)
        XCTAssertTrue(row?.detail.contains("moving now") ?? false, row?.detail ?? "")
    }

    func testAnUnknownCrossfaderMessageAgeIsTreatedAsSilent() {
        let snapshot = makeSnapshot(crossfaderSecondsSinceLastMessage: nil)
        XCTAssertFalse(ReferenceCapturePreflight.crossfaderIsRecentlyActive(snapshot: snapshot))
    }

    /// While a take is recording the panel reports the number that actually
    /// reaches the sidecar, not just the lifetime total.
    func testTheRowReportsTheTakeScopedCountWhileRecording() {
        let snapshot = ReferencePreflightSnapshot(
            controllerName: "Rane ONE MKII",
            controllerIdentifier: "Rane ONE MKII",
            observedCrossfaderAddress: Self.calibration.address,
            latestCrossfaderRawValue: 1,
            calibration: Self.calibration,
            crossfaderEventCount: 1_089,
            platterEventCount: 20_440,
            platterIsMoving: true,
            audioInputPeakLevel: 0.4,
            audioDeviceName: "Rane ONE MKII",
            watchIsReachable: true,
            watchMotionIsStreaming: true,
            cameraDeviceName: "Studio Camera",
            cameraIsActive: true,
            crossfaderSecondsSinceLastMessage: 42,
            takeScopedCrossfaderEventCount: 0,
            isRecordingTake: true
        )
        let result = ReferenceCapturePreflight.evaluate(snapshot: snapshot, technique: .babyScratch)
        let row = result.checks.first { $0.id == "crossfaderEvents" }
        XCTAssertTrue(row?.detail.contains("0 in this take") ?? false, row?.detail ?? "")
        XCTAssertEqual(
            row?.status, .advisory,
            "1,089 lifetime messages and none in 42 seconds is not a working crossfader."
        )
    }

    // MARK: - Technique-aware fader validation (D2, from the 2026-09-05 test)
    //
    // Baby Scratch declares `requiresContinuouslyOpenFader: true` and
    // `minimumCutEventsPerRepetition: 0` — it is PERFORMED without moving the
    // fader. Validation nevertheless demanded crossfader movement
    // unconditionally, so the one authorable technique could never pass. Karl
    // performed it correctly on hardware and take-003 was blocked by
    // "No crossfader MIDI was recorded".

    func testBabyScratchWithACalibratedOpenBaselineAndZeroCutsPassesTheFaderRequirement() {
        let evidence = makeEvidence(
            metadata: makeMetadata(technique: .babyScratch),
            derivation: derivation([(.open, 0, 20)])
        )
        let report = ReferenceValidator.validate(evidence)
        XCTAssertEqual(
            ReferenceValidator.faderOpenEvidence(for: evidence),
            .provenContinuouslyOpen
        )
        XCTAssertTrue(report.passes, report.failureMessages.description)
    }

    func testBabyScratchNeverFailsForCrossfaderEvidenceMissingWhenMovementIsSimplyZero() {
        // Zero cut-family events, zero movement — exactly a correct baby
        // scratch. The fader's OPEN state is still proven by its intervals.
        let evidence = makeEvidence(
            metadata: makeMetadata(technique: .babyScratch),
            derivation: derivation([(.open, 0, 20)], events: [])
        )
        let report = ReferenceValidator.validate(evidence)
        XCTAssertFalse(
            report.findings.contains(.crossfaderEvidenceMissing),
            "an open-fader technique must not be failed for the absence of fader MOVEMENT"
        )
        XCTAssertTrue(report.passes, report.failureMessages.description)
    }

    func testBabyScratchWithAClosedIntervalFails() {
        let evidence = makeEvidence(
            metadata: makeMetadata(technique: .babyScratch),
            derivation: derivation([(.open, 0, 5), (.closed, 5, 6), (.open, 6, 20)])
        )
        XCTAssertEqual(
            ReferenceValidator.faderOpenEvidence(for: evidence),
            .provenClosedAtSomePoint(closedIntervalCount: 1)
        )
        let report = ReferenceValidator.validate(evidence)
        XCTAssertFalse(report.passes)
        XCTAssertTrue(
            report.failureMessages.contains { $0.contains("open") },
            report.failureMessages.description
        )
    }

    /// The third state. No derivation at all means the fader was never
    /// measured — which is NOT the same as measured-and-open, and must not
    /// silently pass.
    func testBabyScratchWithNoCalibratedReadingIsBlockedAsUnknownNotPassed() {
        let evidence = makeEvidence(
            metadata: makeMetadata(technique: .babyScratch),
            crossfaderSampleCount: 0,
            derivation: CrossfaderDerivation(intervals: [], events: [])
        )
        guard case .unknown = ReferenceValidator.faderOpenEvidence(for: evidence) else {
            return XCTFail("no intervals must classify as unknown")
        }
        let report = ReferenceValidator.validate(evidence)
        XCTAssertFalse(report.passes, "unknown must never silently pass")
        XCTAssertTrue(
            report.findings.contains { finding in
                if case .faderOpenStateUnknown = finding { return true }
                return false
            },
            report.failureMessages.description
        )
    }

    /// A reading that only starts well into the take says nothing about the
    /// take's start, so it is unknown rather than open.
    func testABaselineThatArrivesTooLateIsUnknown() {
        let evidence = makeEvidence(
            metadata: makeMetadata(technique: .babyScratch),
            derivation: derivation([(.open, 4.0, 20)])
        )
        guard case .unknown = ReferenceValidator.faderOpenEvidence(for: evidence) else {
            return XCTFail("a late first reading must classify as unknown")
        }
        XCTAssertFalse(ReferenceValidator.validate(evidence).passes)
    }

    func testRawObservationsArePreservedAndNoEventsAreFabricated() {
        let evidence = makeEvidence(
            metadata: makeMetadata(technique: .babyScratch),
            crossfaderSampleCount: 25,
            derivation: derivation([(.open, 0, 20)], events: [])
        )
        XCTAssertEqual(evidence.crossfaderRawSamples.count, 25)
        XCTAssertTrue(
            evidence.derivation?.events.isEmpty ?? false,
            "validation must not invent fader events to satisfy a requirement"
        )
    }

    // MARK: Clicked techniques are NOT weakened

    func testAClickedTechniqueStillFailsWithNoCrossfaderEvidence() {
        let evidence = makeEvidence(
            metadata: makeMetadata(technique: .flare(.oneClick)),
            crossfaderSampleCount: 0,
            derivation: derivation([(.open, 0, 20)])
        )
        let report = ReferenceValidator.validate(evidence)
        XCTAssertTrue(
            report.findings.contains(.crossfaderEvidenceMissing),
            "a technique that requires cuts still requires fader evidence"
        )
        XCTAssertFalse(report.passes)
    }

    func testAConfirmedClickedTechniqueStillEnforcesItsMinimumCutCount() {
        let metadata = makeMetadata(technique: .flare(.twoClick))
        let expectation = ReferenceTechnique.flare(.twoClick)
            .defaultFaderExpectation
            .confirmed(by: "CXL", at: Date(timeIntervalSince1970: 1_788_000_000))
        // One cut in a repetition that requires two.
        let evidence = makeEvidence(
            metadata: metadata,
            derivation: derivation(
                [(.open, 0, 20)],
                events: [(.cut, 4.1, 4.2)]
            )
        )
        let report = ReferenceValidator.validate(evidence, expectation: expectation)
        XCTAssertTrue(
            report.findings.contains { finding in
                if case .insufficientCutEvents = finding { return true }
                return false
            },
            report.failureMessages.description
        )
    }

    // MARK: - Watch evidence states (D1)

    func testAPendingWatchTransferBlocksButIsReportedAsPendingNotMissing() {
        let evidence = makeEvidence(
            metadata: makeMetadata(technique: .babyScratch),
            watchEvidence: .acknowledgedTransferPending
        )
        let report = ReferenceValidator.validate(evidence)
        XCTAssertTrue(report.findings.contains(.watchEvidenceTransferPending))
        XCTAssertFalse(report.findings.contains(.watchEvidenceMissing))
        XCTAssertFalse(report.passes, "approval stays blocked while the transfer is in flight")
    }

    func testAFailedWatchTransferBlocks() {
        let evidence = makeEvidence(
            metadata: makeMetadata(technique: .babyScratch),
            watchEvidence: .transferFailed(detail: "synthetic failure.")
        )
        XCTAssertFalse(ReferenceValidator.validate(evidence).passes)
    }

    func testMismatchedWatchIdentityBlocks() {
        let evidence = makeEvidence(
            metadata: makeMetadata(technique: .babyScratch),
            watchEvidence: .identityMismatch(expected: "s/take-001", found: "s/take-002")
        )
        XCTAssertFalse(ReferenceValidator.validate(evidence).passes)
    }

    func testLinkedWatchEvidencePasses() {
        let evidence = makeEvidence(
            metadata: makeMetadata(technique: .babyScratch),
            watchEvidence: .linked(motionFileName: "scratch-motion.json")
        )
        XCTAssertTrue(ReferenceValidator.validate(evidence).passes)
    }
}

// MARK: - Canonical tear projection

/// The bridge from tear-segmentation evidence into `ScratchNotation.GestureRecord`.
///
/// These tests are the guarantee that a Tear is DRAWN as a tear: same-direction
/// subdivisions separated by horizontal internal holds, N holds and N+1 moving
/// subdivisions, a physical reversal ending the gesture rather than becoming a
/// hold, and fader clicks staying fader evidence. Everything is synthetic; no
/// physical take is read.
final class ReferenceTearCanonicalProjectionTests: XCTestCase {

    /// Gesture-relative controller telemetry, the only coordinate the
    /// projection will claim as platter revolutions. Forward runs rise from
    /// the run's own baseline; backward runs return to it.
    private func controllerRun(
        start: Double,
        end: Double,
        direction: String,
        excursion: Double,
        confidence: Double = 1,
        movementKind: ScratchMovementKind? = nil,
        source: String = "controller"
    ) -> CaptureCore.DetectedNotationRecordMovementEvent {
        let forward = direction == "forward"
        return CaptureCore.DetectedNotationRecordMovementEvent(
            startTime: start,
            endTime: end,
            startPosition: forward ? 0 : excursion,
            endPosition: forward ? excursion : 0,
            direction: direction,
            movementKind: movementKind ?? (forward ? .normalPush : .normalPull),
            speed: excursion / max(1e-6, end - start),
            confidence: confidence,
            source: source
        )
    }

    private func derivation(
        openFrom: Double,
        to end: Double,
        clicks: [(CrossfaderSemanticEventKind, Double, Double)] = []
    ) -> CrossfaderDerivation {
        CrossfaderDerivation(
            intervals: [
                CrossfaderStateInterval(
                    state: .open,
                    startTime: openFrom,
                    endTime: end,
                    startPosition: 1,
                    endPosition: 1
                )
            ],
            events: clicks.map {
                CrossfaderSemanticEvent(
                    kind: $0.0,
                    startTime: $0.1,
                    endTime: $0.2,
                    fromPosition: 1,
                    toPosition: 0
                )
            }
        )
    }

    /// forward → bounded hold → SAME-direction forward.
    private var tearEvents: [CaptureCore.DetectedNotationRecordMovementEvent] {
        [
            controllerRun(start: 0.00, end: 0.20, direction: "forward", excursion: 0.10),
            controllerRun(start: 0.40, end: 0.60, direction: "forward", excursion: 0.10)
        ]
    }

    private func project(
        _ events: [CaptureCore.DetectedNotationRecordMovementEvent],
        derivation: CrossfaderDerivation? = nil
    ) -> ReferenceTearCanonicalProjection {
        ReferenceTearCanonicalProjectionBuilder.project(
            movementEvents: events,
            derivation: derivation,
            referenceTakeID: "synthetic-tear"
        )
    }

    func testMoveHoldSameDirectionMoveProducesTwoSubdivisionsAndOneHorizontalHold() throws {
        let projection = project(tearEvents)
        XCTAssertEqual(projection.records.count, 1, "One same-direction gesture, not two strokes.")
        let record = try XCTUnwrap(projection.records.first)
        XCTAssertTrue(
            record.motionValidationIssues().isEmpty,
            "Issues: \(record.motionValidationIssues())"
        )
        XCTAssertEqual(record.direction, .forward)
        XCTAssertEqual(record.subdivisions.count, 2)
        XCTAssertEqual(record.internalHolds.count, 1)
        // The canonical invariant, derived from structure and never stored.
        XCTAssertEqual(record.subdivisions.count, record.internalHolds.count + 1)
        XCTAssertEqual(record.tearLabel, "tear1")

        let hold = try XCTUnwrap(record.internalHolds.first)
        XCTAssertEqual(hold.span.startTime, 0.20, accuracy: 1e-9)
        XCTAssertEqual(hold.span.endTime, 0.40, accuracy: 1e-9)
        XCTAssertEqual(hold.label.effective, .stationary)
        // Horizontal: the hold sits at the position both neighbours share.
        let holdPosition = try XCTUnwrap(hold.position)
        XCTAssertEqual(holdPosition, 0.10, accuracy: 1e-9)
        XCTAssertEqual(record.subdivisions[0].measuredCurve?.endPosition, holdPosition)
        XCTAssertEqual(record.subdivisions[1].measuredCurve?.startPosition, holdPosition)
        // Measured durations survive, unrounded.
        XCTAssertEqual(record.subdivisions[0].span.duration, 0.20, accuracy: 1e-9)
        XCTAssertEqual(record.subdivisions[1].span.duration, 0.20, accuracy: 1e-9)
    }

    func testTheHoldRendersAsAHorizontalSegmentThroughTheSharedGeometry() throws {
        let projection = project(tearEvents, derivation: derivation(openFrom: 0, to: 0.60))
        let frame = try XCTUnwrap(
            ScratchStrokeGeometry.CanonicalFrame(
                timeRange: 0...0.60,
                positionRange: try XCTUnwrap(projection.positionRange),
                coordinateSpace: projection.coordinateSpace,
                beatsPerMinute: 95
            )
        )
        let geometry = ScratchStrokeGeometry.canonicalGeometry(
            records: projection.records,
            layer: .performance,
            frame: frame
        )
        XCTAssertTrue(geometry.missingMotion.isEmpty, "Every interval must be placed.")
        let holds = geometry.motion.segments.filter(\.isHold)
        XCTAssertEqual(holds.count, 1, "Exactly one internal tear hold.")
        let hold = try XCTUnwrap(holds.first)
        XCTAssertEqual(hold.travel, 0, accuracy: 1e-9, "A tear hold must be horizontal.")
        XCTAssertEqual(hold.startTime, 0.20, accuracy: 1e-9)
        XCTAssertEqual(hold.endTime, 0.40, accuracy: 1e-9)
        // Not one uninterrupted diagonal, and not a reversal: two travel runs
        // separated by a flat hold.
        let travel = geometry.motion.segments.filter { !$0.isHold }
        XCTAssertGreaterThanOrEqual(travel.count, 2)
        XCTAssertTrue(travel.allSatisfy { $0.endPosition >= $0.startPosition },
                      "A forward tear never draws a backward slope.")
    }

    func testADirectionReversalEndsTheTearGesture() throws {
        // The backward run is longer than the reversal-confirmation window, so
        // it is a real polarity flip and not absorbed sign chatter.
        let events = [
            controllerRun(start: 0.00, end: 0.30, direction: "forward", excursion: 0.15),
            controllerRun(start: 0.40, end: 0.90, direction: "backward", excursion: 0.15)
        ]
        let projection = project(events)
        XCTAssertEqual(projection.records.count, 2, "A reversal ends the gesture; it never becomes a hold.")
        XCTAssertEqual(projection.records[0].direction, .forward)
        XCTAssertEqual(projection.records[1].direction, .backward)
        XCTAssertTrue(projection.records.allSatisfy { $0.internalHolds.isEmpty })
        XCTAssertTrue(projection.records.allSatisfy { $0.tearLabel == nil })
    }

    func testFaderClicksNeverIncrementTheTearHoldCount() throws {
        let clicked = derivation(
            openFrom: 0,
            to: 0.60,
            clicks: [(.cut, 0.25, 0.27), (.transformPulse, 0.45, 0.47)]
        )
        let review = ReferenceTearSegmentationReviewBuilder.build(
            referenceTakeID: "synthetic-tear",
            movementEvents: tearEvents,
            derivation: clicked
        )
        XCTAssertEqual(review.totalCountedTearHoldCount, 1, "Two fader clicks add no platter holds.")

        let projection = ReferenceTearCanonicalProjectionBuilder.project(review)
        let record = try XCTUnwrap(projection.records.first)
        XCTAssertEqual(record.internalHolds.count, 1)
        XCTAssertEqual(record.tearLabel, "tear1")
        // Clicks appear as FADER evidence — glyphs, not holds.
        XCTAssertEqual(record.faderTransitions.count, 2)
        XCTAssertTrue(record.faderValidationIssues().isEmpty,
                      "Issues: \(record.faderValidationIssues())")
        XCTAssertTrue(projection.reasons.contains(.faderClicksCitedNotCounted))
    }

    func testUnobservedFaderStaysUnknownAndIsNeverDrawnAsOpen() throws {
        let projection = project(tearEvents)
        let record = try XCTUnwrap(projection.records.first)
        XCTAssertTrue(record.faderIntervals.isEmpty, "No observation means no rail, never an assumed open one.")
        XCTAssertTrue(projection.reasons.contains(.faderUnobserved))
    }

    func testClosedFaderTravelIsProjectedAsAGhostRegionNotASoundingStroke() throws {
        let closed = CrossfaderDerivation(
            intervals: [
                CrossfaderStateInterval(
                    state: .closed,
                    startTime: 0,
                    endTime: 0.60,
                    startPosition: 0,
                    endPosition: 0
                )
            ],
            events: []
        )
        let projection = project(tearEvents, derivation: closed)
        let record = try XCTUnwrap(projection.records.first)
        XCTAssertEqual(record.faderIntervals.count, 1)
        XCTAssertEqual(record.faderIntervals.first?.state, .closed)
        XCTAssertTrue(projection.reasons.contains(.ghostMovementPresent))
    }

    func testFreePlaybackIsNeverFlattenedIntoAnOrdinaryStroke() throws {
        let events = [
            controllerRun(
                start: 0.00,
                end: 0.40,
                direction: "forward",
                excursion: 0.20,
                movementKind: .releaseNormalPlayback
            )
        ]
        let projection = project(events)
        let record = try XCTUnwrap(projection.records.first)
        XCTAssertFalse(
            record.motionValidationIssues().isEmpty,
            "Released playback carries no gesture polarity and must not validate as travel."
        )
        XCTAssertTrue(projection.reasons.contains(.releasedPlaybackPresent))
    }

    func testLowConfidenceEvidenceIsProjectedAsUnknown() throws {
        let events = [
            controllerRun(start: 0.00, end: 0.20, direction: "forward", excursion: 0.10, confidence: 0.2),
            controllerRun(start: 0.40, end: 0.60, direction: "forward", excursion: 0.10, confidence: 0.2)
        ]
        let projection = project(events)
        let record = try XCTUnwrap(projection.records.first)
        XCTAssertFalse(record.motionValidationIssues().isEmpty)
        XCTAssertTrue(projection.reasons.contains(.lowMovementConfidence))
    }

    func testNonControllerCoordinatesAreProjectedAsUnknownRatherThanClaimedAsRevolutions() throws {
        let events = [
            controllerRun(start: 0.00, end: 0.20, direction: "forward", excursion: 0.10, source: "video"),
            controllerRun(start: 0.40, end: 0.60, direction: "forward", excursion: 0.10, source: "video")
        ]
        let projection = project(events)
        let record = try XCTUnwrap(projection.records.first)
        XCTAssertFalse(record.motionValidationIssues().isEmpty)
        XCTAssertTrue(projection.reasons.contains(.unsupportedCoordinateSpace))
    }

    /// The live preview and the finalized review must not disagree about a
    /// gesture's structure. Both go through the SAME projection; only the
    /// fader stream differs, because a live preview has no committed
    /// derivation yet.
    func testLiveAndFinalizedProjectionsShareTheSameCanonicalStructure() throws {
        let live = ReferenceTearCanonicalProjectionBuilder.project(
            movementEvents: tearEvents,
            derivation: nil,
            referenceTakeID: "live-preview"
        )
        let finalizedReview = ReferenceTearSegmentationReviewBuilder.build(
            referenceTakeID: "ref-take-0008",
            movementEvents: tearEvents,
            derivation: derivation(openFrom: 0, to: 0.60)
        )
        let finalized = ReferenceTearCanonicalProjectionBuilder.project(finalizedReview)

        XCTAssertEqual(live.records.count, finalized.records.count)
        XCTAssertEqual(live.coordinateSpace, finalized.coordinateSpace)
        for (liveRecord, finalRecord) in zip(live.records, finalized.records) {
            XCTAssertEqual(liveRecord.direction, finalRecord.direction)
            XCTAssertEqual(liveRecord.subdivisions.map(\.span), finalRecord.subdivisions.map(\.span))
            XCTAssertEqual(liveRecord.internalHolds.map(\.span), finalRecord.internalHolds.map(\.span))
            XCTAssertEqual(liveRecord.internalHolds.map(\.position), finalRecord.internalHolds.map(\.position))
            XCTAssertEqual(liveRecord.tearLabel, finalRecord.tearLabel)
            XCTAssertEqual(
                liveRecord.subdivisions.compactMap { $0.measuredCurve?.points.map(\.position) },
                finalRecord.subdivisions.compactMap { $0.measuredCurve?.points.map(\.position) }
            )
        }
        // The one legitimate difference: the finalized take has fader evidence.
        XCTAssertTrue(live.records.allSatisfy { $0.faderIntervals.isEmpty })
        XCTAssertTrue(finalized.records.allSatisfy { !$0.faderIntervals.isEmpty })
    }

    func testAnOperatorRemovedHoldRepartitionsTheGestureAndKeepsTheInvariant() throws {
        var review = ReferenceTearSegmentationReviewBuilder.build(
            referenceTakeID: "synthetic-tear",
            movementEvents: tearEvents,
            derivation: derivation(openFrom: 0, to: 0.60)
        )
        let candidate = try XCTUnwrap(review.candidates.first)
        let boundary = try XCTUnwrap(candidate.boundaries.first)
        XCTAssertTrue(
            review.setBoundaryRemoved(
                inCandidate: candidate.id,
                boundaryID: boundary.id,
                removed: true,
                correction: ReferenceTearCorrection(
                    correctedBy: "Karl",
                    correctedAt: Date(timeIntervalSince1970: 1_788_000_600),
                    notes: "not a hold",
                    reason: "test"
                )
            )
        )
        let projection = ReferenceTearCanonicalProjectionBuilder.project(review)
        let record = try XCTUnwrap(projection.records.first)
        XCTAssertEqual(record.internalHolds.count, 0, "A struck-out boundary contributes no hold.")
        XCTAssertEqual(record.subdivisions.count, 1, "N holds still require N+1 subdivisions.")
        XCTAssertNil(record.tearLabel)
        XCTAssertTrue(record.motionValidationIssues().isEmpty,
                      "Issues: \(record.motionValidationIssues())")
    }

    func testAHoldRenamedAFaderClickStopsCountingWithoutDeletingAnything() throws {
        var review = ReferenceTearSegmentationReviewBuilder.build(
            referenceTakeID: "synthetic-tear",
            movementEvents: tearEvents,
            derivation: derivation(openFrom: 0, to: 0.60)
        )
        let candidate = try XCTUnwrap(review.candidates.first)
        let boundary = try XCTUnwrap(candidate.boundaries.first)
        XCTAssertTrue(
            review.setBoundaryKind(
                inCandidate: candidate.id,
                boundaryID: boundary.id,
                to: .faderClick,
                correction: ReferenceTearCorrection(
                    correctedBy: "Karl",
                    correctedAt: Date(timeIntervalSince1970: 1_788_000_600),
                    notes: "fader work",
                    reason: "test"
                )
            )
        )
        XCTAssertEqual(review.totalCountedTearHoldCount, 0)
        let retained = try XCTUnwrap(review.candidates.first?.boundaries.first)
        XCTAssertNotNil(retained.proposal, "The machine proposal is retained, never deleted.")
        let projection = ReferenceTearCanonicalProjectionBuilder.project(review)
        XCTAssertEqual(projection.records.first?.internalHolds.count, 0)
    }
}
