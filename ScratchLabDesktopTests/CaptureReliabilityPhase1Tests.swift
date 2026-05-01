import AVFoundation
import CoreMedia
import CoreVideo
import Dispatch
import XCTest
@testable import ScratchLab

final class CaptureReliabilityPhase1CoreTests: XCTestCase {
    private final class MockClickTrackTimingEngine: ClickTrackTimingEngine {
        var startCallCount = 0
        var stopCallCount = 0
        var requestedBPMs: [Int] = []
        var countInBeats: [Int] = []
        var recordingStartCount = 0
        var returnedMetadata = ClickTrackStartMetadata(
            bpm: 95,
            countInBeats: CaptureClickTrackDefaults.countInBeats,
            beatsPerBar: CaptureClickTrackDefaults.beatsPerBar,
            clickStartHostTime: 1_234,
            recordingStartHostTime: 5_678,
            clickAccentPattern: CaptureClickTrackDefaults.clickAccentPattern,
            clickVersion: CaptureClickTrackDefaults.clickVersion
        )

        func start(
            bpm requestedBPM: Int,
            onCountInBeat: ((Int) -> Void)?,
            onRecordingStart: (() -> Void)?
        ) throws -> ClickTrackStartMetadata {
            startCallCount += 1
            requestedBPMs.append(requestedBPM)
            onCountInBeat?(1)
            countInBeats.append(1)
            onRecordingStart?()
            recordingStartCount += 1
            return returnedMetadata
        }

        func stop() {
            stopCallCount += 1
        }
    }

    @MainActor
    private final class MockPracticeBeatPlaybackEngine: PracticeBeatPlaybackEngine {
        var startCallCount = 0
        var stopCallCount = 0
        var requestedModes: [BeatEngineMode] = []
        var requestedBPMs: [Int] = []

        func start(mode: BeatEngineMode, bpm: Int) throws {
            startCallCount += 1
            requestedModes.append(mode)
            requestedBPMs.append(bpm)
        }

        func stop() {
            stopCallCount += 1
        }
    }

    private final class MockScratchCoachDemoPlayable: ScratchCoachDemoPlayable {
        var isPlaying = false
        var currentTime: TimeInterval = 0
        var playCallCount = 0
        var pauseCallCount = 0
        var stopCallCount = 0
        var prepareCallCount = 0

        func prepareToPlay() {
            prepareCallCount += 1
        }

        func play() -> Bool {
            playCallCount += 1
            isPlaying = true
            return true
        }

        func pause() {
            pauseCallCount += 1
            isPlaying = false
        }

        func stop() {
            stopCallCount += 1
            isPlaying = false
        }
    }

    func testUniqueSessionIdentityGeneratesDistinctIDs() {
        let first = SessionIdentity.makeSessionID()
        let second = SessionIdentity.makeSessionID()

        XCTAssertNotEqual(first, second)
        XCTAssertFalse(first.isEmpty)
        XCTAssertFalse(second.isEmpty)
    }

    func testSameDaySessionsDoNotCoMingleDuringLocalExportPreparation() throws {
        let root = try makeTemporaryDirectory()
        let sessionIDOne = "session-one"
        let sessionIDTwo = "session-two"
        let now = Date()

        let firstTakeURL = try makeLocalRecordingTake(
            in: root,
            sessionID: sessionIDOne,
            takeNumber: 1,
            bpm: 70,
            createdAt: now
        )
        _ = try makeLocalRecordingTake(
            in: root,
            sessionID: sessionIDTwo,
            takeNumber: 1,
            bpm: 70,
            createdAt: now
        )

        let matchingSidecars = try SessionArchiveBuilder().matchingLocalRecordingSidecarURLs(
            in: root,
            seedSessionID: sessionIDOne
        )

        XCTAssertEqual(
            matchingSidecars.map(\.lastPathComponent).sorted(),
            [CaptureCore.LocalRecordingFiles.sidecarURL(forMediaURL: firstTakeURL).lastPathComponent]
        )
    }

    func testTakeIdentitySequencingIsDeterministic() {
        let sessionID = "session-sequence"
        XCTAssertEqual(CaptureCore.LocalRecordingNaming.takeIdentity(sessionID: sessionID, takeNumber: 1).takeID, "take-001")
        XCTAssertEqual(CaptureCore.LocalRecordingNaming.takeIdentity(sessionID: sessionID, takeNumber: 2).takeID, "take-002")
        XCTAssertEqual(CaptureCore.LocalRecordingNaming.takeIdentity(sessionID: sessionID, takeNumber: 12).takeID, "take-012")
    }

    func testScratchSpecificTrainingBPMOptionsMatchTrainingPlan() {
        XCTAssertEqual(CaptureSessionScratchType.tear.trainingBPMList, [110, 120, 130])
        XCTAssertEqual(CaptureSessionScratchType.stab.trainingBPMList, [110, 120, 130])
        XCTAssertEqual(CaptureSessionScratchType.transform.trainingBPMList, [110, 120, 130])

        XCTAssertEqual(CaptureSessionScratchType.crab.trainingBPMList, [70, 80, 90])
        XCTAssertEqual(CaptureSessionScratchType.flare1Click.trainingBPMList, [70, 80, 90])
        XCTAssertEqual(CaptureSessionScratchType.orbit.trainingBPMList, [70, 80, 90])
        XCTAssertEqual(CaptureSessionScratchType.flare2Click.trainingBPMList, [70, 80, 90])
        XCTAssertEqual(CaptureSessionScratchType.twiddle.trainingBPMList, [70, 80, 90])

        XCTAssertEqual(CaptureSessionScratchType.boomerang.trainingBPMList, [80, 90, 100])
        XCTAssertEqual(CaptureSessionScratchType.hydroplane.trainingBPMList, [80, 90, 100])
        XCTAssertEqual(CaptureSessionScratchType.flare3Click.trainingBPMList, [80, 90, 100])
        XCTAssertEqual(CaptureSessionScratchType.autobahn.trainingBPMList, [80, 90, 100])
        XCTAssertEqual(CaptureSessionScratchType.military.trainingBPMList, [80, 90, 100])
        XCTAssertEqual(CaptureSessionScratchType.prizm.trainingBPMList, [80, 90, 100])

        XCTAssertEqual(CaptureSessionScratchType.comboL1.trainingBPMList, [70, 80, 95, 105, 125])
        XCTAssertEqual(CaptureSessionScratchType.comboL5.trainingBPMList, [70, 80, 95, 105, 125])
    }

    func testFormulaCatalogUsesScratchSpecificDefaultBeatLengths() throws {
        let babyScratch = try XCTUnwrap(ScratchLibrary.shared.scratch(byID: "baby_scratch"))
        let chirpScratch = try XCTUnwrap(ScratchLibrary.shared.scratch(byID: "chirp"))
        let prizmScratch = try XCTUnwrap(ScratchLibrary.shared.scratch(byID: "prizm"))

        let catalog = ScratchFormulaCatalog.mvp
        let babyEntry = try XCTUnwrap(catalog.resolve("baby"))
        let chirpEntry = try XCTUnwrap(catalog.resolve("chirp"))
        let prizmEntry = try XCTUnwrap(catalog.resolve("prizm"))

        XCTAssertEqual(babyEntry.defaultBeats, babyScratch.formulaDefaultBeats, accuracy: 0.0001)
        XCTAssertEqual(chirpEntry.defaultBeats, chirpScratch.formulaDefaultBeats, accuracy: 0.0001)
        XCTAssertEqual(prizmEntry.defaultBeats, prizmScratch.formulaDefaultBeats, accuracy: 0.0001)
        XCTAssertLessThan(chirpEntry.defaultBeats, babyEntry.defaultBeats)
        XCTAssertGreaterThan(prizmEntry.defaultBeats, babyEntry.defaultBeats)
    }

    func testFormulaRendererKeepsDistinctScratchDurations() throws {
        let renderer = ScratchFormulaRenderer()
        let timeline = try renderer.render(formula: "baby + chirp + prizm")

        XCTAssertEqual(timeline.events.count, 3)

        let expectedScratchIDs = ["baby_scratch", "chirp", "prizm"]
        let expectedDurations = try expectedScratchIDs.map { scratchID in
            try XCTUnwrap(ScratchLibrary.shared.scratch(byID: scratchID)).formulaDefaultBeats
        }

        for (index, expectedDuration) in expectedDurations.enumerated() {
            XCTAssertEqual(timeline.events[index].durationBeats, expectedDuration, accuracy: 0.0001)
        }

        XCTAssertLessThan(timeline.events[1].durationBeats, timeline.events[0].durationBeats)
        XCTAssertGreaterThan(timeline.events[2].durationBeats, timeline.events[0].durationBeats)
        XCTAssertEqual(timeline.events[1].startBeat, timeline.events[0].durationBeats, accuracy: 0.0001)
        XCTAssertEqual(
            timeline.events[2].startBeat,
            timeline.events[0].durationBeats + timeline.events[1].durationBeats,
            accuracy: 0.0001
        )
        XCTAssertEqual(timeline.totalBeats, expectedDurations.reduce(0, +), accuracy: 0.0001)
    }

    func testBeatEngineReusesExistingClickTrackEngineForClickMode() throws {
        let mockClickTrackEngine = MockClickTrackTimingEngine()
        let beatEngine = ScratchLabBeatEngine(clickTrackEngine: mockClickTrackEngine)
        var countInBeats: [Int] = []
        var recordingStarted = false

        let metadata = try beatEngine.start(
            mode: .clickTrack,
            bpm: 95,
            onCountInBeat: { countInBeats.append($0) },
            onRecordingStart: { recordingStarted = true }
        )

        XCTAssertEqual(mockClickTrackEngine.startCallCount, 1)
        XCTAssertEqual(mockClickTrackEngine.requestedBPMs, [95])
        XCTAssertEqual(countInBeats, [1])
        XCTAssertTrue(recordingStarted)
        XCTAssertEqual(metadata.bpm, mockClickTrackEngine.returnedMetadata.bpm)
        XCTAssertEqual(metadata.countInBeats, mockClickTrackEngine.returnedMetadata.countInBeats)
        XCTAssertEqual(metadata.beatsPerBar, mockClickTrackEngine.returnedMetadata.beatsPerBar)
        XCTAssertEqual(metadata.clickStartHostTime, mockClickTrackEngine.returnedMetadata.clickStartHostTime)
        XCTAssertEqual(metadata.recordingStartHostTime, mockClickTrackEngine.returnedMetadata.recordingStartHostTime)
        XCTAssertEqual(metadata.clickAccentPattern, mockClickTrackEngine.returnedMetadata.clickAccentPattern)
        XCTAssertEqual(metadata.clickVersion, mockClickTrackEngine.returnedMetadata.clickVersion)
        XCTAssertEqual(metadata.beatEngineMode, .clickTrack)
        XCTAssertFalse(metadata.beatEnabled)
        XCTAssertNil(metadata.beatPatternName)
        XCTAssertEqual(metadata.engineVersion, CaptureBeatEngineDefaults.engineVersion)
        beatEngine.stop()
    }

    @MainActor
    func testSessionSetupUsesScratchSpecificTimedCaptureBPMOptions() {
        let setup = SessionSetupViewModel(surface: .iosCompanion)

        XCTAssertEqual(setup.allowedBPMList, CaptureSessionScratchType.babyScratch.trainingBPMList)
        XCTAssertEqual(setup.bpmValue, CaptureClickTrackDefaults.defaultTimedBPM)
        XCTAssertTrue(setup.showsTimedCaptureTempo)
        XCTAssertEqual(setup.beatEngineMode, .clickTrack)
        XCTAssertTrue(setup.clickEnabled)
        XCTAssertFalse(setup.beatEnabled)

        setup.scratchType = .transform
        XCTAssertEqual(setup.allowedBPMList, CaptureSessionScratchType.transform.trainingBPMList)

        setup.captureMode = .calibrationNoClick
        XCTAssertFalse(setup.showsTimedCaptureTempo)
        XCTAssertEqual(setup.beatEngineMode, .silent)
        XCTAssertFalse(setup.clickEnabled)
        XCTAssertFalse(setup.beatEnabled)

        setup.captureMode = .timedClick
        XCTAssertEqual(setup.bpmValue, CaptureClickTrackDefaults.defaultTimedBPM)
        XCTAssertEqual(setup.beatEngineMode, .clickTrack)
        XCTAssertTrue(setup.clickEnabled)
        XCTAssertFalse(setup.beatEnabled)

        let macSetup = SessionSetupViewModel(surface: .macRoutine)
        macSetup.scratchType = nil
        XCTAssertEqual(macSetup.allowedBPMList, CaptureClickTrackDefaults.presetBPMs)
    }

    @MainActor
    func testSessionSetupClampsCustomTimedCaptureBPMToSupportedRange() {
        let setup = SessionSetupViewModel(surface: .iosCompanion)
        setup.scratchType = .babyScratch

        setup.bpmText = "40"
        XCTAssertEqual(setup.bpmValue, CaptureClickTrackDefaults.supportedBPMRange.lowerBound)

        setup.bpmText = "150"
        XCTAssertEqual(setup.bpmValue, CaptureClickTrackDefaults.supportedBPMRange.upperBound)
    }

    @MainActor
    func testPracticeBeatCanStartAndStopWithoutCreatingCaptureArtifacts() throws {
        let root = try makeTemporaryDirectory()
        let defaults = try makeEphemeralUserDefaults()
        let playbackEngine = MockPracticeBeatPlaybackEngine()
        let practiceBeatStore = PracticeBeatStore(defaults: defaults, beatEngine: playbackEngine)

        practiceBeatStore.configurePracticeContext(scratchID: CaptureSessionScratchType.transform.rawValue)
        practiceBeatStore.setBeatEnabled(true)
        practiceBeatStore.setBPM(110)
        practiceBeatStore.startPlayback()

        XCTAssertTrue(practiceBeatStore.isPlaying)
        XCTAssertEqual(playbackEngine.startCallCount, 1)
        XCTAssertEqual(playbackEngine.requestedModes, [.clickTrack])
        XCTAssertEqual(playbackEngine.requestedBPMs, [110])

        practiceBeatStore.stopPlayback()

        XCTAssertFalse(practiceBeatStore.isPlaying)
        XCTAssertEqual(playbackEngine.stopCallCount, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    @MainActor
    func testPracticeBeatBPMChangesRestartSharedEngineAtNewTempo() throws {
        let defaults = try makeEphemeralUserDefaults()
        let playbackEngine = MockPracticeBeatPlaybackEngine()
        let practiceBeatStore = PracticeBeatStore(defaults: defaults, beatEngine: playbackEngine)

        practiceBeatStore.setBeatEnabled(true)
        practiceBeatStore.setBPM(95)
        practiceBeatStore.startPlayback()
        practiceBeatStore.setBPM(120)

        XCTAssertTrue(practiceBeatStore.isPlaying)
        XCTAssertEqual(playbackEngine.requestedBPMs, [95, 120])
        XCTAssertEqual(playbackEngine.stopCallCount, 1)
    }

    @MainActor
    func testPracticeBeatModeChangesRestartSharedEngineWithSelectedMode() throws {
        let defaults = try makeEphemeralUserDefaults()
        let playbackEngine = MockPracticeBeatPlaybackEngine()
        let practiceBeatStore = PracticeBeatStore(defaults: defaults, beatEngine: playbackEngine)

        practiceBeatStore.setBeatEnabled(true)
        practiceBeatStore.startPlayback()
        practiceBeatStore.selectBeatMode(.boomBapTrainer)
        practiceBeatStore.selectBeatMode(.minimalFunk)

        XCTAssertTrue(practiceBeatStore.isPlaying)
        XCTAssertEqual(playbackEngine.requestedModes, [.clickTrack, .boomBapTrainer, .minimalFunk])
        XCTAssertEqual(playbackEngine.stopCallCount, 2)
    }

    @MainActor
    func testPracticeBeatStopsOnPracticeExitAndBackground() throws {
        let defaults = try makeEphemeralUserDefaults()
        let playbackEngine = MockPracticeBeatPlaybackEngine()
        let practiceBeatStore = PracticeBeatStore(defaults: defaults, beatEngine: playbackEngine)

        practiceBeatStore.setBeatEnabled(true)
        practiceBeatStore.startPlayback()
        practiceBeatStore.handleLeavingPractice()

        XCTAssertFalse(practiceBeatStore.isPlaying)
        XCTAssertEqual(playbackEngine.stopCallCount, 1)

        practiceBeatStore.startPlayback()
        practiceBeatStore.handleAppDidBecomeInactive()

        XCTAssertFalse(practiceBeatStore.isPlaying)
        XCTAssertEqual(playbackEngine.stopCallCount, 2)
    }

    @MainActor
    func testPracticeBeatStopsWhenRecordingFlowStarts() throws {
        let defaults = try makeEphemeralUserDefaults()
        let playbackEngine = MockPracticeBeatPlaybackEngine()
        let practiceBeatStore = PracticeBeatStore(defaults: defaults, beatEngine: playbackEngine)

        practiceBeatStore.setBeatEnabled(true)
        practiceBeatStore.startPlayback()
        practiceBeatStore.handleRecordingFlowStarted()

        XCTAssertFalse(practiceBeatStore.isPlaying)
        XCTAssertEqual(playbackEngine.stopCallCount, 1)
    }

    @MainActor
    func testPracticeBeatSettingsCarryIntoRecordSetupOnlyWhenBeatIsEnabled() throws {
        let defaults = try makeEphemeralUserDefaults()
        let playbackEngine = MockPracticeBeatPlaybackEngine()
        let practiceBeatStore = PracticeBeatStore(defaults: defaults, beatEngine: playbackEngine)

        practiceBeatStore.configurePracticeContext(scratchID: CaptureSessionScratchType.transform.rawValue)
        practiceBeatStore.setBPM(110)
        practiceBeatStore.selectBeatMode(.boomBapTrainer)
        practiceBeatStore.setBeatEnabled(true)

        let enabledRecordSetup = SessionSetupViewModel(surface: .iosCompanion)
        practiceBeatStore.applyToRecordSetup(enabledRecordSetup)

        XCTAssertEqual(enabledRecordSetup.scratchType, .transform)
        XCTAssertEqual(enabledRecordSetup.bpmValue, 110)
        XCTAssertEqual(enabledRecordSetup.captureMode, .timedClick)
        XCTAssertEqual(enabledRecordSetup.beatEngineMode, .boomBapTrainer)
        XCTAssertFalse(enabledRecordSetup.clickEnabled)
        XCTAssertTrue(enabledRecordSetup.beatEnabled)

        practiceBeatStore.setBeatEnabled(false)
        let disabledRecordSetup = SessionSetupViewModel(surface: .iosCompanion)
        practiceBeatStore.applyToRecordSetup(disabledRecordSetup)

        XCTAssertEqual(disabledRecordSetup.scratchType, .transform)
        XCTAssertEqual(disabledRecordSetup.bpmValue, 110)
        XCTAssertEqual(disabledRecordSetup.captureMode, .timedClick)
        XCTAssertEqual(disabledRecordSetup.beatEngineMode, .clickTrack)
        XCTAssertTrue(disabledRecordSetup.clickEnabled)
        XCTAssertFalse(disabledRecordSetup.beatEnabled)
    }

    func testSessionListPresentationCapsRecentSessionsAtThree() {
        let baseDate = Date(timeIntervalSince1970: 1_720_000_000)
        let sessions = (0..<12).map { index in
            CaptureCore.createNewRoutineSessionDraft(
                sessionID: "session-\(index)",
                now: baseDate.addingTimeInterval(Double(index))
            )
        }
        let lastOpenedAtBySessionID = Dictionary(uniqueKeysWithValues: sessions.enumerated().map { index, session in
            (session.id, baseDate.addingTimeInterval(Double(index * 60)))
        })

        let presentation = SessionListPresentationModel(
            sessions: sessions,
            activeSessionID: sessions.last?.id,
            lastOpenedAtBySessionID: lastOpenedAtBySessionID
        )

        XCTAssertEqual(presentation.activeSession?.id, sessions.last?.id)
        XCTAssertEqual(presentation.recentSessions.count, SessionListPolicy.maximumRecentSessionCount)
        XCTAssertEqual(presentation.recentSessions.first?.id, sessions[10].id)
        XCTAssertEqual(presentation.recentSessions.last?.id, sessions[8].id)
        XCTAssertFalse(presentation.recentSessions.contains(where: { $0.id == presentation.activeSession?.id }))
        XCTAssertEqual(presentation.allSessions.count, 12)
    }

    func testSessionListPresentationFallsBackToMostRecentlyOpenedSessionWhenNoActiveSessionIsSelected() {
        let baseDate = Date(timeIntervalSince1970: 1_720_100_000)
        let olderSession = CaptureCore.createNewRoutineSessionDraft(
            sessionID: "older-session",
            now: baseDate
        )
        let newerSession = CaptureCore.createNewRoutineSessionDraft(
            sessionID: "newer-session",
            now: baseDate.addingTimeInterval(60)
        )

        let presentation = SessionListPresentationModel(
            sessions: [olderSession, newerSession],
            activeSessionID: nil,
            lastOpenedAtBySessionID: [
                olderSession.id: baseDate,
                newerSession.id: baseDate.addingTimeInterval(120)
            ]
        )

        XCTAssertEqual(presentation.activeSession?.id, newerSession.id)
        XCTAssertEqual(presentation.recentSessions.map(\.id), [olderSession.id])
    }

    func testScratchCoachInstructionDecodesStructuredJSON() throws {
        let json = """
        {
          "scratchType": "baby",
          "scratchDisplayName": "Baby Scratch",
          "instructionSummary": "Keep the fader open.",
          "coachScript": "Use the same distance in both directions.",
          "steps": ["Push forward.", "Pull back."],
          "commonMistake": "Rushing the pullback.",
          "practiceChallenge": "Play 8 even reps.",
          "difficulty": "beginner",
          "demoAudioFile": "baby_noBeat.wav",
          "demoAudioRole": "noBeat",
          "poseKeyframesFile": "baby_pose_keyframes.json",
          "controllerKeyframesFile": "baby_controller_keyframes.json",
          "sourceAngle": "front_left",
          "motionReferenceType": "scratchlab_capture_reference"
        }
        """

        let instruction = try JSONDecoder().decode(
            ScratchCoachInstruction.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(instruction.scratchType, "baby")
        XCTAssertEqual(instruction.scratchDisplayName, "Baby Scratch")
        XCTAssertEqual(instruction.steps, ["Push forward.", "Pull back."])
        XCTAssertEqual(instruction.commonMistake, "Rushing the pullback.")
        XCTAssertEqual(instruction.practiceChallenge, "Play 8 even reps.")
        XCTAssertEqual(instruction.demoAudioFile, "baby_noBeat.wav")
        XCTAssertEqual(instruction.demoAudioRole, "noBeat")
        XCTAssertEqual(instruction.poseKeyframesFile, "baby_pose_keyframes.json")
        XCTAssertEqual(instruction.controllerKeyframesFile, "baby_controller_keyframes.json")
        XCTAssertEqual(instruction.sourceAngle, "front_left")
        XCTAssertEqual(instruction.motionReferenceType, "scratchlab_capture_reference")
        XCTAssertTrue(instruction.showsStructuredCoaching)
    }

    @MainActor
    func testScratchCoachInstructionStoreLoadsInstructionByScratchTypeAlias() {
        let store = ScratchCoachInstructionStore(dataProvider: { resourceName in
            guard resourceName == "baby" else { return nil }
            return Data(
                """
                {
                  "scratchType": "baby",
                  "scratchDisplayName": "Baby Scratch",
                  "instructionSummary": "Keep the motion even.",
                  "coachScript": "Stay relaxed.",
                  "steps": ["Push forward.", "Pull back."],
                  "commonMistake": "Overdriving the forward move.",
                  "practiceChallenge": "Play 8 balanced reps.",
                  "difficulty": "beginner",
                  "demoAudioFile": "baby_noBeat.wav"
                }
                """.utf8
            )
        })

        let instruction = store.instruction(
            for: "baby_scratch",
            scratchDisplayName: "Baby Scratch"
        )

        XCTAssertEqual(instruction.scratchType, "baby")
        XCTAssertEqual(instruction.scratchDisplayName, "Baby Scratch")
        XCTAssertEqual(instruction.instructionSummary, "Keep the motion even.")
        XCTAssertEqual(instruction.demoAudioFile, "baby_noBeat.wav")
        XCTAssertEqual(instruction.demoAudioRole, "noBeat")
        XCTAssertNil(instruction.poseKeyframesFile)
        XCTAssertNil(instruction.controllerKeyframesFile)
        XCTAssertNil(instruction.sourceAngle)
        XCTAssertNil(instruction.motionReferenceType)
    }

    @MainActor
    func testScratchCoachInstructionStoreLoadsBabyInstructionFromSimpleAlias() {
        let store = ScratchCoachInstructionStore(dataProvider: { resourceName in
            guard resourceName == "baby" else { return nil }
            return Data(
                """
                {
                  "scratchType": "baby",
                  "scratchDisplayName": "Baby Scratch",
                  "instructionSummary": "Keep the motion even.",
                  "coachScript": "Stay relaxed.",
                  "steps": ["Push forward.", "Pull back."],
                  "commonMistake": "Overdriving the forward move.",
                  "practiceChallenge": "Play 8 balanced reps.",
                  "difficulty": "beginner",
                  "demoAudioFile": "baby_noBeat.wav"
                }
                """.utf8
            )
        })

        let instruction = store.instruction(
            for: "baby",
            scratchDisplayName: "Baby"
        )

        XCTAssertEqual(instruction.scratchType, "baby")
        XCTAssertEqual(instruction.scratchDisplayName, "Baby Scratch")
        XCTAssertEqual(instruction.demoAudioFile, "baby_noBeat.wav")
    }

    @MainActor
    func testScratchCoachInstructionStoreLoadsChirpFlareInstructionFromHumanReadableAlias() {
        let store = ScratchCoachInstructionStore(dataProvider: { resourceName in
            guard resourceName == "chirpflare" else { return nil }
            return Data(
                """
                {
                  "scratchType": "chirpflare",
                  "scratchDisplayName": "Chirp Flare",
                  "instructionSummary": "Keep the chirp tight and the flare light.",
                  "coachScript": "Cut the note cleanly, then let the flare breathe.",
                  "steps": ["Open into the forward push.", "Click the flare lightly on the pullback."],
                  "commonMistake": "Closing the fader too late and smearing the cut.",
                  "practiceChallenge": "Loop 4 even reps at one tempo before speeding up.",
                  "difficulty": "intermediate",
                  "demoAudioFile": "chirpflare_noBeat.wav"
                }
                """.utf8
            )
        })

        let instruction = store.instruction(
            for: "Chirp Flare",
            scratchDisplayName: "Chirp Flare"
        )

        XCTAssertEqual(instruction.scratchType, "chirpflare")
        XCTAssertEqual(instruction.scratchDisplayName, "Chirp Flare")
        XCTAssertEqual(instruction.instructionSummary, "Keep the chirp tight and the flare light.")
        XCTAssertEqual(instruction.demoAudioFile, "chirpflare_noBeat.wav")
    }

    @MainActor
    func testScratchCoachInstructionStoreLoadsChirpFlareInstructionFromCamelAlias() {
        let store = ScratchCoachInstructionStore(dataProvider: { resourceName in
            guard resourceName == "chirpflare" else { return nil }
            return Data(
                """
                {
                  "scratchType": "chirpflare",
                  "scratchDisplayName": "Chirp Flare",
                  "instructionSummary": "Keep the chirp tight and the flare light.",
                  "coachScript": "Cut the note cleanly, then let the flare breathe.",
                  "steps": ["Open into the forward push.", "Click the flare lightly on the pullback."],
                  "commonMistake": "Closing the fader too late and smearing the cut.",
                  "practiceChallenge": "Loop 4 even reps at one tempo before speeding up.",
                  "difficulty": "intermediate",
                  "demoAudioFile": "chirpflare_noBeat.wav"
                }
                """.utf8
            )
        })

        let instruction = store.instruction(
            for: "ChirpFlare",
            scratchDisplayName: "ChirpFlare"
        )

        XCTAssertEqual(instruction.scratchType, "chirpflare")
        XCTAssertEqual(instruction.scratchDisplayName, "Chirp Flare")
        XCTAssertEqual(instruction.demoAudioFile, "chirpflare_noBeat.wav")
    }

    @MainActor
    func testScratchCoachInstructionStoreLoadsChirpFlareInstructionFromUnderscoredAlias() {
        let store = ScratchCoachInstructionStore(dataProvider: { resourceName in
            guard resourceName == "chirpflare" else { return nil }
            return Data(
                """
                {
                  "scratchType": "chirpflare",
                  "scratchDisplayName": "Chirp Flare",
                  "instructionSummary": "Keep the chirp tight and the flare light.",
                  "coachScript": "Cut the note cleanly, then let the flare breathe.",
                  "steps": ["Open into the forward push.", "Click the flare lightly on the pullback."],
                  "commonMistake": "Closing the fader too late and smearing the cut.",
                  "practiceChallenge": "Loop 4 even reps at one tempo before speeding up.",
                  "difficulty": "intermediate",
                  "demoAudioFile": "chirpflare_noBeat.wav"
                }
                """.utf8
            )
        })

        let instruction = store.instruction(
            for: "chirp_flare",
            scratchDisplayName: "Chirp Flare"
        )

        XCTAssertEqual(instruction.scratchType, "chirpflare")
        XCTAssertEqual(instruction.scratchDisplayName, "Chirp Flare")
        XCTAssertEqual(instruction.instructionSummary, "Keep the chirp tight and the flare light.")
        XCTAssertEqual(instruction.demoAudioFile, "chirpflare_noBeat.wav")
    }

    @MainActor
    func testScratchCoachInstructionStoreLoadsChirpFlareInstructionFromLowercaseAlias() {
        let store = ScratchCoachInstructionStore(dataProvider: { resourceName in
            guard resourceName == "chirpflare" else { return nil }
            return Data(
                """
                {
                  "scratchType": "chirpflare",
                  "scratchDisplayName": "Chirp Flare",
                  "instructionSummary": "Keep the chirp tight and the flare light.",
                  "coachScript": "Cut the note cleanly, then let the flare breathe.",
                  "steps": ["Open into the forward push.", "Click the flare lightly on the pullback."],
                  "commonMistake": "Closing the fader too late and smearing the cut.",
                  "practiceChallenge": "Loop 4 even reps at one tempo before speeding up.",
                  "difficulty": "intermediate",
                  "demoAudioFile": "chirpflare_noBeat.wav"
                }
                """.utf8
            )
        })

        let instruction = store.instruction(
            for: "chirpflare",
            scratchDisplayName: "chirpflare"
        )

        XCTAssertEqual(instruction.scratchType, "chirpflare")
        XCTAssertEqual(instruction.scratchDisplayName, "Chirp Flare")
        XCTAssertEqual(instruction.demoAudioFile, "chirpflare_noBeat.wav")
    }

    @MainActor
    func testScratchCoachInstructionStoreFallsBackToDisplayNameAliasWhenScratchIDHasNoCoachFile() {
        let store = ScratchCoachInstructionStore(dataProvider: { resourceName in
            guard resourceName == "chirpflare" else { return nil }
            return Data(
                """
                {
                  "scratchType": "chirpflare",
                  "scratchDisplayName": "Chirp Flare",
                  "instructionSummary": "Keep the chirp tight and the flare light.",
                  "coachScript": "Cut the note cleanly, then let the flare breathe.",
                  "steps": ["Open into the forward push.", "Click the flare lightly on the pullback."],
                  "commonMistake": "Closing the fader too late and smearing the cut.",
                  "practiceChallenge": "Loop 4 even reps at one tempo before speeding up.",
                  "difficulty": "intermediate",
                  "demoAudioFile": "chirpflare_noBeat.wav"
                }
                """.utf8
            )
        })

        let instruction = store.instruction(
            for: "flare_1click",
            scratchDisplayName: "Chirp Flare"
        )

        XCTAssertEqual(instruction.scratchType, "chirpflare")
        XCTAssertEqual(instruction.scratchDisplayName, "Chirp Flare")
        XCTAssertEqual(instruction.instructionSummary, "Keep the chirp tight and the flare light.")
        XCTAssertEqual(instruction.demoAudioFile, "chirpflare_noBeat.wav")
    }

    @MainActor
    func testScratchCoachInstructionStoreReturnsFallbackForMissingInstruction() {
        let store = ScratchCoachInstructionStore(dataProvider: { _ in nil })

        let instruction = store.instruction(
            for: "chirp",
            scratchDisplayName: "Chirp"
        )

        XCTAssertEqual(instruction.scratchType, "chirp")
        XCTAssertEqual(instruction.scratchDisplayName, "Chirp")
        XCTAssertEqual(instruction.instructionSummary, "Coach tip unavailable")
        XCTAssertFalse(instruction.showsStructuredCoaching)
    }

    @MainActor
    func testScratchCoachInstructionStoreReturnsNeutralStateWhenScratchTypeIsMissing() {
        let store = ScratchCoachInstructionStore(dataProvider: { _ in
            XCTFail("No data lookup should happen for a missing scratch selection.")
            return nil
        })

        let instruction = store.instruction(
            for: nil,
            scratchDisplayName: nil
        )

        XCTAssertEqual(instruction.scratchType, "")
        XCTAssertEqual(instruction.scratchDisplayName, "Scratch Coach")
        XCTAssertEqual(instruction.instructionSummary, "Choose a scratch to see coaching tips.")
    }

    @MainActor
    func testScratchCoachInstructionStoreReturnsFallbackForMalformedInstruction() {
        let store = ScratchCoachInstructionStore(dataProvider: { _ in
            Data("{\"scratchType\":\"baby\",\"scratchDisplayName\":".utf8)
        })

        let instruction = store.instruction(
            for: "baby_scratch",
            scratchDisplayName: "Baby Scratch"
        )

        XCTAssertEqual(instruction.scratchType, "baby_scratch")
        XCTAssertEqual(instruction.scratchDisplayName, "Baby Scratch")
        XCTAssertEqual(instruction.instructionSummary, "Coach tip unavailable")
    }

    @MainActor
    func testScratchCoachDemoAudioPlayerFallsBackWhenAudioIsMissing() {
        let player = ScratchCoachDemoAudioPlayer(
            resourceURLProvider: { _ in nil },
            playerFactory: { _ in
                XCTFail("Missing coach demo audio should not create a playback instance.")
                return MockScratchCoachDemoPlayable()
            }
        )
        let instruction = ScratchCoachInstruction(
            scratchType: "baby",
            scratchDisplayName: "Baby Scratch",
            instructionSummary: "Keep the motion even.",
            coachScript: "Stay relaxed.",
            steps: ["Push forward.", "Pull back."],
            commonMistake: "Overdriving the forward move.",
            practiceChallenge: "Play 8 balanced reps.",
            difficulty: "beginner",
            demoAudioFile: "missing_demo",
            demoAudioRole: "noBeat"
        )

        player.configure(with: instruction)
        player.play()

        XCTAssertFalse(player.isAudioAvailable)
        XCTAssertEqual(player.playbackState, .stopped)
        XCTAssertFalse(player.isPlaying)
    }

    @MainActor
    func testScratchCoachDemoAudioPlayerSupportsPlayPauseReplayAndStop() throws {
        let mockPlayable = MockScratchCoachDemoPlayable()
        let root = try makeTemporaryDirectory()
        let resourceURL = root.appendingPathComponent("demo.m4a")
        let player = ScratchCoachDemoAudioPlayer(
            resourceURLProvider: { _ in resourceURL },
            playerFactory: { _ in mockPlayable }
        )
        let instruction = ScratchCoachInstruction(
            scratchType: "baby",
            scratchDisplayName: "Baby Scratch",
            instructionSummary: "Keep the motion even.",
            coachScript: "Stay relaxed.",
            steps: ["Push forward.", "Pull back."],
            commonMistake: "Overdriving the forward move.",
            practiceChallenge: "Play 8 balanced reps.",
            difficulty: "beginner",
            demoAudioFile: "demo.m4a",
            demoAudioRole: "noBeat"
        )

        player.configure(with: instruction)
        player.play()
        XCTAssertEqual(player.playbackState, .playing)
        XCTAssertEqual(mockPlayable.prepareCallCount, 1)
        XCTAssertEqual(mockPlayable.playCallCount, 1)

        player.pause()
        XCTAssertEqual(player.playbackState, .paused)
        XCTAssertEqual(mockPlayable.pauseCallCount, 1)

        mockPlayable.currentTime = 1.5
        player.replay()
        XCTAssertEqual(player.playbackState, .playing)
        XCTAssertEqual(mockPlayable.currentTime, 0, accuracy: 0.0001)
        XCTAssertEqual(mockPlayable.playCallCount, 2)

        player.stop()
        XCTAssertEqual(player.playbackState, .stopped)
        XCTAssertEqual(mockPlayable.stopCallCount, 1)
        XCTAssertEqual(mockPlayable.currentTime, 0, accuracy: 0.0001)
    }

    func testScratchCoachDemoAnimatorResetsWhenPlaybackIsStopped() {
        let animationState = ScratchCoachDemoAnimator.state(
            scratchType: "baby",
            playbackTime: 0.37,
            isPlaying: false
        )

        XCTAssertEqual(animationState, .neutral)
    }

    func testScratchCoachDemoAnimatorKeepsBabyCrossfaderOpenDuringPlayback() {
        let animationState = ScratchCoachDemoAnimator.state(
            scratchType: "baby_scratch",
            playbackTime: 0.25,
            isPlaying: true
        )

        XCTAssertEqual(animationState.crossfaderPosition, 1, accuracy: 0.0001)
        XCTAssertTrue(animationState.crossfaderOpenState)
        XCTAssertGreaterThan(animationState.recordPosition, 0.9)
        XCTAssertGreaterThan(animationState.recordRotationDegrees, 20)
    }

    func testScratchCoachDemoAnimatorAddsChirpflareFaderPulses() {
        let openPulseState = ScratchCoachDemoAnimator.state(
            scratchType: "chirpflare",
            playbackTime: 0.1512,
            isPlaying: true
        )
        let closedState = ScratchCoachDemoAnimator.state(
            scratchType: "chirpflare",
            playbackTime: 0.42,
            isPlaying: true
        )

        XCTAssertGreaterThan(openPulseState.crossfaderPosition, 0.95)
        XCTAssertTrue(openPulseState.crossfaderOpenState)
        XCTAssertLessThan(closedState.crossfaderPosition, 0.05)
        XCTAssertFalse(closedState.crossfaderOpenState)
    }

    @MainActor
    func testFreshRoutineSessionStoreCanCreateNewSession() throws {
        let store = try makeRoutineSessionStore()

        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertNil(store.selectedSessionID)

        store.createNewSessionFromUI()

        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.selectedSessionID, store.sessions.first?.id)
        XCTAssertEqual(store.selectedSession?.id, store.sessions.first?.id)
    }

    func testCaptureCoreSharedRoutineSessionFactoryProducesDefaultDraft() {
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let sessionID = "11111111-1111-1111-1111-111111111111"

        let draft = CaptureCore.createNewRoutineSessionDraft(sessionID: sessionID, now: now)

        XCTAssertEqual(draft.id, sessionID)
        XCTAssertEqual(draft.config.createdAt, now)
        XCTAssertEqual(draft.config.updatedAt, now)
        XCTAssertEqual(draft.config.sessionID, sessionID)
        XCTAssertEqual(draft.config.performerName, "")
        XCTAssertNil(draft.config.scratchType)
        XCTAssertNil(draft.config.bpm)
        XCTAssertEqual(draft.config.drillMode, .fullCapture)
        XCTAssertEqual(draft.config.takeCount, 0)
        XCTAssertNil(draft.config.takeDurationSeconds)
    }

    @MainActor
    func testPersistedRoutineSessionStoreCanCreateNewSessionAfterReload() throws {
        let root = try makeTemporaryDirectory()
        let storageURL = root.appendingPathComponent("RoutineSessionDrafts.json")

        let firstLaunchStore = RoutineSessionStore(storageURL: storageURL)
        firstLaunchStore.createNewSessionFromUI()
        let existingSessionID = try XCTUnwrap(firstLaunchStore.selectedSessionID)

        let reloadedStore = RoutineSessionStore(storageURL: storageURL)
        XCTAssertEqual(reloadedStore.sessions.count, 1)
        XCTAssertEqual(reloadedStore.selectedSessionID, existingSessionID)

        reloadedStore.createNewSessionFromUI()

        XCTAssertEqual(reloadedStore.sessions.count, 2)
        XCTAssertNotEqual(reloadedStore.selectedSessionID, existingSessionID)
        XCTAssertEqual(Set(reloadedStore.sessions.map(\.id)).count, 2)
    }

    @MainActor
    func testRoutineSessionStoreCreatesUUIDStyleSessionID() throws {
        let store = try makeRoutineSessionStore()

        store.createNewSessionFromUI()

        let sessionID = try XCTUnwrap(store.selectedSession?.id)
        XCTAssertNotNil(UUID(uuidString: sessionID))
    }

    @MainActor
    func testRoutineSessionCreationDoesNotRequireMetadata() throws {
        let store = try makeRoutineSessionStore()

        store.createNewSessionFromUI()

        let config = try XCTUnwrap(store.selectedSession?.config)
        XCTAssertEqual(config.performerName, "")
        XCTAssertNil(config.scratchType)
        XCTAssertNil(config.bpm)
        XCTAssertEqual(config.drillMode, .fullCapture)
    }

    @MainActor
    func testMultipleNewClicksCreateMultipleUniqueRoutineSessions() throws {
        let store = try makeRoutineSessionStore()

        store.createNewSessionFromUI()
        let firstSessionID = try XCTUnwrap(store.selectedSessionID)

        store.createNewSessionFromUI()
        let secondSessionID = try XCTUnwrap(store.selectedSessionID)

        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertNotEqual(firstSessionID, secondSessionID)
        XCTAssertEqual(Set(store.sessions.map(\.id)).count, 2)
        XCTAssertEqual(store.sessions.first?.id, secondSessionID)
    }

    @MainActor
    func testRoutineSessionStoreSelectingSessionUpdatesLastOpenedAt() throws {
        let root = try makeTemporaryDirectory()
        let storageURL = root.appendingPathComponent("RoutineSessionDrafts.json")
        let defaults = try makeEphemeralUserDefaults()
        let historyKey = "RoutineSessionHistory.\(UUID().uuidString)"
        var currentDate = Date(timeIntervalSince1970: 1_720_200_000)

        let store = RoutineSessionStore(
            storageURL: storageURL,
            nowProvider: { currentDate },
            sessionOpenHistoryDefaults: defaults,
            sessionOpenHistoryKey: historyKey
        )

        let firstSession = try XCTUnwrap(store.createNewSessionFromUI())
        currentDate = currentDate.addingTimeInterval(10)
        let secondSession = try XCTUnwrap(store.createNewSessionFromUI())

        XCTAssertEqual(store.sessionListPresentation.activeSession?.id, secondSession.id)

        currentDate = currentDate.addingTimeInterval(10)
        store.openSession(id: firstSession.id)

        XCTAssertEqual(store.selectedSessionID, firstSession.id)
        XCTAssertEqual(store.sessionListPresentation.activeSession?.id, firstSession.id)
        XCTAssertEqual(store.sessionListPresentation.recentSessions.first?.id, secondSession.id)

        let storedHistoryData = try XCTUnwrap(defaults.data(forKey: historyKey))
        let storedHistory = try JSONDecoder.captureCoreDecoder.decode([String: Date].self, from: storedHistoryData)
        XCTAssertEqual(storedHistory[firstSession.id], currentDate)
    }

    @MainActor
    func testRoutineSessionStoreDoesNotDeleteCompletedSessionsBeyondRecentLimit() throws {
        let root = try makeTemporaryDirectory()
        let storageURL = root
            .appendingPathComponent("ScratchLab", isDirectory: true)
            .appendingPathComponent("RoutineSessionDrafts.json")
        let now = Date(timeIntervalSince1970: 1_720_300_000)
        var completedSessions: [RoutineSessionDraft] = []
        for index in 0..<5 {
            let completedSession = RoutineSessionDraft(
                config: .routineCapture(
                    sessionID: "completed-\(index)",
                    createdAt: now.addingTimeInterval(-SessionListPolicy.staleDraftRetentionInterval - Double(index + 1)),
                    updatedAt: now.addingTimeInterval(-SessionListPolicy.staleDraftRetentionInterval - Double(index + 1)),
                    takeCount: index + 1,
                    takeDurationSeconds: Double(index + 1) * 10
                )
            )
            completedSessions.append(completedSession)
        }
        try writeRoutineSessionSnapshot(
            RoutineSessionDraftStoreSnapshot(
                sessions: completedSessions,
                selectedSessionID: completedSessions.first?.id
            ),
            to: storageURL
        )

        let store = RoutineSessionStore(
            storageURL: storageURL,
            nowProvider: { now }
        )

        XCTAssertEqual(store.sessions.map { $0.id }, completedSessions.map { $0.id })
        XCTAssertEqual(store.sessionListPresentation.allSessions.count, completedSessions.count)
        XCTAssertEqual(
            store.sessionListPresentation.recentSessions.count,
            SessionListPolicy.maximumRecentSessionCount
        )
    }

    @MainActor
    func testRoutineSessionStorePrunesStaleEmptyDrafts() throws {
        let root = try makeTemporaryDirectory()
        let storageURL = root
            .appendingPathComponent("ScratchLab", isDirectory: true)
            .appendingPathComponent("RoutineSessionDrafts.json")
        let now = Date(timeIntervalSince1970: 1_720_400_000)
        let staleEmptySession = CaptureCore.createNewRoutineSessionDraft(
            sessionID: "stale-empty",
            now: now.addingTimeInterval(-SessionListPolicy.staleDraftRetentionInterval - 60)
        )
        let recentSession = CaptureCore.createNewRoutineSessionDraft(
            sessionID: "recent-session",
            now: now
        )
        try writeRoutineSessionSnapshot(
            RoutineSessionDraftStoreSnapshot(
                sessions: [recentSession, staleEmptySession],
                selectedSessionID: recentSession.id
            ),
            to: storageURL
        )

        let store = RoutineSessionStore(
            storageURL: storageURL,
            nowProvider: { now }
        )

        XCTAssertEqual(store.sessions.map(\.id), [recentSession.id])
        XCTAssertEqual(store.selectedSessionID, recentSession.id)
    }

    @MainActor
    func testRoutineSessionStoreRetainsStaleSessionsWithArtifacts() throws {
        let root = try makeTemporaryDirectory()
        let storageRoot = root.appendingPathComponent("ScratchLab", isDirectory: true)
        let storageURL = storageRoot.appendingPathComponent("RoutineSessionDrafts.json")
        let capturesRoot = storageRoot.appendingPathComponent("RoutineCaptures", isDirectory: true)
        let now = Date(timeIntervalSince1970: 1_720_500_000)
        let staleArtifactSession = CaptureCore.createNewRoutineSessionDraft(
            sessionID: "artifact-session",
            now: now.addingTimeInterval(-SessionListPolicy.staleDraftRetentionInterval - 60)
        )
        let staleEmptySession = CaptureCore.createNewRoutineSessionDraft(
            sessionID: "stale-empty",
            now: now.addingTimeInterval(-SessionListPolicy.staleDraftRetentionInterval - 120)
        )
        let recentSession = CaptureCore.createNewRoutineSessionDraft(
            sessionID: "recent-session",
            now: now
        )

        try writeRoutineSessionSnapshot(
            RoutineSessionDraftStoreSnapshot(
                sessions: [recentSession, staleArtifactSession, staleEmptySession],
                selectedSessionID: recentSession.id
            ),
            to: storageURL
        )
        try FileManager.default.createDirectory(at: capturesRoot, withIntermediateDirectories: true)
        _ = try makeLocalRecordingTake(
            in: capturesRoot,
            sessionID: staleArtifactSession.id,
            takeNumber: 1,
            createdAt: now.addingTimeInterval(-300)
        )

        let store = RoutineSessionStore(
            storageURL: storageURL,
            nowProvider: { now }
        )

        XCTAssertEqual(
            Set(store.sessions.map(\.id)),
            Set([recentSession.id, staleArtifactSession.id])
        )
        XCTAssertFalse(store.sessions.contains(where: { $0.id == staleEmptySession.id }))
    }

    @MainActor
    func testRoutineSessionCreateFailureRestoresStateAndPublishesError() throws {
        let root = try makeTemporaryDirectory()
        let blockingParentURL = root.appendingPathComponent("RoutineSessionDrafts")
        try Data("blocked".utf8).write(to: blockingParentURL)

        let store = RoutineSessionStore(
            storageURL: blockingParentURL.appendingPathComponent("RoutineSessionDrafts.json")
        )

        let createdSession = store.createNewSessionFromUI()

        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertNil(store.selectedSessionID)
        XCTAssertNil(store.selectedSession)
        XCTAssertNil(createdSession)
        let alertState = try XCTUnwrap(store.alertState)
        XCTAssertEqual(alertState.title, "Session Update Failed")
        XCTAssertTrue(alertState.message.contains("create a new session"))
    }

    @MainActor
    func testRoutineSessionUIActionFactoryDelegatesToSharedCreatePath() throws {
        let store = try makeRoutineSessionStore()
        var routedSessionIDs: [String] = []
        let createNewSessionAction = RoutineSessionUIActionFactory.makeCreateNewSessionAction(
            for: store,
            onSuccess: { routedSessionIDs.append($0.id) }
        )

        createNewSessionAction()
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(routedSessionIDs, [store.sessions[0].id])

        createNewSessionAction()
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertEqual(store.selectedSessionID, store.sessions.first?.id)
        XCTAssertEqual(routedSessionIDs, Array(store.sessions.map(\.id).reversed()))
    }

    @MainActor
    func testSessionExportCoordinatorPrepareShareKeepsTemporaryArchive() async throws {
        let root = try makeTemporaryDirectory()
        let package = try makeCanonicalPackage(rootURL: root, useRealMedia: true)
        let coordinator = SessionExportCoordinator()

        coordinator.prepareShare(for: .package(package))

        for _ in 0..<80 {
            if coordinator.lastResult != nil { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        let result = try XCTUnwrap(coordinator.lastResult)
        XCTAssertTrue(result.shouldCleanupAfterUse)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.archiveURL.path))
        XCTAssertEqual(coordinator.statusMessage, "Ready to share")
    }

    @MainActor
    func testSessionExportCoordinatorSaveArchiveUsesChosenDestination() async throws {
        let root = try makeTemporaryDirectory()
        let package = try makeCanonicalPackage(rootURL: root, useRealMedia: true)
        let destinationURL = root.appendingPathComponent("SavedSession.zip")
        let coordinator = SessionExportCoordinator(
            archiveSaveDestinationProvider: { _ in destinationURL }
        )

        coordinator.saveArchiveCopy(for: .package(package))

        for _ in 0..<80 {
            if coordinator.lastResult?.archiveURL == destinationURL { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        let result = try XCTUnwrap(coordinator.lastResult)
        XCTAssertEqual(result.archiveURL, destinationURL)
        XCTAssertFalse(result.shouldCleanupAfterUse)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
        XCTAssertEqual(coordinator.statusMessage, "Saved ZIP.")
    }

    @MainActor
    func testSessionExportCoordinatorSaveArchiveHandlesMatchingGeneratedDestination() async throws {
        let root = try makeTemporaryDirectory()
        let package = try makeCanonicalPackage(rootURL: root, useRealMedia: true)
        let fileManager = FileManager.default
        let archiveDirectory = (fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory)
            .appendingPathComponent("ScratchLabSessionExports", isDirectory: true)
        try fileManager.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)

        let builder = SessionArchiveBuilder()
        let destinationURL = builder.archiveURL(for: package.metadata, in: archiveDirectory)
        try? fileManager.removeItem(at: destinationURL)
        addTeardownBlock {
            try? fileManager.removeItem(at: destinationURL)
        }

        let coordinator = SessionExportCoordinator(
            archiveSaveDestinationProvider: { _ in destinationURL }
        )

        coordinator.saveArchiveCopy(for: .package(package))

        for _ in 0..<80 {
            if coordinator.lastResult?.archiveURL == destinationURL { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        let result = try XCTUnwrap(coordinator.lastResult)
        XCTAssertEqual(result.archiveURL, destinationURL)
        XCTAssertFalse(result.shouldCleanupAfterUse)
        XCTAssertTrue(fileManager.fileExists(atPath: destinationURL.path))
        XCTAssertEqual(coordinator.statusMessage, "Saved ZIP.")
    }

    func testSessionExportCoordinatorSecurityScopedAccessUsesParentDirectoryForNewSaveDestination() throws {
        let root = try makeTemporaryDirectory()
        let destinationURL = root.appendingPathComponent("Nested Folder", isDirectory: true)
            .appendingPathComponent("Saved Session.zip")

        XCTAssertEqual(
            SessionExportCoordinator.securityScopedAccessURL(for: destinationURL),
            destinationURL.deletingLastPathComponent().standardizedFileURL
        )

        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("zip".utf8).write(to: destinationURL)

        XCTAssertEqual(
            SessionExportCoordinator.securityScopedAccessURL(for: destinationURL),
            destinationURL.standardizedFileURL
        )
    }

    func testSessionExportCoordinatorSourceUsesSecurityScopedSaveAccess() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLab/Services/SessionExportCoordinator.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("startAccessingSecurityScopedResource()"))
        XCTAssertTrue(source.contains("securityScopedAccessURL(for: destinationURL"))
    }

    func testScratchLabDesktopEntitlementsAllowUserSelectedArchiveSave() throws {
        let entitlementsURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/ScratchLabDesktop.entitlements")
        let source = try String(contentsOf: entitlementsURL, encoding: .utf8)

        XCTAssertTrue(source.contains("com.apple.security.files.user-selected.read-write"))
    }

    func testMacScratchDetectorTrainingLookupReturnsEmptyWithoutBundledTrainingLibrary() throws {
        let root = try makeTemporaryDirectory()

        XCTAssertTrue(MacScratchDetector.bundledBabyTrainingFiles(in: root).isEmpty)
        XCTAssertTrue(MacScratchDetector.bundledBabyTrainingFiles(in: nil).isEmpty)
    }

    func testAudioEngineSourceExposesBabyScratchMotionAnalyzerContract() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLab/Models/ScratchMotionAnalysis.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("enum ScratchMotionDirection: String, Equatable"))
        XCTAssertTrue(source.contains("enum ScratchMotionBalance: String, Equatable"))
        XCTAssertTrue(source.contains("struct ScratchMotionFeedback: Equatable"))
        XCTAssertTrue(source.contains("final class ScratchMotionAnalyzer"))
        XCTAssertTrue(source.contains("private struct EnvelopePoint"))
        XCTAssertTrue(source.contains("private let historyWindowDuration: TimeInterval = 0.18"))
        XCTAssertTrue(source.contains("private func detectExtremum("))
        XCTAssertTrue(source.contains("let timingError = abs(forwardStroke.duration - backwardStroke.duration)"))
        XCTAssertTrue(source.contains("let isBalanced = timingError <= absoluteTimingTolerance"))
        XCTAssertTrue(source.contains("print(\"[ScratchMotion] forwardDuration="))
        XCTAssertTrue(source.contains("print(\"[ScratchMotion] backwardDuration="))
        XCTAssertTrue(source.contains("print(\"[ScratchMotion] timingError="))
    }

    func testAudioEngineSourcePublishesScratchMotionFeedbackFromInputTap() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLab/Audio/AudioEngine.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("@Published var scratchMotionDirection: ScratchMotionDirection = .neutral"))
        XCTAssertTrue(source.contains("@Published var scratchMotionFeedback: ScratchMotionFeedback?"))
        XCTAssertTrue(source.contains("private let scratchMotionAnalyzer = ScratchMotionAnalyzer()"))
        XCTAssertTrue(source.contains("let motionFeedback = scratchMotionAnalyzer.process(samples: samples, sampleRate: packet.sampleRate)"))
        XCTAssertTrue(source.contains("let motionDirection = scratchMotionAnalyzer.currentDirection"))
        XCTAssertTrue(source.contains("self.scratchMotionDirection = motionDirection"))
        XCTAssertTrue(source.contains("self.scratchMotionFeedback = motionFeedback"))
    }

    func testScratchMotionAnalyzerSegmentsBalancedBabyScratchEnvelope() {
        let analyzer = ScratchMotionAnalyzer()
        let samples = makeScratchMotionSamples(
            amplitudes: Array(repeating: 0.002, count: 6)
                + linearAmplitudeRamp(start: 0.02, end: 0.14, frames: 12)
                + linearAmplitudeRamp(start: 0.13, end: 0.015, frames: 12)
                + Array(repeating: 0.002, count: 8)
        )

        let feedback = analyzer.process(samples: samples, sampleRate: 44_100)

        XCTAssertEqual(feedback?.balance, .balanced)
        XCTAssertEqual(feedback?.direction, ScratchMotionDirection.neutral)
        XCTAssertNotNil(feedback?.forwardDuration)
        XCTAssertNotNil(feedback?.backwardDuration)
        XCTAssertNotNil(feedback?.timingError)

        let forwardMilliseconds = Int(((feedback?.forwardDuration ?? 0) * 1_000).rounded())
        let backwardMilliseconds = Int(((feedback?.backwardDuration ?? 0) * 1_000).rounded())
        let timingErrorMilliseconds = feedback?.timingErrorMilliseconds ?? .max

        XCTAssertGreaterThan(forwardMilliseconds, 45)
        XCTAssertGreaterThan(backwardMilliseconds, 45)
        XCTAssertLessThan(timingErrorMilliseconds, 80)
        XCTAssertEqual(analyzer.currentDirection, ScratchMotionDirection.neutral)
    }

    func testScratchMotionAnalyzerMarksUnbalancedWhenStrokeDurationsDrift() {
        let analyzer = ScratchMotionAnalyzer()
        let samples = makeScratchMotionSamples(
            amplitudes: Array(repeating: 0.002, count: 6)
                + linearAmplitudeRamp(start: 0.02, end: 0.18, frames: 26)
                + linearAmplitudeRamp(start: 0.17, end: 0.02, frames: 10)
                + Array(repeating: 0.002, count: 8)
        )

        let feedback = analyzer.process(samples: samples, sampleRate: 44_100)

        XCTAssertEqual(feedback?.balance, .unbalanced)
        XCTAssertNotNil(feedback?.forwardDuration)
        XCTAssertNotNil(feedback?.backwardDuration)
        XCTAssertNotNil(feedback?.timingError)
        XCTAssertGreaterThan(feedback?.timingErrorMilliseconds ?? 0, 80)
    }

    func testShippingTargetsDoNotBundleReviewRiskAudioResources() throws {
        let projectURL = projectRootURL().appendingPathComponent("ScratchLab.xcodeproj/project.pbxproj")
        let source = try String(contentsOf: projectURL, encoding: .utf8)

        XCTAssertFalse(source.contains("reference_pro in Resources"))
        XCTAssertFalse(source.contains("reference_champ in Resources"))
        XCTAssertFalse(source.contains("reference_beginner in Resources"))
        XCTAssertFalse(source.contains("cxl_scratch_library in Resources"))
        XCTAssertFalse(source.contains("boom_bap_100bpm.wav in Resources"))
    }

    private func makeScratchMotionSamples(
        amplitudes: [Float],
        frameSize: Int = 256
    ) -> [Float] {
        amplitudes.flatMap { amplitude in
            Array(repeating: amplitude, count: frameSize)
        }
    }

    private func linearAmplitudeRamp(
        start: Float,
        end: Float,
        frames: Int
    ) -> [Float] {
        guard frames > 1 else { return [end] }

        return (0..<frames).map { index in
            let progress = Float(index) / Float(frames - 1)
            return start + ((end - start) * progress)
        }
    }

    func testTrainingAudioLookupSourcesDoNotUseHardCodedUserPaths() throws {
        let audioEngineSourceURL = projectRootURL().appendingPathComponent("ScratchLab/Audio/AudioEngine.swift")
        let macDetectorSourceURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/Services/MacScratchDetector.swift")

        let audioEngineSource = try String(contentsOf: audioEngineSourceURL, encoding: .utf8)
        let macDetectorSource = try String(contentsOf: macDetectorSourceURL, encoding: .utf8)

        let userRootToken = "\"/" + "Users/"
        XCTAssertFalse(audioEngineSource.contains(userRootToken))
        XCTAssertFalse(macDetectorSource.contains(userRootToken))
    }

    func testLegacyBundleAudioManagersFilterMissingBundledAssetsInSource() throws {
        let sampleSourceURL = projectRootURL().appendingPathComponent("ScratchLab/Audio/SampleManager.swift")
        let trackSourceURL = projectRootURL().appendingPathComponent("ScratchLab/Audio/BackingTrackManager.swift")

        let sampleSource = try String(contentsOf: sampleSourceURL, encoding: .utf8)
        let trackSource = try String(contentsOf: trackSourceURL, encoding: .utf8)

        XCTAssertTrue(sampleSource.contains("static func bundledDefaultSamples(in resource" + "Root: URL?)"))
        XCTAssertTrue(sampleSource.contains("Self.bundledDefaultSamples(in: Bundle.main.resourceURL)"))
        XCTAssertTrue(sampleSource.contains("Bundled scratch samples are unavailable on this build."))
        XCTAssertTrue(trackSource.contains("static func bundledDefaultTracks(in resource" + "Root: URL?)"))
        XCTAssertTrue(trackSource.contains("Self.bundledDefaultTracks(in: Bundle.main.resourceURL)"))
        XCTAssertTrue(trackSource.contains("Bundled backing tracks are unavailable on this build."))
    }

    func testTrainingAudioLookupSourcesUseFallbackWhenBundledLibraryIsMissing() throws {
        let audioEngineSourceURL = projectRootURL().appendingPathComponent("ScratchLab/Audio/AudioEngine.swift")
        let macDetectorSourceURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/Services/MacScratchDetector.swift")
        let analyzerSourceURL = projectRootURL().appendingPathComponent("ScratchLab/Audio/ScratchAnalyzer.swift")

        let audioEngineSource = try String(contentsOf: audioEngineSourceURL, encoding: .utf8)
        let macDetectorSource = try String(contentsOf: macDetectorSourceURL, encoding: .utf8)
        let analyzerSource = try String(contentsOf: analyzerSourceURL, encoding: .utf8)

        XCTAssertTrue(audioEngineSource.contains("guard !audioFiles.isEmpty else { return fallback }"))
        XCTAssertTrue(audioEngineSource.contains("static func bundledBabyTrainingFiles(in resource" + "Root: URL?)"))
        XCTAssertTrue(macDetectorSource.contains("guard !audioFiles.isEmpty else { return fallback }"))
        XCTAssertTrue(macDetectorSource.contains("static func bundledBabyTrainingFiles(in resource" + "Root: URL?)"))
        XCTAssertTrue(analyzerSource.contains("guard foundReferenceFolder, !allSamples.isEmpty else"))
        XCTAssertTrue(analyzerSource.contains("throw AnalyzerError.resourceNotFound"))
    }

    func testTrainingAudioLookupSourcesGateTrainingPathsOutOfRelease() throws {
        let audioEngineSourceURL = projectRootURL().appendingPathComponent("ScratchLab/Audio/AudioEngine.swift")
        let macDetectorSourceURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/Services/MacScratchDetector.swift")

        let audioEngineSource = try String(contentsOf: audioEngineSourceURL, encoding: .utf8)
        let macDetectorSource = try String(contentsOf: macDetectorSourceURL, encoding: .utf8)
        let runtimeSources = [
            "AudioEngine.swift": audioEngineSource,
            "MacScratchDetector.swift": macDetectorSource,
        ]
        let forbiddenRuntimePathFragments = [
            "cxl_scratch_library",
            "scratch_training_library",
            "reference_pro",
            "reference_champ",
            "reference_beginner",
        ]

        for (fileName, source) in runtimeSources {
            XCTAssertTrue(source.contains("guard let resourceRoot, let trainingPath = babyTrainingFolderPath else { return [] }"), fileName)
            XCTAssertTrue(source.contains("private static var babyTrainingFolderPath: String?"), fileName)
            XCTAssertTrue(source.contains("#if DEBUG"), fileName)
            XCTAssertTrue(source.contains("return \"internal_training/baby_scratch\""), fileName)
            XCTAssertTrue(source.contains("#else\n        return nil\n        #endif"), fileName)
            XCTAssertTrue(source.contains("appendingPathComponent(trainingPath, isDirectory: true)"), fileName)

            for fragment in forbiddenRuntimePathFragments {
                XCTAssertFalse(source.localizedCaseInsensitiveContains(fragment), "\(fileName) contains \(fragment)")
            }
        }
    }

    func testLegacySampleAndBackingTrackSelectorsAreNotRoutedFromShippedMenus() throws {
        let mainMenuSourceURL = projectRootURL().appendingPathComponent("ScratchLab/Views/MainMenuView.swift")
        let levelSelectSourceURL = projectRootURL().appendingPathComponent("ScratchLab/Views/LevelSelectView.swift")
        let practiceSourceURL = projectRootURL().appendingPathComponent("ScratchLab/Views/PracticeModeView.swift")

        let mainMenuSource = try String(contentsOf: mainMenuSourceURL, encoding: .utf8)
        let levelSelectSource = try String(contentsOf: levelSelectSourceURL, encoding: .utf8)
        let practiceSource = try String(contentsOf: practiceSourceURL, encoding: .utf8)

        XCTAssertFalse(mainMenuSource.contains("SampleSelectionView("))
        XCTAssertFalse(mainMenuSource.contains("BackingTrackSelectionView("))
        XCTAssertFalse(levelSelectSource.contains("SampleSelectionView("))
        XCTAssertFalse(levelSelectSource.contains("BackingTrackSelectionView("))
        XCTAssertFalse(practiceSource.contains("SampleSelectionView("))
        XCTAssertFalse(practiceSource.contains("BackingTrackSelectionView("))
        XCTAssertFalse(mainMenuSource.contains("ScratchAnalyzer("))
        XCTAssertFalse(levelSelectSource.contains("ScratchAnalyzer("))
        XCTAssertFalse(practiceSource.contains("ScratchAnalyzer("))
    }

    func testLegacySampleAndBackingTrackSelectorsRenderMissingAssetEmptyStates() throws {
        let sampleSourceURL = projectRootURL().appendingPathComponent("ScratchLab/Audio/SampleManager.swift")
        let trackSourceURL = projectRootURL().appendingPathComponent("ScratchLab/Audio/BackingTrackManager.swift")

        let sampleSource = try String(contentsOf: sampleSourceURL, encoding: .utf8)
        let trackSource = try String(contentsOf: trackSourceURL, encoding: .utf8)

        XCTAssertTrue(sampleSource.contains("Bundled scratch samples are unavailable on this build."))
        XCTAssertTrue(trackSource.contains("Bundled backing tracks are unavailable on this build."))
    }

    @MainActor
    func testPerformerMonitorBroadcasterProvidesManualConnectionAddress() {
        let broadcaster = PerformerMonitorBroadcaster(startImmediately: false)

        XCTAssertEqual(broadcaster.connectionStatus, "Searching for Performer Monitor on a nearby device")
        XCTAssertTrue(broadcaster.manualConnectAddress.hasSuffix(":58585"))
        XCTAssertFalse(broadcaster.manualConnectAddress.isEmpty)
    }

    func testScratchLabDesktopSourceKeepsWindowReopenCommands() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/ScratchLabDesktopApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("Window(\"ScratchLab\", id: ScratchLabDesktopWindowID.mainWindow)"))
        XCTAssertTrue(source.contains("Button(\"Show ScratchLab\")"))
        XCTAssertTrue(source.contains("Button(\"Show Performer Monitor\")"))
    }

    func testScratchLabDesktopRootInjectsPracticeBeatStore() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/ScratchLabDesktopApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("@StateObject private var practiceBeatStore = PracticeBeatStore()"))
        XCTAssertTrue(source.contains(".environmentObject(practiceBeatStore)"))
    }

    func testMacRoutineSidebarUsesSharedSessionPresentationModel() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/Views/MacAnalyzerView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("routineSessionStore.sessionListPresentation"))
        XCTAssertTrue(source.contains("Text(\"Active Session\")"))
        XCTAssertTrue(source.contains("Text(\"Recent Sessions\")"))
        XCTAssertTrue(source.contains("Dis" + "closureGroup(\"All Sessions\""))
        XCTAssertFalse(source.contains("ForEach(routineSessionStore.sessions)"))
    }

    func testGuidedCaptureSetupUsesSharedSessionPresentationModel() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLab/Views/CompanionCameraView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("captureStore.sessionListPresentation"))
        XCTAssertTrue(source.contains("Text(\"Current Session\")"))
        XCTAssertTrue(source.contains("Text(\"Recent Sessions\")"))
        XCTAssertTrue(source.contains("Dis" + "closureGroup(\"All Sessions\""))
        XCTAssertTrue(source.contains("Text(\"New Session\")"))
        XCTAssertFalse(source.contains("Text(\"Reuse Last Setup\")"))
    }

    func testGuidedCaptureSourceUsesToolbarSafeNavigationChrome() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLab/Views/CompanionCameraView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains(".toolbar(.visible, for: .navigationBar)"))
        XCTAssertTrue(source.contains("ToolbarItem(placement: .topBarLeading)"))
    }

    func testGuidedCaptureSystemCheckScrollsOnSmallScreens() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLab/Views/CompanionCameraView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let systemCheckSource = try XCTUnwrap(
            source.components(separatedBy: "private struct SystemCheckView: View").last
        )

        XCTAssertTrue(systemCheckSource.contains("ScrollView(showsIndicators: false)"))
        XCTAssertTrue(systemCheckSource.contains("Text(\"Open Record Controls\")"))
    }

    func testPracticeFlowDoesNotCreateCaptureSessions() throws {
        let practiceSourceURL = projectRootURL().appendingPathComponent("ScratchLab/Views/PracticeModeView.swift")
        let practiceSource = try String(contentsOf: practiceSourceURL, encoding: .utf8)
        let levelSourceURL = projectRootURL().appendingPathComponent("ScratchLab/Views/LevelSelectView.swift")
        let levelSource = try String(contentsOf: levelSourceURL, encoding: .utf8)

        XCTAssertFalse(practiceSource.contains("GuidedCaptureStore("))
        XCTAssertFalse(practiceSource.contains("SessionSetupViewModel("))
        XCTAssertFalse(practiceSource.contains("refreshSessionIdentity("))
        XCTAssertTrue(practiceSource.contains("ScratchCoachInstructionStore.shared.instruction("))
        XCTAssertTrue(practiceSource.contains("for: normalizeScratchType(input: activeScratch.id)"))
        XCTAssertTrue(practiceSource.contains("scratchDisplayName: activeScratch.name"))
        XCTAssertTrue(practiceSource.contains("ScratchCoachCard("))
        XCTAssertTrue(practiceSource.contains("instruction: coachInstruction"))
        XCTAssertTrue(levelSource.contains("PracticeModeView("))
    }

    func testPracticeModeSourceKeepsSelectedScratchInsteadOfForcingBabyFallback() throws {
        let practiceSourceURL = projectRootURL().appendingPathComponent("ScratchLab/Views/PracticeModeView.swift")
        let source = try String(contentsOf: practiceSourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("private var mvpScratch"))
        XCTAssertFalse(source.contains("scratch.id == \"baby_scratch\" ? scratch : mvpScratch"))
        XCTAssertTrue(source.contains("private var activeScratch: Scratch {"))
    }

    func testLevelSelectSourceRequiresExplicitScratchSelectionBeforeLaunchingPractice() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLab/Views/LevelSelectView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("@State private var selectedPracticeScratch: Scratch?"))
        XCTAssertTrue(source.contains("private var practiceScratchOptions: [Scratch]"))
        XCTAssertTrue(source.contains("Chirp Flare"))
        XCTAssertTrue(source.contains(".fullScreenCover(item: $selectedPracticeScratch)"))
        XCTAssertFalse(source.contains("Start Live Baby Practice"))
    }

    func testPracticeModeSourceExposesVisibleBeatControlsInSetupOverlay() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLab/Views/PracticeModeView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("ScrollView(showsIndicators: true)"))
        XCTAssertTrue(source.contains("PracticeBeatControlsCard(practiceBeatStore: practiceBeatStore)"))
        XCTAssertTrue(source.contains("PracticeBeatUIContract.noBeatLabel"))
        XCTAssertTrue(source.contains("PracticeBeatUIContract.beatOnLabel"))
        XCTAssertTrue(source.contains("PracticeBeatUIContract.playLabel"))
        XCTAssertTrue(source.contains("LazyVGrid(columns: Self.beatModeColumns"))
        XCTAssertTrue(source.contains("practiceBeatStore.selectBeatMode(mode)"))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(\"practice-beat-mode-\\(mode.rawValue)\")"))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(PracticeBeatUIContract.sectionAccessibilityID)"))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(\"practice-beat-on-button\")"))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(\"practice-beat-playback-button\")"))
    }

    func testPracticeModeSourceExposesCoachCardInScrollableSetupOverlay() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLab/Views/PracticeModeView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let beatControlsRange = try XCTUnwrap(source.range(of: "PracticeBeatControlsCard(practiceBeatStore: practiceBeatStore)"))
        let audioInputRange = try XCTUnwrap(source.range(of: "Text(\"AUDIO INPUT\")"))
        let coachCardRange = try XCTUnwrap(source.range(of: "ScratchCoachCard("))

        XCTAssertTrue(source.contains("ScrollView(showsIndicators: true)"))
        XCTAssertTrue(source.contains("ScratchCoachCardContent("))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(\"scratchlab-coach-card\")"))
        XCTAssertLessThan(beatControlsRange.lowerBound, coachCardRange.lowerBound)
        XCTAssertLessThan(coachCardRange.lowerBound, audioInputRange.lowerBound)
    }

    func testPracticeModeSourceUsesSafeAreaAwareCoachSetupLayout() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLab/Views/PracticeModeView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("GeometryReader { geometry in"))
        XCTAssertTrue(source.contains("topBar(topSafeAreaInset: geometry.safeAreaInsets.top)"))
        XCTAssertTrue(source.contains("topSafeAreaInset: geometry.safeAreaInsets.top"))
        XCTAssertTrue(source.contains("bottomSafeAreaInset: geometry.safeAreaInsets.bottom"))
        XCTAssertTrue(source.contains(".padding(.top, topSafeAreaInset + 12)"))
        XCTAssertTrue(source.contains(".padding(.bottom, max(bottomSafeAreaInset, 16) + 20)"))
    }

    func testPracticeModeSourceDoesNotExposePlaceholderTutorialEntryPoints() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLab/Views/PracticeModeView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let forbiddenFragments = [
            "Watch Tutorial First",
            "Watch Tutorial",
            "Tutorial Video",
            "showingTutorial",
            "TutorialOverlayView",
            "tutorialVideoName",
            "play.circle.fill",
        ]

        for fragment in forbiddenFragments {
            XCTAssertFalse(source.contains(fragment), "PracticeModeView.swift exposes \(fragment)")
        }
        XCTAssertTrue(source.contains("SessionSetupOverlay("))
        XCTAssertTrue(source.contains("ScratchCoachCard("))
        XCTAssertTrue(source.contains("onStart: { startSession() }"))
    }

    func testScratchDefinitionsDoNotExposeTutorialVideoAssetReferencesInRelease() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLab/Models/Scratch.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("tutorialVideoName"))
        XCTAssertFalse(source.contains("TutorialOverlayView"))
        XCTAssertFalse(source.localizedCaseInsensitiveContains("tutorial video"))
        XCTAssertEqual(ScratchLibrary.shared.allScratches.count, 20)
        XCTAssertNotNil(ScratchLibrary.shared.scratch(byID: "baby_scratch"))
    }

    func testPracticeModeSourceKeepsLaunchFlowWithoutTutorialAssets() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLab/Views/PracticeModeView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("SessionSetupOverlay("))
        XCTAssertTrue(source.contains("ScratchCoachCard("))
        XCTAssertTrue(source.contains("onStart: { startSession() }"))
        XCTAssertTrue(source.contains("private func startSession()"))
        XCTAssertFalse(source.contains("Bundle.main.url(forResource: activeScratch.tutorialVideoName"))
        XCTAssertFalse(source.contains("tutorialVideoName"))
    }

    func testPythonBytecodeCachesAreIgnoredAndUntracked() throws {
        let gitignoreURL = projectRootURL().appendingPathComponent(".gitignore")
        let gitignore = try String(contentsOf: gitignoreURL, encoding: .utf8)

        XCTAssertTrue(gitignore.contains("__pycache__/"))
        XCTAssertTrue(gitignore.contains("*.pyc"))

        let indexURL = projectRootURL().appendingPathComponent(".git/index")
        let indexData = try Data(contentsOf: indexURL)

        XCTAssertNil(indexData.range(of: Data("scripts/__pycache__".utf8)))
        XCTAssertNil(indexData.range(of: Data(".pyc".utf8)))
    }

    func testLevelSelectSourceUsesSafeAreaAwareScrollableHeaderLayout() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLab/Views/LevelSelectView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("GeometryReader { geometry in"))
        XCTAssertTrue(source.contains("ScrollView(showsIndicators: false)"))
        XCTAssertTrue(source.contains(".padding(.top, geometry.safeAreaInsets.top + 12)"))
        XCTAssertTrue(source.contains(".padding(.bottom, max(geometry.safeAreaInsets.bottom, 20) + 20)"))
        XCTAssertFalse(source.contains("headerView\n                    .padding(.top, 20)"))
    }

    func testMainMenuSourceUsesSafeAreaAwareHeaderLayout() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLab/Views/MainMenuView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("GeometryReader { geometry in"))
        XCTAssertTrue(source.contains("ScrollView(showsIndicators: false)"))
        XCTAssertTrue(source.contains(".padding(.top, geometry.safeAreaInsets.top + 12)"))
        XCTAssertTrue(source.contains(".padding(.bottom, max(geometry.safeAreaInsets.bottom, 16) + 28)"))
        XCTAssertFalse(source.contains(".padding(.top, 16)"))
    }

    func testScratchLabIOSSchemeUsesForegroundLaunchWithoutLocationSimulation() throws {
        let schemeURL = projectRootURL().appendingPathComponent("ScratchLab.xcodeproj/xcshareddata/xcschemes/ScratchLab.xcscheme")
        let scheme = try String(contentsOf: schemeURL, encoding: .utf8)

        XCTAssertTrue(scheme.contains("<LaunchAction"))
        XCTAssertTrue(scheme.contains("launchStyle = \"0\""))
        XCTAssertTrue(scheme.contains("BuildableName = \"ScratchLab.app\""))
        XCTAssertFalse(scheme.contains("allowLocationSimulation = \"YES\""))
        XCTAssertFalse(scheme.contains("<LocationScenarioReference"))
        XCTAssertFalse(scheme.contains("waitForExecutable = \"YES\""))
    }

    func testMainMenuSourceExposesDebugCoachPreviewEntryPoint() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLab/Views/MainMenuView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("@State private var showingCoachPreview = false"))
        XCTAssertTrue(source.contains("#if DEBUG && canImport(RealityKit)"))
        XCTAssertTrue(source.contains(".sheet(isPresented: $showingCoachPreview)"))
        XCTAssertTrue(source.contains("CoachPreviewView()"))
        XCTAssertTrue(source.contains("title: \"3D Coach Demo\""))
        XCTAssertTrue(source.contains("subtitle: \"Preview the coach model reacting to your input\""))
        XCTAssertTrue(source.contains("action: { showingCoachPreview = true }"))
        XCTAssertFalse(source.contains("Debug only"))
    }

    func testPracticeModeSourceExposesDebugCoachPreviewEntryPoint() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLab/Views/PracticeModeView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("@State private var showingCoachPreview = false"))
        XCTAssertTrue(source.contains("#if DEBUG && canImport(RealityKit)"))
        XCTAssertTrue(source.contains(".sheet(isPresented: $showingCoachPreview)"))
        XCTAssertTrue(source.contains("CoachPreviewView()"))
        XCTAssertTrue(source.contains("onShowCoachPreview: { showingCoachPreview = true }"))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(\"practice-coach-preview-button\")"))
        XCTAssertTrue(source.contains("Text(\"Open 3D Coach Demo\")"))
        XCTAssertTrue(source.contains("Text(\"Try the 3D coach in Demo mode\")"))
        XCTAssertFalse(source.contains("Debug only"))
    }

    func testPracticeModeSourceExposesBabyScratchAudioMotionFeedback() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLab/Views/PracticeModeView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("private var showsBabyScratchMotionFeedback: Bool"))
        XCTAssertTrue(source.contains("activeScratch.id == \"baby_scratch\""))
        XCTAssertTrue(source.contains("audioEngine.scratchMotionFeedback"))
        XCTAssertTrue(source.contains("Text(\"AUDIO MOTION\")"))
        XCTAssertTrue(source.contains("audioMotionChip(title: \"Direction\", value: audioEngine.scratchMotionDirection.label)"))
        XCTAssertTrue(source.contains("audioMotionChip(title: \"Forward\", value: scratchMotionForwardDurationText)"))
        XCTAssertTrue(source.contains("audioMotionChip(title: \"Back\", value: scratchMotionBackwardDurationText)"))
        XCTAssertTrue(source.contains("audioMotionChip(title: \"Error\", value: scratchMotionTimingErrorText)"))
        XCTAssertTrue(source.contains("private func formatScratchMotionDuration(_ duration: TimeInterval?) -> String"))
    }

    func testCoachPreviewSourceLoadsBundledCoachUSDZWithRealityKitDiagnosticsAndARViewFraming() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLab/Views/CoachPreviewView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("import RealityKit"))
        XCTAssertTrue(source.contains("struct CoachPreviewView: View"))
        XCTAssertTrue(source.contains("@EnvironmentObject private var audioEngine: AudioEngine"))
        XCTAssertTrue(source.contains("static let entityName = \"Coach\""))
        XCTAssertTrue(source.contains("static let resourceExtension = \"usdz\""))
        XCTAssertTrue(source.contains("try await Entity("))
        XCTAssertTrue(source.contains("contentsOf: bundleURL"))
        XCTAssertTrue(source.contains("withName: CoachPreviewConstants.resourceName"))
        XCTAssertTrue(source.contains("try await Entity(named: CoachPreviewConstants.entityName, in: Bundle.main)"))
        XCTAssertTrue(source.contains("let initialBounds = coachEntity.visualBounds(relativeTo: nil)"))
        XCTAssertTrue(source.contains("let framedBounds = applyPreviewFraming("))
        XCTAssertTrue(source.contains("animationController = coachEntity.playAnimation("))
        XCTAssertTrue(source.contains("firstAnimation.repeat(),"))
        XCTAssertTrue(source.contains("ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)"))
        XCTAssertTrue(source.contains("DispatchQueue.main.async { [weak arView] in"))
        XCTAssertTrue(source.contains("arView.debugOptions = []"))
        XCTAssertTrue(source.contains("arView.debugOptions.remove(.showStatistics)"))
        XCTAssertTrue(source.contains("arView.__statisticsOptions = []"))
        XCTAssertTrue(source.contains("arView.__disableStatisticsRendering = true"))
        XCTAssertTrue(source.contains("NSSelectorFromString(\"setShowStatistics:\")"))
        XCTAssertTrue(source.contains("(arView as NSObject).setValue(false, forKey: \"showStatistics\")"))
        XCTAssertTrue(source.contains("AnchorEntity(world: .zero)"))
        XCTAssertTrue(source.contains("Bundle.main.url("))
        XCTAssertTrue(source.contains("print(\"[CoachPreview] rootEntity.name="))
        XCTAssertTrue(source.contains("print(\"[CoachPreview] namedEntity.loadSucceeded=false error="))
        XCTAssertTrue(source.contains("print(\"[CoachPreview] namedEntity.fallback=rootEntity\")"))
        XCTAssertTrue(source.contains("print(\"[CoachPreview] finalScale="))
        XCTAssertTrue(source.contains("print(\"[CoachPreview] finalTranslation="))
        XCTAssertTrue(source.contains("print(\"[CoachPreview] loadSucceeded=true\")"))
        XCTAssertTrue(source.contains("print(\"[CoachPreview] availableAnimations.count=\\(animationCount)\")"))
        XCTAssertTrue(source.contains("private var previewBadge: some View"))
        XCTAssertTrue(source.contains("Text(status.summaryLine)"))
        XCTAssertTrue(source.contains(".overlay(alignment: .topLeading)"))
        XCTAssertTrue(source.contains(".frame(height: 400)"))
        XCTAssertTrue(source.contains("private var audioMotionCard: some View"))
        XCTAssertTrue(source.contains("Text(\"Audio Motion\")"))
        XCTAssertTrue(source.contains("audioEngine.scratchMotionFeedback"))
        XCTAssertTrue(source.contains("audioEngine.selectInputSource(source)"))
        XCTAssertTrue(source.contains("prepareAudioMonitoringIfNeeded()"))
        XCTAssertTrue(source.contains("teardownAudioMonitoringIfNeeded()"))
        XCTAssertTrue(source.contains("@State private var inputSourceBeforePreview: AudioInputSource?"))
        XCTAssertTrue(source.contains("inputSourceBeforePreview = audioEngine.currentInputSource"))
        XCTAssertTrue(source.contains("audioEngine.selectInputSource(inputSourceBeforePreview)"))
        XCTAssertFalse(source.contains("Debug-only"))
        XCTAssertFalse(source.contains("RealityView { content in"))
        XCTAssertFalse(source.contains("showStatistics = true"))
        XCTAssertFalse(source.contains("ARView.appearance"))
        XCTAssertFalse(source.contains("import SceneKit"))
    }

    func testCoachPreviewSourceExposesInteractiveScratchTrainerPrototypeControls() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLab/Views/CoachPreviewView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("enum CoachMotionMode: String, CaseIterable, Identifiable"))
        XCTAssertTrue(source.contains("case idleLoop = \"Idle Loop\""))
        XCTAssertTrue(source.contains("case forwardScratch = \"Forward Scratch\""))
        XCTAssertTrue(source.contains("case backScratch = \"Back Scratch\""))
        XCTAssertTrue(source.contains("case babyScratchDemo = \"Baby Scratch Demo\""))
        XCTAssertTrue(source.contains("@State private var motionMode: CoachMotionMode = .idleLoop"))
        XCTAssertTrue(source.contains("@State private var scratchValue = 0.0"))
        XCTAssertTrue(source.contains("@State private var scratchVelocityApprox = 0.0"))
        XCTAssertTrue(source.contains("Text(\"Motion\")"))
        XCTAssertTrue(source.contains("Text(\"Scratch Pad\")"))
        XCTAssertTrue(source.contains("Text(formattedScratchValue(scratchValue))"))
        XCTAssertTrue(source.contains("@State private var motionDemoTask: Task<Void, Never>?"))
        XCTAssertTrue(source.contains("@State private var scratchReleaseTask: Task<Void, Never>?"))
        XCTAssertTrue(source.contains("@State private var startedAudioEngineForPreview = false"))
        XCTAssertTrue(source.contains("private func applyMotionMode(_ mode: CoachMotionMode)"))
        XCTAssertTrue(source.contains("applyMotionMode(mode)"))
        XCTAssertTrue(source.contains("DragGesture(minimumDistance: 0)"))
        XCTAssertTrue(source.contains("if motionDemoTask != nil {"))
        XCTAssertTrue(source.contains("cancelActiveMotionDemo()"))
        XCTAssertTrue(source.contains("if scratchReleaseTask != nil {"))
        XCTAssertTrue(source.contains("cancelScratchReleaseMotion()"))
        XCTAssertTrue(source.contains("rotationEffect(.degrees(platterRotationDegrees))"))
        XCTAssertTrue(source.contains("case .idleLoop:"))
        XCTAssertTrue(source.contains("resetTrainerToNeutral()"))
        XCTAssertTrue(source.contains("print(\"[CoachTrainerMode] Forward Scratch\")"))
        XCTAssertTrue(source.contains("print(\"[CoachTrainerMode] Back Scratch\")"))
        XCTAssertTrue(source.contains("print(\"[CoachTrainerMode] Baby Scratch Demo started\")"))
        XCTAssertTrue(source.contains("print(\"[CoachTrainerMode] Baby Scratch Demo completed\")"))
        XCTAssertTrue(source.contains("private func beginScratchRelease() -> Int"))
        XCTAssertTrue(source.contains("private func runScratchRelease("))
        XCTAssertTrue(source.contains("private func settleScratchToNeutral("))
        XCTAssertTrue(source.contains("private func animateScratchValue("))
        XCTAssertTrue(source.contains("private func easeInOutCubic(_ progress: Double) -> Double"))
        XCTAssertTrue(source.contains("static let motionDemoForwardMilliseconds: UInt64 = 520"))
        XCTAssertTrue(source.contains("static let motionDemoBackMilliseconds: UInt64 = 520"))
        XCTAssertTrue(source.contains("static let motionDemoCenterPauseMilliseconds: UInt64 = 120"))
        XCTAssertTrue(source.contains("static let motionDemoReturnMilliseconds: UInt64 = 440"))
        XCTAssertTrue(source.contains("static let motionPulseTravelMilliseconds: UInt64 = 220"))
        XCTAssertTrue(source.contains("static let motionPulseHoldMilliseconds: UInt64 = 90"))
        XCTAssertTrue(source.contains("velocity *= exp(-CoachPreviewConstants.releaseDecelerationPerSecond * timeStep)"))
        XCTAssertTrue(source.contains("let acceleration = (-CoachPreviewConstants.releaseSpringStiffness * position)"))
        XCTAssertTrue(source.contains("print(\"[CoachTrainer] scratchValue="))
        XCTAssertTrue(source.contains("print(\"[CoachTrainer] direction="))
        XCTAssertTrue(source.contains("print(\"[CoachTrainer] velocityApprox="))
        XCTAssertTrue(source.contains("let scratchValue: Double"))
        XCTAssertTrue(source.contains("let scratchVelocityApprox: Double"))
        XCTAssertTrue(source.contains("var platterEntity: Entity?"))
        XCTAssertTrue(source.contains("func applyPlatterState(scratchValue: Double, scratchVelocityApprox: Double)"))
        XCTAssertTrue(source.contains("makeTrainerPlatter("))
        XCTAssertTrue(source.contains("around: loadedCoach.visualBounds"))
        XCTAssertTrue(source.contains("viewportSize: viewportSize"))
        XCTAssertTrue(source.contains("mesh: .generateCylinder("))
        XCTAssertTrue(source.contains("platterEntity.name = \"CoachTrainerPlatter\""))
        XCTAssertTrue(source.contains("context.coordinator.applyPlatterState("))
        XCTAssertTrue(source.contains("print(\"[CoachTrainer3D] platterRotation="))
        XCTAssertTrue(source.contains("print(\"[CoachTrainer3D] scratchValue="))
        XCTAssertTrue(source.contains("static let platterRadius: Float = 0.28"))
        XCTAssertTrue(source.contains("static let platterTargetScreenWidthRatio: Float = 0.35"))
        XCTAssertTrue(source.contains("let waistHeight = coachBounds.min.y + (coachBounds.extents.y * CoachPreviewConstants.platterWaistHeightRatio)"))
        XCTAssertTrue(source.contains("let targetDistance = platterDistanceFromCamera(for: viewportSize)"))
        XCTAssertTrue(source.contains("let accentSurfaceMaterial = UnlitMaterial("))
        XCTAssertTrue(source.contains("print(\"[CoachPreview] platter.diameter="))
        XCTAssertTrue(source.contains("trainerBadge(title: \"Timing Error\", value: audioTimingErrorText)"))
        XCTAssertTrue(source.contains("private func formattedDuration(_ duration: TimeInterval?) -> String"))
        XCTAssertTrue(source.contains("case .pausedForScratch"))
        XCTAssertTrue(source.contains("animationController.pause()"))
        XCTAssertTrue(source.contains("animationController.resume()"))
        XCTAssertFalse(source.contains("Text(\"Coach model test\")"))
        XCTAssertFalse(source.contains("Debug only"))
        XCTAssertFalse(source.contains("Text(\"Coach Trainer Prototype\")"))
        XCTAssertFalse(source.contains("Text(\"PROTOTYPE NOTES\")"))
        XCTAssertFalse(source.contains("Text(\"Preview the bundled coach model, keep its default loop alive, and sketch scratch motion before real rig controls are wired in.\")"))
    }

    func testProjectBundlesCoachUSDZForPreviewTargets() throws {
        let projectURL = projectRootURL().appendingPathComponent("ScratchLab.xcodeproj/project.pbxproj")
        let project = try String(contentsOf: projectURL, encoding: .utf8)

        XCTAssertTrue(project.contains("Coach.usdz in Resources"))
        XCTAssertTrue(project.contains("Coach.usdz */ = {isa = PBXFileReference;"))
        XCTAssertTrue(project.contains("path = Resources/Coach/Coach.usdz;"))
        XCTAssertTrue(project.contains("CoachPreviewView.swift in Sources"))
        XCTAssertTrue(project.contains("CoachPreviewView.swift */ = {isa = PBXFileReference;"))
    }

    func testHostedDesktopBundleContainsCoachUSDZAsset() throws {
        let assetURL = try XCTUnwrap(Bundle.main.url(forResource: "Coach", withExtension: "usdz"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: assetURL.path))
    }

    func testPracticeModeCoachDemoSourceStopsWhenPracticeBeatStarts() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLab/Views/PracticeModeView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("title: \"Listen\""))
        XCTAssertTrue(source.contains("title: \"Pause\""))
        XCTAssertTrue(source.contains("title: \"Replay\""))
        XCTAssertTrue(source.contains("\"Demo audio unavailable for this scratch.\""))
        XCTAssertTrue(source.contains("ScratchCoachCardContent("))
        XCTAssertTrue(source.contains("demoPlayer.currentPlaybackTime"))
        XCTAssertTrue(source.contains(".onChange(of: practiceBeatStore.isPlaying)"))
        XCTAssertTrue(source.contains("demoPlayer.stop()"))
    }

    func testMacPracticeSourceExposesVisibleBeatControls() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/Views/MacAnalyzerView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("@EnvironmentObject private var practiceBeatStore: PracticeBeatStore"))
        XCTAssertTrue(source.contains("practiceBeatStore.configurePracticeContext(scratchID: CaptureSessionScratchType.babyScratch.rawValue)"))
        XCTAssertTrue(source.contains("Text(\"Practice beat\")"))
        XCTAssertTrue(source.contains("practiceBeatStore.setBeatEnabled(false)"))
        XCTAssertTrue(source.contains("practiceBeatStore.setBeatEnabled(true)"))
        XCTAssertTrue(source.contains("LazyVGrid(columns: Self.practiceBeatModeColumns"))
        XCTAssertTrue(source.contains("practiceBeatStore.selectBeatMode(mode)"))
        XCTAssertTrue(source.contains("practiceBeatStore.stepBPM(by: -1)"))
        XCTAssertTrue(source.contains("practiceBeatStore.stepBPM(by: 1)"))
        XCTAssertTrue(source.contains("practiceBeatStore.togglePlayback()"))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(\"practice-beat-on-button\")"))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(\"practice-beat-playback-button\")"))
        XCTAssertTrue(source.contains("practiceBeatStore.handleLeavingPractice()"))
        XCTAssertTrue(source.contains("practiceBeatStore.handleAppDidBecomeInactive()"))
        XCTAssertTrue(source.contains("practiceBeatStore.handleRecordingFlowStarted()"))
    }

    func testMacAnalyzerSourceExposesCoachPanel() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/Views/MacAnalyzerView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("ScratchCoachInstructionStore.shared.instruction("))
        XCTAssertTrue(source.contains("coachScratchTypeID.map { normalizeScratchType(input: $0) }"))
        XCTAssertTrue(source.contains("ScratchCoachCardContent("))
        XCTAssertTrue(source.contains("theme: coachCardTheme"))
        XCTAssertTrue(source.contains("Text(\"Audio Input\")"))
        XCTAssertFalse(source.contains("Text(\"Test Audio\")"))
    }

    func testMacCoachDemoSourceStopsWhenPracticeBeatOrRoutineCaptureStarts() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/Views/MacAnalyzerView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("coachDemoPlayer.configure(with: coachInstruction)"))
        XCTAssertTrue(source.contains("coachDemoPlayer.stop()"))
        XCTAssertTrue(source.contains("\"Demo audio unavailable for this scratch.\""))
        XCTAssertTrue(source.contains("ScratchCoachCardContent("))
        XCTAssertTrue(source.contains("coachDemoPlayer.currentPlaybackTime"))
        XCTAssertTrue(source.contains(".onChange(of: coachDemoPlaybackBlocked)"))
        XCTAssertTrue(source.contains("practiceBeatStore.isPlaying || captureEngine.isRoutineRecording"))
        XCTAssertFalse(source.contains("isolatedScratch"))
    }

    func testScratchCoachSharedViewsExistAndUseAnimator() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLab/Views/ScratchCoachViews.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("struct ScratchCoachRigView: View"))
        XCTAssertTrue(source.contains("struct ScratchCoachCardContent<Controls: View>: View"))
        XCTAssertTrue(source.contains("ScratchCoachDemoAnimator.state("))
        XCTAssertTrue(source.contains("@State private var showsDetails = false"))
        XCTAssertTrue(source.contains("Dis" + "closureGroup(isExpanded: $showsDetails)"))
        XCTAssertTrue(source.contains("instruction.coachScript"))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(\"scratchlab-coach-rig\")"))
        XCTAssertFalse(source.contains("struct ScratchCoachCharacterView: View"))
    }

    func testScratchCoachSharedViewsUseScratchSpecificFaderCueCopy() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLab/Views/ScratchCoachViews.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("return \"Fader stays open.\""))
        XCTAssertTrue(source.contains("return \"Quick fader click.\""))
        XCTAssertFalse(source.contains("case \"baby\":\n            return \"Close between cuts.\""))
    }

    func testScratchCoachSharedViewsAreBuiltForIOSAndMacTargets() throws {
        let projectURL = projectRootURL().appendingPathComponent("ScratchLab.xcodeproj/project.pbxproj")
        let project = try String(contentsOf: projectURL, encoding: .utf8)

        XCTAssertTrue(project.contains("ScratchCoachViews.swift"))
        XCTAssertTrue(project.contains("A1000030 /* ScratchCoachViews.swift in Sources */"))
        XCTAssertTrue(project.contains("B5AA0008A1B2C3D4E5F60709 /* ScratchCoachViews.swift in Sources */"))
    }

    func testCoachInstructionsResourceFolderIsBundledForIOSAndMacTargets() throws {
        let projectURL = projectRootURL().appendingPathComponent("ScratchLab.xcodeproj/project.pbxproj")
        let project = try String(contentsOf: projectURL, encoding: .utf8)

        XCTAssertTrue(project.contains("CoachInstructions"))
        XCTAssertTrue(project.contains("CoachInstructions in Resources"))
        XCTAssertTrue(project.contains("B9AF9ED5370241CF8BEFDB7C /* Resources/CoachInstructions in Resources */"))
        XCTAssertTrue(project.contains("219D8D60A93840FC9A724C11 /* Resources/CoachInstructions in Resources */"))
        XCTAssertTrue(project.contains("CoachDemoAudio"))
        XCTAssertTrue(project.contains("CoachDemoAudio in Resources"))
        XCTAssertTrue(project.contains("09C738A56A342FC5A7BBBEA3 /* Resources */"))
        XCTAssertTrue(project.contains("A6000003 /* Resources */"))
    }

    func testCoachInstructionResourcesContainNoProvenanceMetadataAndDecode() throws {
        let resourceFolder = projectRootURL().appendingPathComponent("ScratchLab/Resources/CoachInstructions")
        let fileNames = Set(try FileManager.default.contentsOfDirectory(atPath: resourceFolder.path))
        let expectedFileNames: Set<String> = [
            "baby.json",
            "chirpflare.json",
        ]
        let forbiddenFragments = [
            "sourceReference",
            "rightsStatus",
            "reviewStatus",
            "sourceRoot",
            "sourceMKV",
            "makemkv",
            "MakeMKV",
            "qbert",
            "QBERT",
            "Qbert",
            "cxl",
            "CXL",
        ]

        XCTAssertTrue(expectedFileNames.isSubset(of: fileNames))

        for fileName in expectedFileNames {
            let fileURL = resourceFolder.appendingPathComponent(fileName)
            let data = try Data(contentsOf: fileURL)
            let content = try XCTUnwrap(String(data: data, encoding: .utf8))
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            let instruction = try JSONDecoder().decode(ScratchCoachInstruction.self, from: data)

            XCTAssertFalse(instruction.scratchType.isEmpty)
            XCTAssertFalse(instruction.scratchDisplayName.isEmpty)
            XCTAssertFalse(instruction.instructionSummary.isEmpty)
            XCTAssertFalse(instruction.coachScript.isEmpty)
            XCTAssertFalse(instruction.steps.isEmpty)
            XCTAssertFalse(instruction.demoAudioFile?.isEmpty ?? true)

            for fragment in forbiddenFragments {
                XCTAssertFalse(
                    content.localizedCaseInsensitiveContains(fragment),
                    "\(fileName) contains \(fragment)"
                )
                XCTAssertFalse(
                    payload.keys.contains { $0.localizedCaseInsensitiveCompare(fragment) == .orderedSame },
                    "\(fileName) contains key \(fragment)"
                )
            }
        }
    }

    func testHostedDesktopBundleContainsCoachInstructionResources() throws {
        for resourceName in ["baby", "chirpflare"] {
            let fileURL = try XCTUnwrap(
                Bundle.main.url(
                    forResource: resourceName,
                    withExtension: "json",
                    subdirectory: "CoachInstructions"
                )
            )
            let data = try Data(contentsOf: fileURL)
            _ = try JSONDecoder().decode(ScratchCoachInstruction.self, from: data)
        }
    }

    func testCoachDemoAudioResourceFolderShipsOnlyRuntimeWavs() throws {
        let resourceFolder = projectRootURL().appendingPathComponent("ScratchLab/Resources/CoachDemoAudio")
        let fileNames = Set(try FileManager.default.contentsOfDirectory(atPath: resourceFolder.path))
        let expectedFileNames: Set<String> = [
            "baby_noBeat.wav",
            "chirpflare_noBeat.wav",
        ]

        XCTAssertEqual(fileNames, expectedFileNames)
        XCTAssertFalse(fileNames.contains("README.md"))
        XCTAssertFalse(fileNames.contains("coach_demo_manifest.json"))
        XCTAssertFalse(fileNames.contains { $0.hasSuffix(".json") })
    }

    func testShippingProjectAndTextResourcesDoNotContainUnsafeCoachDemoMetadata() throws {
        let projectURL = projectRootURL().appendingPathComponent("ScratchLab.xcodeproj/project.pbxproj")
        let project = try String(contentsOf: projectURL, encoding: .utf8)
        let forbiddenFragments = [
            "qb" + "ert",
            "make" + "mkv",
            "source" + "Root",
            "source" + "MKV",
            "output" + "Root",
            "source" + "Collection",
            "/" + "Users/",
            "/" + "Volumes/",
            "." + "mkv",
            "D" + "VD",
            "D" + "ISC",
        ]

        XCTAssertFalse(project.contains("coach_demo_manifest.json"))
        XCTAssertFalse(project.contains("README.md in Resources/CoachDemoAudio"))
        for fragment in forbiddenFragments {
            XCTAssertFalse(project.localizedCaseInsensitiveContains(fragment), fragment)
        }

        let resourcesURL = projectRootURL().appendingPathComponent("ScratchLab/Resources")
        let resourceEnumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: resourcesURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        )
        let checkedExtensions = Set(["json", "md", "txt"])

        for case let fileURL as URL in resourceEnumerator {
            let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard resourceValues.isRegularFile == true,
                  checkedExtensions.contains(fileURL.pathExtension.lowercased())
            else {
                continue
            }

            let content = try String(contentsOf: fileURL, encoding: .utf8)
            for fragment in forbiddenFragments {
                XCTAssertFalse(
                    content.localizedCaseInsensitiveContains(fragment),
                    "\(fileURL.path) contains \(fragment)"
                )
            }
        }
    }

    func testCoachDemoAudioFilesExistAndCanBeRead() throws {
        let coachDemoAudioFolder = projectRootURL().appendingPathComponent("ScratchLab/Resources/CoachDemoAudio")
        let babyURL = coachDemoAudioFolder.appendingPathComponent("baby_noBeat.wav")
        let chirpflareURL = coachDemoAudioFolder.appendingPathComponent("chirpflare_noBeat.wav")

        for fileURL in [babyURL, chirpflareURL] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

            let audioFile = try AVAudioFile(forReading: fileURL)
            XCTAssertGreaterThan(audioFile.length, 0)
            XCTAssertGreaterThan(audioFile.processingFormat.sampleRate, 0)
            XCTAssertGreaterThan(audioFile.processingFormat.channelCount, 0)
        }
    }

    func testCoachDemoAudioDevelopmentManifestUsesMinimalRuntimeSafeClipMetadata() throws {
        let manifestURL = projectRootURL().appendingPathComponent("scripts/dataset_processor/coach_demo_manifest.dev.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        )
        let clips = try XCTUnwrap(payload["clips"] as? [[String: Any]])

        XCTAssertEqual(clips.count, 2)
        XCTAssertNil(payload["generatedAt"])
        XCTAssertNil(payload["output" + "Root"])
        XCTAssertNil(payload["source" + "Root"])
        XCTAssertNil(payload["source" + "Collection"])

        let clipsByName = Dictionary(
            uniqueKeysWithValues: clips.compactMap { clip -> (String, [String: Any])? in
                guard let name = clip["name"] as? String else { return nil }
                return (name, clip)
            }
        )
        let expectedClips: [(name: String, file: String, demoStart: Double, demoEnd: Double)] = [
            ("baby", "baby_noBeat.wav", 0.0, 12.0),
            ("chirpflare", "chirpflare_noBeat.wav", 0.0, 11.0),
        ]

        for expectedClip in expectedClips {
            let clip = try XCTUnwrap(clipsByName[expectedClip.name])
            XCTAssertEqual(clip["file"] as? String, expectedClip.file)
            XCTAssertEqual(clip["demoStart"] as? Double, expectedClip.demoStart)
            XCTAssertEqual(clip["demoEnd"] as? Double, expectedClip.demoEnd)
            XCTAssertNil(clip["source" + "MKV"])
            XCTAssertNil(clip["audioStreamIndex"])
            XCTAssertNil(clip["source" + "Collection"])

            let audioURL = projectRootURL()
                .appendingPathComponent("ScratchLab/Resources/CoachDemoAudio")
                .appendingPathComponent(expectedClip.file)
            XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        }
    }

    func testMacScreenshotCaptureScriptTargetsRealScratchLabWindow() throws {
        let scriptURL = projectRootURL().appendingPathComponent("scripts/capture_mac_review_window.sh")
        let source = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(source.contains("find_window_id"))
        XCTAssertTrue(source.contains("tell application \"${app_name}\""))
        XCTAssertTrue(source.contains("/usr/sbin/screencapture -o -l \"${window_id}\""))
    }

    func testReviewDemoSeedDataLoadsSelectedSession() throws {
        let scriptURL = projectRootURL().appendingPathComponent("scripts/seed_review_demo_data.sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptURL.path, "--print-store-json"]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, errorOutput)

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let snapshot = try JSONDecoder.captureCoreDecoder.decode(RoutineSessionDraftStoreSnapshot.self, from: outputData)
        let selectedSessionID = try XCTUnwrap(snapshot.selectedSessionID)
        let selectedSession = try XCTUnwrap(snapshot.sessions.first(where: { $0.id == selectedSessionID }))

        XCTAssertEqual(selectedSessionID, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(selectedSession.config.performerName, "Demo DJ")
        XCTAssertEqual(selectedSession.config.scratchType, .babyScratch)
        XCTAssertEqual(selectedSession.config.bpm, 90)
        XCTAssertEqual(selectedSession.config.drillMode, .fullCapture)
        XCTAssertEqual(selectedSession.config.takeCount, 1)
        XCTAssertTrue(selectedSession.config.notes.contains("Baby Scratch Warmup"))
    }

    func testReviewDemoSeedScriptDoesNotDependOnRemovedBundledAudio() throws {
        let scriptURL = projectRootURL().appendingPathComponent("scripts/seed_review_demo_data.sh")
        let source = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertFalse(source.contains("ScratchLab/Resources/boom_bap_100bpm.wav"))
        XCTAssertFalse(source.contains("source_wav"))
        XCTAssertTrue(source.contains("generate_demo_audio()"))
        XCTAssertTrue(source.contains("/usr/bin/python3 -"))
        XCTAssertTrue(source.contains("cannot seed export-ready demo audio"))
    }

    func testLatestCompletedRoutineCapturePrefersSelectedSession() throws {
        let root = try makeTemporaryDirectory()
        let selectedSessionID = "selected-session"
        let otherSessionID = "other-session"
        let selectedRecordingDate = Date(timeIntervalSince1970: 1_720_000_000)
        let otherRecordingDate = Date(timeIntervalSince1970: 1_720_000_100)

        let selectedRecordingURL = try makeLocalRecordingTake(
            in: root,
            sessionID: selectedSessionID,
            takeNumber: 1,
            bpm: 90,
            createdAt: selectedRecordingDate
        )
        let otherRecordingURL = try makeLocalRecordingTake(
            in: root,
            sessionID: otherSessionID,
            takeNumber: 1,
            bpm: 90,
            createdAt: otherRecordingDate
        )

        let selectedSnapshot = try XCTUnwrap(
            MacCaptureEngine.latestCompletedRoutineCapture(
                in: root,
                preferredSessionID: selectedSessionID
            )
        )
        XCTAssertEqual(selectedSnapshot.mediaURL, selectedRecordingURL)
        XCTAssertEqual(selectedSnapshot.sessionID, selectedSessionID)
        XCTAssertEqual(selectedSnapshot.takeID, "take-001")

        let latestSnapshot = try XCTUnwrap(MacCaptureEngine.latestCompletedRoutineCapture(in: root))
        XCTAssertEqual(latestSnapshot.mediaURL, otherRecordingURL)
        XCTAssertEqual(latestSnapshot.sessionID, otherSessionID)
    }

    func testGuidedCaptureReviewStateDoesNotInventWatchMotionWhenMotionIsSkipped() {
        let assessment = GuidedCaptureReviewStateResolver.motionAssessment(
            calibrationValid: true,
            audioPresent: true,
            motionPresent: false,
            motionSkipped: true,
            motionOptional: false
        )

        XCTAssertEqual(assessment.syncStatus, "Motion optional")
        XCTAssertEqual(assessment.motionStatusTitle, "Motion Optional")
        XCTAssertFalse(assessment.motionPresent)
    }

    func testLocalRecordingIdentityIncludesSessionWhenTakeNumbersReset() throws {
        let root = try makeTemporaryDirectory()
        let first = try makeTestSidecar(
            in: root,
            sessionID: "session-one",
            takeNumber: 1
        )
        let second = try makeTestSidecar(
            in: root,
            sessionID: "session-two",
            takeNumber: 1
        )

        XCTAssertEqual(first.takeID, second.takeID)
        XCTAssertNotEqual(first.recordingIdentity, second.recordingIdentity)
    }

    func testWatchCommandPayloadRoundTripsSessionAndTake() throws {
        let payload = WatchCaptureCommandPayload(
            commandID: "command-1",
            command: .start,
            sessionID: "session-1",
            takeID: "take-001",
            requestedAt: Date(timeIntervalSince1970: 100)
        )

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(WatchCaptureCommandPayload.self, from: data)

        XCTAssertEqual(decoded.commandID, "command-1")
        XCTAssertEqual(decoded.sessionID, "session-1")
        XCTAssertEqual(decoded.takeID, "take-001")
        XCTAssertEqual(decoded.command, .start)
    }

    func testWatchAckSuccessAndTimeoutRemainDeterministic() async {
        let coordinator = WatchCaptureCommandCoordinator()
        let command = WatchCaptureCommandPayload(
            commandID: "ack-command",
            command: .start,
            sessionID: "session-ack",
            takeID: "take-001"
        )

        async let awaitedReply = coordinator.begin(command: command)
        _ = coordinator.resolve(
            WatchCaptureControlReply(
                commandID: command.commandID,
                sessionID: command.sessionID,
                takeID: command.takeID,
                syncState: .acknowledged,
                detail: "Acked",
                acknowledgedAt: Date(timeIntervalSince1970: 123)
            )
        )
        let ackReply = await awaitedReply
        XCTAssertEqual(ackReply.syncState, .acknowledged)

        let timeoutCoordinator = WatchCaptureCommandCoordinator()
        let timeoutCommand = WatchCaptureCommandPayload(
            commandID: "timeout-command",
            command: .start,
            sessionID: "session-timeout",
            takeID: "take-002"
        )
        async let timedOut = timeoutCoordinator.begin(command: timeoutCommand)
        try? await Task.sleep(nanoseconds: 20_000_000)
        let timeoutReply = timeoutCoordinator.timeout(commandID: timeoutCommand.commandID)
        XCTAssertEqual(timeoutReply?.syncState, .timedOut)
        let awaitedTimeout = await timedOut
        XCTAssertEqual(awaitedTimeout.syncState, .timedOut)

        let lateReply = timeoutCoordinator.resolve(
            WatchCaptureControlReply(
                commandID: timeoutCommand.commandID,
                sessionID: timeoutCommand.sessionID,
                takeID: timeoutCommand.takeID,
                syncState: .acknowledged,
                detail: "Late ack",
                acknowledgedAt: Date(timeIntervalSince1970: 456)
            )
        )
        XCTAssertEqual(lateReply?.syncState, .timedOut)
        XCTAssertEqual(lateReply?.detail, "Watch acknowledged too late; take remains degraded.")
        XCTAssertEqual(timeoutCoordinator.finalizedReply(for: timeoutCommand.commandID)?.syncState, .timedOut)
    }

    func testMotionPresenceRequiresExactLinkedWatchArtifact() throws {
        let root = try makeTemporaryDirectory()
        let package = try makeCanonicalPackage(rootURL: root)
        let validTake = try XCTUnwrap(package.takes.first)
        let invalidWatchSession = makeWatchSession(sessionID: "wrong-session", takeID: validTake.takeID)
        let invalidTake = SessionExportTake(
            takeID: validTake.takeID,
            takeNumber: validTake.takeNumber,
            bpm: validTake.bpm,
            mediaURL: validTake.mediaURL,
            audioArtifactURL: validTake.audioArtifactURL,
            sidecarURL: validTake.sidecarURL,
            watchCaptureSession: invalidWatchSession,
            drillName: validTake.drillName,
            duration: validTake.duration,
            quality: validTake.quality,
            comboTagged: validTake.comboTagged,
            audioPresent: validTake.audioPresent,
            motionPresent: true,
            syncStatus: validTake.syncStatus,
            recordingStatus: validTake.recordingStatus,
            verbalSlateUsed: validTake.verbalSlateUsed,
            syncClapUsed: validTake.syncClapUsed,
            note: validTake.note
        )
        var brokenPackage = package
        brokenPackage = SessionExportPackage(
            metadata: package.metadata,
            takes: [invalidTake] + Array(package.takes.dropFirst()),
            calibrationData: package.calibrationData
        )

        XCTAssertThrowsError(try SessionArchiveBuilder().preparePackage(from: .package(brokenPackage))) { error in
            XCTAssertEqual(error as? SessionExportError, .invalidSessionMetadata)
        }
    }

    func testExportValidationFailsWhenAudioArtifactIsMissing() throws {
        let root = try makeTemporaryDirectory()
        let package = try makeCanonicalPackage(rootURL: root)
        let validTake = try XCTUnwrap(package.takes.first)
        let brokenTake = SessionExportTake(
            takeID: validTake.takeID,
            takeNumber: validTake.takeNumber,
            bpm: validTake.bpm,
            mediaURL: validTake.mediaURL,
            audioArtifactURL: nil,
            sidecarURL: validTake.sidecarURL,
            watchCaptureSession: validTake.watchCaptureSession,
            drillName: validTake.drillName,
            duration: validTake.duration,
            quality: validTake.quality,
            comboTagged: validTake.comboTagged,
            audioPresent: validTake.audioPresent,
            motionPresent: validTake.motionPresent,
            syncStatus: validTake.syncStatus,
            recordingStatus: validTake.recordingStatus,
            verbalSlateUsed: validTake.verbalSlateUsed,
            syncClapUsed: validTake.syncClapUsed,
            note: validTake.note
        )

        let brokenPackage = SessionExportPackage(
            metadata: package.metadata,
            takes: [brokenTake] + Array(package.takes.dropFirst()),
            calibrationData: package.calibrationData
        )

        XCTAssertThrowsError(try SessionArchiveBuilder().preparePackage(from: .package(brokenPackage))) { error in
            XCTAssertEqual(error as? SessionExportError, .missingRequiredFiles)
        }
    }

    func testExportValidationFailsOnMixedSessionContamination() throws {
        let root = try makeTemporaryDirectory()
        let package = try makeCanonicalPackage(rootURL: root)
        let validTake = try XCTUnwrap(package.takes.first)
        let contaminatedSidecarURL = root.appendingPathComponent("mixed-session.json")
        try writeFinalizedSidecar(
            to: contaminatedSidecarURL,
            sessionID: "different-session",
            takeIdentity: CaptureCore.LocalRecordingNaming.takeIdentity(
                sessionID: "different-session",
                takeNumber: validTake.takeNumber
            ),
            mediaURL: validTake.mediaURL,
            performerName: "DJ Alpha",
            bpm: validTake.bpm,
            createdAt: Date(timeIntervalSince1970: 1_710_000_000)
        )

        let contaminatedTake = SessionExportTake(
            takeID: validTake.takeID,
            takeNumber: validTake.takeNumber,
            bpm: validTake.bpm,
            mediaURL: validTake.mediaURL,
            audioArtifactURL: validTake.audioArtifactURL,
            sidecarURL: contaminatedSidecarURL,
            watchCaptureSession: validTake.watchCaptureSession,
            drillName: validTake.drillName,
            duration: validTake.duration,
            quality: validTake.quality,
            comboTagged: validTake.comboTagged,
            audioPresent: validTake.audioPresent,
            motionPresent: validTake.motionPresent,
            syncStatus: validTake.syncStatus,
            recordingStatus: validTake.recordingStatus,
            verbalSlateUsed: validTake.verbalSlateUsed,
            syncClapUsed: validTake.syncClapUsed,
            note: validTake.note
        )

        let brokenPackage = SessionExportPackage(
            metadata: package.metadata,
            takes: [contaminatedTake] + Array(package.takes.dropFirst()),
            calibrationData: package.calibrationData
        )

        XCTAssertThrowsError(try SessionArchiveBuilder().preparePackage(from: .package(brokenPackage))) { error in
            XCTAssertEqual(error as? SessionExportError, .invalidSessionMetadata)
        }
    }

    func testExportValidationFailsWhenCanonicalManifestContractDrifts() throws {
        let root = try makeTemporaryDirectory()
        let package = try makeCanonicalPackage(rootURL: root, scratchType: .chirp)

        XCTAssertThrowsError(try SessionArchiveBuilder().preparePackage(from: .package(package))) { error in
            XCTAssertEqual(error as? SessionExportError, .invalidSessionMetadata)
        }
    }

    func testMacRoutineDefaultsPersistIntoStoredConfig() throws {
        let now = Date()
        let config = CaptureSessionConfig.routineCapture(
            sessionID: "routine-session",
            createdAt: now,
            updatedAt: now,
            takeCount: 0,
            takeDurationSeconds: 10
        )

        XCTAssertEqual(config.drillMode, .fullCapture)
        XCTAssertEqual(config.handedness, .right)

        let files = CaptureCore.LocalRecordingFiles(
            baseName: "routine-session_take001_routine",
            mediaURL: URL(fileURLWithPath: "/tmp/routine.mov"),
            sidecarURL: URL(fileURLWithPath: "/tmp/routine.json")
        )
        let sidecar = CaptureCore.LocalRecordingSidecar.recording(
            sessionID: config.sessionID,
            sessionConfig: config,
            takeIdentity: CaptureCore.LocalRecordingNaming.takeIdentity(sessionID: config.sessionID, takeNumber: 1),
            files: files,
            recordingRole: "routine_capture",
            platform: "macOS",
            appSurface: "mac_desktop",
            sourceDeviceName: "ScratchLab Mac",
            startedAt: now
        )

        let decoded = try JSONDecoder.captureCoreDecoder.decode(
            CaptureCore.LocalRecordingSidecar.self,
            from: try sidecar.encodedData()
        )
        XCTAssertEqual(decoded.sessionConfig?.drillMode, .fullCapture)
        XCTAssertEqual(decoded.sessionConfig?.handedness, .right)
    }

    func testCanonicalExportManifestParity() throws {
        let root = try makeTemporaryDirectory()
        let package = try makeCanonicalPackage(rootURL: root)
        let decodedSidecars = try package.takes.map {
            try JSONDecoder.captureCoreDecoder.decode(
                CaptureCore.LocalRecordingSidecar.self,
                from: Data(contentsOf: $0.sidecarURL)
            )
        }

        XCTAssertEqual(package.metadata.takeCount, package.takes.count)
        XCTAssertEqual(package.metadata.scratchTypeID, CaptureCanonicalRules.scratchTypeID)
        XCTAssertEqual(package.metadata.performerName?.trimmingCharacters(in: .whitespacesAndNewlines), "DJ Alpha")
        XCTAssertEqual(CaptureCanonicalFormatting.sanitizeDJToken(package.metadata.performerName ?? ""), "DJALPHA")
        XCTAssertTrue(SessionExportMetadataResolver.metadataMatchesSidecars(package.metadata, sidecars: decodedSidecars))
        XCTAssertEqual(Set(package.takes.map(\.bpm)), CaptureCanonicalRules.allowedBPMs)
        XCTAssertEqual(Set(package.takes.map(\.takeID)).count, package.takes.count)
        XCTAssertEqual(Set(package.takes.map { "\($0.bpm)-\($0.takeNumber)" }).count, package.takes.count)
        for (take, sidecar) in zip(package.takes, decodedSidecars) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: take.mediaURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: take.sidecarURL.path))
            XCTAssertEqual(sidecar.sessionID, package.metadata.sessionID)
            XCTAssertEqual(sidecar.takeID, take.takeID)
            XCTAssertEqual(sidecar.appLocalTakeNumber, take.takeNumber)
            XCTAssertEqual(sidecar.sessionConfig?.bpm, take.bpm)
            XCTAssertEqual(take.recordingStatus, "completed")
            XCTAssertTrue(CaptureCanonicalRules.allowedBPMs.contains(take.bpm))
            XCTAssertNotNil(take.verbalSlateUsed)
            XCTAssertNotNil(take.syncClapUsed)
            XCTAssertNotNil(take.audioArtifactURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: take.audioArtifactURL!.path))
            XCTAssertNotEqual(take.audioPresent, false)
            XCTAssertEqual(take.mediaURL.pathExtension.lowercased(), "mov")
            XCTAssertEqual(take.audioArtifactURL?.pathExtension.lowercased(), "wav")
            if sidecar.linkedMotionFileName != nil || take.motionPresent == true {
                XCTAssertNotNil(take.watchCaptureSession)
                XCTAssertTrue(
                    WatchAssociationResolver.isLinkedCaptureValid(
                        sessionID: package.metadata.sessionID,
                        takeID: take.takeID,
                        captureSession: try XCTUnwrap(take.watchCaptureSession)
                    )
                )
            } else if let motionPresent = take.motionPresent {
                XCTAssertFalse(motionPresent)
            }
        }

        let builder = SessionArchiveBuilder { source, _, generatedData in
            switch source {
            case "camA":
                return [
                    "kind": .string("video"),
                    "duration_seconds": .double(1.0),
                    "width": .int(1920),
                    "height": .int(1080),
                    "frame_rate_fps": .double(30.0),
                    "codec": .string("h264")
                ]
            case "serato":
                return [
                    "kind": .string("audio"),
                    "duration_seconds": .double(1.0),
                    "sample_rate_hz": .int(44_100),
                    "channel_count": .int(2),
                    "frame_count": .int(44_100),
                    "sample_width_bytes": .int(2)
                ]
            case "watch":
                guard let generatedData else {
                    throw SessionExportError.missingRequiredFiles
                }
                return [
                    "kind": .string("csv"),
                    "row_count": .int(String(data: generatedData, encoding: .utf8)?.split(whereSeparator: \.isNewline).count ?? 0),
                    "data_row_count": .int(12),
                    "column_count": .int(CaptureCanonicalRules.watchCSVHeader.count)
                ]
            default:
                throw SessionExportError.invalidSessionMetadata
            }
        }
        let validatedPackage = try builder.preparePackage(from: .package(package))
        let preview = try builder.canonicalPreview(for: validatedPackage)
        let manifestData = preview.manifestData
        let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any]

        XCTAssertEqual(manifest?["spec_version"] as? String, "capture_spec_v1")
        XCTAssertEqual(manifest?["scratch_type"] as? String, "baby")
        XCTAssertEqual((manifest?["allowed_bpms"] as? [Int]) ?? [], [70, 90, 110])

        let takes = try XCTUnwrap(manifest?["takes"] as? [[String: Any]])
        XCTAssertEqual(takes.count, 3)
        XCTAssertEqual((takes.first?["files"] as? [String: String])?["camA"], "video/DJALPHA_baby_070_take01_camA.mov")
        XCTAssertEqual((takes.first?["files"] as? [String: String])?["serato"], "audio/DJALPHA_baby_070_take01_serato.wav")

        let takeLog = preview.takeLogCSV
        XCTAssertTrue(takeLog.contains("bpm,take_number,raw_camA,raw_camB,raw_audio,raw_watch,verbal_slate_used,sync_clap_used,notes"))
        XCTAssertTrue(takeLog.contains("\"70\",\"1\",\"\",\"\",\"\",\"\",\"true\",\"true\",\"take 1 note\""))
    }

    func testRoutineCaptureExportAcceptsRecordedBPMSubset() throws {
        let root = try makeTemporaryDirectory()
        let createdAt = Date(timeIntervalSince1970: 1_710_000_500)
        let sessionID = "routine-bpm-subset"
        let takeIdentity = CaptureCore.LocalRecordingNaming.takeIdentity(sessionID: sessionID, takeNumber: 1)
        let videoURL = root.appendingPathComponent("routine.mov")
        let audioURL = root.appendingPathComponent("routine.wav")
        let sidecarURL = root.appendingPathComponent("routine.json")

        try writePlaceholderFile(at: videoURL, contents: Data("mov".utf8))
        try writePlaceholderFile(at: audioURL, contents: Data("wav".utf8))
        try writeFinalizedSidecar(
            to: sidecarURL,
            sessionID: sessionID,
            takeIdentity: takeIdentity,
            mediaURL: videoURL,
            performerName: "DJ Alpha",
            bpm: 90,
            createdAt: createdAt,
            scratchType: .stab
        )

        let decodedSidecar = try JSONDecoder.captureCoreDecoder.decode(
            CaptureCore.LocalRecordingSidecar.self,
            from: Data(contentsOf: sidecarURL)
        )
        let metadataConfig = SessionExportMetadataResolver.mergedConfig(
            preferredConfig: nil,
            seedSidecar: decodedSidecar,
            sidecars: [decodedSidecar],
            fallbackSessionID: sessionID,
            createdAt: createdAt,
            updatedAt: createdAt.addingTimeInterval(1),
            takeCount: 1,
            totalDurationSeconds: 1
        )
        let package = SessionExportPackage(
            metadata: SessionExportMetadata(
                config: metadataConfig,
                workflow: "routine_capture",
                platform: "macOS",
                sessionName: "Routine Session",
                totalDurationSeconds: 1
            ),
            takes: [
                SessionExportTake(
                    takeID: takeIdentity.takeID,
                    takeNumber: 1,
                    bpm: 90,
                    mediaURL: videoURL,
                    audioArtifactURL: audioURL,
                    sidecarURL: sidecarURL,
                    watchCaptureSession: nil,
                    drillName: nil,
                    duration: 1,
                    quality: nil,
                    comboTagged: false,
                    audioPresent: true,
                    motionPresent: false,
                    syncStatus: "notRequested",
                    recordingStatus: "completed",
                    verbalSlateUsed: false,
                    syncClapUsed: false,
                    note: ""
                )
            ],
            calibrationData: nil
        )

        let builder = SessionArchiveBuilder { source, _, _ in
            switch source {
            case "camA":
                return [
                    "kind": .string("video"),
                    "duration_seconds": .double(1.0),
                    "width": .int(1920),
                    "height": .int(1080),
                    "frame_rate_fps": .double(30.0),
                    "codec": .string("h264")
                ]
            case "serato":
                return [
                    "kind": .string("audio"),
                    "duration_seconds": .double(1.0),
                    "sample_rate_hz": .int(44_100),
                    "channel_count": .int(2),
                    "frame_count": .int(44_100),
                    "sample_width_bytes": .int(2)
                ]
            default:
                throw SessionExportError.invalidSessionMetadata
            }
        }

        let validatedPackage = try builder.preparePackage(from: .package(package))
        let preview = try builder.canonicalPreview(for: validatedPackage)
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: preview.manifestData) as? [String: Any]
        )

        XCTAssertEqual(manifest["scratch_type"] as? String, "stab")
        XCTAssertEqual((manifest["allowed_bpms"] as? [Int]) ?? [], [90])
        XCTAssertEqual((manifest["takes"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((manifest["takes"] as? [[String: Any]])?.first?["scratch_type"] as? String, "stab")
        XCTAssertEqual((manifest["takes"] as? [[String: Any]])?.first?["files"] as? [String: String], [
            "camA": "video/DJALPHA_stab_090_take01_camA.mov",
            "serato": "audio/DJALPHA_stab_090_take01_serato.wav"
        ])
    }

    func testRoutineExportValidationAcceptsSelectedNonBabyScratchType() throws {
        let root = try makeTemporaryDirectory()
        let videoURL = try makeLocalRecordingTake(
            in: root,
            sessionID: "routine-stab-export",
            takeNumber: 1,
            bpm: 110,
            createdAt: Date(timeIntervalSince1970: 1_710_001_100),
            scratchType: .stab,
            useRealMedia: true
        )

        let report = SessionArchiveBuilder().validationReport(
            for: .localRecordingSession(
                lastRecordingURL: videoURL,
                sessionName: "Stab Routine",
                config: nil
            )
        )

        XCTAssertNil(report)
    }

    func testRoutineExportUsesSelectedTakeMetadataGroupWithinMutableSession() throws {
        let root = try makeTemporaryDirectory()
        let sessionID = "routine-mixed-session"
        _ = try makeLocalRecordingTake(
            in: root,
            sessionID: sessionID,
            takeNumber: 1,
            bpm: 95,
            createdAt: Date(timeIntervalSince1970: 1_710_001_150),
            scratchType: .babyScratch,
            useRealMedia: true
        )
        let stabURL = try makeLocalRecordingTake(
            in: root,
            sessionID: sessionID,
            takeNumber: 2,
            bpm: 110,
            createdAt: Date(timeIntervalSince1970: 1_710_001_200),
            scratchType: .stab,
            useRealMedia: true
        )

        let builder = SessionArchiveBuilder()
        let source = SessionExportSource.localRecordingSession(
            lastRecordingURL: stabURL,
            sessionName: "Stab Routine",
            config: nil
        )

        XCTAssertNil(builder.validationReport(for: source))

        let package = try builder.preparePackage(from: source)
        XCTAssertEqual(package.metadata.scratchTypeID, CaptureSessionScratchType.stab.rawValue)
        XCTAssertEqual(package.metadata.scratchTypeName, CaptureSessionScratchType.stab.title)
        XCTAssertEqual(package.takes.count, 1)
        XCTAssertEqual(package.takes.first?.takeID, "take-002")
        XCTAssertEqual(package.takes.first?.takeNumber, 2)
        XCTAssertEqual(package.takes.first?.bpm, 110)
    }

    func testCalibrationModeExportMetadataDisablesClickTrack() throws {
        let root = try makeTemporaryDirectory()
        let videoURL = try makeLocalRecordingTake(
            in: root,
            sessionID: "calibration-click-off",
            takeNumber: 1,
            bpm: nil,
            createdAt: Date(timeIntervalSince1970: 1_710_000_700),
            captureMode: .calibrationNoClick,
            captureTiming: CaptureTimingMetadata(
                clickStartHostTime: nil,
                recordingStartHostTime: 456
            ),
            useRealMedia: true
        )

        let builder = SessionArchiveBuilder()
        let source = SessionExportSource.localRecordingSession(
            lastRecordingURL: videoURL,
            sessionName: "Calibration Session",
            config: nil
        )
        XCTAssertNil(builder.validationReport(for: source))

        let package = try builder.preparePackage(from: source)
        let metadataDocument = try builder.metadataDocument(for: package)
        let takeMetadata = try XCTUnwrap(metadataDocument.takes.first)
        let exportMetadata = try builder.exportMetadataDocument(
            for: package,
            options: SessionExportOptions(mixMode: .scratchOnly)
        )
        let exportTakeMetadata = try XCTUnwrap(exportMetadata.takes.first)

        XCTAssertNil(package.metadata.bpm)
        XCTAssertEqual(package.metadata.captureMode, CaptureSessionCaptureMode.calibrationNoClick.rawValue)
        XCTAssertFalse(package.metadata.clickEnabled)
        XCTAssertEqual(package.metadata.beatEngineMode, BeatEngineMode.silent.rawValue)
        XCTAssertFalse(package.metadata.beatEnabled)
        XCTAssertEqual(package.metadata.countInBeats, CaptureClickTrackDefaults.countInBeats)
        XCTAssertEqual(package.metadata.beatsPerBar, CaptureClickTrackDefaults.beatsPerBar)
        XCTAssertEqual(package.metadata.timingPrintedToRecording, TimingPrintedToRecordingState.notPrinted.rawValue)
        XCTAssertEqual(metadataDocument.session.captureMode, CaptureSessionCaptureMode.calibrationNoClick.rawValue)
        XCTAssertFalse(metadataDocument.session.clickEnabled)
        XCTAssertEqual(metadataDocument.session.beatEngineMode, BeatEngineMode.silent.rawValue)
        XCTAssertFalse(metadataDocument.session.beatEnabled)
        XCTAssertNil(takeMetadata.bpm)
        XCTAssertFalse(takeMetadata.clickEnabled)
        XCTAssertEqual(takeMetadata.beatEngineMode, BeatEngineMode.silent.rawValue)
        XCTAssertFalse(takeMetadata.beatEnabled)
        XCTAssertEqual(takeMetadata.countInBeats, CaptureClickTrackDefaults.countInBeats)
        XCTAssertEqual(takeMetadata.beatsPerBar, CaptureClickTrackDefaults.beatsPerBar)
        XCTAssertNil(takeMetadata.clickStartHostTime)
        XCTAssertEqual(takeMetadata.recordingStartHostTime, 456)
        XCTAssertEqual(takeMetadata.timingPrintedToRecording, TimingPrintedToRecordingState.notPrinted.rawValue)
        XCTAssertNil(exportTakeMetadata.bpm)
        XCTAssertEqual(exportTakeMetadata.captureMode, CaptureSessionCaptureMode.calibrationNoClick.rawValue)
        XCTAssertFalse(exportTakeMetadata.clickEnabled)
        XCTAssertEqual(exportTakeMetadata.beatEngineMode, BeatEngineMode.silent.rawValue)
        XCTAssertFalse(exportTakeMetadata.beatEnabled)
        XCTAssertNil(exportTakeMetadata.clickStartHostTime)
        XCTAssertEqual(exportTakeMetadata.recordingStartHostTime, 456)
        XCTAssertEqual(exportTakeMetadata.clickVersion, CaptureClickTrackDefaults.clickVersion)
        XCTAssertEqual(exportTakeMetadata.engineVersion, CaptureBeatEngineDefaults.engineVersion)

        let archiveDirectory = root.appendingPathComponent("archives", isDirectory: true)
        try FileManager.default.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
        let archive = try builder.createArchive(
            from: package,
            options: SessionExportOptions(mixMode: .scratchOnly),
            in: archiveDirectory
        )
        let archiveRoot = try unzipArchive(
            archive.archiveURL,
            to: root.appendingPathComponent("calibration-unzipped", isDirectory: true)
        )
        let archivedMetadata = try decodeSessionMetadataDocument(from: archiveRoot)
        let archivedExportMetadata = try decodeExportMetadataDocument(from: archiveRoot)
        let archivedTakeMetadata = try XCTUnwrap(archivedMetadata.takes.first)
        let archivedExportTakeMetadata = try XCTUnwrap(archivedExportMetadata.takes.first)

        XCTAssertEqual(archivedMetadata.session.captureMode, CaptureSessionCaptureMode.calibrationNoClick.rawValue)
        XCTAssertEqual(archivedMetadata.session.beatEngineMode, BeatEngineMode.silent.rawValue)
        XCTAssertNil(archivedMetadata.session.bpm)
        XCTAssertNil(archivedTakeMetadata.bpm)
        XCTAssertNil(archivedTakeMetadata.clickStartHostTime)
        XCTAssertEqual(archivedTakeMetadata.recordingStartHostTime, 456)
        XCTAssertNil(archivedExportTakeMetadata.bpm)
        XCTAssertNil(archivedExportTakeMetadata.clickStartHostTime)
        XCTAssertEqual(archivedExportTakeMetadata.recordingStartHostTime, 456)
    }

    func testTimedClickExportMetadataPersistsPresetBPMsAndTiming() throws {
        let root = try makeTemporaryDirectory()
        let sessionID = "timed-click-presets"
        var lastRecordingURL: URL?

        for (index, bpm) in CaptureClickTrackDefaults.presetBPMs.enumerated() {
            lastRecordingURL = try makeLocalRecordingTake(
                in: root,
                sessionID: sessionID,
                takeNumber: index + 1,
                bpm: bpm,
                createdAt: Date(timeIntervalSince1970: 1_710_000_800 + Double(index)),
                captureMode: .timedClick,
                captureTiming: CaptureTimingMetadata(
                    clickStartHostTime: UInt64(1_000 + index),
                    recordingStartHostTime: UInt64(2_000 + index)
                ),
                useRealMedia: true
            )
        }

        let builder = SessionArchiveBuilder()
        let package = try builder.preparePackage(
            from: .localRecordingSession(
                lastRecordingURL: try XCTUnwrap(lastRecordingURL),
                sessionName: "Timed Capture Session",
                config: nil
            )
        )
        let metadataDocument = try builder.metadataDocument(for: package)

        XCTAssertEqual(package.metadata.captureMode, CaptureSessionCaptureMode.timedClick.rawValue)
        XCTAssertTrue(package.metadata.clickEnabled)
        XCTAssertEqual(package.metadata.beatEngineMode, BeatEngineMode.clickTrack.rawValue)
        XCTAssertFalse(package.metadata.beatEnabled)
        XCTAssertEqual(metadataDocument.session.captureMode, CaptureSessionCaptureMode.timedClick.rawValue)
        XCTAssertTrue(metadataDocument.session.clickEnabled)
        XCTAssertEqual(metadataDocument.session.beatEngineMode, BeatEngineMode.clickTrack.rawValue)
        XCTAssertFalse(metadataDocument.session.beatEnabled)
        XCTAssertEqual(metadataDocument.takes.compactMap(\.bpm).sorted(), CaptureClickTrackDefaults.presetBPMs)
        XCTAssertTrue(metadataDocument.takes.allSatisfy(\.clickEnabled))
        XCTAssertTrue(metadataDocument.takes.allSatisfy { $0.beatEngineMode == BeatEngineMode.clickTrack.rawValue })
        XCTAssertTrue(metadataDocument.takes.allSatisfy { !$0.beatEnabled })
        XCTAssertTrue(
            metadataDocument.takes.allSatisfy {
                $0.countInBeats == CaptureClickTrackDefaults.countInBeats
                    && $0.beatsPerBar == CaptureClickTrackDefaults.beatsPerBar
                    && $0.clickAccentPattern == CaptureClickTrackDefaults.clickAccentPattern
                    && $0.clickVersion == CaptureClickTrackDefaults.clickVersion
            }
        )
        XCTAssertEqual(metadataDocument.takes.first?.clickStartHostTime, 1_000)
        XCTAssertEqual(metadataDocument.takes.first?.recordingStartHostTime, 2_000)
    }

    func testLocalRecordingExportUsesSharedMetadataResolverForClickTrackConfig() throws {
        let root = try makeTemporaryDirectory()
        let videoURL = try makeLocalRecordingTake(
            in: root,
            sessionID: "resolver-click-metadata",
            takeNumber: 1,
            bpm: 110,
            createdAt: Date(timeIntervalSince1970: 1_710_000_900),
            captureMode: .timedClick,
            captureTiming: CaptureTimingMetadata(
                clickStartHostTime: 9_999,
                recordingStartHostTime: 10_999
            ),
            useRealMedia: true
        )

        let builder = SessionArchiveBuilder()
        let staleConfig = CaptureSessionConfig.routineCapture(
            sessionID: "stale-session",
            createdAt: Date(timeIntervalSince1970: 1_710_000_899),
            updatedAt: Date(timeIntervalSince1970: 1_710_000_899),
            takeCount: 0,
            takeDurationSeconds: nil
        )
        let package = try builder.preparePackage(
            from: .localRecordingSession(
                lastRecordingURL: videoURL,
                sessionName: "Resolver Session",
                config: staleConfig
            )
        )
        let metadataDocument = try builder.metadataDocument(for: package)
        let takeMetadata = try XCTUnwrap(metadataDocument.takes.first)
        let exportMetadata = try builder.exportMetadataDocument(
            for: package,
            options: SessionExportOptions(mixMode: .scratchWithTiming)
        )
        let exportTakeMetadata = try XCTUnwrap(exportMetadata.takes.first)

        XCTAssertEqual(package.metadata.bpm, 110)
        XCTAssertEqual(package.metadata.captureMode, CaptureSessionCaptureMode.timedClick.rawValue)
        XCTAssertTrue(package.metadata.clickEnabled)
        XCTAssertEqual(metadataDocument.session.bpm, 110)
        XCTAssertEqual(metadataDocument.session.captureMode, CaptureSessionCaptureMode.timedClick.rawValue)
        XCTAssertEqual(metadataDocument.session.beatEngineMode, BeatEngineMode.clickTrack.rawValue)
        XCTAssertEqual(takeMetadata.bpm, 110)
        XCTAssertEqual(takeMetadata.captureMode, CaptureSessionCaptureMode.timedClick.rawValue)
        XCTAssertTrue(takeMetadata.clickEnabled)
        XCTAssertEqual(takeMetadata.beatEngineMode, BeatEngineMode.clickTrack.rawValue)
        XCTAssertFalse(takeMetadata.beatEnabled)
        XCTAssertEqual(takeMetadata.clickStartHostTime, 9_999)
        XCTAssertEqual(takeMetadata.recordingStartHostTime, 10_999)
        XCTAssertEqual(exportTakeMetadata.captureMode, CaptureSessionCaptureMode.timedClick.rawValue)
        XCTAssertTrue(exportTakeMetadata.clickEnabled)
        XCTAssertEqual(exportTakeMetadata.beatEngineMode, BeatEngineMode.clickTrack.rawValue)
        XCTAssertFalse(exportTakeMetadata.beatEnabled)
        XCTAssertEqual(exportTakeMetadata.clickStartHostTime, 9_999)
        XCTAssertEqual(exportTakeMetadata.recordingStartHostTime, 10_999)
        XCTAssertEqual(exportTakeMetadata.clickVersion, CaptureClickTrackDefaults.clickVersion)
        XCTAssertEqual(exportTakeMetadata.engineVersion, CaptureBeatEngineDefaults.engineVersion)

        let archiveDirectory = root.appendingPathComponent("resolver-archives", isDirectory: true)
        try FileManager.default.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
        let archive = try builder.createArchive(
            from: package,
            options: SessionExportOptions(mixMode: .scratchWithTiming),
            in: archiveDirectory
        )
        let archiveRoot = try unzipArchive(
            archive.archiveURL,
            to: root.appendingPathComponent("resolver-unzipped", isDirectory: true)
        )
        let archivedMetadata = try decodeSessionMetadataDocument(from: archiveRoot)
        let archivedExportMetadata = try decodeExportMetadataDocument(from: archiveRoot)
        let archivedTakeMetadata = try XCTUnwrap(archivedMetadata.takes.first)
        let archivedExportTakeMetadata = try XCTUnwrap(archivedExportMetadata.takes.first)

        XCTAssertEqual(archivedMetadata.session.bpm, 110)
        XCTAssertEqual(archivedMetadata.session.captureMode, CaptureSessionCaptureMode.timedClick.rawValue)
        XCTAssertTrue(archivedMetadata.session.clickEnabled)
        XCTAssertEqual(archivedTakeMetadata.bpm, 110)
        XCTAssertEqual(archivedTakeMetadata.clickStartHostTime, 9_999)
        XCTAssertEqual(archivedTakeMetadata.recordingStartHostTime, 10_999)
        XCTAssertEqual(archivedExportTakeMetadata.bpm, 110)
        XCTAssertEqual(archivedExportTakeMetadata.clickStartHostTime, 9_999)
        XCTAssertEqual(archivedExportTakeMetadata.recordingStartHostTime, 10_999)
    }

    func testLocalRecordingExportPrefersSelectedTakeMetadataOverCompatibleSiblingDefaults() throws {
        let root = try makeTemporaryDirectory()
        let sessionID = "resolver-mixed-compatible"
        _ = try makeLocalRecordingTake(
            in: root,
            sessionID: sessionID,
            takeNumber: 1,
            bpm: nil,
            createdAt: Date(timeIntervalSince1970: 1_710_000_910),
            scratchType: nil,
            captureMode: .timedClick,
            captureTiming: nil,
            useRealMedia: true
        )
        let selectedVideoURL = try makeLocalRecordingTake(
            in: root,
            sessionID: sessionID,
            takeNumber: 2,
            bpm: 95,
            createdAt: Date(timeIntervalSince1970: 1_710_000_920),
            captureMode: .timedClick,
            captureTiming: CaptureTimingMetadata(
                clickStartHostTime: 55_555,
                recordingStartHostTime: 66_666
            ),
            useRealMedia: true
        )

        let builder = SessionArchiveBuilder()
        let package = try builder.preparePackage(
            from: .localRecordingSession(
                lastRecordingURL: selectedVideoURL,
                sessionName: "Resolver Mixed Session",
                config: nil
            )
        )
        let metadataDocument = try builder.metadataDocument(for: package)
        let selectedTakeMetadata = try XCTUnwrap(
            metadataDocument.takes.first(where: { $0.takeID == "take-002" })
        )
        let exportMetadata = try builder.exportMetadataDocument(
            for: package,
            options: SessionExportOptions(mixMode: .scratchOnly)
        )
        let selectedExportTakeMetadata = try XCTUnwrap(
            exportMetadata.takes.first(where: { $0.takeID == "take-002" })
        )

        XCTAssertEqual(package.metadata.bpm, 95)
        XCTAssertEqual(metadataDocument.session.bpm, 95)
        XCTAssertEqual(metadataDocument.session.captureMode, CaptureSessionCaptureMode.timedClick.rawValue)
        XCTAssertEqual(metadataDocument.session.beatEngineMode, BeatEngineMode.clickTrack.rawValue)
        XCTAssertEqual(selectedTakeMetadata.bpm, 95)
        XCTAssertEqual(selectedTakeMetadata.clickStartHostTime, 55_555)
        XCTAssertEqual(selectedTakeMetadata.recordingStartHostTime, 66_666)
        XCTAssertEqual(selectedExportTakeMetadata.bpm, 95)
        XCTAssertEqual(selectedExportTakeMetadata.clickStartHostTime, 55_555)
        XCTAssertEqual(selectedExportTakeMetadata.recordingStartHostTime, 66_666)

        let archiveDirectory = root.appendingPathComponent("mixed-archives", isDirectory: true)
        try FileManager.default.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
        let archive = try builder.createArchive(
            from: package,
            options: SessionExportOptions(mixMode: .scratchOnly),
            in: archiveDirectory
        )
        let archiveRoot = try unzipArchive(
            archive.archiveURL,
            to: root.appendingPathComponent("mixed-unzipped", isDirectory: true)
        )
        let archivedMetadata = try decodeSessionMetadataDocument(from: archiveRoot)
        let archivedExportMetadata = try decodeExportMetadataDocument(from: archiveRoot)
        let archivedSelectedTakeMetadata = try XCTUnwrap(
            archivedMetadata.takes.first(where: { $0.takeID == "take-002" })
        )
        let archivedSelectedExportTakeMetadata = try XCTUnwrap(
            archivedExportMetadata.takes.first(where: { $0.takeID == "take-002" })
        )

        XCTAssertEqual(archivedMetadata.session.bpm, 95)
        XCTAssertEqual(archivedSelectedTakeMetadata.bpm, 95)
        XCTAssertEqual(archivedSelectedTakeMetadata.clickStartHostTime, 55_555)
        XCTAssertEqual(archivedSelectedTakeMetadata.recordingStartHostTime, 66_666)
        XCTAssertEqual(archivedSelectedExportTakeMetadata.bpm, 95)
        XCTAssertEqual(archivedSelectedExportTakeMetadata.clickStartHostTime, 55_555)
        XCTAssertEqual(archivedSelectedExportTakeMetadata.recordingStartHostTime, 66_666)
    }

    func testPracticeBeatExportMetadataPersistsBeatPattern() throws {
        let root = try makeTemporaryDirectory()
        let videoURL = try makeLocalRecordingTake(
            in: root,
            sessionID: "practice-beat-export",
            takeNumber: 1,
            bpm: 95,
            createdAt: Date(timeIntervalSince1970: 1_710_000_950),
            captureMode: .timedClick,
            beatEngineMode: .minimalFunk,
            timingPrintedToRecording: .unknown,
            captureTiming: CaptureTimingMetadata(
                clickStartHostTime: 12_345,
                recordingStartHostTime: 23_456
            ),
            useRealMedia: true
        )

        let builder = SessionArchiveBuilder()
        let package = try builder.preparePackage(
            from: .localRecordingSession(
                lastRecordingURL: videoURL,
                sessionName: "Practice Beat Session",
                config: nil
            )
        )
        let metadataDocument = try builder.metadataDocument(for: package)
        let takeMetadata = try XCTUnwrap(metadataDocument.takes.first)

        XCTAssertEqual(package.metadata.captureMode, CaptureSessionCaptureMode.timedClick.rawValue)
        XCTAssertFalse(package.metadata.clickEnabled)
        XCTAssertEqual(package.metadata.beatEngineMode, BeatEngineMode.minimalFunk.rawValue)
        XCTAssertTrue(package.metadata.beatEnabled)
        XCTAssertEqual(package.metadata.beatPatternName, BeatEngineMode.minimalFunk.beatPatternName)
        XCTAssertEqual(package.metadata.beatPatternVersion, CaptureBeatEngineDefaults.beatPatternVersion)
        XCTAssertEqual(package.metadata.engineVersion, CaptureBeatEngineDefaults.engineVersion)
        XCTAssertEqual(package.metadata.swingAmount, CaptureBeatEngineDefaults.minimalFunkSwingAmount, accuracy: 0.0001)
        XCTAssertEqual(takeMetadata.captureMode, CaptureSessionCaptureMode.timedClick.rawValue)
        XCTAssertFalse(takeMetadata.clickEnabled)
        XCTAssertEqual(takeMetadata.beatEngineMode, BeatEngineMode.minimalFunk.rawValue)
        XCTAssertTrue(takeMetadata.beatEnabled)
        XCTAssertEqual(takeMetadata.beatPatternName, BeatEngineMode.minimalFunk.beatPatternName)
        XCTAssertEqual(takeMetadata.beatPatternVersion, CaptureBeatEngineDefaults.beatPatternVersion)
        XCTAssertEqual(takeMetadata.engineVersion, CaptureBeatEngineDefaults.engineVersion)
        XCTAssertEqual(takeMetadata.swingAmount, CaptureBeatEngineDefaults.minimalFunkSwingAmount, accuracy: 0.0001)
        XCTAssertEqual(takeMetadata.clickStartHostTime, 12_345)
        XCTAssertEqual(takeMetadata.recordingStartHostTime, 23_456)
    }

    func testDefaultExportMixModeIsScratchOnly() {
        XCTAssertEqual(SessionExportOptions().mixMode, .scratchOnly)
    }

    func testReleaseExportModeUISourceRestrictsAdvancedModesBehindDebugGate() throws {
        let modelSourceURL = projectRootURL().appendingPathComponent("ScratchLab/Models/CaptureCore.swift")
        let companionSourceURL = projectRootURL().appendingPathComponent("ScratchLab/Views/CompanionCameraView.swift")
        let macSourceURL = projectRootURL().appendingPathComponent("ScratchLabDesktop/Views/MacAnalyzerView.swift")
        let modelSource = try String(contentsOf: modelSourceURL, encoding: .utf8)
        let companionSource = try String(contentsOf: companionSourceURL, encoding: .utf8)
        let macSource = try String(contentsOf: macSourceURL, encoding: .utf8)

        XCTAssertTrue(modelSource.contains("static var appReviewVisibleModes: [ExportMixMode]"))
        XCTAssertTrue(modelSource.contains("#if DEBUG"))
        XCTAssertTrue(modelSource.contains("return allCases"))
        XCTAssertTrue(modelSource.contains("return [.scratchOnly]"))
        XCTAssertTrue(companionSource.contains("ForEach(ExportMixMode.appReviewVisibleModes)"))
        XCTAssertTrue(macSource.contains("ForEach(ExportMixMode.appReviewVisibleModes)"))
        XCTAssertTrue(companionSource.contains("exportMixMode = .scratchOnly"))
        XCTAssertTrue(macSource.contains("exportMixMode = .scratchOnly"))
        XCTAssertFalse(companionSource.contains("ForEach(ExportMixMode.allCases)"))
        XCTAssertFalse(macSource.contains("ForEach(ExportMixMode.allCases)"))
    }

    @MainActor
    func testLocalProgressUpdatesWithGameCenterDisabledByDefault() throws {
        let defaults = try makeEphemeralUserDefaults()
        let manager = ProgressManager(defaults: defaults)
        manager.createProfile(displayName: "Reviewer")

        manager.activateGameCenterIfNeeded()
        XCTAssertFalse(manager.isGameCenterEnabled)
        XCTAssertNil(manager.gameCenterPlayerID)

        manager.recordScratchAttempt(scratchID: "baby_scratch", accuracy: 92, duration: 30)

        XCTAssertEqual(manager.totalScratchAttempts, 1)
        XCTAssertEqual(manager.totalPracticeTime, 30, accuracy: 0.001)
        XCTAssertEqual(manager.currentStreak, 1)
        XCTAssertEqual(manager.playerProfile?.experience, 90)
        XCTAssertEqual(manager.babyScratchProgress?.practiceCount, 1)
        XCTAssertEqual(manager.babyScratchProgress?.bestAccuracy ?? 0, 92, accuracy: 0.001)
        XCTAssertTrue(manager.babyScratchProgress?.isMastered ?? false)
        XCTAssertFalse(manager.isGameCenterEnabled)
        XCTAssertNil(manager.gameCenterPlayerID)

        let reloaded = ProgressManager(defaults: defaults)
        XCTAssertEqual(reloaded.totalScratchAttempts, 1)
        XCTAssertEqual(reloaded.totalPracticeTime, 30, accuracy: 0.001)
        XCTAssertEqual(reloaded.playerProfile?.experience, 90)
        XCTAssertEqual(reloaded.babyScratchProgress?.practiceCount, 1)
    }

    func testGameCenterDashboardIsDisabledForAppReviewBuilds() throws {
        let infoURL = projectRootURL().appendingPathComponent("ScratchLab/Info.plist")
        let data = try Data(contentsOf: infoURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        XCTAssertFalse(plist["GCSupportsGameCenterDashboard"] as? Bool ?? false)
    }

    func testGameCenterLeaderboardCodeIsDebugAndFeatureFlagGated() throws {
        let sourceURL = projectRootURL().appendingPathComponent("ScratchLab/Services/ProgressManager.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("#if DEBUG\nimport GameKit\n#endif"))
        XCTAssertTrue(source.contains("SCRATCHLAB_ENABLE_GAME_CENTER"))
        XCTAssertTrue(source.contains("private var gameCenterFeatureEnabled: Bool"))
        XCTAssertTrue(source.contains("#if DEBUG\n    private let gameCenterLeaderboardID = \"scratchlab_highscores\"\n    #endif"))
        XCTAssertTrue(source.contains("#if DEBUG\n        if gameCenterFeatureEnabled"))
        XCTAssertTrue(source.contains("#if DEBUG\n    private func reportScoreToGameCenter"))
        XCTAssertTrue(source.contains("GKLeaderboard.submitScore"))
        XCTAssertTrue(source.contains("func showGameCenterLeaderboard(from viewController: UIViewController)"))
        XCTAssertTrue(source.contains("#if DEBUG\n        guard gameCenterFeatureEnabled else { return }"))
        XCTAssertTrue(source.contains("GKGameCenterViewController"))
        XCTAssertFalse(source.contains("leaderboardIDs: [\"scratchlab_highscores\"]"))
        XCTAssertFalse(source.contains("leaderboardID: \"scratchlab_highscores\""))
    }

    func testScratchOnlyExportMetadataMarksCleanCaptureWhenTimingNotPrinted() throws {
        let root = try makeTemporaryDirectory()
        let videoURL = try makeLocalRecordingTake(
            in: root,
            sessionID: "scratch-only-clean",
            takeNumber: 1,
            bpm: 95,
            createdAt: Date(timeIntervalSince1970: 1_710_000_960),
            timingPrintedToRecording: .notPrinted,
            captureTiming: CaptureTimingMetadata(
                clickStartHostTime: 1_111,
                recordingStartHostTime: 2_222
            ),
            useRealMedia: true
        )

        let builder = SessionArchiveBuilder()
        let package = try builder.preparePackage(
            from: .localRecordingSession(
                lastRecordingURL: videoURL,
                sessionName: "Scratch Only Clean",
                config: nil
            )
        )
        let exportMetadata = try builder.exportMetadataDocument(
            for: package,
            options: SessionExportOptions(mixMode: .scratchOnly)
        )
        let takeMetadata = try XCTUnwrap(exportMetadata.takes.first)

        XCTAssertEqual(exportMetadata.exportMixMode, ExportMixMode.scratchOnly.rawValue)
        XCTAssertEqual(exportMetadata.captureQuality, CaptureQuality.clean.rawValue)
        XCTAssertEqual(exportMetadata.timingPrintedToRecording, TimingPrintedToRecordingState.notPrinted.rawValue)
        XCTAssertEqual(takeMetadata.captureQuality, CaptureQuality.clean.rawValue)
        XCTAssertEqual(takeMetadata.timingPrintedToRecording, TimingPrintedToRecordingState.notPrinted.rawValue)
        XCTAssertNil(takeMetadata.scratchFile)
        XCTAssertNil(takeMetadata.timingFile)
        XCTAssertNil(takeMetadata.rawTakeFile)
    }

    func testScratchOnlyExportMetadataMarksMixedCaptureWhenTimingPrintedOrUnknown() throws {
        let builder = SessionArchiveBuilder()

        for state in [TimingPrintedToRecordingState.printed, .unknown] {
            let root = try makeTemporaryDirectory()
            let videoURL = try makeLocalRecordingTake(
                in: root,
                sessionID: "scratch-only-\(state.rawValue)",
                takeNumber: 1,
                bpm: 95,
                createdAt: Date(timeIntervalSince1970: 1_710_000_970),
                timingPrintedToRecording: state,
                captureTiming: CaptureTimingMetadata(
                    clickStartHostTime: 3_333,
                    recordingStartHostTime: 4_444
                ),
                useRealMedia: true
            )

            let package = try builder.preparePackage(
                from: .localRecordingSession(
                    lastRecordingURL: videoURL,
                    sessionName: "Scratch Only Mixed",
                    config: nil
                )
            )
            let exportMetadata = try builder.exportMetadataDocument(
                for: package,
                options: SessionExportOptions(mixMode: .scratchOnly)
            )
            let takeMetadata = try XCTUnwrap(exportMetadata.takes.first)

            XCTAssertEqual(exportMetadata.exportMixMode, ExportMixMode.scratchOnly.rawValue)
            XCTAssertEqual(exportMetadata.captureQuality, CaptureQuality.mixed.rawValue)
            XCTAssertEqual(exportMetadata.timingPrintedToRecording, state.rawValue)
            XCTAssertEqual(takeMetadata.captureQuality, CaptureQuality.mixed.rawValue)
            XCTAssertEqual(takeMetadata.timingPrintedToRecording, state.rawValue)
        }
    }

    func testScratchWithTimingExportMetadataPersistsMixModeAndClickFields() throws {
        let root = try makeTemporaryDirectory()
        let videoURL = try makeLocalRecordingTake(
            in: root,
            sessionID: "scratch-with-timing",
            takeNumber: 1,
            bpm: 95,
            createdAt: Date(timeIntervalSince1970: 1_710_000_980),
            captureTiming: CaptureTimingMetadata(
                clickStartHostTime: 5_555,
                recordingStartHostTime: 6_666
            ),
            useRealMedia: true
        )

        let builder = SessionArchiveBuilder()
        let package = try builder.preparePackage(
            from: .localRecordingSession(
                lastRecordingURL: videoURL,
                sessionName: "Scratch With Timing",
                config: nil
            )
        )
        let exportMetadata = try builder.exportMetadataDocument(
            for: package,
            options: SessionExportOptions(mixMode: .scratchWithTiming)
        )
        let takeMetadata = try XCTUnwrap(exportMetadata.takes.first)

        XCTAssertEqual(exportMetadata.exportMixMode, ExportMixMode.scratchWithTiming.rawValue)
        XCTAssertEqual(exportMetadata.captureQuality, CaptureQuality.processed.rawValue)
        XCTAssertEqual(takeMetadata.exportMixMode, ExportMixMode.scratchWithTiming.rawValue)
        XCTAssertEqual(takeMetadata.captureQuality, CaptureQuality.processed.rawValue)
        XCTAssertEqual(takeMetadata.captureMode, CaptureSessionCaptureMode.timedClick.rawValue)
        XCTAssertTrue(takeMetadata.clickEnabled)
        XCTAssertEqual(takeMetadata.beatEngineMode, BeatEngineMode.clickTrack.rawValue)
        XCTAssertFalse(takeMetadata.beatEnabled)
        XCTAssertEqual(takeMetadata.countInBeats, CaptureClickTrackDefaults.countInBeats)
        XCTAssertEqual(takeMetadata.beatsPerBar, CaptureClickTrackDefaults.beatsPerBar)
        XCTAssertEqual(takeMetadata.clickStartHostTime, 5_555)
        XCTAssertEqual(takeMetadata.recordingStartHostTime, 6_666)
        XCTAssertEqual(takeMetadata.clickVersion, CaptureClickTrackDefaults.clickVersion)
        XCTAssertEqual(takeMetadata.engineVersion, CaptureBeatEngineDefaults.engineVersion)
        XCTAssertEqual(takeMetadata.scratchFile, "mixes/take_001/scratch.wav")
        XCTAssertEqual(takeMetadata.timingFile, "mixes/take_001/timing.wav")
        XCTAssertEqual(takeMetadata.rawTakeFile, "mixes/take_001/raw_take.wav")
    }

    func testTimingOnlyExportMetadataPersistsMixMode() throws {
        let root = try makeTemporaryDirectory()
        let videoURL = try makeLocalRecordingTake(
            in: root,
            sessionID: "timing-only-export",
            takeNumber: 1,
            bpm: 110,
            createdAt: Date(timeIntervalSince1970: 1_710_000_990),
            captureTiming: CaptureTimingMetadata(
                clickStartHostTime: 7_777,
                recordingStartHostTime: 8_888
            ),
            useRealMedia: true
        )

        let builder = SessionArchiveBuilder()
        let package = try builder.preparePackage(
            from: .localRecordingSession(
                lastRecordingURL: videoURL,
                sessionName: "Timing Only",
                config: nil
            )
        )
        let exportMetadata = try builder.exportMetadataDocument(
            for: package,
            options: SessionExportOptions(mixMode: .timingOnly)
        )
        let takeMetadata = try XCTUnwrap(exportMetadata.takes.first)

        XCTAssertEqual(exportMetadata.exportMixMode, ExportMixMode.timingOnly.rawValue)
        XCTAssertEqual(exportMetadata.captureQuality, CaptureQuality.processed.rawValue)
        XCTAssertEqual(takeMetadata.exportMixMode, ExportMixMode.timingOnly.rawValue)
        XCTAssertEqual(takeMetadata.captureQuality, CaptureQuality.processed.rawValue)
        XCTAssertNil(takeMetadata.scratchFile)
        XCTAssertEqual(takeMetadata.timingFile, "mixes/take_001/timing.wav")
        XCTAssertNil(takeMetadata.rawTakeFile)
    }

    func testStemsFolderArchiveIncludesExpectedFilenames() throws {
        let root = try makeTemporaryDirectory()
        let videoURL = try makeLocalRecordingTake(
            in: root,
            sessionID: "stems-folder-export",
            takeNumber: 1,
            bpm: 95,
            createdAt: Date(timeIntervalSince1970: 1_710_001_000),
            captureTiming: CaptureTimingMetadata(
                clickStartHostTime: 9_999,
                recordingStartHostTime: 10_999
            ),
            useRealMedia: true
        )
        let builder = SessionArchiveBuilder()
        let package = try builder.preparePackage(
            from: .localRecordingSession(
                lastRecordingURL: videoURL,
                sessionName: "Stems Folder",
                config: nil
            )
        )
        let archiveDirectory = root.appendingPathComponent("archives", isDirectory: true)
        try FileManager.default.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
        let result = try builder.createArchive(
            from: package,
            options: SessionExportOptions(mixMode: .stemsFolder),
            in: archiveDirectory
        )
        let extractionDirectory = root.appendingPathComponent("unzipped", isDirectory: true)
        let archiveRoot = try unzipArchive(result.archiveURL, to: extractionDirectory)

        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveRoot.appendingPathComponent("stems/take_001/scratch.wav").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveRoot.appendingPathComponent("stems/take_001/timing.wav").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveRoot.appendingPathComponent("stems/take_001/raw_take.wav").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveRoot.appendingPathComponent("manifests/session_metadata.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveRoot.appendingPathComponent("manifests/export_metadata.json").path))
    }

    func testCaptureModeMetadataDoesNotChangeRecordingIdentity() throws {
        let root = try makeTemporaryDirectory()
        let timedSidecar = try makeTestSidecar(
            in: root,
            sessionID: "timed-session",
            takeNumber: 1,
            captureMode: .timedClick
        )
        let calibrationSidecar = try makeTestSidecar(
            in: root,
            sessionID: "calibration-session",
            takeNumber: 1,
            captureMode: .calibrationNoClick
        )

        XCTAssertEqual(timedSidecar.takeID, calibrationSidecar.takeID)
        XCTAssertNotEqual(timedSidecar.recordingIdentity, calibrationSidecar.recordingIdentity)
    }

    func testGuidedCaptureExportHydratesMissingAudioArtifactAndDefaultsSlateFlags() throws {
        let root = try makeTemporaryDirectory()
        let createdAt = Date(timeIntervalSince1970: 1_710_000_600)
        let sessionID = "guided-share-session"
        let takeIdentity = CaptureCore.LocalRecordingNaming.takeIdentity(sessionID: sessionID, takeNumber: 1)
        let videoURL = root.appendingPathComponent("guided.mov")
        let audioURL = root.appendingPathComponent("guided.wav")
        let sidecarURL = root.appendingPathComponent("guided.json")

        try writePlaceholderFile(at: videoURL, contents: Data("mov".utf8))
        try writeTestWAV(at: audioURL)
        try writeFinalizedSidecar(
            to: sidecarURL,
            sessionID: sessionID,
            takeIdentity: takeIdentity,
            mediaURL: videoURL,
            performerName: "DJ Alpha",
            bpm: 90,
            createdAt: createdAt
        )

        let decodedSidecar = try JSONDecoder.captureCoreDecoder.decode(
            CaptureCore.LocalRecordingSidecar.self,
            from: Data(contentsOf: sidecarURL)
        )
        let metadataConfig = SessionExportMetadataResolver.mergedConfig(
            preferredConfig: nil,
            seedSidecar: decodedSidecar,
            sidecars: [decodedSidecar],
            fallbackSessionID: sessionID,
            createdAt: createdAt,
            updatedAt: createdAt.addingTimeInterval(1),
            takeCount: 1,
            totalDurationSeconds: 1
        )
        let package = SessionExportPackage(
            metadata: SessionExportMetadata(
                config: metadataConfig,
                workflow: "guided_capture",
                platform: "iOS",
                sessionName: "Guided Session",
                totalDurationSeconds: 1
            ),
            takes: [
                SessionExportTake(
                    takeID: takeIdentity.takeID,
                    takeNumber: 1,
                    bpm: 90,
                    mediaURL: videoURL,
                    audioArtifactURL: nil,
                    sidecarURL: sidecarURL,
                    watchCaptureSession: nil,
                    drillName: nil,
                    duration: 1,
                    quality: nil,
                    comboTagged: false,
                    audioPresent: nil,
                    motionPresent: false,
                    syncStatus: "notRequested",
                    recordingStatus: "completed",
                    verbalSlateUsed: nil,
                    syncClapUsed: nil,
                    note: ""
                )
            ],
            calibrationData: nil
        )

        let builder = SessionArchiveBuilder { source, _, _ in
            switch source {
            case "camA":
                return [
                    "kind": .string("video"),
                    "duration_seconds": .double(1.0),
                    "width": .int(1920),
                    "height": .int(1080),
                    "frame_rate_fps": .double(30.0),
                    "codec": .string("h264")
                ]
            case "serato":
                return [
                    "kind": .string("audio"),
                    "duration_seconds": .double(1.0),
                    "sample_rate_hz": .int(44_100),
                    "channel_count": .int(1),
                    "frame_count": .int(1_024),
                    "sample_width_bytes": .int(2)
                ]
            default:
                throw SessionExportError.invalidSessionMetadata
            }
        }

        let validatedPackage = try builder.preparePackage(from: .package(package))
        let hydratedTake = try XCTUnwrap(validatedPackage.takes.first)
        XCTAssertEqual(hydratedTake.audioArtifactURL, audioURL)
        XCTAssertEqual(hydratedTake.audioPresent, true)
        XCTAssertEqual(hydratedTake.verbalSlateUsed, false)
        XCTAssertEqual(hydratedTake.syncClapUsed, false)

        let preview = try builder.canonicalPreview(for: validatedPackage)
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: preview.manifestData) as? [String: Any]
        )

        XCTAssertEqual((manifest["allowed_bpms"] as? [Int]) ?? [], [90])
        XCTAssertTrue(preview.takeLogCSV.contains("\"90\",\"1\",\"\",\"\",\"\",\"\",\"false\",\"false\",\"\""))
    }
}

final class CaptureRecoveryPhase2CoreTests: XCTestCase {
    func testInterruptedRecordingIsRecoveredOnRelaunch() throws {
        let root = try makeTemporaryDirectory()
        let auditRoot = root.appendingPathComponent("audit", isDirectory: true)
        let sessionID = "recovery-session"
        let takeIdentity = CaptureCore.LocalRecordingNaming.takeIdentity(sessionID: sessionID, takeNumber: 1)
        let now = Date(timeIntervalSince1970: 1_720_000_100)
        let mediaURL = root.appendingPathComponent("recovery.mov")
        let sidecarURL = root.appendingPathComponent("recovery.json")

        try Data("mov".utf8).write(to: mediaURL, options: .atomic)
        let sidecar = try makeRecordingSidecar(
            sessionID: sessionID,
            takeIdentity: takeIdentity,
            mediaURL: mediaURL,
            sidecarURL: sidecarURL,
            startedAt: now.addingTimeInterval(-5)
        )
        try sidecar.encodedData().write(to: sidecarURL, options: .atomic)

        let report = StagedCaptureRecoveryManager(
            fileManager: .default,
            nowProvider: { now },
            auditRootDirectoryOverride: auditRoot
        ).recoverRecordingDirectory(at: root, storageKind: .routine)

        XCTAssertEqual(report.recoveredInterruptedCount, 1)
        XCTAssertEqual(report.issues.first?.code, .interruptedCaptureRecovered)

        let recovered = try JSONDecoder.captureCoreDecoder.decode(
            CaptureCore.LocalRecordingSidecar.self,
            from: Data(contentsOf: sidecarURL)
        )
        XCTAssertEqual(recovered.recordingStatus, "interrupted")
        XCTAssertEqual(recovered.auditTrail.last?.category, "recovered_interrupted")

        let takeSummaries = try CaptureAuditStore.loadTakeSummaries(
            sessionID: sessionID,
            storageKind: .routine,
            rootDirectoryOverride: auditRoot
        )
        XCTAssertEqual(takeSummaries.count, 1)
        XCTAssertEqual(takeSummaries.first?.recordingStatus, "interrupted")

        let sessionSummary = try XCTUnwrap(
            CaptureAuditStore.loadSessionSummary(
                sessionID: sessionID,
                storageKind: .routine,
                rootDirectoryOverride: auditRoot
            )
        )
        XCTAssertEqual(sessionSummary.interruptedTakeCount, 1)
        XCTAssertEqual(sessionSummary.takeCount, 1)
    }

    func testOrphanedMediaArtifactsAreQuarantined() throws {
        let root = try makeTemporaryDirectory()
        let orphanMovie = root.appendingPathComponent("orphan.mov")
        let orphanAudio = root.appendingPathComponent("orphan.wav")
        try Data("mov".utf8).write(to: orphanMovie, options: .atomic)
        try Data("wav".utf8).write(to: orphanAudio, options: .atomic)

        let report = StagedCaptureRecoveryManager(
            fileManager: .default,
            nowProvider: { Date(timeIntervalSince1970: 1_720_000_200) },
            auditRootDirectoryOverride: root.appendingPathComponent("audit", isDirectory: true)
        ).recoverRecordingDirectory(at: root, storageKind: .routine)

        XCTAssertEqual(report.quarantinedArtifactCount, 2)
        XCTAssertTrue(report.issues.contains(where: { $0.code == .quarantinedOrphanedMedia && $0.fileName == "orphan.mov" }))
        XCTAssertTrue(report.issues.contains(where: { $0.code == .quarantinedOrphanedMedia && $0.fileName == "orphan.wav" }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Quarantine/orphan.mov").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Quarantine/orphan.wav").path))
    }

    func testInterruptedTransactionHistoryAnnotatesOrphanedMediaQuarantine() throws {
        let root = try makeTemporaryDirectory()
        let auditRoot = root.appendingPathComponent("audit", isDirectory: true)
        let sessionID = "transaction-session"
        let takeID = "take-001"
        let orphanMovie = root.appendingPathComponent("transaction.mov")
        try Data("mov".utf8).write(to: orphanMovie, options: .atomic)

        try CaptureJournalStore.appendTransactionBegan(
            storageKind: .routine,
            sessionID: sessionID,
            takeID: takeID,
            sidecarFileName: "transaction.json",
            mediaFileName: "transaction.mov",
            rootDirectoryOverride: auditRoot
        )

        let report = StagedCaptureRecoveryManager(
            fileManager: .default,
            nowProvider: { Date(timeIntervalSince1970: 1_720_000_205) },
            auditRootDirectoryOverride: auditRoot
        ).recoverRecordingDirectory(at: root, storageKind: .routine)

        let issue = try XCTUnwrap(report.issues.first(where: { $0.fileName == "transaction.mov" }))
        XCTAssertEqual(issue.sessionID, sessionID)
        XCTAssertEqual(issue.takeID, takeID)
        XCTAssertTrue(issue.message.localizedCaseInsensitiveContains("interrupted staged write"))
    }

    func testTransactionSnapshotReportsOnlySidecarCommitted() throws {
        let root = try makeTemporaryDirectory()
        let sessionID = "snapshot-sidecar-session"
        let takeID = "take-001"
        let sidecar = try makeRecordingSidecar(
            sessionID: sessionID,
            takeIdentity: CaptureCore.LocalRecordingNaming.takeIdentity(sessionID: sessionID, takeNumber: 1),
            mediaURL: root.appendingPathComponent("snapshot.mov"),
            sidecarURL: root.appendingPathComponent("snapshot.json"),
            startedAt: Date(timeIntervalSince1970: 1_720_000_210)
        )

        try CaptureJournalStore.appendTransactionBegan(
            storageKind: .routine,
            sessionID: sessionID,
            takeID: takeID,
            sidecarFileName: sidecar.sidecarFileName,
            mediaFileName: sidecar.mediaFileName,
            rootDirectoryOverride: root
        )
        try CaptureAuditStore.persist(
            sidecar: sidecar,
            storageKind: .routine,
            rootDirectoryOverride: root
        )

        let snapshot = try XCTUnwrap(
            CaptureJournalStore.loadTransactionSnapshots(
                storageKind: .routine,
                sessionID: sessionID,
                takeID: takeID,
                rootDirectoryOverride: root
            ).first
        )
        XCTAssertEqual(snapshot.state, .sidecarCommittedAwaitingMedia)
    }

    func testTransactionSnapshotReportsMediaCommittedWithoutFinalize() throws {
        let root = try makeTemporaryDirectory()
        let sessionID = "snapshot-media-session"
        let takeID = "take-001"
        let sidecar = try makeRecordingSidecar(
            sessionID: sessionID,
            takeIdentity: CaptureCore.LocalRecordingNaming.takeIdentity(sessionID: sessionID, takeNumber: 1),
            mediaURL: root.appendingPathComponent("snapshot.mov"),
            sidecarURL: root.appendingPathComponent("snapshot.json"),
            startedAt: Date(timeIntervalSince1970: 1_720_000_220)
        )

        try CaptureJournalStore.appendTransactionBegan(
            storageKind: .routine,
            sessionID: sessionID,
            takeID: takeID,
            sidecarFileName: sidecar.sidecarFileName,
            mediaFileName: sidecar.mediaFileName,
            rootDirectoryOverride: root
        )
        try CaptureJournalStore.appendMediaCommitted(
            storageKind: .routine,
            sidecar: sidecar,
            rootDirectoryOverride: root
        )

        let snapshot = try XCTUnwrap(
            CaptureJournalStore.loadTransactionSnapshots(
                storageKind: .routine,
                sessionID: sessionID,
                takeID: takeID,
                rootDirectoryOverride: root
            ).first
        )
        XCTAssertEqual(snapshot.state, .mediaCommittedAwaitingFinalize)
    }

    func testWatchCaptureIsLinkedDuringReconciliation() throws {
        let root = try makeTemporaryDirectory()
        let watchRoot = root.appendingPathComponent("watch", isDirectory: true)
        let sidecarRoot = root.appendingPathComponent("sidecars", isDirectory: true)
        let auditRoot = root.appendingPathComponent("audit", isDirectory: true)
        try FileManager.default.createDirectory(at: watchRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sidecarRoot, withIntermediateDirectories: true)

        let sessionID = "watch-link-session"
        let takeIdentity = CaptureCore.LocalRecordingNaming.takeIdentity(sessionID: sessionID, takeNumber: 1)
        let mediaURL = sidecarRoot.appendingPathComponent("linked.mov")
        let sidecarURL = sidecarRoot.appendingPathComponent("linked.json")
        try Data("mov".utf8).write(to: mediaURL, options: .atomic)
        try makeCompletedSidecar(
            sessionID: sessionID,
            takeIdentity: takeIdentity,
            mediaURL: mediaURL,
            sidecarURL: sidecarURL
        )

        let watchSession = makeWatchSession(
            sessionID: sessionID,
            takeID: takeIdentity.takeID,
            syncState: .acknowledged
        )
        let watchURL = watchRoot.appendingPathComponent("watch-\(takeIdentity.takeID).json")
        try WatchMotionCaptureCodec.encoder.encode(watchSession).write(to: watchURL, options: .atomic)

        let report = StagedCaptureRecoveryManager(
            fileManager: .default,
            nowProvider: { Date(timeIntervalSince1970: 1_720_000_300) },
            auditRootDirectoryOverride: auditRoot
        ).reconcileWatchDirectory(
            at: watchRoot,
            storageKind: .relayedWatch,
            sidecarDirectories: [sidecarRoot],
            sidecarStorageKind: .routine
        )

        XCTAssertTrue(report.issues.contains(where: { $0.code == .linkedWatchCapture }))

        let updated = try JSONDecoder.captureCoreDecoder.decode(
            CaptureCore.LocalRecordingSidecar.self,
            from: Data(contentsOf: sidecarURL)
        )
        XCTAssertEqual(updated.linkedMotionFileName, watchURL.lastPathComponent)
        XCTAssertEqual(updated.auditTrail.last?.category, "watch_reconciled")

        let summary = try XCTUnwrap(
            CaptureAuditStore.loadSessionSummary(
                sessionID: sessionID,
                storageKind: .routine,
                rootDirectoryOverride: auditRoot
            )
        )
        XCTAssertEqual(summary.linkedWatchTakeCount, 1)
    }

    func testUnlinkedWatchCaptureIsQuarantined() throws {
        let root = try makeTemporaryDirectory()
        let watchRoot = root.appendingPathComponent("watch", isDirectory: true)
        let sidecarRoot = root.appendingPathComponent("sidecars", isDirectory: true)
        try FileManager.default.createDirectory(at: watchRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sidecarRoot, withIntermediateDirectories: true)

        let watchSession = makeWatchSession(
            sessionID: "missing-session",
            takeID: "take-001",
            syncState: .failed
        )
        let watchURL = watchRoot.appendingPathComponent("orphan-watch.json")
        try WatchMotionCaptureCodec.encoder.encode(watchSession).write(to: watchURL, options: .atomic)

        let report = StagedCaptureRecoveryManager(
            fileManager: .default,
            nowProvider: { Date(timeIntervalSince1970: 1_720_000_400) },
            auditRootDirectoryOverride: root.appendingPathComponent("audit", isDirectory: true)
        ).reconcileWatchDirectory(
            at: watchRoot,
            storageKind: .importedWatch,
            sidecarDirectories: [sidecarRoot],
            sidecarStorageKind: .companion
        )

        XCTAssertTrue(report.issues.contains(where: { $0.code == .quarantinedUnlinkedWatchCapture }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: watchRoot.appendingPathComponent("Quarantine/orphan-watch.json").path))
    }

    func testLocalRecordingSessionValidationReportsInterruptedTake() throws {
        let root = try makeTemporaryDirectory()
        let sessionID = "validation-session"
        let createdAt = Date(timeIntervalSince1970: 1_720_000_500)
        let seedBaseName = CaptureCore.LocalRecordingNaming.baseName(
            sessionID: sessionID,
            takeNumber: 1,
            roleLabel: "guided"
        )
        let interruptedBaseName = CaptureCore.LocalRecordingNaming.baseName(
            sessionID: sessionID,
            takeNumber: 2,
            roleLabel: "guided"
        )
        let seedURL = root.appendingPathComponent(seedBaseName).appendingPathExtension("mov")
        let seedSidecarURL = root.appendingPathComponent(seedBaseName).appendingPathExtension("json")
        let interruptedURL = root.appendingPathComponent(interruptedBaseName).appendingPathExtension("mov")
        let interruptedSidecarURL = root.appendingPathComponent(interruptedBaseName).appendingPathExtension("json")
        try Data("mov".utf8).write(to: seedURL, options: .atomic)
        try Data("mov".utf8).write(to: interruptedURL, options: .atomic)

        try makeCompletedSidecar(
            sessionID: sessionID,
            takeIdentity: CaptureCore.LocalRecordingNaming.takeIdentity(sessionID: sessionID, takeNumber: 1),
            mediaURL: seedURL,
            sidecarURL: seedSidecarURL,
            createdAt: createdAt
        )

        var interrupted = try makeRecordingSidecar(
            sessionID: sessionID,
            takeIdentity: CaptureCore.LocalRecordingNaming.takeIdentity(sessionID: sessionID, takeNumber: 2),
            mediaURL: interruptedURL,
            sidecarURL: interruptedSidecarURL,
            startedAt: createdAt.addingTimeInterval(1)
        )
        interrupted.recordingStatus = "interrupted"
        interrupted.endedAt = createdAt.addingTimeInterval(2)
        interrupted.errorDescription = "Recovered after interruption."
        try interrupted.encodedData().write(to: interruptedSidecarURL, options: .atomic)

        let config = CaptureSessionConfig(
            performerName: "DJ Alpha",
            bpm: 70,
            scratchType: .babyScratch,
            drillMode: .fullCapture,
            takeDurationSeconds: 1,
            takeCount: 2,
            handedness: .right,
            notes: "",
            sessionID: sessionID,
            createdAt: createdAt,
            updatedAt: createdAt
        )

        let report = SessionArchiveBuilder().validationReport(
            for: .localRecordingSession(lastRecordingURL: seedURL, sessionName: "Recovered Session", config: config)
        )

        XCTAssertNotNil(report)
        XCTAssertEqual(report?.suggestedError, .invalidSessionMetadata)
        XCTAssertTrue(report?.issues.contains(where: { $0.contains("take-002") && $0.localizedCaseInsensitiveContains("interrupted") }) == true)
    }

    @MainActor
    func testStagingInspectorSummarizesBlockedRoutineSession() throws {
        let root = try makeTemporaryDirectory()
        let captureRoot = root.appendingPathComponent("routine", isDirectory: true)
        let auditRoot = root.appendingPathComponent("audit", isDirectory: true)
        let journalRoot = root.appendingPathComponent("journal", isDirectory: true)
        try FileManager.default.createDirectory(at: captureRoot, withIntermediateDirectories: true)

        let sessionID = "inspector-routine-session"
        let takeIdentity = CaptureCore.LocalRecordingNaming.takeIdentity(sessionID: sessionID, takeNumber: 1)
        let mediaURL = captureRoot.appendingPathComponent("routine.mov")
        let sidecarURL = captureRoot.appendingPathComponent("routine.json")
        try Data("mov".utf8).write(to: mediaURL, options: .atomic)
        try makeCompletedSidecar(
            sessionID: sessionID,
            takeIdentity: takeIdentity,
            mediaURL: mediaURL,
            sidecarURL: sidecarURL
        )

        let sidecar = try JSONDecoder.captureCoreDecoder.decode(
            CaptureCore.LocalRecordingSidecar.self,
            from: Data(contentsOf: sidecarURL)
        )
        try CaptureAuditStore.persist(
            sidecar: sidecar,
            storageKind: .routine,
            rootDirectoryOverride: auditRoot
        )

        let context = StagingInspectorContext(
            storageKind: .routine,
            title: "Routine Capture",
            actionTitle: "Re-scan",
            captureDirectoryURLProvider: { captureRoot },
            statusTextProvider: { "Routine capture blocked." },
            runAction: nil,
            validationReportProvider: { _, _, _ in
                SessionValidationReport(
                    suggestedError: .invalidSessionMetadata,
                    issues: [
                        "Take \(takeIdentity.takeID) is missing its audio artifact.",
                        "Take \(takeIdentity.takeID) is not export-ready."
                    ]
                )
            }
        )

        let store = StagingInspectorStore(
            context: context,
            auditRootDirectoryOverride: auditRoot,
            journalRootDirectoryOverride: journalRoot
        )

        XCTAssertEqual(store.latestStatusText, "Routine capture blocked.")
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions.first?.summary.sessionID, sessionID)
        XCTAssertEqual(store.sessions.first?.exportReadinessLabel, "Blocked")
        XCTAssertEqual(
            store.sessions.first?.blockingIssues,
            [
                "Take \(takeIdentity.takeID) is missing its audio artifact.",
                "Take \(takeIdentity.takeID) is not export-ready."
            ]
        )
        XCTAssertEqual(store.sessions.first?.takes.first?.summary.takeID, takeIdentity.takeID)
    }

    @MainActor
    func testStagingInspectorSurfacesQuarantineAndJournalEntries() throws {
        let root = try makeTemporaryDirectory()
        let captureRoot = root.appendingPathComponent("watch", isDirectory: true)
        let journalRoot = root.appendingPathComponent("journal", isDirectory: true)
        try FileManager.default.createDirectory(
            at: captureRoot.appendingPathComponent("Quarantine", isDirectory: true),
            withIntermediateDirectories: true
        )

        let quarantinedURL = captureRoot
            .appendingPathComponent("Quarantine", isDirectory: true)
            .appendingPathComponent("orphan-watch.json")
        try Data("watch".utf8).write(to: quarantinedURL, options: .atomic)

        try CaptureJournalStore.append(
            CaptureJournalEntry(
                timestamp: Date(timeIntervalSince1970: 1_720_000_700),
                storageKind: .relayedWatch,
                kind: .artifactQuarantined,
                message: "Watch capture was quarantined because no matching take exists.",
                sessionID: "session-z",
                takeID: "take-001",
                fileName: quarantinedURL.lastPathComponent
            ),
            rootDirectoryOverride: journalRoot
        )

        let context = StagingInspectorContext(
            storageKind: .relayedWatch,
            title: "Relayed Watch Capture",
            actionTitle: nil,
            captureDirectoryURLProvider: { captureRoot },
            statusTextProvider: { "Relayed watch capture needs review." },
            runAction: nil,
            validationReportProvider: nil
        )

        let store = StagingInspectorStore(
            context: context,
            auditRootDirectoryOverride: root.appendingPathComponent("audit", isDirectory: true),
            journalRootDirectoryOverride: journalRoot
        )

        XCTAssertEqual(store.quarantineItems.count, 1)
        XCTAssertEqual(store.quarantineItems.first?.fileName, "orphan-watch.json")
        XCTAssertEqual(
            store.quarantineItems.first?.message,
            "Watch capture was quarantined because no matching take exists."
        )
        XCTAssertEqual(store.quarantineItems.first?.journalEntries.first?.kind, .artifactQuarantined)
        XCTAssertEqual(store.recentJournalEntries.count, 1)
        XCTAssertEqual(store.recentJournalEntries.first?.kind, .artifactQuarantined)
    }

    @MainActor
    func testAmbiguousQuarantineRestoreRemainsBlocked() throws {
        let root = try makeTemporaryDirectory()
        let captureRoot = root.appendingPathComponent("watch", isDirectory: true)
        let journalRoot = root.appendingPathComponent("journal", isDirectory: true)
        let quarantineRoot = captureRoot.appendingPathComponent("Quarantine", isDirectory: true)
        try FileManager.default.createDirectory(at: quarantineRoot, withIntermediateDirectories: true)

        let quarantinedURL = quarantineRoot.appendingPathComponent("ambiguous-watch.json")
        try Data("watch".utf8).write(to: quarantinedURL, options: .atomic)
        try CaptureJournalStore.append(
            CaptureJournalEntry(
                timestamp: Date(timeIntervalSince1970: 1_720_000_710),
                storageKind: .relayedWatch,
                kind: .artifactQuarantined,
                message: "Ambiguous quarantined watch artifact.",
                sessionID: "session-a",
                takeID: "take-001",
                transactionID: CaptureJournalEntry.transactionID(sessionID: "session-a", takeID: "take-001"),
                fileName: "ambiguous-watch.json",
                artifactRole: .watch,
                relatedFileNames: ["ambiguous-watch.json"],
                decisionReason: "Candidate A"
            ),
            rootDirectoryOverride: journalRoot
        )
        try CaptureJournalStore.append(
            CaptureJournalEntry(
                timestamp: Date(timeIntervalSince1970: 1_720_000_711),
                storageKind: .relayedWatch,
                kind: .artifactQuarantined,
                message: "Ambiguous quarantined watch artifact.",
                sessionID: "session-b",
                takeID: "take-002",
                transactionID: CaptureJournalEntry.transactionID(sessionID: "session-b", takeID: "take-002"),
                fileName: "ambiguous-watch.json",
                artifactRole: .watch,
                relatedFileNames: ["ambiguous-watch.json"],
                decisionReason: "Candidate B"
            ),
            rootDirectoryOverride: journalRoot
        )

        let context = StagingInspectorContext(
            storageKind: .relayedWatch,
            title: "Relayed Watch Capture",
            actionTitle: nil,
            captureDirectoryURLProvider: { captureRoot },
            statusTextProvider: { "Review quarantine." },
            runAction: nil,
            validationReportProvider: nil
        )
        let store = StagingInspectorStore(
            context: context,
            auditRootDirectoryOverride: root.appendingPathComponent("audit", isDirectory: true),
            journalRootDirectoryOverride: journalRoot
        )

        let item = try XCTUnwrap(store.quarantineItems.first)
        XCTAssertTrue(item.isRestoreAmbiguous)
        store.restoreQuarantineItem(item)
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantinedURL.path))
        XCTAssertTrue(store.latestStatusText.localizedCaseInsensitiveContains("multiple candidate"))
    }

    @MainActor
    func testStagingInspectorRunRecoveryActionRefreshesInspectorState() throws {
        let root = try makeTemporaryDirectory()
        let captureRoot = root.appendingPathComponent("companion", isDirectory: true)
        let auditRoot = root.appendingPathComponent("audit", isDirectory: true)
        let journalRoot = root.appendingPathComponent("journal", isDirectory: true)
        try FileManager.default.createDirectory(at: captureRoot, withIntermediateDirectories: true)

        final class Probe {
            var statusText = "Before re-scan"
            var actionCount = 0
        }
        let probe = Probe()
        let sessionID = "rescan-session"
        let takeIdentity = CaptureCore.LocalRecordingNaming.takeIdentity(sessionID: sessionID, takeNumber: 1)

        let context = StagingInspectorContext(
            storageKind: .companion,
            title: "Companion Capture",
            actionTitle: "Re-scan",
            captureDirectoryURLProvider: { captureRoot },
            statusTextProvider: { probe.statusText },
            runAction: {
                probe.actionCount += 1
                probe.statusText = "After re-scan"
                let mediaURL = captureRoot.appendingPathComponent("capture.mov")
                let sidecarURL = captureRoot.appendingPathComponent("capture.json")
                try? Data("mov".utf8).write(to: mediaURL, options: .atomic)
                try? self.makeCompletedSidecar(
                    sessionID: sessionID,
                    takeIdentity: takeIdentity,
                    mediaURL: mediaURL,
                    sidecarURL: sidecarURL,
                    createdAt: Date(timeIntervalSince1970: 1_720_000_800)
                )
                if let sidecarData = try? Data(contentsOf: sidecarURL),
                   let sidecar = try? JSONDecoder.captureCoreDecoder.decode(
                    CaptureCore.LocalRecordingSidecar.self,
                    from: sidecarData
                   ) {
                    try? CaptureAuditStore.persist(
                        sidecar: sidecar,
                        storageKind: .companion,
                        rootDirectoryOverride: auditRoot
                    )
                }
                try? CaptureJournalStore.append(
                    CaptureJournalEntry(
                        timestamp: Date(timeIntervalSince1970: 1_720_000_801),
                        storageKind: .companion,
                        kind: .recoveryScanCompleted,
                        message: "Operator requested a re-scan.",
                        sessionID: sessionID,
                        takeID: takeIdentity.takeID
                    ),
                    rootDirectoryOverride: journalRoot
                )
            },
            validationReportProvider: { _, _, _ in nil }
        )

        let store = StagingInspectorStore(
            context: context,
            auditRootDirectoryOverride: auditRoot,
            journalRootDirectoryOverride: journalRoot
        )

        XCTAssertEqual(store.latestStatusText, "Before re-scan")
        XCTAssertTrue(store.sessions.isEmpty)

        store.runRecoveryAction()

        XCTAssertEqual(probe.actionCount, 1)
        XCTAssertEqual(store.latestStatusText, "After re-scan")
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions.first?.summary.sessionID, sessionID)
        XCTAssertEqual(store.recentJournalEntries.first?.kind, .recoveryScanCompleted)
    }

    @MainActor
    func testStagingInspectorShowsTakeArtifactHistory() throws {
        let root = try makeTemporaryDirectory()
        let captureRoot = root.appendingPathComponent("routine", isDirectory: true)
        let auditRoot = root.appendingPathComponent("audit", isDirectory: true)
        let journalRoot = root.appendingPathComponent("journal", isDirectory: true)
        try FileManager.default.createDirectory(at: captureRoot, withIntermediateDirectories: true)

        let sessionID = "history-session"
        let takeIdentity = CaptureCore.LocalRecordingNaming.takeIdentity(sessionID: sessionID, takeNumber: 1)
        let mediaURL = captureRoot.appendingPathComponent("history.mov")
        let sidecarURL = captureRoot.appendingPathComponent("history.json")
        try Data("mov".utf8).write(to: mediaURL, options: .atomic)
        try makeCompletedSidecar(
            sessionID: sessionID,
            takeIdentity: takeIdentity,
            mediaURL: mediaURL,
            sidecarURL: sidecarURL
        )
        let sidecar = try JSONDecoder.captureCoreDecoder.decode(
            CaptureCore.LocalRecordingSidecar.self,
            from: Data(contentsOf: sidecarURL)
        )
        try CaptureAuditStore.persist(sidecar: sidecar, storageKind: .routine, rootDirectoryOverride: auditRoot)
        try CaptureJournalStore.appendTransactionBegan(
            storageKind: .routine,
            sessionID: sessionID,
            takeID: takeIdentity.takeID,
            sidecarFileName: sidecar.sidecarFileName,
            mediaFileName: sidecar.mediaFileName,
            rootDirectoryOverride: journalRoot
        )
        try CaptureJournalStore.appendMediaCommitted(
            storageKind: .routine,
            sidecar: sidecar,
            rootDirectoryOverride: journalRoot
        )
        try CaptureJournalStore.appendTransactionFinalized(
            storageKind: .routine,
            sidecar: sidecar,
            rootDirectoryOverride: journalRoot
        )

        let context = StagingInspectorContext(
            storageKind: .routine,
            title: "Routine Capture",
            actionTitle: nil,
            captureDirectoryURLProvider: { captureRoot },
            statusTextProvider: { "History ready." },
            runAction: nil,
            validationReportProvider: { _, _, _ in nil }
        )

        let store = StagingInspectorStore(
            context: context,
            auditRootDirectoryOverride: auditRoot,
            journalRootDirectoryOverride: journalRoot
        )

        let take = try XCTUnwrap(store.sessions.first?.takes.first)
        let historyKinds = take.journalEntries.map(\.kind)
        XCTAssertTrue(historyKinds.contains(.mediaWriteCommitted))
        XCTAssertTrue(historyKinds.contains(.transactionBegan))
        XCTAssertTrue(historyKinds.contains(.transactionFinalized))
    }

    @MainActor
    func testQuarantineRestoreMovesArtifactBackToStagingAndJournals() throws {
        let root = try makeTemporaryDirectory()
        let captureRoot = root.appendingPathComponent("watch", isDirectory: true)
        let journalRoot = root.appendingPathComponent("journal", isDirectory: true)
        let quarantineRoot = captureRoot.appendingPathComponent("Quarantine", isDirectory: true)
        try FileManager.default.createDirectory(at: quarantineRoot, withIntermediateDirectories: true)

        let quarantinedURL = quarantineRoot.appendingPathComponent("restore-watch.json")
        try Data("watch".utf8).write(to: quarantinedURL, options: .atomic)
        try CaptureJournalStore.append(
            CaptureJournalEntry(
                timestamp: Date(timeIntervalSince1970: 1_720_000_900),
                storageKind: .relayedWatch,
                kind: .artifactQuarantined,
                message: "Watch capture was quarantined for review.",
                sessionID: "restore-session",
                takeID: "take-001",
                transactionID: CaptureJournalEntry.transactionID(sessionID: "restore-session", takeID: "take-001"),
                fileName: "restore-watch.json",
                relatedFileNames: ["restore-watch.json"]
            ),
            rootDirectoryOverride: journalRoot
        )

        let context = StagingInspectorContext(
            storageKind: .relayedWatch,
            title: "Relayed Watch Capture",
            actionTitle: nil,
            captureDirectoryURLProvider: { captureRoot },
            statusTextProvider: { "Review quarantine." },
            runAction: nil,
            validationReportProvider: nil
        )
        let store = StagingInspectorStore(
            context: context,
            auditRootDirectoryOverride: root.appendingPathComponent("audit", isDirectory: true),
            journalRootDirectoryOverride: journalRoot
        )

        let item = try XCTUnwrap(store.quarantineItems.first)
        store.restoreQuarantineItem(item)

        XCTAssertTrue(FileManager.default.fileExists(atPath: captureRoot.appendingPathComponent("restore-watch.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantinedURL.path))
        let entries = try CaptureJournalStore.loadEntries(
            storageKind: .relayedWatch,
            fileName: "restore-watch.json",
            rootDirectoryOverride: journalRoot
        )
        XCTAssertEqual(entries.first?.kind, .quarantineItemRestored)
    }

    @MainActor
    func testRestoreFollowedByExplicitRescanUpdatesInspectorState() throws {
        let root = try makeTemporaryDirectory()
        let captureRoot = root.appendingPathComponent("watch", isDirectory: true)
        let sidecarRoot = root.appendingPathComponent("sidecars", isDirectory: true)
        let auditRoot = root.appendingPathComponent("audit", isDirectory: true)
        let journalRoot = root.appendingPathComponent("journal", isDirectory: true)
        let quarantineRoot = captureRoot.appendingPathComponent("Quarantine", isDirectory: true)
        try FileManager.default.createDirectory(at: quarantineRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sidecarRoot, withIntermediateDirectories: true)

        let sessionID = "restore-rescan-session"
        let takeIdentity = CaptureCore.LocalRecordingNaming.takeIdentity(sessionID: sessionID, takeNumber: 1)
        let mediaURL = sidecarRoot.appendingPathComponent("linked.mov")
        let sidecarURL = sidecarRoot.appendingPathComponent("linked.json")
        try Data("mov".utf8).write(to: mediaURL, options: .atomic)
        try makeCompletedSidecar(
            sessionID: sessionID,
            takeIdentity: takeIdentity,
            mediaURL: mediaURL,
            sidecarURL: sidecarURL
        )

        let watchSession = makeWatchSession(
            sessionID: sessionID,
            takeID: takeIdentity.takeID,
            syncState: .acknowledged
        )
        let quarantinedURL = quarantineRoot.appendingPathComponent("restore-rescan-watch.json")
        try WatchMotionCaptureCodec.encoder.encode(watchSession).write(to: quarantinedURL, options: .atomic)
        try CaptureJournalStore.append(
            CaptureJournalEntry(
                timestamp: Date(timeIntervalSince1970: 1_720_000_915),
                storageKind: .relayedWatch,
                kind: .artifactQuarantined,
                message: "Watch capture was quarantined pending operator review.",
                sessionID: sessionID,
                takeID: takeIdentity.takeID,
                transactionID: CaptureJournalEntry.transactionID(sessionID: sessionID, takeID: takeIdentity.takeID),
                fileName: quarantinedURL.lastPathComponent,
                artifactRole: .watch,
                relatedFileNames: [quarantinedURL.lastPathComponent],
                decisionReason: "Restorable linked watch artifact."
            ),
            rootDirectoryOverride: journalRoot
        )

        let context = StagingInspectorContext(
            storageKind: .relayedWatch,
            title: "Relayed Watch Capture",
            actionTitle: "Reconcile",
            captureDirectoryURLProvider: { captureRoot },
            statusTextProvider: { "Needs reconcile." },
            runAction: {
                _ = StagedCaptureRecoveryManager(
                    fileManager: .default,
                    nowProvider: { Date(timeIntervalSince1970: 1_720_000_916) },
                    auditRootDirectoryOverride: auditRoot
                ).reconcileWatchDirectory(
                    at: captureRoot,
                    storageKind: .relayedWatch,
                    sidecarDirectories: [sidecarRoot],
                    sidecarStorageKind: .routine
                )
            },
            validationReportProvider: nil
        )
        let store = StagingInspectorStore(
            context: context,
            auditRootDirectoryOverride: auditRoot,
            journalRootDirectoryOverride: journalRoot
        )

        let item = try XCTUnwrap(store.quarantineItems.first)
        store.restoreQuarantineItem(item)
        store.runRecoveryAction()

        XCTAssertTrue(store.quarantineItems.isEmpty)
        let summary = try XCTUnwrap(
            CaptureAuditStore.loadSessionSummary(
                sessionID: sessionID,
                storageKind: .routine,
                rootDirectoryOverride: auditRoot
            )
        )
        XCTAssertEqual(summary.linkedWatchTakeCount, 1)
    }

    func testStartupRecoveryPreservesDeterministicJournalAndAuditState() throws {
        let root = try makeTemporaryDirectory()
        let auditRoot = root.appendingPathComponent("audit", isDirectory: true)
        let sessionID = "startup-recovery-session"
        let takeIdentity = CaptureCore.LocalRecordingNaming.takeIdentity(sessionID: sessionID, takeNumber: 1)
        let mediaURL = root.appendingPathComponent("startup.mov")
        let sidecarURL = root.appendingPathComponent("startup.json")
        try Data("mov".utf8).write(to: mediaURL, options: .atomic)
        let recordingSidecar = try makeRecordingSidecar(
            sessionID: sessionID,
            takeIdentity: takeIdentity,
            mediaURL: mediaURL,
            sidecarURL: sidecarURL,
            startedAt: Date(timeIntervalSince1970: 1_720_000_930)
        )
        try recordingSidecar.encodedData().write(to: sidecarURL, options: .atomic)
        try CaptureJournalStore.appendTransactionBegan(
            storageKind: .routine,
            sessionID: sessionID,
            takeID: takeIdentity.takeID,
            sidecarFileName: recordingSidecar.sidecarFileName,
            mediaFileName: recordingSidecar.mediaFileName,
            rootDirectoryOverride: auditRoot
        )
        try CaptureAuditStore.persist(
            sidecar: recordingSidecar,
            storageKind: .routine,
            rootDirectoryOverride: auditRoot
        )

        _ = StagedCaptureRecoveryManager(
            fileManager: .default,
            nowProvider: { Date(timeIntervalSince1970: 1_720_000_931) },
            auditRootDirectoryOverride: auditRoot
        ).recoverRecordingDirectory(at: root, storageKind: .routine)

        let snapshot = try XCTUnwrap(
            CaptureJournalStore.loadTransactionSnapshots(
                storageKind: .routine,
                sessionID: sessionID,
                takeID: takeIdentity.takeID,
                rootDirectoryOverride: auditRoot
            ).first
        )
        XCTAssertEqual(snapshot.state, .sidecarCommittedAwaitingMedia)
        let takeSummary = try XCTUnwrap(
            CaptureAuditStore.loadTakeSummaries(
                sessionID: sessionID,
                storageKind: .routine,
                rootDirectoryOverride: auditRoot
            ).first
        )
        XCTAssertEqual(takeSummary.recordingStatus, "interrupted")
    }

    @MainActor
    func testUploadPreparationPreservesDetailedValidationBlockReporting() async throws {
        let root = try makeTemporaryDirectory()
        let journalRoot = root.appendingPathComponent("journal", isDirectory: true)
        let captureRoot = root.appendingPathComponent("CompanionCaptures", isDirectory: true)
        try FileManager.default.createDirectory(at: captureRoot, withIntermediateDirectories: true)

        let sessionID = "upload-block-session"
        let takeIdentity = CaptureCore.LocalRecordingNaming.takeIdentity(sessionID: sessionID, takeNumber: 1)
        let mediaURL = captureRoot.appendingPathComponent(
            CaptureCore.LocalRecordingNaming.baseName(sessionID: sessionID, takeNumber: 1, roleLabel: "guided")
        ).appendingPathExtension("mov")
        let sidecarURL = CaptureCore.LocalRecordingFiles.sidecarURL(forMediaURL: mediaURL)
        try Data("mov".utf8).write(to: mediaURL, options: .atomic)
        try makeCompletedSidecar(
            sessionID: sessionID,
            takeIdentity: takeIdentity,
            mediaURL: mediaURL,
            sidecarURL: sidecarURL
        )

        let config = CaptureSessionConfig(
            performerName: "DJ Alpha",
            bpm: 70,
            scratchType: .babyScratch,
            drillMode: .fullCapture,
            takeDurationSeconds: 1,
            takeCount: 1,
            handedness: .right,
            notes: "",
            sessionID: sessionID,
            createdAt: Date(timeIntervalSince1970: 1_720_000_940),
            updatedAt: Date(timeIntervalSince1970: 1_720_000_940)
        )

        let coordinator = SessionExportCoordinator(journalRootDirectoryOverride: journalRoot)
        coordinator.prepareShare(
            for: .localRecordingSession(
                lastRecordingURL: mediaURL,
                sessionName: "Upload Blocked",
                config: config
            )
        )

        for _ in 0..<40 {
            if coordinator.validationReport != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let report = try XCTUnwrap(coordinator.validationReport)
        XCTAssertTrue(report.issues.contains(where: { $0.localizedCaseInsensitiveContains("audio artifact") }))
        let journalEntries = try CaptureJournalStore.loadEntries(
            storageKind: .companion,
            sessionID: sessionID,
            fileManager: .default,
            rootDirectoryOverride: journalRoot
        )
        XCTAssertEqual(journalEntries.first?.kind, .validationBlocked)
        XCTAssertEqual(journalEntries.first?.decisionReason, report.issues.joined(separator: " | "))
    }

    @MainActor
    func testQuarantineDeleteRemovesArtifactAndJournals() throws {
        let root = try makeTemporaryDirectory()
        let captureRoot = root.appendingPathComponent("watch", isDirectory: true)
        let journalRoot = root.appendingPathComponent("journal", isDirectory: true)
        let quarantineRoot = captureRoot.appendingPathComponent("Quarantine", isDirectory: true)
        try FileManager.default.createDirectory(at: quarantineRoot, withIntermediateDirectories: true)

        let quarantinedURL = quarantineRoot.appendingPathComponent("delete-watch.json")
        try Data("watch".utf8).write(to: quarantinedURL, options: .atomic)

        let context = StagingInspectorContext(
            storageKind: .relayedWatch,
            title: "Relayed Watch Capture",
            actionTitle: nil,
            captureDirectoryURLProvider: { captureRoot },
            statusTextProvider: { "Review quarantine." },
            runAction: nil,
            validationReportProvider: nil
        )
        let store = StagingInspectorStore(
            context: context,
            auditRootDirectoryOverride: root.appendingPathComponent("audit", isDirectory: true),
            journalRootDirectoryOverride: journalRoot
        )

        let item = try XCTUnwrap(store.quarantineItems.first)
        store.deleteQuarantineItem(item)

        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantinedURL.path))
        let entries = try CaptureJournalStore.loadEntries(
            storageKind: .relayedWatch,
            fileName: "delete-watch.json",
            rootDirectoryOverride: journalRoot
        )
        XCTAssertEqual(entries.first?.kind, .quarantineItemDeleted)
    }

    @MainActor
    func testInspectorOverviewSummarizesBlockedSessionsAndNextSteps() throws {
        let harness = try makeStagingOperationsHarness(storageKind: .routine)
        let sessionID = "inspector-overview-session"
        let takeIdentity = CaptureCore.LocalRecordingNaming.takeIdentity(sessionID: sessionID, takeNumber: 1)
        let mediaURL = harness.captureRoot.appendingPathComponent("overview.mov")
        let sidecarURL = harness.captureRoot.appendingPathComponent("overview.json")
        try Data("mov".utf8).write(to: mediaURL, options: .atomic)
        let sidecar = try makeRecordingSidecar(
            sessionID: sessionID,
            takeIdentity: takeIdentity,
            mediaURL: mediaURL,
            sidecarURL: sidecarURL,
            startedAt: Date(timeIntervalSince1970: 1_720_001_000)
        )
        try sidecar.encodedData().write(to: sidecarURL, options: .atomic)

        _ = StagedCaptureRecoveryManager(
            fileManager: .default,
            nowProvider: { Date(timeIntervalSince1970: 1_720_001_010) },
            auditRootDirectoryOverride: harness.auditRoot
        ).recoverRecordingDirectory(at: harness.captureRoot, storageKind: .routine)

        let store = StagingInspectorStore(
            context: harness.makeContext(
                statusText: { "Routine staging needs review." },
                validationReportProvider: { _, _, _ in
                    SessionValidationReport(
                        suggestedError: .invalidSessionMetadata,
                        issues: ["Interrupted take must be reviewed before export."]
                    )
                }
            ),
            auditRootDirectoryOverride: harness.auditRoot,
            journalRootDirectoryOverride: harness.journalRoot
        )

        XCTAssertEqual(store.blockedSessionCount, 1)
        XCTAssertEqual(store.readySessionCount, 0)
        XCTAssertEqual(store.sessions.first?.nextActionText, "Review interrupted takes before attempting export again.")
    }

    @MainActor
    func testInspectorQuarantineGuidanceKeepsAmbiguousRestoreBlocked() throws {
        let harness = try makeStagingOperationsHarness(storageKind: .relayedWatch)
        let quarantineRoot = harness.captureRoot.appendingPathComponent("Quarantine", isDirectory: true)
        try FileManager.default.createDirectory(at: quarantineRoot, withIntermediateDirectories: true)

        let quarantinedURL = quarantineRoot.appendingPathComponent("ambiguous-watch.json")
        try Data("watch".utf8).write(to: quarantinedURL, options: .atomic)
        try CaptureJournalStore.append(
            CaptureJournalEntry(
                timestamp: Date(timeIntervalSince1970: 1_720_001_020),
                storageKind: .relayedWatch,
                kind: .artifactQuarantined,
                message: "Ambiguous quarantined watch artifact.",
                sessionID: "session-a",
                takeID: "take-001",
                transactionID: CaptureJournalEntry.transactionID(sessionID: "session-a", takeID: "take-001"),
                fileName: "ambiguous-watch.json",
                artifactRole: .watch,
                relatedFileNames: ["ambiguous-watch.json"],
                decisionReason: "Candidate A"
            ),
            rootDirectoryOverride: harness.journalRoot
        )
        try CaptureJournalStore.append(
            CaptureJournalEntry(
                timestamp: Date(timeIntervalSince1970: 1_720_001_021),
                storageKind: .relayedWatch,
                kind: .artifactQuarantined,
                message: "Ambiguous quarantined watch artifact.",
                sessionID: "session-b",
                takeID: "take-002",
                transactionID: CaptureJournalEntry.transactionID(sessionID: "session-b", takeID: "take-002"),
                fileName: "ambiguous-watch.json",
                artifactRole: .watch,
                relatedFileNames: ["ambiguous-watch.json"],
                decisionReason: "Candidate B"
            ),
            rootDirectoryOverride: harness.journalRoot
        )

        let store = StagingInspectorStore(
            context: harness.makeContext(statusText: { "Review quarantine." }),
            auditRootDirectoryOverride: harness.auditRoot,
            journalRootDirectoryOverride: harness.journalRoot
        )

        let item = try XCTUnwrap(store.quarantineItems.first)
        XCTAssertEqual(store.ambiguousQuarantineCount, 1)
        XCTAssertEqual(store.restorableQuarantineCount, 0)
        XCTAssertTrue(item.isRestoreAmbiguous)
        XCTAssertTrue(item.nextActionText.localizedCaseInsensitiveContains("conflicting origin"))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func makeStagingOperationsHarness(storageKind: StagedCaptureStorageKind) throws -> StagingOperationsHarness {
        let root = try makeTemporaryDirectory()
        let captureRoot = root.appendingPathComponent(storageKind.rawValue, isDirectory: true)
        let auditRoot = root.appendingPathComponent("audit", isDirectory: true)
        let journalRoot = root.appendingPathComponent("journal", isDirectory: true)
        try FileManager.default.createDirectory(at: captureRoot, withIntermediateDirectories: true)
        return StagingOperationsHarness(
            storageKind: storageKind,
            captureRoot: captureRoot,
            auditRoot: auditRoot,
            journalRoot: journalRoot
        )
    }

    private func makeRecordingSidecar(
        sessionID: String,
        takeIdentity: TakeIdentity,
        mediaURL: URL,
        sidecarURL: URL,
        startedAt: Date
    ) throws -> CaptureCore.LocalRecordingSidecar {
        let config = CaptureSessionConfig(
            performerName: "DJ Alpha",
            bpm: 70,
            scratchType: .babyScratch,
            drillMode: .fullCapture,
            takeDurationSeconds: 1,
            takeCount: 2,
            handedness: .right,
            notes: "phase2",
            sessionID: sessionID,
            createdAt: startedAt,
            updatedAt: startedAt
        )
        return CaptureCore.LocalRecordingSidecar.recording(
            sessionID: sessionID,
            sessionConfig: config,
            takeIdentity: takeIdentity,
            files: CaptureCore.LocalRecordingFiles(
                baseName: mediaURL.deletingPathExtension().lastPathComponent,
                mediaURL: mediaURL,
                sidecarURL: sidecarURL
            ),
            recordingRole: "guided_capture",
            platform: "macOS",
            appSurface: "mac_desktop",
            sourceDeviceName: "ScratchLab Mac",
            startedAt: startedAt
        )
    }

    private func makeCompletedSidecar(
        sessionID: String,
        takeIdentity: TakeIdentity,
        mediaURL: URL,
        sidecarURL: URL,
        createdAt: Date = Date(timeIntervalSince1970: 1_720_000_300)
    ) throws {
        let completed = try makeRecordingSidecar(
            sessionID: sessionID,
            takeIdentity: takeIdentity,
            mediaURL: mediaURL,
            sidecarURL: sidecarURL,
            startedAt: createdAt
        ).finalized(
            endedAt: createdAt.addingTimeInterval(1),
            mediaFileName: mediaURL.lastPathComponent,
            captureErrorDescription: nil
        )
        try completed.encodedData().write(to: sidecarURL, options: .atomic)
    }

    private func makeWatchSession(
        sessionID: String,
        takeID: String,
        syncState: CaptureWatchSyncState
    ) -> WatchMotionCaptureSession {
        let samples = (0..<12).map { index in
            WatchMotionSample(
                elapsedTime: Double(index) * 0.02,
                coreMotionTimestamp: Double(index) * 0.02,
                attitudeRoll: 0,
                attitudePitch: 0,
                attitudeYaw: 0,
                quaternionX: 0,
                quaternionY: 0,
                quaternionZ: 0,
                quaternionW: 1,
                gravityX: 0,
                gravityY: -1,
                gravityZ: 0,
                userAccelerationX: 0,
                userAccelerationY: 0,
                userAccelerationZ: 0,
                rotationRateX: 0,
                rotationRateY: 0,
                rotationRateZ: 0
            )
        }
        return WatchMotionCaptureSession(
            sessionID: sessionID,
            takeID: takeID,
            commandID: "command-\(takeID)",
            requestedAt: Date(timeIntervalSince1970: 1_720_000_300),
            acknowledgedAt: syncState == .acknowledged ? Date(timeIntervalSince1970: 1_720_000_300.2) : nil,
            syncState: syncState,
            sourceDeviceName: "Apple Watch",
            sampleRateHz: 50,
            startedAt: Date(timeIntervalSince1970: 1_720_000_300),
            endedAt: Date(timeIntervalSince1970: 1_720_000_301),
            deviceRecordedAtStart: Date(timeIntervalSince1970: 1_720_000_300),
            deviceRecordedAtEnd: Date(timeIntervalSince1970: 1_720_000_301),
            appVersion: "1.0",
            timingMetadata: nil,
            samples: samples
        )
    }
}

private extension CaptureReliabilityPhase1CoreTests {
    func projectRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func makeCanonicalPackage(rootURL: URL) throws -> SessionExportPackage {
        try makeCanonicalPackage(rootURL: rootURL, scratchType: .babyScratch)
    }

    func makeCanonicalPackage(
        rootURL: URL,
        useRealMedia: Bool
    ) throws -> SessionExportPackage {
        try makeCanonicalPackage(rootURL: rootURL, scratchType: .babyScratch, useRealMedia: useRealMedia)
    }

    func makeCanonicalPackage(
        rootURL: URL,
        scratchType: CaptureSessionScratchType,
        useRealMedia: Bool = false
    ) throws -> SessionExportPackage {
        let sessionID = "phase1-canonical-session"
        let createdAt = Date(timeIntervalSince1970: 1_710_000_000)
        let performerName = "DJ Alpha"
        var takes: [SessionExportTake] = []
        var decodedSidecars: [CaptureCore.LocalRecordingSidecar] = []

        for (index, bpm) in [70, 90, 110].enumerated() {
            let takeNumber = index + 1
            let takeIdentity = CaptureCore.LocalRecordingNaming.takeIdentity(sessionID: sessionID, takeNumber: takeNumber)
            let videoURL = rootURL.appendingPathComponent("source-\(takeNumber).mov")
            let audioURL = rootURL.appendingPathComponent("source-\(takeNumber).wav")
            let sidecarURL = rootURL.appendingPathComponent("source-\(takeNumber).json")

            if useRealMedia {
                try writeTestMOV(at: videoURL)
                try writeTestWAV(at: audioURL)
            } else {
                try writePlaceholderFile(at: videoURL, contents: Data("mov-\(takeNumber)".utf8))
                try writePlaceholderFile(at: audioURL, contents: Data("wav-\(takeNumber)".utf8))
            }

            try writeFinalizedSidecar(
                to: sidecarURL,
                sessionID: sessionID,
                takeIdentity: takeIdentity,
                mediaURL: videoURL,
                performerName: performerName,
                bpm: bpm,
                createdAt: createdAt,
                scratchType: scratchType
            )
            let sidecarData = try Data(contentsOf: sidecarURL)
            let decodedSidecar = try JSONDecoder.captureCoreDecoder.decode(
                CaptureCore.LocalRecordingSidecar.self,
                from: sidecarData
            )
            decodedSidecars.append(decodedSidecar)

            let watchCapture = bpm == 70 ? makeWatchSession(sessionID: sessionID, takeID: takeIdentity.takeID) : nil
            takes.append(
                SessionExportTake(
                    takeID: takeIdentity.takeID,
                    takeNumber: takeNumber,
                    bpm: bpm,
                    mediaURL: videoURL,
                    audioArtifactURL: audioURL,
                    sidecarURL: sidecarURL,
                    watchCaptureSession: watchCapture,
                    drillName: nil,
                    duration: 1,
                    quality: nil,
                    comboTagged: false,
                    audioPresent: true,
                    motionPresent: watchCapture != nil,
                    syncStatus: watchCapture != nil ? "acknowledged" : nil,
                    recordingStatus: "completed",
                    verbalSlateUsed: true,
                    syncClapUsed: true,
                    note: "take \(takeNumber) note"
                )
            )
        }

        let metadataConfig = SessionExportMetadataResolver.mergedConfig(
            preferredConfig: nil,
            seedSidecar: try XCTUnwrap(decodedSidecars.first),
            sidecars: decodedSidecars,
            fallbackSessionID: sessionID,
            createdAt: createdAt,
            updatedAt: createdAt,
            takeCount: takes.count,
            totalDurationSeconds: 3
        )
        let metadata = SessionExportMetadata(
            config: metadataConfig,
            workflow: "guided_capture",
            platform: "macOS",
            sessionName: "Canonical Session",
            totalDurationSeconds: 3
        )

        return SessionExportPackage(
            metadata: metadata,
            takes: takes,
            calibrationData: nil
        )
    }

    func makeLocalRecordingTake(
        in root: URL,
        sessionID: String,
        takeNumber: Int,
        bpm: Int? = 95,
        createdAt: Date,
        scratchType: CaptureSessionScratchType? = .babyScratch,
        captureMode: CaptureSessionCaptureMode = .timedClick,
        beatEngineMode: BeatEngineMode = .clickTrack,
        timingPrintedToRecording: TimingPrintedToRecordingState = .unknown,
        captureTiming: CaptureTimingMetadata? = nil,
        useRealMedia: Bool = false
    ) throws -> URL {
        let baseName = CaptureCore.LocalRecordingNaming.baseName(
            sessionID: sessionID,
            takeNumber: takeNumber,
            roleLabel: "guided"
        )
        let videoURL = root.appendingPathComponent(baseName).appendingPathExtension("mov")
        let audioURL = root.appendingPathComponent(baseName).appendingPathExtension("wav")
        let sidecarURL = root.appendingPathComponent(baseName).appendingPathExtension("json")
        if useRealMedia {
            try writeTestMOV(at: videoURL)
            try writeTestWAV(at: audioURL)
        } else {
            try writePlaceholderFile(at: videoURL, contents: Data("mov-\(takeNumber)".utf8))
            try writePlaceholderFile(at: audioURL, contents: Data("wav-\(takeNumber)".utf8))
        }
        try writeFinalizedSidecar(
            to: sidecarURL,
            sessionID: sessionID,
            takeIdentity: CaptureCore.LocalRecordingNaming.takeIdentity(sessionID: sessionID, takeNumber: takeNumber),
            mediaURL: videoURL,
            performerName: "DJ Alpha",
            bpm: bpm,
            createdAt: createdAt,
            scratchType: scratchType,
            captureMode: captureMode,
            beatEngineMode: beatEngineMode,
            timingPrintedToRecording: timingPrintedToRecording,
            captureTiming: captureTiming
        )
        return videoURL
    }

    func makeTestSidecar(
        in root: URL,
        sessionID: String,
        takeNumber: Int,
        captureMode: CaptureSessionCaptureMode = .timedClick
    ) throws -> CaptureCore.LocalRecordingSidecar {
        let baseName = CaptureCore.LocalRecordingNaming.baseName(
            sessionID: sessionID,
            takeNumber: takeNumber,
            roleLabel: "camA"
        )
        let mediaURL = root.appendingPathComponent(baseName).appendingPathExtension("mov")
        let sidecarURL = root.appendingPathComponent(baseName).appendingPathExtension("json")
        return CaptureCore.LocalRecordingSidecar.recording(
            sessionID: sessionID,
            sessionConfig: CaptureSessionConfig(
                performerName: "DJ Alpha",
                bpm: 95,
                scratchType: .babyScratch,
                drillMode: .fullCapture,
                captureMode: captureMode,
                takeDurationSeconds: 1,
                takeCount: 1,
                handedness: .right,
                notes: "",
                sessionID: sessionID,
                createdAt: Date(timeIntervalSince1970: 1_720_000_500),
                updatedAt: Date(timeIntervalSince1970: 1_720_000_500)
            ),
            takeIdentity: CaptureCore.LocalRecordingNaming.takeIdentity(sessionID: sessionID, takeNumber: takeNumber),
            files: CaptureCore.LocalRecordingFiles(
                baseName: baseName,
                mediaURL: mediaURL,
                sidecarURL: sidecarURL
            ),
            recordingRole: "guided_capture",
            platform: "iOS",
            appSurface: "ScratchLab Companion Camera",
            sourceDeviceName: "Test Device",
            startedAt: Date(timeIntervalSince1970: 1_720_000_500)
        ).finalized(
            endedAt: Date(timeIntervalSince1970: 1_720_000_505),
            mediaFileName: mediaURL.lastPathComponent,
            captureErrorDescription: nil
        )
    }

    func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    func writePlaceholderFile(at url: URL, contents: Data) throws {
        try contents.write(to: url, options: .atomic)
    }

    func writeTestWAV(at url: URL) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024),
              let channelData = buffer.floatChannelData else {
            throw SessionExportError.unableToPrepareExport
        }

        buffer.frameLength = 1_024
        channelData[0].initialize(repeating: 0, count: Int(buffer.frameLength))

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    func writeTestMOV(at url: URL) throws {
        try? FileManager.default.removeItem(at: url)

        let width = 64
        let height = 64
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height
            ]
        )
        input.expectsMediaDataInRealTime = false

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attributes
        )

        guard writer.canAdd(input) else {
            throw SessionExportError.unableToPrepareExport
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw writer.error ?? SessionExportError.unableToPrepareExport
        }
        writer.startSession(atSourceTime: .zero)

        for frameIndex in 0..<3 {
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.01)
            }

            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                nil,
                &pixelBuffer
            )
            guard let pixelBuffer else {
                throw SessionExportError.unableToPrepareExport
            }

            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            let baseAddress = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer))
                .assumingMemoryBound(to: UInt32.self)
            let pixelsPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer) / MemoryLayout<UInt32>.size
            let shade = UInt32(48 + frameIndex)
            let color = UInt32(255 << 24) | (shade << 16) | (shade << 8) | shade

            for y in 0..<height {
                let row = baseAddress.advanced(by: y * pixelsPerRow)
                for x in 0..<width {
                    row[x] = color
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

            let presentationTime = CMTime(value: CMTimeValue(frameIndex), timescale: 30)
            guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                throw writer.error ?? SessionExportError.unableToPrepareExport
            }
        }

        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting {
            semaphore.signal()
        }
        semaphore.wait()

        guard writer.status == .completed else {
            throw writer.error ?? SessionExportError.unableToPrepareExport
        }
    }

    func writeFinalizedSidecar(
        to sidecarURL: URL,
        sessionID: String,
        takeIdentity: TakeIdentity,
        mediaURL: URL,
        performerName: String,
        bpm: Int?,
        createdAt: Date,
        scratchType: CaptureSessionScratchType? = .babyScratch,
        captureMode: CaptureSessionCaptureMode = .timedClick,
        beatEngineMode: BeatEngineMode = .clickTrack,
        timingPrintedToRecording: TimingPrintedToRecordingState = .unknown,
        captureTiming: CaptureTimingMetadata? = nil
    ) throws {
        var config = CaptureSessionConfig(
            performerName: performerName,
            bpm: bpm,
            scratchType: scratchType,
            drillMode: .fullCapture,
            captureMode: captureMode,
            beatEngineMode: beatEngineMode,
            timingPrintedToRecording: timingPrintedToRecording,
            takeDurationSeconds: 1,
            takeCount: 3,
            handedness: .right,
            notes: "session note",
            sessionID: sessionID,
            createdAt: createdAt,
            updatedAt: createdAt
        )
        config.applyCapturedTakeMetrics(takeCount: 3, totalDurationSeconds: 3, updatedAt: createdAt)
        let sidecar = CaptureCore.LocalRecordingSidecar.recording(
            sessionID: sessionID,
            sessionConfig: config,
            takeIdentity: takeIdentity,
            files: CaptureCore.LocalRecordingFiles(
                baseName: mediaURL.deletingPathExtension().lastPathComponent,
                mediaURL: mediaURL,
                sidecarURL: sidecarURL
            ),
            recordingRole: "guided_capture",
            platform: "macOS",
            appSurface: "mac_desktop",
            sourceDeviceName: "ScratchLab Mac",
            captureTiming: captureTiming,
            startedAt: createdAt
        ).finalized(
            endedAt: createdAt.addingTimeInterval(1),
            mediaFileName: mediaURL.lastPathComponent,
            captureErrorDescription: nil
        )
        try sidecar.encodedData().write(to: sidecarURL, options: .atomic)
    }

    func unzipArchive(_ archiveURL: URL, to destinationURL: URL) throws -> URL {
        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        try FileManager.default.unzipItem(at: archiveURL, to: destinationURL)
        let contents = try FileManager.default.contentsOfDirectory(
            at: destinationURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return try XCTUnwrap(contents.first(where: {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }))
    }

    func decodeSessionMetadataDocument(from archiveRoot: URL) throws -> SessionExportMetadataDocument {
        let data = try Data(
            contentsOf: archiveRoot.appendingPathComponent("manifests/session_metadata.json")
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionExportMetadataDocument.self, from: data)
    }

    func decodeExportMetadataDocument(from archiveRoot: URL) throws -> SessionExportArtifactMetadataDocument {
        let data = try Data(
            contentsOf: archiveRoot.appendingPathComponent("manifests/export_metadata.json")
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionExportArtifactMetadataDocument.self, from: data)
    }

    func makeWatchSession(sessionID: String, takeID: String) -> WatchMotionCaptureSession {
        let samples = (0..<12).map { index in
            WatchMotionSample(
                elapsedTime: Double(index) * 0.02,
                coreMotionTimestamp: Double(index) * 0.02,
                attitudeRoll: 0.1,
                attitudePitch: 0.2,
                attitudeYaw: 0.3,
                quaternionX: 0.0,
                quaternionY: 0.0,
                quaternionZ: 0.0,
                quaternionW: 1.0,
                gravityX: 0.0,
                gravityY: -1.0,
                gravityZ: 0.0,
                userAccelerationX: 0.0,
                userAccelerationY: 0.0,
                userAccelerationZ: 0.0,
                rotationRateX: 0.0,
                rotationRateY: 0.0,
                rotationRateZ: 0.0
            )
        }

        return WatchMotionCaptureSession(
            id: UUID(),
            sessionID: sessionID,
            takeID: takeID,
            commandID: "watch-command-\(takeID)",
            requestedAt: Date(timeIntervalSince1970: 1_710_000_000),
            acknowledgedAt: Date(timeIntervalSince1970: 1_710_000_000.1),
            syncState: .acknowledged,
            sourceDeviceName: "Apple Watch",
            sampleRateHz: 50,
            startedAt: Date(timeIntervalSince1970: 1_710_000_000),
            endedAt: Date(timeIntervalSince1970: 1_710_000_001),
            deviceRecordedAtStart: Date(timeIntervalSince1970: 1_710_000_000),
            deviceRecordedAtEnd: Date(timeIntervalSince1970: 1_710_000_001),
            appVersion: "1.0",
            timingMetadata: nil,
            samples: samples
        )
    }

    @MainActor
    func makeRoutineSessionStore() throws -> RoutineSessionStore {
        let root = try makeTemporaryDirectory()
        let storageURL = root.appendingPathComponent("RoutineSessionDrafts.json")
        let defaults = try makeEphemeralUserDefaults()
        let historyKey = "RoutineSessionHistory.\(UUID().uuidString)"
        return RoutineSessionStore(
            storageURL: storageURL,
            sessionOpenHistoryDefaults: defaults,
            sessionOpenHistoryKey: historyKey
        )
    }

    func writeRoutineSessionSnapshot(
        _ snapshot: RoutineSessionDraftStoreSnapshot,
        to storageURL: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(snapshot)
        try data.write(to: storageURL, options: .atomic)
    }

    func makeEphemeralUserDefaults() throws -> UserDefaults {
        let suiteName = "PracticeBeatStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw XCTSkip("Unable to create isolated user defaults suite.")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

}

private struct StagingOperationsHarness {
    let storageKind: StagedCaptureStorageKind
    let captureRoot: URL
    let auditRoot: URL
    let journalRoot: URL

    func makeContext(
        statusText: @escaping () -> String,
        actionTitle: String? = nil,
        runAction: (() -> Void)? = nil,
        validationReportProvider: ((String, [CaptureTakeAuditSummary], URL) -> SessionValidationReport?)? = nil
    ) -> StagingInspectorContext {
        StagingInspectorContext(
            storageKind: storageKind,
            title: storageKind.title,
            actionTitle: actionTitle,
            captureDirectoryURLProvider: { captureRoot },
            statusTextProvider: statusText,
            runAction: runAction,
            validationReportProvider: validationReportProvider
        )
    }
}

private extension JSONDecoder {
    static var captureCoreDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
